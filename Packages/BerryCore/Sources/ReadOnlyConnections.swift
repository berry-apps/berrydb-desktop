import BerryDriverKit
import Foundation

/// Why a session's read-only connection could not be handed out: its open
/// or its read-only setup failed, now or less than
/// `ReadOnlyConnections.retryAfter` ago.
public struct ReadOnlyConnectionUnavailable: Error, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// A session's read-only connection, handed out for one statement.
public struct ReadOnlyLease: Sendable {
    public let connection: any ReadOnlyExecuting
    private let onFinish: @Sendable (Bool) async -> Void

    public init(connection: any ReadOnlyExecuting, onFinish: @escaping @Sendable (Bool) async -> Void) {
        self.connection = connection
        self.onFinish = onFinish
    }

    /// Reports that the statement's stream ended, `failed` when it ended
    /// with an error other than its own cancellation. Until every lease on a
    /// connection is finished, the pool neither closes the connection nor
    /// checks it. Starts the idle countdown, and after a failure checks that
    /// the connection still answers. Call it once per lease; later calls do
    /// nothing.
    public func finish(failed: Bool) async {
        await onFinish(failed)
    }
}

/// The time `ReadOnlyConnections` reads and waits on, replaceable so a test
/// moves time forward instead of waiting minutes.
struct ReadOnlyClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async throws -> Void

    static let system = ReadOnlyClock(
        now: { ContinuousClock.now },
        sleep: { try await Task.sleep(for: $0) }
    )
}

