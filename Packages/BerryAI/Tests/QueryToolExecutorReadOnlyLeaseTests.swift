import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryAI
@testable import BerryCore

/// Records every card and denies it. No statement in these tests should
/// need one.
@MainActor
private final class CardRecorder: AIApprovalGate {
    private(set) var cards: [String] = []

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        cards.append(sql)
        return false
    }

    func approveOnSessionConnection(
        sql: String, danger: DangerLevel, reason: ReadOnlyUnavailableReason, timeoutSeconds: TimeInterval
    ) async -> Bool {
        cards.append(sql)
        return false
    }
}

/// What the read-only connections a pool opens for one test do with each
/// statement, and what happened to them.
private actor LeaseScript {
    enum Answer: Sendable {
        case rows
        case failure(DriverError)
        /// Sends its columns, then waits for `release()` whatever happens
        /// to its stream, as a statement stuck on its socket would.
        case held
    }

    private let answer: Answer
    private let holdsConnects: Bool
    private(set) var connects = 0
    private(set) var ran: [String] = []
    private(set) var holding = 0
    private(set) var cancels = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ answer: Answer = .rows, holdsConnects: Bool = false) {
        self.answer = answer
        self.holdsConnects = holdsConnects
    }

    func connecting() async {
        connects += 1
        guard holdsConnects else { return }
        await hold()
    }

    func run(_ sql: String, _ continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        ran.append(sql)
        continuation.yield(.columns([ColumnMeta(name: "id", declaredType: "INTEGER")]))
        switch answer {
        case .rows:
            break
        case .failure(let error):
            continuation.finish(throwing: error)
            return
        case .held:
            holding += 1
            await hold()
        }
        continuation.yield(.rows([[.int(1)]]))
        continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
        continuation.finish()
    }

    /// Lets every held connect and statement go on, and every later one
    /// through without waiting.
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func statementCancelled() { cancels += 1 }

    private func hold() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// The pool builds its driver with no arguments, so the driver finds the
/// test's script by the configuration's name.
private actor LeaseScripts {
    static let shared = LeaseScripts()
    private var scripts: [String: LeaseScript] = [:]

    func register(_ script: LeaseScript, as name: String) { scripts[name] = script }
    func script(named name: String) -> LeaseScript? { scripts[name] }
}

private struct LeaseScriptedDriver: DatabaseDriver {
    static let id = DriverID.postgres
    static let displayName = "Scripted"
    static let capabilities = Capabilities()
    static let dialect: any SQLDialect = SQLiteDialect()

    init() {}

    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let script = await LeaseScripts.shared.script(named: config.name) else {
            throw DriverError.connectionFailed("no script for this configuration")
        }
        await script.connecting()
        return LeaseScriptedConnection(script: script)
    }
}

/// Ends a statement's stream when its consumer goes away and counts that
/// as a cancel, the way a driver's cancel path sees it.
private actor LeaseScriptedConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private let script: LeaseScript

    init(script: LeaseScript) { self.script = script }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DriverError.unsupported("not the read-only path")) }
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            let task = Task { await script.run(sql, continuation) }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                Task { await script.statementCancelled() }
            }
        }
    }

    func prepareReadOnly() async throws {}
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

/// A session's own connection on an engine with the read-only contract;
/// records what reaches it.
private actor SessionConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private(set) var ran: [String] = []

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(sql)
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            }
        }
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: DriverError.unsupported("not this connection's read-only path")) }
    }

    private func record(_ sql: String) { ran.append(sql) }
    func prepareReadOnly() async throws {}
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

@MainActor
private final class Validity {
    var isValid = true
}

/// Every lease the read-only route hands the executor goes back to the
/// pool, however the statement ends: a lease never given back keeps its
/// connection open for good, and the pool neither checks nor closes it.
/// The route is a real pool over a scripted driver, so these tests count
/// what the pool itself still holds.
@MainActor
@Suite("QueryToolExecutor read-only leases", .timeLimit(.minutes(2)))
struct QueryToolExecutorReadOnlyLeaseTests {
    private struct Fixture {
        let session: Session
        let main: SessionConnection
        let pool: ReadOnlyConnections
        let script: LeaseScript
    }

    private func fixture(_ script: LeaseScript) async -> Fixture {
        let name = UUID().uuidString
        await LeaseScripts.shared.register(script, as: name)
        let main = SessionConnection()
        let session = Session(
            id: UUID(), profileID: nil, isProduction: false,
            config: ConnectionConfig(driver: .postgres, name: name),
            connection: main,
            capabilities: Capabilities(), dialect: SQLiteDialect(),
            driverDisplayName: "Scripted", tunnel: nil, recordHistory: false
        )
        let pool = ReadOnlyConnections(driverType: { _ in LeaseScriptedDriver.self }, clock: .system)
        return Fixture(session: session, main: main, pool: pool, script: script)
    }

    /// The panel's routing over the fixture's pool.
    private func router(_ fixture: Fixture) -> @MainActor (Session) async -> ReadOnlyRoute {
        let router = ReadOnlyRouter(connections: fixture.pool, tracker: SessionStateTracker(), transactionIsActive: { false })
        return { await router.route(for: $0) }
    }

