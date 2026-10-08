import BerryDriverKit
import BerryTunnel
import Foundation

/// Maps a profile's driver ID to the SQL driver the helper may open.
///
/// Only the SQL family (which includes DynamoDB) is reachable from the
/// helper; an ID with no SQL driver is rejected before any connection opens.
public struct MCPDriverRegistries: Sendable {
    public let sql: @Sendable (DriverID) -> (any DatabaseDriver.Type)?

    /// Uses `sql` as the only lookup; returning nil rejects the profile.
    public init(sql: @escaping @Sendable (DriverID) -> (any DatabaseDriver.Type)?) {
        self.sql = sql
    }

    /// The SQL drivers registered with `DriverRegistry` in this process.
    public static let registered = MCPDriverRegistries(sql: DriverRegistry.driverType)
}

/// The address a driver connects to, possibly a local SSH tunnel port, and
/// the action that tears that tunnel down.
public struct MCPTunnelEndpoint: Sendable {
    public let config: ConnectionConfig
    public let close: @Sendable () async -> Void

    /// An endpoint whose `close` must run once the connection using it is
    /// closed; the default does nothing, for endpoints without a tunnel.
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

    /// Builds the SQL factory. `enforceSQLReadOnly` defaults to
    /// `enforceSQLReadOnly(profile:connection:)`, which only admits SQLite;
    /// `openTunnel` defaults to `openTunnel(_:)`. Either override must keep
    /// the guarantee that no session escapes without read-only enforcement.
    // A public default-argument closure is re-emitted in every client module; the linker can pair one copy's
    // body with another copy's async context size. Parameterless `{}` defaults emit identical copies, so they stay.
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
/// The driver's cancel and close never run concurrently: the cancel action
/// runs at most once and never after close started, and close waits for an
/// in-flight cancel before closing the connection. Close runs the
/// connection close and then the tunnel close exactly once; concurrent and
/// later callers await that same close and observe its result.
public actor MCPConnectionLifecycle {
    private let cancelAction: @Sendable () async -> Void
    private let closeConnectionAction: @Sendable () async throws -> Void
    private let closeTunnelAction: @Sendable () async -> Void
    private var cancelTask: Task<Void, Never>?
    private var closeTask: Task<Void, Error>?

    /// `cancel` interrupts the connection's running query; `closeConnection`
    /// and `closeTunnel` release the connection and then its tunnel.
    public init(
        cancel: @escaping @Sendable () async -> Void,
        closeConnection: @escaping @Sendable () async throws -> Void,
        closeTunnel: @escaping @Sendable () async -> Void = {}
    ) {
        cancelAction = cancel
        closeConnectionAction = closeConnection
        closeTunnelAction = closeTunnel
    }

    /// Runs the cancel action at most once and never once `close()` has
    /// started; returns when the action returns. Later calls return at once.
    public func cancel() async {
        await startCancel()?.value
    }

    /// Records the cancel as a task before any suspension, so a close that
    /// starts afterwards waits for it; nil when a cancel ran or close started.
    private func startCancel() -> Task<Void, Never>? {
        guard cancelTask == nil, closeTask == nil else { return nil }
        let cancelAction = self.cancelAction
        let task = Task { await cancelAction() }
        cancelTask = task
        return task
    }

    /// Closes the connection, then the tunnel, exactly once, after any
    /// in-flight cancel has returned. The close is recorded before the first
    /// suspension, so a later `cancel()` is a no-op.
    public func close() async throws {
        if let closeTask {
            return try await closeTask.value
        }
        let pendingCancel = cancelTask
        let closeConnectionAction = self.closeConnectionAction
        let closeTunnelAction = self.closeTunnelAction
        let task = Task {
            await pendingCancel?.value
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

    /// `lifecycle` must close `connection`; `recordsHistory` is false for
    /// helper sessions, which never write query history.
    public init(connection: any DriverConnection, recordsHistory: Bool = false, lifecycle: MCPConnectionLifecycle) {
        self.connection = connection
        self.recordsHistory = recordsHistory
        self.lifecycle = lifecycle
    }
}

/// Why the coordinator refused a request before running its operation.
public enum MCPConnectionCoordinatorError: Error, Equatable, Sendable {
    /// Another request with this ID is still in flight; IDs are never shared.
    case duplicateRequestID(String)
    /// The profile's driver is not a SQL driver the helper can open.
    case wrongDriverFamily(DriverID)
    /// No database-enforced read-only mode exists for this driver, so no
    /// session is handed out.
    case sqlReadOnlyEnforcementUnavailable(DriverID)
    /// `closeAll()` has begun; no new request starts.
    case shuttingDown
}

/// Result of a shutdown: requests whose work did not finish before the deadline.
public struct MCPShutdownReport: Equatable, Sendable {
    public let abandonedRequestIDs: [String]

    /// `abandonedRequestIDs` is sorted so reports compare deterministically.
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
        let token: UUID
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

    /// Uses `sqlFactory` as given, bypassing `MCPConnectionFactories` and its
    /// read-only enforcer; for tests and injection only. The factory must
    /// itself hand out read-only sessions.
    public init(
        resolver: MCPProjectResolver,
        sqlFactory: @escaping SQLFactory,
        shutdownDeadline: Duration = .seconds(5)
    ) {
        self.resolver = resolver
        self.sqlFactory = sqlFactory
        self.shutdownDeadline = shutdownDeadline
    }

    /// Opens sessions through `factories`, whose default enforces read-only
    /// state before a session escapes. `closeAll()` returns within
    /// `shutdownDeadline`.
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
    /// Cancelling the task that called `withSQLSession` has the same effect.
    public func cancel(requestID: String) async {
        await cancel(requestID: requestID, token: nil)
    }

    /// `token` limits the cancel to the request that registered it, so a late
    /// caller-cancellation cannot reach a later request reusing the ID.
    private func cancel(requestID: String, token: UUID?) async {
        guard var request = active[requestID], token == nil || request.token == token else { return }
        request.cancelled = true
        active[requestID] = request
        // Task first, so a driver cancel that never returns cannot block it. The
        // lifecycle hop is queued before this actor is released, ahead of any close.
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

        let finished = FinishedSet()
        let deadline = CompletionSignal()
        let timeout = shutdownDeadline
        let timer = Task {
            try? await Task.sleep(for: timeout)
            await deadline.complete()
        }
        // Driver cancels run inside the deadline race: a cancel that never
        // returns leaves its request abandoned instead of blocking shutdown.
        // Each request's own completion covers activate/finish closing a
        // resource that appeared after shutdown began.
        for (id, request) in requests {
            Task {
                await request.lifecycle?.cancel()
                await request.awaitCompletion()
                await finished.insert(id)
                if await finished.count == requests.count { await deadline.complete() }
            }
        }
        if requests.isEmpty { await deadline.complete() }
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
        let token = UUID()
        active[requestID] = ActiveRequest(
            token: token,
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
        let result: Result<T, Error>
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                Task { await self.cancel(requestID: requestID, token: token) }
            }
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        // Exactly one finish per request: a second one could remove and close
        // a later request that reused this ID while the first close awaited.
        var closeError: Error?
        do {
            try await finish(requestID: requestID)
        } catch {
            closeError = error
        }
        await completion.complete()
        if case .success = result, let closeError { throw closeError }
        return try result.get()
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