/// One extra connection per open session for the statements the assistant
/// runs without an approval card, each under a read-only mode the server
/// enforces (`ReadOnlyExecuting`). It is separate from the session's own
/// connection so such a statement never runs inside the user's transaction,
/// and a cancel on one connection never stops the other's statement; and
/// separate from `MetadataConnections`, whose harvest holds one transaction
/// for a whole pass and whose statements are bounded at 15 seconds.
///
/// Like `MetadataConnections`, it reuses the session's configuration and
/// its SSH tunnel's local port, never prompts for a credential or opens a
/// second tunnel, opens on first use and never reopens for a closed
/// session. It also closes a connection idle for `idleTimeout`, and after a
/// failed open or setup, or one that took longer than `openTimeout`,
/// answers with the failure's reason, without trying again, for
/// `retryAfter`.
///
/// A connection is never closed or pinged while a lease on it is
/// unfinished. A driver's `ping()` does not take the connection's turn, so
/// it would run inside another statement's read-only transaction, and
/// closing under a running statement can trap in a driver: MySQLNIO 1.9.1
/// asserts "Statement not closed" in debug builds when a prepared
/// statement's command is released unclosed
/// (https://github.com/vapor/mysql-nio/blob/1.9.1/Sources/MySQLNIO/MySQLQueryCommand.swift),
/// which a test process hit after closing a MySQL connection under a
/// running `SELECT SLEEP(10)`. The pool knows a statement only through its
/// lease: one whose stream its caller abandoned may still be ending in the
/// driver after the lease is finished.
public actor ReadOnlyConnections {
    public static let idleTimeout: Duration = .seconds(300)
    public static let retryAfter: Duration = .seconds(300)
    /// How long the connect and the read-only setup together may take; an
    /// open that takes longer fails like one the server refused. Only the
    /// TCP connect has a bound of its own: PostgresNIO 1.33.0's
    /// `connectTimeout` covers the socket alone
    /// (https://github.com/vapor/postgres-nio/blob/1.33.0/Sources/PostgresNIO/Connection/PostgresConnection%2BConfiguration.swift),
    /// MySQLNIO 1.9.1 sets no bound on its handshake (verified in its
    /// `MySQLConnection.connect`), and the setup's statements have none. An
    /// SSH tunnel whose local listener accepts while its channel never opens
    /// leaves the driver waiting for a greeting that never comes, and
    /// PgBouncer with no free server holds the setup's BEGIN for
    /// `query_wait_timeout`, 120 seconds by default
    /// (https://www.pgbouncer.org/config.html#query_wait_timeout).
    static let openTimeout: Duration = .seconds(15)
    /// What the server lists the connection as (`pg_stat_activity` on
    /// Postgres), so a database administrator can tell it from the session's
    /// own connection.
    public static let applicationName = "BerryDB AI (read-only)"
    /// How long a connection has to answer `ping()` after a statement on it
    /// failed. A wedged socket, the case a statement's timeout exists for,
    /// never answers, and an unbounded ping would keep the dead connection.
    static let pingTimeout: Duration = .seconds(5)
    private static let closedMemory = 64

    /// One connection the pool opened, or is opening, for a session.
    private struct Slot {
        let sessionID: UUID
        let opening: Task<PooledReadOnlyConnection, any Error>
        /// Set once a lease is handed out, so a finish can check or close it
        /// without waiting on `opening`.
        var connection: PooledReadOnlyConnection?
        /// Leases handed out and not finished.
        var holders: Set<UUID> = []
        var lastFinished: ContinuousClock.Instant
        /// A statement failed since the connection last answered a ping.
        var failed = false
        /// The running ping, which leases wait for.
        var check: Task<Void, Never>?
        var idleTimer: Task<Void, Never>?
        /// Closed or dropped: no lease is handed out, and the connection
        /// closes when its last lease finishes.
        var retiring = false
    }

    private struct Failure {
        let reason: String
        let until: ContinuousClock.Instant
    }

    /// Every connection the pool holds, open, opening or retiring, by slot.
    private var slots: [UUID: Slot] = [:]
    /// The slot that serves each session's next lease.
    private var current: [UUID: UUID] = [:]
    private var failures: [UUID: Failure] = [:]
    /// Sessions closed most recently, oldest first; see
    /// `MetadataConnections` for why only the last few are kept.
    private var closed: [UUID] = []
    /// Set by `closeAll()`: the pool opens nothing after it, for any session.
    private var isShutDown = false
    private let driverType: @Sendable (DriverID) -> (any DatabaseDriver.Type)?
    private let clock: ReadOnlyClock

    public init() {
        self.init(driverType: DriverRegistry.driverType, clock: .system)
    }

    /// Takes the driver lookup and the clock so a test can supply a scripted
    /// driver and move time itself.
    init(driverType: @escaping @Sendable (DriverID) -> (any DatabaseDriver.Type)?, clock: ReadOnlyClock) {
        self.driverType = driverType
        self.clock = clock
    }

    /// Whether the session's engine runs statements on a read-only
    /// connection of its own: true for Postgres, MySQL, MariaDB and SQLite,
    /// whose connections adopt `ReadOnlyExecuting`.
    public nonisolated static func supports(_ session: Session) -> Bool {
        session.connection is any ReadOnlyExecuting
    }

    /// The session's read-only connection for one statement, opened and set
    /// up on first use. Throws `CancellationError` for a session that was
    /// closed, or a pool closed with `closeAll()`, before or while its
    /// connection opened, and to a caller
    /// cancelled while it waits; and `ReadOnlyConnectionUnavailable` when the
    /// open or the setup failed or took longer than `openTimeout`, to every
    /// caller that waited on it.
    public func lease(for session: Session) async throws -> ReadOnlyLease {
        while true {
            guard !isShutDown, !closed.contains(session.id) else { throw CancellationError() }
            if let failure = failures[session.id] {
                guard clock.now() >= failure.until else {
                    throw ReadOnlyConnectionUnavailable(reason: failure.reason)
                }
                failures[session.id] = nil
            }
            let slotID = current[session.id] ?? startOpening(session)
            guard let slot = slots[slotID] else {
                current[session.id] = nil
                continue
            }
            if let check = slot.check {
                // Nothing may start on the connection while it is pinged.
                leasesWaiting += 1
                defer { leasesWaiting -= 1 }
                try await Self.unlessCancelled { await check.value }
                continue
            }
            let opening = slot.opening
            leasesWaiting += 1
            let opened: Result<PooledReadOnlyConnection, any Error>
            do {
                opened = try await Self.unlessCancelled { await opening.result }
            } catch {
                leasesWaiting -= 1
                settleWhenOpened(slotID)
                throw error
            }
            leasesWaiting -= 1
            guard !isShutDown, !closed.contains(session.id) else { throw CancellationError() }
            switch opened {
            case .failure(let error):
                throw ReadOnlyConnectionUnavailable(reason: failedToOpen(slotID, sessionID: session.id, error: error))
            case .success(let connection):
                // Dropped, closed for idleness or put under a check while
                // this caller waited: start over from the current state.
                guard current[session.id] == slotID, slots[slotID]?.check == nil else { continue }
                let leaseID = UUID()
                slots[slotID]?.connection = connection
                slots[slotID]?.holders.insert(leaseID)
                return ReadOnlyLease(connection: connection) { [weak self] failed in
                    await self?.finished(leaseID, slotID: slotID, failed: failed)
                }
            }
        }
    }

    /// Ends the statements running on the session's connection through
    /// their own streams, whose cancel path stops each one on the server,
    /// and closes the connection once their leases are finished. The session
    /// is never connected again.
    public func close(sessionID: UUID) async {
        remember(closed: sessionID)
        failures[sessionID] = nil
        guard let slotID = current.removeValue(forKey: sessionID) else { return }
        await retire(slotID)
    }

    /// Closes every connection, as `close(sessionID:)` does, and opens none
    /// afterwards, for any session: the workspace that owns the pool is
    /// closing, and nothing would close a connection opened after this.
    public func closeAll() async {
        isShutDown = true
        for sessionID in current.keys { remember(closed: sessionID) }
        let slotIDs = Array(current.values)
        current.removeAll()
        failures.removeAll()
        for slotID in slotIDs { await retire(slotID) }
    }

    var cachedSessionCount: Int { current.count }
    /// How many idle checks have run, so a test can wait for one that
    /// decided to keep the connection.
    private(set) var idleChecks = 0
    /// How many idle countdowns have started, so a test can tell that one
    /// is running before it moves time on.
    private(set) var idleTimersArmed = 0
    /// How many leases wait for a connection to open or to answer its
    /// check, so a test can tell that one is waiting.
    private(set) var leasesWaiting = 0
    /// Leases handed out and not finished, on every connection the pool
    /// holds, so a test can tell that each caller gave its lease back: one
    /// that never does keeps its connection open for good.
    var unfinishedLeases: Int {
        slots.values.reduce(0) { $0 + $1.holders.count }
    }

    private func startOpening(_ session: Session) -> UUID {
        let driverType = driverType
        let clock = clock
        let slotID = UUID()
        slots[slotID] = Slot(
            sessionID: session.id,
            opening: Task { try await Self.open(session, driverType: driverType, within: Self.openTimeout, clock: clock) },
            lastFinished: clock.now()
        )
        current[session.id] = slotID
        return slotID
    }

    /// Takes the slot out of service after its open failed, unless a later
    /// slot already serves the session, and remembers the reason for
    /// `retryAfter`. Returns the reason.
    private func failedToOpen(_ slotID: UUID, sessionID: UUID, error: any Error) -> String {
        let reason = Self.reason(of: error)
        if current[sessionID] == slotID {
            current[sessionID] = nil
            slots[slotID] = nil
            failures[sessionID] = Failure(reason: reason, until: clock.now() + Self.retryAfter)
        }
        return reason
    }

    /// A caller stopped waiting for the open, which goes on. Its outcome is
    /// settled as a waiting caller would have: a failure is remembered, and
    /// a connection no lease has taken starts its idle countdown, so it
    /// closes like any other unused one.
    private func settleWhenOpened(_ slotID: UUID) {
        guard let slot = slots[slotID] else { return }
        let opening = slot.opening
        let sessionID = slot.sessionID
        Task { [weak self] in
            let opened = await opening.result
            await self?.settle(slotID, sessionID: sessionID, opened: opened)
        }
    }

    private func settle(_ slotID: UUID, sessionID: UUID, opened: Result<PooledReadOnlyConnection, any Error>) {
        switch opened {
        case .failure(let error):
            _ = failedToOpen(slotID, sessionID: sessionID, error: error)
        case .success(let connection):
            guard let slot = slots[slotID], !slot.retiring, slot.connection == nil else { return }
            slots[slotID]?.connection = connection
            slots[slotID]?.lastFinished = clock.now()
            armIdleTimer(slotID)
        }
    }

    private func finished(_ leaseID: UUID, slotID: UUID, failed: Bool) async {
        guard var slot = slots[slotID], slot.holders.remove(leaseID) != nil else { return }
        slot.lastFinished = clock.now()
        slot.failed = slot.failed || failed
        slots[slotID] = slot
        if slot.retiring {
            await closeIfUnheld(slotID)
        } else if slot.failed {
            if slot.holders.isEmpty { await check(slotID) }
        } else {
            armIdleTimer(slotID)
        }
    }

    /// Pings the connection after a failed statement, once no lease on it
    /// is unfinished, and drops it if it does not answer within
    /// `pingTimeout`. A dropped connection is replaced on the next lease;
    /// the retry delay is only for opens that fail.
    private func check(_ slotID: UUID) async {
        guard var slot = slots[slotID], let connection = slot.connection else { return }
        let clock = clock
        let check = Task {
            let alive = await Self.answers(connection.base, within: Self.pingTimeout, clock: clock)
            await self.checked(slotID, alive: alive)
        }
        slot.check = check
        slot.idleTimer?.cancel()
        slot.idleTimer = nil
        slots[slotID] = slot
        await check.value
    }

    /// Runs inside the check's task, so a lease waiting on the check sees
    /// its outcome when it resumes.
    private func checked(_ slotID: UUID, alive: Bool) async {
        guard var slot = slots[slotID], !slot.retiring else { return }
        slot.check = nil
        slot.failed = false
        slots[slotID] = slot
        if alive {
            armIdleTimer(slotID)
            return
        }
        if current[slot.sessionID] == slotID { current[slot.sessionID] = nil }
        slots[slotID]?.retiring = true
        await closeIfUnheld(slotID)
    }

    private func armIdleTimer(_ slotID: UUID) {
        idleTimersArmed += 1
        slots[slotID]?.idleTimer?.cancel()
        let clock = clock
        slots[slotID]?.idleTimer = Task { [weak self] in
            do {
                try await clock.sleep(Self.idleTimeout)
            } catch {
                return
            }
            await self?.closeIfIdle(slotID)
        }
    }

    /// Runs `idleTimeout` after a statement finished. A later statement
    /// moved `lastFinished` on, and one still running holds the slot;
    /// either keeps the connection.
    private func closeIfIdle(_ slotID: UUID) async {
        idleChecks += 1
        guard let slot = slots[slotID], !slot.retiring, slot.holders.isEmpty, slot.check == nil,
              clock.now() - slot.lastFinished >= Self.idleTimeout
        else { return }
        if current[slot.sessionID] == slotID { current[slot.sessionID] = nil }
        slots[slotID]?.retiring = true
        await closeIfUnheld(slotID)
    }

    /// Takes the slot out of service: waits for a connection still opening,
    /// ends its running statements, and closes it unless a lease is still
    /// unfinished, in which case the last finish closes it.
    private func retire(_ slotID: UUID) async {
        guard let slot = slots[slotID] else { return }
        slots[slotID]?.retiring = true
        slots[slotID]?.idleTimer?.cancel()
        slots[slotID]?.idleTimer = nil
        guard case .success(let connection) = await slot.opening.result else {
            slots[slotID] = nil
            return
        }
        slots[slotID]?.connection = connection
        connection.endStatements()
        await closeIfUnheld(slotID)
    }

    private func closeIfUnheld(_ slotID: UUID) async {
        guard let slot = slots[slotID], slot.retiring, slot.holders.isEmpty, let connection = slot.connection else {
            return
        }
        slots[slotID] = nil
        slot.idleTimer?.cancel()
        connection.endStatements()
        await connection.base.close()
    }

    private func remember(closed sessionID: UUID) {
        closed.append(sessionID)
        if closed.count > Self.closedMemory { closed.removeFirst(closed.count - Self.closedMemory) }
    }

    /// The bare words of a failed open: `readOnlyUnavailable` already carries
    /// the server's or the driver's reason, and its `localizedDescription`
    /// would put its own prefix in front of it, which the card then wraps
    /// again.
    private static func reason(of error: any Error) -> String {
        guard let driverError = error as? DriverError else { return error.localizedDescription }
        if case .readOnlyUnavailable(let detail) = driverError { return detail }
        return driverError.detail
    }

    /// `open(_:driverType:)`, failed with `openTimedOutDetail` once `bound`
    /// passes. The open is not awaited past the bound, because nothing may
    /// ever end it; a connection it makes after that is closed, never
    /// handed out.
    private static func open(
        _ session: Session,
        driverType: @escaping @Sendable (DriverID) -> (any DatabaseDriver.Type)?,
        within bound: Duration,
        clock: ReadOnlyClock
    ) async throws -> PooledReadOnlyConnection {
        let answer = FirstAnswer<Result<PooledReadOnlyConnection, any Error>>()
        let opening = Task {
            let opened: Result<PooledReadOnlyConnection, any Error>
            do {
                opened = .success(try await open(session, driverType: driverType))
            } catch {
                opened = .failure(error)
            }
            if !answer.give(opened), case .success(let late) = opened {
                await late.base.close()
            }
        }
        let timer = Task {
            do {
                try await clock.sleep(bound)
            } catch {
                // Cancelled because the open answered first.
                return
            }
            answer.give(.failure(DriverError.readOnlyUnavailable(ReadOnlyUnavailableReason.openTimedOutDetail)))
            opening.cancel()
        }
        let opened = await answer.value()
        timer.cancel()
        return try opened.get()
    }

    /// What `wait` returns, unless the caller is cancelled first; `wait`
    /// itself goes on. Awaiting a task's value does not respond to the
    /// caller's cancellation, so a statement stopped while the connection
    /// opens would otherwise wait out the open.
    private static func unlessCancelled<T: Sendable>(_ wait: @escaping @Sendable () async -> T) async throws -> T {
        let answer = FirstAnswer<T?>()
        Task { answer.give(await wait()) }
        let value = await withTaskCancellationHandler {
            await answer.value()
        } onCancel: {
            answer.give(nil)
        }
        guard let value else { throw CancellationError() }
        return value
    }

    /// Connects, then sets the connection up read-only; a connection that
    /// fails the setup is closed and never handed out.
    private static func open(
        _ session: Session,
        driverType: @Sendable (DriverID) -> (any DatabaseDriver.Type)?
    ) async throws -> PooledReadOnlyConnection {
        var effective = session.config.withApplicationName(applicationName)
        if let tunnel = session.tunnel {
            effective = effective.replacingEndpoint(host: "127.0.0.1", port: tunnel.localPort)
        }
        guard let driver = driverType(effective.driver) else {
            throw DriverError.unsupported("Driver \(effective.driver.rawValue) is not registered")
        }
        let connection = try await driver.init().connect(effective)
        guard let readOnly = connection as? any ReadOnlyExecuting else {
            await connection.close()
            throw DriverError.unsupported("\(effective.driver.rawValue) has no read-only connection")
        }
        do {
            try await readOnly.prepareReadOnly()
        } catch {
            await readOnly.close()
            throw error
        }
        return PooledReadOnlyConnection(readOnly)
    }

    /// Whether `connection` answers a ping within `bound`. The ping is not
    /// awaited past the bound: on a wedged socket it never returns, and the
    /// close that follows a false answer is what ends it.
    private static func answers(
        _ connection: any ReadOnlyExecuting, within bound: Duration, clock: ReadOnlyClock
    ) async -> Bool {
        let answer = FirstAnswer<Bool>()
        let ping = Task { answer.give(await connection.ping()) }
        let timer = Task {
            do {
                try await clock.sleep(bound)
                answer.give(false)
            } catch {
                // Cancelled because the ping answered first.
            }
        }
        let alive = await answer.value()
        timer.cancel()
        ping.cancel()
        return alive
    }
}

