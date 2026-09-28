import BerryDriverKit
import BerryTunnel
import Foundation

/// Maps a profile's driver ID to the SQL driver the helper may open.
///
/// Only the SQL family (which includes DynamoDB) is reachable from the
/// helper; an ID with no SQL driver is rejected before any connection opens.
public struct MCPDriverRegistries: Sendable {
    public let sql: @Sendable (DriverID) -> (any DatabaseDriver.Type)?

    public init(sql: @escaping @Sendable (DriverID) -> (any DatabaseDriver.Type)?) {
        self.sql = sql
    }

    public static let registered = MCPDriverRegistries(sql: DriverRegistry.driverType)
}

/// The address a driver connects to, possibly a local SSH tunnel port, and
/// the action that tears that tunnel down.
public struct MCPTunnelEndpoint: Sendable {
    public let config: ConnectionConfig
    public let close: @Sendable () async -> Void

    public init(config: ConnectionConfig, close: @escaping @Sendable () async -> Void = {}) {
        self.config = config
        self.close = close
    }
}

/// Opens SQL sessions for the coordinator.
///
/// A session never leaves the factory before database-enforced read-only
/// state is established; on any failure the opened connection and tunnel
/// are closed before the error propagates.
public struct MCPConnectionFactories: Sendable {
    public typealias SQLReadOnlyEnforcer = @Sendable (MCPConnectionProfile, any DriverConnection) async throws -> Void
    public let sql: MCPConnectionCoordinator.SQLFactory

    // Defaults are nil rather than function references: a public default-argument closure is
    // re-emitted in each client module, and differing -Onone copies corrupt the task allocator.
    public init(
        registries: MCPDriverRegistries = .registered,
        enforceSQLReadOnly: SQLReadOnlyEnforcer? = nil,
        openTunnel: (@Sendable (ConnectionConfig) async throws -> MCPTunnelEndpoint)? = nil
    ) {
        let enforceSQLReadOnly = enforceSQLReadOnly ?? { try await Self.enforceSQLReadOnly(profile: $0, connection: $1) }
        let openTunnel = openTunnel ?? { try await Self.openTunnel($0) }
        sql = { profile in
            guard let driver = registries.sql(profile.driverID) else {
                throw MCPConnectionCoordinatorError.wrongDriverFamily(profile.driverID)
            }
            let endpoint = try await openTunnel(profile.config)
            let connection: any DriverConnection
            do {
                connection = try await driver.init().connect(endpoint.config)
            } catch {
                await endpoint.close()
                throw error
            }
            let lifecycle = MCPConnectionLifecycle(
                cancel: { connection.cancelCurrentQuery() },
                closeConnection: { await connection.close() },
                closeTunnel: endpoint.close
            )
            do {
                try await enforceSQLReadOnly(profile, connection)
                return MCPSQLSession(connection: connection, recordsHistory: false, lifecycle: lifecycle)
            } catch {
                try? await lifecycle.close()
                throw error
            }
        }
    }

    /// Establishes database-enforced read-only state before a connection can
    /// escape its factory. Callers may inject a dialect-specific implementation
    /// as more drivers acquire a reliable session-level read-only primitive.
    public static func enforceSQLReadOnly(
        profile: MCPConnectionProfile,
        connection: any DriverConnection
    ) async throws {
        guard profile.driverID == .sqlite else {
            throw MCPConnectionCoordinatorError.sqlReadOnlyEnforcementUnavailable(profile.driverID)
        }
        for try await _ in connection.execute("PRAGMA query_only = ON") {}
    }

    /// Opens an SSH tunnel when the profile has one and returns the local
    /// endpoint to connect to; otherwise returns the profile's own endpoint.
    public static func openTunnel(_ config: ConnectionConfig) async throws -> MCPTunnelEndpoint {
        guard let ssh = config.ssh else { return MCPTunnelEndpoint(config: config) }
        guard let host = config.host else { throw DriverError.connectionFailed("Missing host") }
        let tunnel = try await SSHTunnel.open(ssh, targetHost: host, targetPort: config.port ?? defaultPort(config.driver))
        return MCPTunnelEndpoint(
            config: config.replacingEndpoint(host: "127.0.0.1", port: tunnel.localPort),
            close: { await tunnel.close() }
        )
    }

