import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryAI
@testable import BerryCore

/// The panel's gate: records every card and answers each with `approves`.
/// `trusts` stands for Run All Safe having been used this turn.
@MainActor
private final class RoutingGate: AIApprovalGate {
    var approves: Bool
    var trusts = false
    private(set) var cards: [String] = []
    private(set) var reasons: [ReadOnlyUnavailableReason] = []

    init(approves: Bool) { self.approves = approves }

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        cards.append(sql)
        return approves
    }

    func trustsWithoutCard(sql: String, danger: DangerLevel) -> Bool { trusts }

    func approveOnSessionConnection(
        sql: String, danger: DangerLevel, reason: ReadOnlyUnavailableReason, timeoutSeconds: TimeInterval
    ) async -> Bool {
        cards.append(sql)
        reasons.append(reason)
        return approves
    }
}

/// Records each statement and the path it took, and answers it with one
/// row. Serves as a session's own connection and as its read-only one.
private actor RecordingConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private let readOnlyFailure: DriverError?
    private(set) var onSessionPath: [String] = []
    private(set) var onReadOnlyPath: [String] = []

    init(readOnlyFailure: DriverError? = nil) {
        self.readOnlyFailure = readOnlyFailure
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.run(sql, readOnly: false, continuation) }
        }
    }

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { await self.run(sql, readOnly: true, continuation) }
        }
    }

    private func run(_ sql: String, readOnly: Bool, _ continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) {
        if readOnly {
            onReadOnlyPath.append(sql)
            if let readOnlyFailure {
                continuation.finish(throwing: readOnlyFailure)
                return
            }
        } else {
            onSessionPath.append(sql)
        }
        continuation.yield(.columns([ColumnMeta(name: "id", declaredType: "INTEGER")]))
        continuation.yield(.rows([[.int(1)]]))
        continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
        continuation.finish()
    }

    func prepareReadOnly() async throws {}
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

/// A session's own connection on an engine without the read-only contract.
private actor PlainRecordingConnection: DriverConnection {
    nonisolated let id = UUID()
    private(set) var onSessionPath: [String] = []

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(sql)
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            }
        }
    }

    private func record(_ sql: String) { onSessionPath.append(sql) }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

/// The panel's routing closure with a fixed answer; counts its calls and
/// the read-only connection's hand-backs.
@MainActor
private final class Routing {
    enum Answer {
        case readOnly
        case notSupported
        case unavailable(ReadOnlyUnavailableReason)
    }

    let readOnly: RecordingConnection
    let answer: Answer
    private(set) var calls = 0
    private(set) var handedBack: [Bool] = []

    init(_ answer: Answer, readOnly: RecordingConnection = RecordingConnection()) {
        self.answer = answer
        self.readOnly = readOnly
    }

    func route(_ session: Session) async -> ReadOnlyRoute {
        calls += 1
        switch answer {
        case .readOnly:
            return .readOnly(ReadOnlyLease(connection: readOnly) { failed in await self.handBack(failed) })
        case .notSupported:
            return .notSupported
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    private func handBack(_ failed: Bool) { handedBack.append(failed) }
}

@MainActor
@Suite("QueryToolExecutor read-only routing")
struct QueryToolExecutorReadOnlyRoutingTests {
    private func session(main: any DriverConnection) -> Session {
        Session(
            id: UUID(), profileID: nil, isProduction: false,
            config: ConnectionConfig(driver: .sqlite, name: "scripted"),
            connection: main,
            capabilities: Capabilities(), dialect: SQLiteDialect(),
            driverDisplayName: "Scripted", tunnel: nil, recordHistory: false
        )
    }

    private func executor(
        _ session: Session, gate: RoutingGate, routing: Routing?,
        autoRun: Bool = true, sampleRows: Bool = false, tab: [String] = []
    ) -> QueryToolExecutor {
        var route: (@MainActor (Session) async -> ReadOnlyRoute)?
        if let routing {
            route = { await routing.route($0) }
        }
        return QueryToolExecutor(
            session: session, gate: gate,
            options: .init(allowSampleRows: sampleRows, autoApproveSelects: autoRun),
            onPropose: { _, _ in },
            activeTabStatements: { _ in tab },
            readOnlyRoute: route
        )
    }

    private func runSQL(_ executor: QueryToolExecutor, _ sql: String) async -> ToolOutcome {
        await executor.execute(AIToolCall(id: "c", name: "run_sql", args: ["sql": sql]))
    }

    /// Polls rather than suspends. The deadline is long because the whole
    /// suite runs in parallel on a loaded machine; it only costs time when
    /// the condition never holds.
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

    @Test func anAutomaticRunGoesToTheReadOnlyConnection() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        let routing = Routing(.readOnly)

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing), "SELECT id FROM t")