/// The first of several answers, for a race whose losers keep running.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    /// Kept apart from `answer`, which an optional `Value` may set to nil.
    private var answered = false
    private var answer: Value?
    private var waiter: CheckedContinuation<Value, Never>?

    /// False when another answer came first; `value` is then dropped, and
    /// whatever it holds stays the giver's to dispose of.
    @discardableResult
    func give(_ value: Value) -> Bool {
        let given: (first: Bool, waiter: CheckedContinuation<Value, Never>?) = lock.withLock {
            guard !answered else { return (false, nil) }
            answered = true
            answer = value
            defer { self.waiter = nil }
            return (true, self.waiter)
        }
        given.waiter?.resume(returning: value)
        return given.first
    }

    func value() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let ready: Value? = lock.withLock {
                guard answered else {
                    waiter = continuation
                    return nil
                }
                return answer
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// What a lease hands out in place of the pool's connection. Only
/// read-only statements reach the connection through it: anything else
/// would run outside the connection's turn, and without the read-only mode.
/// Each statement's stream is kept, so a pool that closes the connection
/// can end it through the driver's own cancel path, which stops a statement
/// still waiting for the connection's turn before it runs and cancels the
/// one running on the server.
actor PooledReadOnlyConnection: ReadOnlyExecuting {
    nonisolated let id: UUID
    nonisolated let base: any ReadOnlyExecuting
    private nonisolated let statements = RunningStatements()

    init(_ base: any ReadOnlyExecuting) {
        self.base = base
        self.id = base.id
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        let base = base
        let statements = statements
        return AsyncThrowingStream { continuation in
            let statementID = UUID()
            guard statements.reserve(statementID) else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let forward = Task {
                do {
                    for try await event in base.executeReadOnly(sql, parameters: parameters, timeout: timeout) {
                        continuation.yield(event)
                    }
                    // A cancelled consumer ends the driver's stream without
                    // an error; reporting that as success would hand back
                    // a result that never completed.
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : nil)
                } catch {
                    continuation.finish(throwing: error)
                }
                statements.release(statementID)
            }
            statements.attach(forward, to: statementID)
            continuation.onTermination = { _ in forward.cancel() }
        }
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: Self.readOnlyOnly) }
    }

    /// The pool set the connection up before handing it out.
    func prepareReadOnly() async throws {}

    nonisolated func cancelCurrentQuery() {
        statements.cancelRunning()
    }

    func setDatabase(_ name: String) async throws {
        throw Self.readOnlyOnly
    }

    nonisolated var introspector: any Introspector { RefusingIntrospector() }

    /// Answers from the pool's side, without a statement: true until the
    /// pool closes the connection. The pool pings the connection itself
    /// after a failed statement, once nothing else runs on it.
    func ping() async -> Bool {
        !statements.isEnded
    }

    /// The pool closes the connection; a lease holder only finishes its
    /// lease.
    func close() async {}

    /// Ends every running statement, and every one started later.
    nonisolated func endStatements() {
        statements.end()
    }

    static let readOnlyOnly = DriverError.unsupported("A read-only connection runs read-only statements only")
}