    private static func defaultPort(_ driver: DriverID) -> Int {
        switch driver {
        case .postgres: 5432
        case .mysql: 3306
        case .redis: 6379
        case .sqlserver: 1433
        case .mongodb: 27017
        case .qdrant: 6333
        case .elasticsearch: 9200
        case .dynamodb: 443
        case .sqlite: 0
        }
    }
}

/// Cancel and close actions for one opened connection and its tunnel.
///
/// `cancel` runs at most once. `close` runs the connection close and then
/// the tunnel close exactly once; concurrent and later callers await that
/// same close and observe its result.
public actor MCPConnectionLifecycle {
    private let cancelAction: @Sendable () async -> Void
    private let closeConnectionAction: @Sendable () async throws -> Void
    private let closeTunnelAction: @Sendable () async -> Void
    private var didCancel = false
    private var closeTask: Task<Void, Error>?

    public init(
        cancel: @escaping @Sendable () async -> Void,
        closeConnection: @escaping @Sendable () async throws -> Void,
        closeTunnel: @escaping @Sendable () async -> Void = {}
    ) {
        cancelAction = cancel
        closeConnectionAction = closeConnection
        closeTunnelAction = closeTunnel
    }

    public func cancel() async {
        guard !didCancel else { return }
        didCancel = true
        await cancelAction()
    }

    public func close() async throws {
        if let closeTask {
            return try await closeTask.value
        }
        let closeConnectionAction = self.closeConnectionAction
        let closeTunnelAction = self.closeTunnelAction
        let task = Task {
            do {
                try await closeConnectionAction()
                await closeTunnelAction()
            } catch {
                await closeTunnelAction()
                throw error
            }
        }
        closeTask = task
        try await task.value
    }
}

/// A read-only SQL connection lent to one request's operation. The
/// coordinator owns its lifecycle; the operation must not close it.
public struct MCPSQLSession: Sendable {
    public let connection: any DriverConnection
    public let recordsHistory: Bool
    public let lifecycle: MCPConnectionLifecycle

    public init(connection: any DriverConnection, recordsHistory: Bool = false, lifecycle: MCPConnectionLifecycle) {
        self.connection = connection
        self.recordsHistory = recordsHistory
        self.lifecycle = lifecycle
    }
}

public enum MCPConnectionCoordinatorError: Error, Equatable, Sendable {
    case duplicateRequestID(String)
    case wrongDriverFamily(DriverID)
    case sqlReadOnlyEnforcementUnavailable(DriverID)
    case shuttingDown
}

/// Result of a shutdown: requests whose work did not finish before the deadline.
public struct MCPShutdownReport: Equatable, Sendable {
    public let abandonedRequestIDs: [String]

    public init(abandonedRequestIDs: [String]) {
        self.abandonedRequestIDs = abandonedRequestIDs
    }
}

