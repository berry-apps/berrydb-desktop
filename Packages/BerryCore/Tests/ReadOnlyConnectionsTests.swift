import BerryDriverKit
import BerryDriverPostgres
import BerryDriverSQLite
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryCore

/// Several tests hold a connect, a statement or a ping; the time limit, with
/// waits that poll rather than suspend, turns a pool that never lets one
/// through into a failure instead of a stalled run.
@Suite("Read-only connections", .timeLimit(.minutes(1)))
struct ReadOnlyConnectionsTests {
    @Test func opensOnFirstUseOncePerSessionAndPreparesBeforeHandingOut() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            #expect(await script.connects == 0)

            let first = try await pool.lease(for: session)
            let second = try await pool.lease(for: session)

            #expect(first.connection.id == second.connection.id)
            #expect(first.connection.id != session.connection.id)
            #expect(await script.connects == 1)
            #expect(await script.prepares == 1)
            #expect(await script.configs.map(\.applicationName) == [ReadOnlyConnections.applicationName])
            await first.finish(failed: false)
            await second.finish(failed: false)
        }
    }

    @Test func aFailedPrepareClosesTheConnectionAndNeverHandsItOut() async throws {
        let script = ROScript(prepareFailure: "BEGIN READ ONLY refused")
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let error = await #expect(throws: ReadOnlyConnectionUnavailable.self) {
                _ = try await pool.lease(for: session)
            }

            #expect(error?.reason.contains("BEGIN READ ONLY refused") == true)
            #expect(await script.closes == 1)
            #expect(await pool.cachedSessionCount == 0)
        }
    }

    /// A connection that cannot be opened is not tried again for five
    /// minutes, so every auto-run in that time shows its card at once
    /// instead of waiting on a connect that will fail the same way.
    @Test func aFailureIsRememberedWithItsReasonForFiveMinutes() async throws {
        let time = ManualTime()
        let script = ROScript(failingConnects: 1)
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let first = await Self.reason(pool, session)
            time.advance(by: .seconds(299))
            let second = await Self.reason(pool, session)
            #expect(first != nil)
            #expect(second == first)
            #expect(await script.connects == 1)

            time.advance(by: .seconds(1))
            await (try await pool.lease(for: session)).finish(failed: false)
            #expect(await script.connects == 2)
        }
    }

    /// Statements the assistant runs side by side can wait on one open; a
    /// failed open is the reason for each of them, so none of them reports
    /// the session as closed.
    @Test func everyCallerWaitingOnAFailedOpenGetsItsReason() async throws {
        let gate = ROGate()
        let script = ROScript(failingConnects: 1, gate: gate)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let first = Task { await Self.reason(pool, session) }
            await gate.waitUntilReached()
            let second = Task { await Self.reason(pool, session) }
            await Self.waitUntil { await pool.leasesWaiting == 2 }
            await gate.open()

            let reasons = [await Self.value(of: first) ?? nil, await Self.value(of: second) ?? nil]
            #expect(reasons[0] != nil)
            #expect(reasons[1] == reasons[0])
            #expect(await script.connects == 1)
        }
    }

    /// A tunnel whose SSH channel never opens, or a pooler with no free
    /// server, leaves a connect or its setup without an answer. After 15
    /// seconds the open counts as failed, like one the server refused, and
    /// the connection it makes later is closed rather than handed out.
    @Test func anOpenWithoutAnAnswerFailsAfterFifteenSecondsAndIsNotTriedAgainForFiveMinutes() async throws {
        let time = ManualTime()
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let waiting = Self.leaseTask(pool, session)
            await gate.waitUntilReached()
            await Self.waitUntil { time.sleepers == 1 }
            time.advance(by: .seconds(14))
            #expect(await pool.leasesWaiting == 1)

            time.advance(by: .seconds(1))
            let outcome = await Self.value(of: waiting)
            #expect(throws: ReadOnlyConnectionUnavailable(reason: ReadOnlyUnavailableReason.openTimedOutDetail)) {
                _ = try outcome?.get()
            }
            time.advance(by: .seconds(299))
            let retried = await Self.value(of: Task { await Self.reason(pool, session) })
            #expect(retried == .some(ReadOnlyUnavailableReason.openTimedOutDetail))
            #expect(await script.connects == 1)

            await gate.open()
            await Self.waitUntil { await script.closes == 1 }
            #expect(await pool.cachedSessionCount == 0)
            time.advance(by: .seconds(1))
            await (try await pool.lease(for: session)).finish(failed: false)
            #expect(await script.connects == 2)
        }
    }

    /// A statement stopped while the connection opens stops waiting at once.
    /// The open goes on, and its connection serves the next statement.
    @Test func aCallerStoppedWhileTheConnectionOpensStopsWaiting() async throws {
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let stopped = Self.leaseTask(pool, session)
            await gate.waitUntilReached()
            await Self.waitUntil { await pool.leasesWaiting == 1 }
            stopped.cancel()

            let outcome = await Self.value(of: stopped)
            #expect(throws: CancellationError.self) { _ = try outcome?.get() }
            #expect(await pool.leasesWaiting == 0)
            await gate.open()
            let next = try await pool.lease(for: session)
            #expect(await script.connects == 1)
            await next.finish(failed: false)
        }
    }

    /// A connection whose only caller stopped waiting is held by no lease;
    /// it closes like one idle since it opened.
    @Test func aConnectionNobodyTookClosesWhenIdle() async throws {
        let time = ManualTime()
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let stopped = Self.leaseTask(pool, session)
            await gate.waitUntilReached()
            await Self.waitUntil { await pool.leasesWaiting == 1 }
            stopped.cancel()
            _ = await Self.value(of: stopped)
            await gate.open()
            await Self.waitUntil { await pool.idleTimersArmed == 1 }
            await Self.waitUntil { time.sleepers == 1 }

            time.advance(by: .seconds(299))
            #expect(await script.closes == 0)
            time.advance(by: .seconds(1))
            await Self.waitUntil { await script.closes == 1 }
            #expect(await pool.cachedSessionCount == 0)
        }
    }

    @Test func anIdleConnectionClosesFiveMinutesAfterItsLastStatement() async throws {
        let time = ManualTime()
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let lease = try await pool.lease(for: session)
            await lease.finish(failed: false)
            await Self.waitUntil { time.sleepers == 1 }
            time.advance(by: .seconds(299))
            #expect(await pool.cachedSessionCount == 1)

            time.advance(by: .seconds(1))
            await Self.waitUntil { await pool.cachedSessionCount == 0 }
            #expect(await script.closes == 1)

            await (try await pool.lease(for: session)).finish(failed: false)
            #expect(await script.connects == 2)
        }
    }

    /// A statement still running keeps the connection open even when the
    /// last one to finish did so five minutes ago.
    @Test func aStatementInFlightKeepsTheConnectionOpen() async throws {
        let time = ManualTime()
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let running = try await pool.lease(for: session)
            await (try await pool.lease(for: session)).finish(failed: false)
            await Self.waitUntil { time.sleepers == 1 }
            time.advance(by: .seconds(300))
            await Self.waitUntil { await pool.idleChecks == 1 }
            #expect(await pool.cachedSessionCount == 1)

            await running.finish(failed: false)
            await Self.waitUntil { time.sleepers == 1 }
            time.advance(by: .seconds(300))
            await Self.waitUntil { await pool.cachedSessionCount == 0 }
            #expect(await script.closes == 1)
        }
    }

    @Test func aClosedSessionIsNeverConnectedAgain() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            await (try await pool.lease(for: session)).finish(failed: false)
            await pool.close(sessionID: session.id)
            await #expect(throws: CancellationError.self) { _ = try await pool.lease(for: session) }

            #expect(await script.connects == 1)
            #expect(await script.closes == 1)
            #expect(await pool.cachedSessionCount == 0)
        }
    }

    /// Closing the pool, as closing a window or quitting does, stops every
    /// later open, for sessions it never opened a connection for too.
    @Test func aClosedPoolNeverOpensAgain() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        let pool = Self.pool()
        await pool.closeAll()

        await #expect(throws: CancellationError.self) { _ = try await pool.lease(for: session) }

        #expect(await script.connects == 0)
        #expect(await pool.cachedSessionCount == 0)
        await pool.closeAll()
    }

    @Test func closingWhileConnectingClosesTheConnectionOnceItExists() async throws {
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let opening = Self.leaseTask(pool, session)
            await gate.waitUntilReached()
            let closing = Task { await pool.close(sessionID: session.id) }
            await Self.waitUntil { await pool.cachedSessionCount == 0 }
            await gate.open()
            _ = await Self.value(of: closing)

            #expect(await script.closes == 1)
            let opened = await Self.value(of: opening)
            #expect(throws: CancellationError.self) { _ = try opened?.get() }
        }
    }

    /// Closing a connection under a running statement can trap in a driver
    /// (see `ReadOnlyConnections`), so a session close ends the statement
    /// through its stream's own cancel and closes the connection once the
    /// statement's lease is given back.
    @Test func closingWhileAStatementRunsEndsItAndClosesAfterItsLeaseFinishes() async throws {
        let statementGate = ROGate()
        let script = ROScript(statementGate: statementGate)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let lease = try await pool.lease(for: session)
            let running = Task { () -> (any Error)? in
                do {
                    for try await _ in lease.connection.executeReadOnly("SELECT 1", timeout: .seconds(5)) {}
                    return nil
                } catch {
                    return error
                }
            }
            await statementGate.waitUntilReached()

            await pool.close(sessionID: session.id)
            await Self.waitUntil { await script.statementCancels == 1 }
            #expect(await script.closes == 0)
            // The scripted statement ignores its cancel, as a statement still
            // waiting on the server would; letting it through shows the
            // stream had already ended rather than completed.
            await statementGate.open()
            let ended = await Self.value(of: running) ?? nil

            #expect(ended is CancellationError)
            #expect(await lease.connection.ping() == false)
            #expect(await script.closes == 0)
            await lease.finish(failed: false)
            #expect(await script.closes == 1)
        }
    }

    /// Cancelling through a leased connection ends what runs on it, as a
    /// driver's own cancel does, and leaves the connection in service.
    @Test func cancellingALeasedConnectionEndsItsStatementAndKeepsTheConnection() async throws {
        let statementGate = ROGate()
        let script = ROScript(statementGate: statementGate)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let lease = try await pool.lease(for: session)
            let running = Task { () -> (any Error)? in
                do {
                    for try await _ in lease.connection.executeReadOnly("SELECT 1", timeout: .seconds(5)) {}
                    return nil
                } catch {
                    return error
                }
            }
            await statementGate.waitUntilReached()

            lease.connection.cancelCurrentQuery()
            await Self.waitUntil { await script.statementCancels == 1 }
            await statementGate.open()
            let ended = await Self.value(of: running) ?? nil
            for try await _ in lease.connection.executeReadOnly("SELECT 2", timeout: .seconds(5)) {}

            #expect(ended is CancellationError)
            #expect(await script.readOnlyStatements == ["SELECT 1", "SELECT 2"])
            #expect(await lease.connection.ping())
            await lease.finish(failed: false)
            #expect(await script.closes == 0)
        }
    }

    /// The liveness check runs on the connection only once nothing else
    /// does: `ping()` does not take the connection's turn, so it would run
    /// inside another statement's read-only transaction.
    @Test func aDeadConnectionIsCheckedAndClosedOnlyAfterItsLastStatementFinishes() async throws {
        let script = ROScript(alive: false)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let failing = try await pool.lease(for: session)
            let running = try await pool.lease(for: session)

            await failing.finish(failed: true)
            #expect(await script.pings == 0)
            #expect(await script.closes == 0)
            #expect(await pool.cachedSessionCount == 1)

            await running.finish(failed: false)
            #expect(await script.pings == 1)
            #expect(await script.closes == 1)
            #expect(await pool.cachedSessionCount == 0)
        }
    }

    /// A server, a pooler or a tunnel can drop the connection; the next
    /// statement then opens a new one rather than fail on the dead one.
    @Test func aFailedStatementOnADeadConnectionDropsIt() async throws {
        let script = ROScript(alive: false)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let dead = try await pool.lease(for: session)
            await dead.finish(failed: true)

            #expect(await script.closes == 1)
            #expect(await pool.cachedSessionCount == 0)
            let fresh = try await pool.lease(for: session)
            #expect(fresh.connection.id != dead.connection.id)
            #expect(await script.connects == 2)
            await fresh.finish(failed: false)
        }
    }

    /// A wedged socket, the case a statement's timeout exists for, never
    /// answers a ping either; five seconds without an answer drops the
    /// connection like a failed one.
    @Test func aConnectionThatDoesNotAnswerWithinFiveSecondsIsDropped() async throws {
        let time = ManualTime()
        let script = ROScript(pingHangs: true)
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let lease = try await pool.lease(for: session)
            let finishing = Task { await lease.finish(failed: true) }
            await Self.waitUntil { time.sleepers == 1 }

            time.advance(by: .seconds(4))
            #expect(await script.closes == 0)
            time.advance(by: .seconds(1))
            _ = await Self.value(of: finishing)

            #expect(await script.closes == 1)
            #expect(await pool.cachedSessionCount == 0)
        }
    }

    /// A statement asked for while the connection is being checked waits for
    /// the answer, so nothing runs beside the ping, and then gets a
    /// connection that answered or a new one.
    @Test func aLeaseAskedForDuringTheCheckWaitsForItsAnswer() async throws {
        let time = ManualTime()
        let script = ROScript(pingHangs: true)
        let session = await Self.session(script: script)
        try await Self.withPool(time: time) { pool in
            let checked = try await pool.lease(for: session)
            let finishing = Task { await checked.finish(failed: true) }
            await Self.waitUntil { time.sleepers == 1 }
            let waiting = Self.leaseTask(pool, session)
            await Self.waitUntil { await pool.leasesWaiting == 1 }

            time.advance(by: .seconds(5))
            _ = await Self.value(of: finishing)
            let next = try #require(await Self.value(of: waiting)).get()

            #expect(next.connection.id != checked.connection.id)
            #expect(await script.connects == 2)
            await next.finish(failed: false)
        }
    }

    /// Guard: a statement the server refused leaves a live connection in place.
    @Test func aFailedStatementOnALiveConnectionKeepsIt() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let lease = try await pool.lease(for: session)
            await lease.finish(failed: true)

            #expect(await script.closes == 0)
            let next = try await pool.lease(for: session)
            #expect(next.connection.id == lease.connection.id)
            await next.finish(failed: false)
        }
    }

    @Test func aConnectionWithoutTheContractIsClosedAndNotHandedOut() async throws {
        let script = ROScript(plain: true)
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            await #expect(throws: ReadOnlyConnectionUnavailable.self) { _ = try await pool.lease(for: session) }
            #expect(await script.closes == 1)
        }
    }

    /// What a lease hands out runs nothing on the pool's connection but
    /// read-only statements, and leaves closing it to the pool.
    @Test func aLeasedConnectionRunsOnlyReadOnlyStatements() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let lease = try await pool.lease(for: session)
            let connection = lease.connection

            await #expect(throws: DriverError.self) { for try await _ in connection.execute("SELECT 1") {} }
            await #expect(throws: DriverError.self) { try await connection.setDatabase("other") }
            await #expect(throws: DriverError.self) { _ = try await connection.introspector.databases() }
            #expect(await connection.ping())
            await connection.close()
            for try await _ in connection.executeReadOnly("SELECT 2", timeout: .seconds(5)) {}

            #expect(await script.plainStatements.isEmpty)
            #expect(await script.pings == 0)
            #expect(await script.closes == 0)
            #expect(await script.readOnlyStatements == ["SELECT 2"])
            await lease.finish(failed: false)
        }
    }

    /// Parameters go through a lease to the pool's connection unchanged;
    /// without them the statement runs with none.
    @Test func aLeasedConnectionPassesParametersOn() async throws {
        let script = ROScript()
        let session = await Self.session(script: script)
        try await Self.withPool { pool in
            let lease = try await pool.lease(for: session)

            for try await _ in lease.connection.executeReadOnly("SELECT ?, ?", parameters: [.int(7), .text("x")], timeout: .seconds(5)) {}
            for try await _ in lease.connection.executeReadOnly("SELECT 2", timeout: .seconds(5)) {}

            #expect(await script.readOnlyStatements == ["SELECT ?, ?", "SELECT 2"])
            #expect(await script.readOnlyParameters == [[.int(7), .text("x")], []])
            await lease.finish(failed: false)
        }
    }

    /// Session IDs are never reused, so the pool remembers only the last 64
    /// closed ones.
    @Test func theLastSixtyFourClosedSessionsAreRemembered() async throws {
        let script = ROScript()
        var opened: [Session] = []
        for _ in 0...64 { opened.append(await Self.session(script: script)) }
        let sessions = opened
        try await Self.withPool { pool in
            for session in sessions { await pool.close(sessionID: session.id) }

            await #expect(throws: CancellationError.self) { _ = try await pool.lease(for: sessions[1]) }
            await (try await pool.lease(for: sessions[0])).finish(failed: false)
            #expect(await script.connects == 1)
        }
    }

    @Test func onlyEnginesWithTheContractAreSupported() async {
        let withContract = await Self.session(script: ROScript())
        let without = await Self.session(script: ROScript(), main: PlainConnection())

        #expect(ReadOnlyConnections.supports(withContract))
        #expect(!ReadOnlyConnections.supports(without))
    }

    /// End to end through the driver registry: a SQLite session gets a
    /// second connection to its file, set up so the file refuses writes. The
    /// statement starts like a read, so only the connection's read-only mode
    /// stands in its way.
    @Test func aSQLiteSessionGetsASecondConnectionThatRefusesWrites() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-readonly-pool-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await Self.withOpenedSession(.sqlite(path: path)) { session, pool in
            for try await _ in session.connection.execute("CREATE TABLE t (id INTEGER)") {}

            let lease = try await pool.lease(for: session)
            let write = "WITH one AS (SELECT 1) INSERT INTO t (id) SELECT * FROM one"
            let error = await #expect(throws: DriverError.self) {
                for try await _ in lease.connection.executeReadOnly(write, timeout: .seconds(5)) {}
            }
            await lease.finish(failed: true)

            #expect(lease.connection.id != session.connection.id)
            #expect(error?.detail.contains("readonly") == true)
            #expect(await pool.cachedSessionCount == 1)
            #expect(try await Self.rows("SELECT count(*) FROM t", on: session.connection) == [[.int(0)]])
        }
    }

    /// End to end through the registry against a real server: the setup ran
    /// and the server lists the connection under its own name.
    @Test(.enabled(if: TestServer.postgres != nil))
    func aPostgresSessionGetsANamedReadOnlyConnection() async throws {
        DriverRegistry.register(PostgresDriver.self)
        let server = try #require(TestServer.postgres)
        let config = ConnectionConfig(
            driver: .postgres, name: "t", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        )
        try await Self.withOpenedSession(config) { session, pool in
            let lease = try await pool.lease(for: session)
            var rows: [[BerryValue]] = []
            let sql = "SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()"
            for try await event in lease.connection.executeReadOnly(sql, timeout: .seconds(10)) {
                if case let .rows(batch) = event { rows += batch }
            }
            await lease.finish(failed: false)

            #expect(rows == [[.text(ReadOnlyConnections.applicationName)]])
        }
    }

    // MARK: - Fixtures

    static func pool(time: ManualTime = ManualTime()) -> ReadOnlyConnections {
        ReadOnlyConnections(driverType: { _ in ROScriptedDriver.self }, clock: time.clock)
    }

    /// Runs `body` with a scripted pool and closes the pool however `body`
    /// ends.
    static func withPool(
        time: ManualTime = ManualTime(),
        _ body: (ReadOnlyConnections) async throws -> Void
    ) async throws {
        let pool = pool(time: time)
        do {
            try await body(pool)
        } catch {
            await pool.closeAll()
            throw error
        }
        await pool.closeAll()
    }

    /// Runs `body` with a session opened through the process-wide driver
    /// registry and a pool that opens through it too, then closes both
    /// however `body` ends.
    static func withOpenedSession(
        _ config: ConnectionConfig,
        _ body: (Session, ReadOnlyConnections) async throws -> Void
    ) async throws {
        let manager = ConnectionManager()
        let session = try await manager.open(config)
        let pool = ReadOnlyConnections()
        do {
            try await body(session, pool)
        } catch {
            await pool.closeAll()
            await manager.close(session.id)
            throw error
        }
        await pool.closeAll()
        await manager.close(session.id)
    }

    static func session(script: ROScript, main: any DriverConnection = MainConnection()) async -> Session {
        let name = UUID().uuidString
        await ROScriptRegistry.shared.register(script, for: name)
        return Session(
            id: UUID(), profileID: nil, isProduction: false,
            config: ConnectionConfig(driver: .postgres, name: name),
            connection: main,
            capabilities: Capabilities(), dialect: SQLiteDialect(),
            driverDisplayName: "Scripted", tunnel: nil, recordHistory: false
        )
    }

    /// The reason a lease is refused with; nil when one is handed out, which
    /// is then given back at once.
    static func reason(_ pool: ReadOnlyConnections, _ session: Session) async -> String? {
        do {
            await (try await pool.lease(for: session)).finish(failed: false)
            return nil
        } catch {
            return (error as? ReadOnlyConnectionUnavailable)?.reason
        }
    }

    static func rows(_ sql: String, on connection: any DriverConnection) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in connection.execute(sql) {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    /// A lease asked for on a task of its own, its outcome kept as a value
    /// so `value(of:)` can bound the wait for it.
    static func leaseTask(_ pool: ReadOnlyConnections, _ session: Session) -> Task<Result<ReadOnlyLease, any Error>, Never> {
        Task {
            do {
                return .success(try await pool.lease(for: session))
            } catch {
                return .failure(error)
            }
        }
    }

    /// The task's value, waited for no longer than `waitUntil` waits; nil
    /// when the task has not finished by then. Awaiting `Task.value` itself
    /// cannot be cut short, and a test over its time limit is still waited
    /// for, so a pool that never answers would stall the run.
    static func value<T: Sendable>(of task: Task<T, Never>) async -> T? {
        let box = ROValueBox<T>()
        Task { box.store(await task.value) }
        await waitUntil { box.value != nil }
        return box.value
    }

    /// Polls rather than suspends, so a test that its time limit cancels
    /// stops waiting.
    static func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 60 seconds")
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(1))
            } catch {
                Issue.record("cancelled while waiting for a condition")
                return
            }
        }
    }
}