/// The statements running through one pooled connection.
private final class RunningStatements: @unchecked Sendable {
    private let lock = NSLock()
    /// A reserved statement whose task is not attached yet maps to nil.
    private var running: [UUID: Task<Void, Never>?] = [:]
    private var ended = false

    var isEnded: Bool {
        lock.withLock { ended }
    }

    /// False once the connection is closing, so the statement never starts.
    func reserve(_ statementID: UUID) -> Bool {
        lock.withLock {
            guard !ended else { return false }
            running[statementID] = .some(nil)
            return true
        }
    }

    /// Keeps `task` while its statement runs. A task whose statement already
    /// ended is not kept, and one attached after `end()` is cancelled.
    func attach(_ task: Task<Void, Never>, to statementID: UUID) {
        let cancel: Bool = lock.withLock {
            if ended { return true }
            if running.keys.contains(statementID) { running[statementID] = .some(task) }
            return false
        }
        if cancel { task.cancel() }
    }

    func release(_ statementID: UUID) {
        lock.withLock { _ = running.removeValue(forKey: statementID) }
    }

    func cancelRunning() {
        let tasks = lock.withLock { running.values.compactMap { $0 } }
        for task in tasks { task.cancel() }
    }

    func end() {
        let tasks: [Task<Void, Never>] = lock.withLock {
            ended = true
            defer { running.removeAll() }
            return running.values.compactMap { $0 }
        }
        for task in tasks { task.cancel() }
    }
}

/// The introspector of a pooled connection: a catalog read is a statement
/// outside the read-only path.
private struct RefusingIntrospector: Introspector {
    func databases() async throws -> [DatabaseInfo] { throw PooledReadOnlyConnection.readOnlyOnly }
    func objects(in database: String?) async throws -> [SchemaObject] { throw PooledReadOnlyConnection.readOnlyOnly }
    func tableDetail(_ ref: TableRef) async throws -> TableDetail { throw PooledReadOnlyConnection.readOnlyOnly }
    func tableStats(_ ref: TableRef) async throws -> TableStats { throw PooledReadOnlyConnection.readOnlyOnly }
    func ddl(of object: SchemaObject) async throws -> String { throw PooledReadOnlyConnection.readOnlyOnly }
}