    private func executor(
        _ fixture: Fixture, gate: CardRecorder,
        route: (@MainActor (Session) async -> ReadOnlyRoute)? = nil,
        tab: [String] = [], queryTimeoutSeconds: TimeInterval = 90
    ) -> QueryToolExecutor {
        QueryToolExecutor(
            session: fixture.session, gate: gate,
            options: .init(allowSampleRows: true, autoApproveSelects: true),
            onPropose: { _, _ in },
            activeTabStatements: { _ in tab },
            readOnlyRoute: route ?? router(fixture),
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }

    private func runSQL(_ sql: String) -> AIToolCall {
        AIToolCall(id: "c", name: "run_sql", args: ["sql": sql])
    }

    /// Polls rather than suspends, so the suite's time limit can end it.
    /// The deadline is long because the whole suite runs in parallel on a
    /// loaded machine; it only costs time when the condition never holds.
    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 60 seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Lets anything still held finish, then closes the pool.
    private func tearDown(_ fixture: Fixture) async {
        await fixture.script.release()
        await fixture.pool.closeAll()
    }

    @Test func everyToolThatRunsAutomaticallyGivesItsLeaseBack() async {
        let fixture = await fixture(LeaseScript())
        let gate = CardRecorder()
        let executor = executor(fixture, gate: gate, tab: ["SELECT 1", "SELECT 2"])

        let run = await executor.execute(runSQL("SELECT id FROM t"))
        let sample = await executor.execute(AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "t"]))
        let tab = await executor.execute(AIToolCall(id: "c", name: "run_tab_statements", args: ["which": "all"]))

        #expect([run.status, sample.status, tab.status] == ["ok", "ok", "ok"])
        #expect(await fixture.script.ran.count == 4)
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    @Test func aStatementThatFailsGivesItsLeaseBack() async {
        let fixture = await fixture(LeaseScript(.failure(.queryFailed(message: "no such table: t", code: nil))))
        let gate = CardRecorder()

        let outcome = await executor(fixture, gate: gate).execute(runSQL("SELECT id FROM t"))

        #expect(outcome.status == "error")
        #expect(await fixture.script.ran == ["SELECT id FROM t LIMIT 1000"])
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    /// The statement ignores its cancel, as one stuck on its socket would.
    /// Its lease goes back when the tool call gives up, not when the
    /// statement ends, so the pool can check the connection and drop it.
    @Test func aStatementThatTimesOutGivesItsLeaseBackWhileStillStuck() async {
        let fixture = await fixture(LeaseScript(.held))
        let gate = CardRecorder()

        let outcome = await executor(fixture, gate: gate, queryTimeoutSeconds: 0.2).execute(runSQL("SELECT id FROM t"))

        #expect(outcome.status == "error")
        #expect(outcome.resultJSON?.contains("timed out") == true)
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(await fixture.script.holding == 1)
        await waitUntil { await fixture.script.cancels == 1 }
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    /// Stopping the turn ends the statement on the read-only connection
    /// through its stream, which is how a driver's cancel path reaches the
    /// server, and gives the lease back.
    @Test func aCancelledTurnEndsTheStatementAndGivesItsLeaseBack() async {
        let fixture = await fixture(LeaseScript(.held))
        let gate = CardRecorder()
        let executor = executor(fixture, gate: gate)

        let call = Task { await executor.execute(runSQL("SELECT id FROM t")) }
        await waitUntil { await fixture.script.holding == 1 }
        call.cancel()

        #expect(await call.value.status == "denied")
        await waitUntil { await fixture.script.cancels == 1 }
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    /// The host revoked the call's execution lease while rows were on the
    /// way, so the executor stopped reading before the stream completed.
    @Test func aStreamLeftBeforeItsEndGivesItsLeaseBack() async {
        let fixture = await fixture(LeaseScript(.held))
        let gate = CardRecorder()
        let validity = Validity()
        let executor = executor(fixture, gate: gate)

        let call = Task {
            await executor.execute(self.runSQL("SELECT id FROM t"), lease: AIExecutionLease { validity.isValid })
        }
        await waitUntil { await fixture.script.holding == 1 }
        validity.isValid = false
        await fixture.script.release()

        #expect(await call.value.status == "denied")
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    /// A route can hand out a lease to a turn already cancelled, since the
    /// pool goes on opening the connection for it. The executor gives it
    /// back without running anything on it.
    @Test func aLeaseHandedOutAfterTheTurnWasCancelledIsGivenBack() async {
        let fixture = await fixture(LeaseScript(holdsConnects: true))
        let gate = CardRecorder()
        let pool = fixture.pool
        let executor = executor(fixture, gate: gate, route: { session in
            guard let lease = try? await pool.lease(for: session) else { return .notSupported }
            return .readOnly(lease)
        })

        let call = Task { await executor.execute(runSQL("SELECT id FROM t")) }
        await waitUntil { await fixture.script.connects == 1 }
        call.cancel()
        await fixture.script.release()

        #expect(await call.value.status == "denied")
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(await fixture.script.ran.isEmpty)
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }

    /// The router gives back a lease that arrives after its caller was
    /// cancelled and answers that the connection is unavailable. A turn
    /// that was stopped asks for no card.
    @Test func aTurnCancelledWhileTheConnectionOpensAsksForNoCard() async {
        let fixture = await fixture(LeaseScript(holdsConnects: true))
        let gate = CardRecorder()
        let executor = executor(fixture, gate: gate)

        let call = Task { await executor.execute(runSQL("SELECT id FROM t")) }
        await waitUntil { await fixture.script.connects == 1 }
        call.cancel()
        await fixture.script.release()

        #expect(await call.value.status == "denied")
        await waitUntil { await fixture.pool.unfinishedLeases == 0 }
        #expect(gate.cards.isEmpty)
        #expect(await fixture.main.ran.isEmpty)
        await tearDown(fixture)
    }
}