/// Time that moves only when a test moves it: `sleep` returns once
/// `advance` has passed its deadline, and throws when its task is cancelled.
final class ManualTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var waiting: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>)] = [:]

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    var sleepers: Int {
        lock.withLock { waiting.count }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    // The cancel handler may have run before this registered.
                    guard !Task.isCancelled else { return true }
                    waiting[id] = (current + duration, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { waiting.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            current += duration
            let due = waiting.filter { $0.value.deadline <= current }
            for id in due.keys { waiting[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    var clock: ReadOnlyClock {
        ReadOnlyClock(now: { self.now }, sleep: { try await self.sleep(for: $0) })
    }
}

/// Holds what one test's task stores for another to read.
final class ROValueBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        lock.withLock { stored }
    }

    func store(_ value: T) {
        lock.withLock { stored = value }
    }
}

/// Lets a test hold a connect or a statement and observe that it is in
/// flight.
actor ROGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isReached = false
    private var isOpen = false

    func pass() async {
        isReached = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Polls, like `waitUntil`, so a pool that never reaches the gate fails
    /// the test instead of stalling it.
    func waitUntilReached() async {
        let deadline = ContinuousClock.now + .seconds(60)
        while !isReached {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(1))) != nil else {
                Issue.record("the gate was not reached")
                return
            }
        }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

enum ROScriptedError: Error {
    case connectFailed
}

/// What one test tells the scripted driver to do, and what it did.
actor ROScript {
    private var failingConnects: Int
    private let prepareFailure: String?
    private let gate: ROGate?
    let statementGate: ROGate?
    let alive: Bool
    let pingHangs: Bool
    let plain: Bool
    private(set) var connects = 0
    private(set) var prepares = 0
    private(set) var closes = 0
    private(set) var pings = 0
    private(set) var statementCancels = 0
    private(set) var configs: [ConnectionConfig] = []
    private(set) var readOnlyStatements: [String] = []
    private(set) var readOnlyParameters: [[SQLParameter]] = []
    private(set) var plainStatements: [String] = []

    init(
        failingConnects: Int = 0, prepareFailure: String? = nil, gate: ROGate? = nil,
        statementGate: ROGate? = nil, alive: Bool = true, pingHangs: Bool = false, plain: Bool = false
    ) {
        self.failingConnects = failingConnects
        self.prepareFailure = prepareFailure
        self.gate = gate
        self.statementGate = statementGate
        self.alive = alive
        self.pingHangs = pingHangs
        self.plain = plain
    }

    func connect(_ config: ConnectionConfig) async throws {
        connects += 1
        configs.append(config)
        if let gate { await gate.pass() }
        if failingConnects > 0 {
            failingConnects -= 1
            throw ROScriptedError.connectFailed
        }
    }

    func prepare() throws {
        prepares += 1
        if let prepareFailure { throw DriverError.readOnlyUnavailable(prepareFailure) }
    }

    func ranReadOnly(_ sql: String, parameters: [SQLParameter]) {
        readOnlyStatements.append(sql)
        readOnlyParameters.append(parameters)
    }

    func ranPlain(_ sql: String) { plainStatements.append(sql) }
    func statementCancelled() { statementCancels += 1 }
    func pinged() { pings += 1 }
    func closed() { closes += 1 }
}

/// The driver is built with no arguments, so it finds its script by the
/// configuration's name.
actor ROScriptRegistry {
    static let shared = ROScriptRegistry()
    private var scripts: [String: ROScript] = [:]

    func register(_ script: ROScript, for name: String) { scripts[name] = script }
    func script(for name: String) -> ROScript? { scripts[name] }
}

struct ROScriptedDriver: DatabaseDriver {
    static let id = DriverID.postgres
    static let displayName = "Scripted"
    static let capabilities = Capabilities()
    static let dialect: any SQLDialect = SQLiteDialect()
    init() {}

    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let script = await ROScriptRegistry.shared.script(for: config.name) else {
            throw DriverError.connectionFailed("No script registered for this configuration")
        }
        try await script.connect(config)
        if script.plain { return PlainConnection(script: script) }
        return ROScriptedConnection(script: script)
    }
}

actor ROScriptedConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private let script: ROScript
    private var hangingPings: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false

    init(script: ROScript) { self.script = script }

    /// Finishes only after recording the statement, so a caller that saw
    /// the stream end can tell whether it reached this connection.
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            Task {
                await script.ranPlain(sql)
                continuation.finish(throwing: DriverError.unsupported("not the read-only path"))
            }
        }
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    /// Holds at the script's statement gate when it has one, and records a
    /// cancel the way a driver's cancel path would see it.
    nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            let task = Task {
                await script.ranReadOnly(sql, parameters: parameters)
                if let gate = script.statementGate { await gate.pass() }
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await script.statementCancelled() }
            }
        }
    }

    func prepareReadOnly() async throws { try await script.prepare() }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws { await script.ranPlain("USE \(name)") }
    nonisolated var introspector: any Introspector { ROIntrospector() }

    /// A ping on a wedged socket answers only when the connection closes.
    func ping() async -> Bool {
        await script.pinged()
        guard script.pingHangs, !isClosed else { return script.alive && !isClosed }
        await withCheckedContinuation { hangingPings.append($0) }
        return false
    }

    func close() async {
        isClosed = true
        for ping in hangingPings { ping.resume() }
        hangingPings.removeAll()
        await script.closed()
    }
}