        #expect(outcome.status == "ok")
        #expect(gate.cards.isEmpty)
        #expect(await routing.readOnly.onReadOnlyPath == ["SELECT id FROM t LIMIT 1000"])
        #expect(await main.onSessionPath.isEmpty)
    }

    @Test func anAutomaticRunThatCannotUseTheReadOnlyConnectionWaitsForACard() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        let routing = Routing(.unavailable(.sessionState))

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing), "SELECT id FROM t")

        #expect(outcome.status == "denied")
        #expect(gate.reasons == [.sessionState])
        #expect(await main.onSessionPath.isEmpty)
    }

    @Test func onceItsCardIsApprovedTheStatementRunsOnTheSessionConnection() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: true)
        let routing = Routing(.unavailable(.connectionFailed("too many connections")))

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing), "SELECT id FROM t")

        #expect(outcome.status == "ok")
        #expect(gate.reasons == [.connectionFailed("too many connections")])
        #expect(await main.onSessionPath == ["SELECT id FROM t LIMIT 1000"])
        #expect(await routing.readOnly.onReadOnlyPath.isEmpty)
    }

    /// A function the classifier cannot see into wrote, and the server
    /// refused it. The model gets the refusal; the statement does not run
    /// again anywhere.
    @Test func aWriteTheServerRefusedIsNeverRetriedOnTheSessionConnection() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: true)
        let refusing = RecordingConnection(readOnlyFailure: .queryFailed(
            message: "cannot execute INSERT in a read-only transaction", code: nil
        ))
        let routing = Routing(.readOnly, readOnly: refusing)

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing), "SELECT write_audit_row()")

        #expect(outcome.status == "error")
        #expect(outcome.resultJSON?.contains("read-only transaction") == true)
        #expect(gate.cards.isEmpty)
        #expect(await main.onSessionPath.isEmpty)
    }

    /// The read-only mode could not start, so the statement never ran; it
    /// gets the card, as when the connection could not open.
    @Test func aReadOnlyModeThatCannotStartFallsBackToTheCard() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: true)
        let refusing = RecordingConnection(readOnlyFailure: .readOnlyUnavailable("BEGIN refused in statement pooling mode"))
        let routing = Routing(.readOnly, readOnly: refusing)

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing), "SELECT id FROM t")

        #expect(outcome.status == "ok")
        #expect(gate.reasons == [.connectionFailed("BEGIN refused in statement pooling mode")])
        #expect(await main.onSessionPath == ["SELECT id FROM t LIMIT 1000"])
    }

    /// Guard: a statement the user approved on its own card, a write among
    /// them, runs on the session's own connection as before.
    @Test func aCardApprovedStatementStaysOnTheSessionConnection() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: true)
        let routing = Routing(.readOnly)
        let executor = executor(session(main: main), gate: gate, routing: routing, autoRun: false)

        _ = await runSQL(executor, "SELECT id FROM t")
        _ = await runSQL(executor, "INSERT INTO t (id) VALUES (2)")

        #expect(gate.cards == ["SELECT id FROM t", "INSERT INTO t (id) VALUES (2)"])
        #expect(await main.onSessionPath == ["SELECT id FROM t LIMIT 1000", "INSERT INTO t (id) VALUES (2)"])
        #expect(routing.calls == 0)
    }

    /// Guard: SQL Server and DynamoDB have no read-only connection and keep
    /// running a proven read without a card on their own connection.
    @Test func anEngineWithoutTheContractKeepsAutomaticRunsOnItsConnection() async {
        let viaRouting = PlainRecordingConnection()
        let withoutRouting = PlainRecordingConnection()
        let gate = RoutingGate(approves: false)

        _ = await runSQL(executor(session(main: viaRouting), gate: gate, routing: Routing(.notSupported)), "SELECT id FROM t")
        _ = await runSQL(executor(session(main: withoutRouting), gate: gate, routing: nil), "SELECT id FROM t")

        #expect(gate.cards.isEmpty)
        #expect(await viaRouting.onSessionPath == ["SELECT id FROM t LIMIT 1000"])
        #expect(await withoutRouting.onSessionPath == ["SELECT id FROM t LIMIT 1000"])
    }

    @Test func withoutRoutingAnEngineWithTheContractGetsACard() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: nil), "SELECT id FROM t")

        #expect(outcome.status == "denied")
        #expect(gate.cards == ["SELECT id FROM t"])
        #expect(await main.onSessionPath.isEmpty)
    }

    /// Run All Safe lets later reads through without a card; they are
    /// automatic runs and go to the read-only connection.
    @Test func aStatementTheGateTrustsGoesThroughTheReadOnlyRoute() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        gate.trusts = true
        let routing = Routing(.readOnly)

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing, autoRun: false), "SELECT id FROM t")

        #expect(outcome.status == "ok")
        #expect(gate.cards.isEmpty)
        #expect(await routing.readOnly.onReadOnlyPath == ["SELECT id FROM t LIMIT 1000"])
        #expect(await main.onSessionPath.isEmpty)
    }

    /// A trust skips the statement's own card, never the card that says the
    /// read-only connection cannot take it.
    @Test func aTrustedStatementThatCannotUseTheReadOnlyConnectionStillGetsACard() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        gate.trusts = true
        let routing = Routing(.unavailable(.sessionState))

        let outcome = await runSQL(executor(session(main: main), gate: gate, routing: routing, autoRun: false), "SELECT id FROM t")

        #expect(outcome.status == "denied")
        #expect(gate.reasons == [.sessionState])
        #expect(await main.onSessionPath.isEmpty)
    }

    /// The statement is built from a quoted table name and a LIMIT, so it
    /// keeps running without a card.
    @Test func sampleRowsUseTheReadOnlyConnectionWhenTheyCan() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        let routing = Routing(.readOnly)
        let executor = executor(session(main: main), gate: gate, routing: routing, sampleRows: true)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "t"]))

        #expect(outcome.status == "ok")
        #expect(await routing.readOnly.onReadOnlyPath == [#"SELECT * FROM "t" LIMIT 20"#])
        #expect(await main.onSessionPath.isEmpty)
        #expect(gate.cards.isEmpty)
    }

    @Test func sampleRowsRunOnTheSessionConnectionWithoutACardOtherwise() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        let executor = executor(
            session(main: main), gate: gate, routing: Routing(.unavailable(.sessionState)), sampleRows: true
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "t"]))

        #expect(outcome.status == "ok")
        #expect(await main.onSessionPath == [#"SELECT * FROM "t" LIMIT 20"#])
        #expect(gate.cards.isEmpty)
    }

    @Test func eachTabStatementThatRunsAutomaticallyGoesToTheReadOnlyConnection() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: true)
        let routing = Routing(.readOnly)
        let executor = executor(
            session(main: main), gate: gate, routing: routing,
            tab: ["SELECT id FROM t", "UPDATE t SET id = 2 WHERE id = 1", "SELECT 1"]
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_tab_statements", args: ["which": "all"]))

        #expect(outcome.status == "ok")
        #expect(gate.cards == ["UPDATE t SET id = 2 WHERE id = 1"])
        #expect(await routing.readOnly.onReadOnlyPath == ["SELECT id FROM t LIMIT 1000", "SELECT 1 LIMIT 1000"])
        #expect(await main.onSessionPath == ["UPDATE t SET id = 2 WHERE id = 1"])
    }

    /// A document store has no read-only connection; its boundary learns
    /// which statements ran without a card, so it can refuse one that
    /// resolves to a write.
    @Test func theDocumentStoreLearnsWhichStatementsRanWithoutACard() async {
        let gate = RoutingGate(approves: true)
        var calls: [(sql: String, autoRun: Bool)] = []
        let executor = QueryToolExecutor(
            gate: gate,
            onPropose: { _, _ in },
            executeStatement: { sql, _, autoRun in
                calls.append((sql, autoRun))
                return .payload(["executed": true])
            }
        )

        _ = await runSQL(executor, "db.users.find({})")
        _ = await runSQL(executor, "db.users.deleteMany({})")

        #expect(calls.map(\.sql) == ["db.users.find({})", "db.users.deleteMany({})"])
        #expect(calls.map(\.autoRun) == [true, false])
        #expect(gate.cards == ["db.users.deleteMany({})"])
    }

    /// Each statement hands the connection back once, so its idle countdown
    /// starts; a refused write counts as a failure, which makes the pool
    /// check that the connection still answers.
    @Test func theConnectionIsHandedBackOncePerStatement() async {
        let main = RecordingConnection()
        let gate = RoutingGate(approves: false)
        let refusing = Routing(.readOnly, readOnly: RecordingConnection(readOnlyFailure: .queryFailed(message: "read-only", code: nil)))
        let healthy = Routing(.readOnly)

        _ = await runSQL(executor(session(main: main), gate: gate, routing: healthy), "SELECT id FROM t")
        _ = await runSQL(executor(session(main: main), gate: gate, routing: refusing), "SELECT write_audit_row()")

        await waitUntil { healthy.handedBack.count == 1 && refusing.handedBack.count == 1 }
        #expect(healthy.handedBack == [false])
        #expect(refusing.handedBack == [true])
    }
}
