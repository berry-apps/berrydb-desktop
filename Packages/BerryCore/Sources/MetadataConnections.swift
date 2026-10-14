import BerryDriverKit
import Foundation

/// One extra connection per open session, used only to read catalog
/// metadata so a harvest never queues behind the user's own statements.
/// Reuses the session's configuration and, when present, its SSH tunnel's
/// local port; never prompts for a credential or opens a second tunnel.
public actor MetadataConnections {
    /// Upper bound for one metadata statement on engines that can enforce it;
    /// see `applyTimeout(on:driver:)`.
    public static let statementTimeout: Duration = .seconds(15)

    private struct Opened: Sendable {
        let connection: any DriverConnection
        let timeoutApplied: Bool
    }

    /// The open, or still opening, connection of each session. Callers await
    /// the one task, so a close that arrives mid-connect can wait for the
    /// connection to exist and close it, instead of leaving it open.
    private var opening: [UUID: Task<Opened, any Error>] = [:]
    /// Sessions closed most recently, oldest first. A pass or a statistics
    /// refresh can still ask for a session's connection after the session
    /// closed; opening one then would hold a connection nothing closes until
    /// the app quits. Session ids are never reused, so only the last few
    /// closes need remembering, and the list stays bounded.
    private var closed: [UUID] = []
    private static let closedMemory = 64
    private let driverType: @Sendable (DriverID) -> (any DatabaseDriver.Type)?

    public init() { self.init(driverType: DriverRegistry.driverType) }

    /// Takes the driver lookup so a test can supply a scripted driver without
    /// replacing a driver in the process-wide registry.
    init(driverType: @escaping @Sendable (DriverID) -> (any DatabaseDriver.Type)?) {
        self.driverType = driverType
    }

    /// The session's metadata connection, opened on first use and kept until
    /// `close(sessionID:)` or `closeAll()`. Throws `CancellationError` when
    /// the session was closed, before or while the connection was opening.
    public func connection(for session: Session) async throws -> any DriverConnection {
        guard !closed.contains(session.id) else { throw CancellationError() }
        let task: Task<Opened, any Error>
        if let existing = opening[session.id] {
            task = existing
        } else {
            task = Task { try await self.open(session) }
            opening[session.id] = task
        }
        let opened: Opened
        do {
            opened = try await task.value
        } catch {
            if opening[session.id] == task { opening[session.id] = nil }
            throw error
        }
        guard opening[session.id] == task else { throw CancellationError() }
        return opened.connection
    }

    public func close(sessionID: UUID) async {
        remember(closed: sessionID)
        guard let task = opening.removeValue(forKey: sessionID) else { return }
        await Self.closeWhenOpened(task)
    }

    /// Closes the session's connection, waiting for one still opening, and
    /// forgets it, so the next `connection(for:)` connects again. For a
    /// connection a pass found dead: unlike `close(sessionID:)`, the session
    /// stays open. A session already closed has nothing left to discard.
    public func discard(sessionID: UUID) async {
        guard let task = opening.removeValue(forKey: sessionID) else { return }
        await Self.closeWhenOpened(task)
    }

    public func closeAll() async {
        for sessionID in opening.keys { remember(closed: sessionID) }
        let tasks = opening.values
        opening.removeAll()
        for task in tasks {
            await Self.closeWhenOpened(task)
        }
    }

    var cachedSessionCount: Int { opening.count }

    private func remember(closed sessionID: UUID) {
        closed.append(sessionID)
        if closed.count > Self.closedMemory { closed.removeFirst(closed.count - Self.closedMemory) }
    }

    /// Whether the session's metadata connection bounds its statements, each
    /// on its own or through a session setting. Waits for a connection that is
    /// still opening.
    func timeoutApplied(sessionID: UUID) async -> Bool {
        guard let task = opening[sessionID], let opened = try? await task.value else { return false }
        return opened.timeoutApplied
    }

    private func open(_ session: Session) async throws -> Opened {
        let effective =
            session.tunnel.map {
                session.config.replacingEndpoint(host: "127.0.0.1", port: $0.localPort)
            } ?? session.config
        guard let driverType = driverType(effective.driver) else {
            throw DriverError.unsupported("Driver \(effective.driver.rawValue) is not registered")
        }
        let connection = try await driverType.init().connect(effective)
        let applied = await Self.applyTimeout(on: connection, driver: effective.driver)
        return Opened(connection: connection, timeoutApplied: applied)
    }

    /// A connect still in flight is awaited so the connection it produces is
    /// closed; a connect that failed has nothing to close.
    private static func closeWhenOpened(_ task: Task<Opened, any Error>) async {
        if case .success(let opened) = await task.result {
            await opened.connection.close()
        }
    }

    /// Bounds the statements of a connection that can do so on its own,
    /// which leaves nothing on the server session: on MySQL and MariaDB each
    /// statement, on PostgreSQL the statements of each pass or statistics
    /// refresh, which read in one transaction. Otherwise tries the driver's
    /// session statements in order and stops at the first one the server
    /// accepts. A session setting is a fallback with a known limit: a
    /// connection pooler in transaction mode gives the server session to other
    /// clients between transactions, so the setting can follow the session
    /// away from this connection and reach another client
    /// (https://www.pgbouncer.org/features.html lists SET as never supported
    /// in transaction pooling). The timeout is a safeguard, not a requirement:
    /// a server that rejects every alternative keeps its connection, which
    /// then runs without a bound. Nothing is logged, because a rejection
    /// message can carry details of the server.
    private static func applyTimeout(on connection: any DriverConnection, driver: DriverID) async -> Bool {
        if let bounding = connection as? any StatementBoundingConnection,
           await bounding.boundEachStatement(by: statementTimeout) {
            return true
        }
        for statement in timeoutStatementAlternatives(for: driver) {
            do {
                for try await _ in connection.execute(statement) {}
                return true
            } catch {
                // A server without this variable rejects the statement.
            }
        }
        return false
    }

    /// The session statements that bound a metadata query on a connection that
    /// cannot bound each statement on its own, in the order they are tried.
    /// PostgreSQL always can, so only MySQL is listed: a MySQL server before
    /// 8.0.3, a MariaDB server before 10.1.2, or one whose version the driver
    /// cannot read. Engines not listed run without a timeout.
    ///
    /// - MySQL: `max_execution_time` is in milliseconds and bounds read-only
    ///   `SELECT` statements only, so a `SHOW` statement is not covered.
    ///   https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html#sysvar_max_execution_time
    /// - A server that rejects the MySQL variable gets the second MySQL
    ///   alternative. MariaDB documents `max_statement_time` for that purpose:
    ///   seconds, global or session scope, every query.
    ///   https://mariadb.com/kb/en/server-system-variables/#max_statement_time
    static func timeoutStatementAlternatives(for driver: DriverID) -> [String] {
        let seconds = statementTimeout.components.seconds
        switch driver {
        case .mysql:
            return [
                "SET SESSION max_execution_time = \(seconds * 1000)",
                "SET SESSION max_statement_time = \(seconds)",
            ]
        default: return []
        }
    }
}