/// Answers catalog reads without a statement, so a test can tell whether a
/// read reached the scripted connection.
struct ROIntrospector: Introspector {
    func databases() async throws -> [DatabaseInfo] { [] }
    func objects(in database: String?) async throws -> [SchemaObject] { [] }
    func tableDetail(_ ref: TableRef) async throws -> TableDetail { throw DriverError.unsupported("scripted") }
    func tableStats(_ ref: TableRef) async throws -> TableStats { throw DriverError.unsupported("scripted") }
    func ddl(of object: SchemaObject) async throws -> String { "" }
}

/// A session's own connection on an engine with the read-only contract.
/// Nothing in these tests runs on it.
actor MainConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DriverError.unsupported("never run")) }
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DriverError.unsupported("never run")) }
    }

    func prepareReadOnly() async throws {}
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { ROIntrospector() }
    func ping() async -> Bool { true }
    func close() async {}
}

/// A connection without the read-only contract: a session's own connection
/// on such an engine, or what a driver without it hands back.
actor PlainConnection: DriverConnection {
    nonisolated let id = UUID()
    private let script: ROScript?

    init(script: ROScript? = nil) { self.script = script }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DriverError.unsupported("never run")) }
    }

    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { ROIntrospector() }
    func ping() async -> Bool { true }
    func close() async { await script?.closed() }
}