/// Owns every connection and tunnel the helper opens.
///
/// Each request gets its own connection, resolved against the project on
/// every call, and closed exactly once on success, error, cancellation or
/// shutdown. No request starts after `closeAll()` begins.
public actor MCPConnectionCoordinator {
    public typealias SQLFactory = @Sendable (MCPConnectionProfile) async throws -> MCPSQLSession

    private struct ActiveRequest {
        var cancelTask: @Sendable () -> Void
        var awaitCompletion: @Sendable () async -> Void
        var lifecycle: MCPConnectionLifecycle?
        var cancelled: Bool
    }

    private let resolver: MCPProjectResolver
    private let sqlFactory: SQLFactory
    private let shutdownDeadline: Duration
    private var active: [String: ActiveRequest] = [:]
    private var shuttingDown = false

    private actor CompletionSignal {
        private var completed = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !completed else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func complete() {
            guard !completed else { return }
            completed = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor FinishedSet {
        private(set) var ids = Set<String>()
        var count: Int { ids.count }
        func insert(_ id: String) { ids.insert(id) }
    }

    public init(
        resolver: MCPProjectResolver,
        sqlFactory: @escaping SQLFactory,
        shutdownDeadline: Duration = .seconds(5)
    ) {
        self.resolver = resolver
        self.sqlFactory = sqlFactory
        self.shutdownDeadline = shutdownDeadline
    }

    public init(
        resolver: MCPProjectResolver,
        factories: MCPConnectionFactories = MCPConnectionFactories(),
        shutdownDeadline: Duration = .seconds(5)
    ) {
        self.init(resolver: resolver, sqlFactory: factories.sql, shutdownDeadline: shutdownDeadline)
    }

    /// Runs `operation` on a fresh read-only session for a profile with live
    /// reads enabled, and closes that session before returning or throwing.
    public func withSQLSession<T: Sendable>(
        requestID: String, profileID: UUID,
        operation: @escaping @Sendable (MCPSQLSession) async throws -> T
    ) async throws -> T {
        try await run(requestID: requestID) { [resolver, sqlFactory] in
            let profile = try await resolver.resolve(profileID: profileID, access: .liveRead)
            try Task.checkCancellation()
            let session = try await sqlFactory(profile)
            return (session.lifecycle, { try await operation(session) })
        }
    }

    /// Cancels one in-flight request; its connection is closed as it unwinds.
    public func cancel(requestID: String) async {
        guard var request = active[requestID] else { return }
        request.cancelled = true
        active[requestID] = request
        request.cancelTask()
        await request.lifecycle?.cancel()
    }

    /// Cancels every request, closes what it can, and returns within
    /// `shutdownDeadline` even if a driver ignores cancellation. The helper
    /// exits right after this, so abandoned work cannot outlive the process.
    public func closeAll() async -> MCPShutdownReport {
        shuttingDown = true
        for id in Array(active.keys) {
            active[id]?.cancelled = true
        }
        let requests = active
        for request in requests.values { request.cancelTask() }
        for request in requests.values { await request.lifecycle?.cancel() }

        // Each request's own completion covers activate/finish closing a
        // resource that appeared after shutdown began.
        let finished = FinishedSet()
        let deadline = CompletionSignal()
        for (id, request) in requests {
            Task {
                await request.awaitCompletion()
                await finished.insert(id)
                if await finished.count == requests.count { await deadline.complete() }
            }
        }
        if requests.isEmpty { await deadline.complete() }
        let timeout = shutdownDeadline
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await deadline.complete()
        }
        await deadline.wait()
        timer.cancel()
        let done = await finished.ids
        return MCPShutdownReport(abandonedRequestIDs: requests.keys.filter { !done.contains($0) }.sorted())
    }

    private func run<T: Sendable>(
        requestID: String,
        prepare: @escaping @Sendable () async throws -> (
            lifecycle: MCPConnectionLifecycle,
            operation: @Sendable () async throws -> T
        )
    ) async throws -> T {
        guard !shuttingDown else { throw MCPConnectionCoordinatorError.shuttingDown }
        guard active[requestID] == nil else {
            throw MCPConnectionCoordinatorError.duplicateRequestID(requestID)
        }
        // Reserve before resolution/opening. ConnectionManager cannot provide
        // this process-scoped pending-request lifecycle or late-open cleanup.
        let completion = CompletionSignal()
        active[requestID] = ActiveRequest(
            cancelTask: {},
            awaitCompletion: { await completion.wait() },
            lifecycle: nil,
            cancelled: false
        )
        let task = Task {
            let prepared = try await prepare()
            guard await self.activate(requestID: requestID, lifecycle: prepared.lifecycle) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            return try await prepared.operation()
        }
        active[requestID]?.cancelTask = { task.cancel() }
        do {
            let value = try await task.value
            do {
                try await finish(requestID: requestID)
                await completion.complete()
                return value
            } catch {
                await completion.complete()
                throw error
            }
        } catch {
            try? await finish(requestID: requestID)
            await completion.complete()
            throw error
        }
    }

    private func activate(requestID: String, lifecycle: MCPConnectionLifecycle) async -> Bool {
        guard var request = active[requestID], !shuttingDown, !request.cancelled else {
            await lifecycle.cancel()
            try? await lifecycle.close()
            return false
        }
        request.lifecycle = lifecycle
        active[requestID] = request
        return true
    }

    private func finish(requestID: String) async throws {
        let request = active.removeValue(forKey: requestID)
        try await request?.lifecycle?.close()
    }
}
