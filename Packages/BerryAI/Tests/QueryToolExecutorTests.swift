import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryStore
import Foundation
import Testing

@testable import BerryAI

/// Approval gate that records what it was asked and returns a scripted answer.
@MainActor
private final class ScriptedGate: AIApprovalGate {
    var decision: Bool
    private(set) var asked: [(sql: String, danger: DangerLevel, autoApprovable: Bool)] = []

    init(_ decision: Bool) { self.decision = decision }

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        asked.append((sql, danger, autoApprovable))
        return decision
    }
}

@MainActor
private final class SuspendedApprovalGate: AIApprovalGate {
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var decisionContinuation: CheckedContinuation<Bool, Never>?
    private var entered = false

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        return await withCheckedContinuation { decisionContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func resume(_ decision: Bool) {
        decisionContinuation?.resume(returning: decision)
        decisionContinuation = nil
    }
}

@MainActor
private final class LeaseInvalidator {
    var action: () -> Void = {}
    func invalidate() { action() }
}

/// Serialized: every test calls `DriverRegistry.register(SQLiteDriver.self)`
/// (shared global state, same as `WorkspaceGraphTests`) — running them
/// concurrently is a pre-existing race that grew more likely to manifest as
/// this suite (now 40+ tests) grew across the Artifacts phases.
@MainActor
@Suite("QueryToolExecutor", .serialized)
struct QueryToolExecutorTests {
    private func makeSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-ai-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        try await drain("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", on: session)
        try await drain("INSERT INTO t (id, name) VALUES (1, 'ann'), (2, 'bob')", on: session)
        return session
    }

    private func drain(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    private func decode(_ outcome: ToolOutcome) -> [String: Any] {
        guard let json = outcome.resultJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func makeExecutor(
        session: Session,
        gate: ScriptedGate,
        options: QueryToolExecutor.Options = .init(),
        onPropose: @escaping (String, String?) -> Void = { _, _ in },
        queryTimeoutSeconds: UInt64 = 90
    ) -> QueryToolExecutor {
        QueryToolExecutor(
            session: session,
            catalog: SchemaCatalog(session: session),
            gate: gate,
            options: options,
            onPropose: onPropose,
            queryTimeoutSeconds: queryTimeoutSeconds
        )
    }

    @Test func invalidatedHostLeaseStopsDatabaseActionAfterApproval() async {
        let gate = SuspendedApprovalGate()
        var actionCount = 0
        let query = QueryToolExecutor(
            gate: gate,
            options: .init(autoApproveSelects: false),
            onPropose: { _, _ in },
            executeStatement: { _, lease in
                guard lease.isValid else { return .denied }
                actionCount += 1
                return .payload(["executed": true])
            }
        )
        let router = ToolRouter(routes: [:], fallback: query)
        let host = LocalCapabilityHost(executor: router)
        let spec = AIToolSpec(
            name: "run_sql", description: "Run SQL",
            parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}"#
        )
        _ = try! host.beginTurn(with: [spec])
        try! host.setTransportMode(.legacy)

        let task = Task {
            await host.execute(AIToolCall(
                id: "c", name: "run_sql", args: ["sql": "DELETE FROM users"]
            ))
        }
        await gate.waitUntilEntered()
        host.invalidate()
        gate.resume(true)
        let outcome = await task.value

        #expect(outcome.status == "denied")
        #expect(actionCount == 0)
    }

    @Test func invalidatedLeaseStopsRemainingMultiWrites() async {
        let gate = ScriptedGate(true)
        var actionCount = 0
        let invalidator = LeaseInvalidator()
        let query = QueryToolExecutor(
            gate: gate,
            options: .init(autoApproveSelects: false),
            onPropose: { _, _ in },
            executeStatement: { _, lease in
                for _ in 0..<3 {
                    guard lease.isValid else { return .denied }
                    actionCount += 1
                    if actionCount == 1 { invalidator.invalidate() }
                }
                return .payload(["executed": true])
            }
        )
        let host = LocalCapabilityHost(executor: ToolRouter(routes: [:], fallback: query))
        let spec = AIToolSpec(
            name: "run_sql", description: "Run query writes",
            parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}"#
        )
        _ = try! host.beginTurn(with: [spec])
        try! host.setTransportMode(.legacy)
        invalidator.action = { host.invalidate() }

        let outcome = await host.execute(.init(
            id: "c", name: "run_sql", args: ["sql": "db.items.insertMany([])"]
        ))

        #expect(outcome.status == "denied")
        #expect(actionCount == 1)
    }

    @Test func schemaInvalidationSuppressesStaleResult() async {
        let invalidator = LeaseInvalidator()
        let query = QueryToolExecutor(
            gate: ScriptedGate(true),
            onPropose: { _, _ in },
            listCollections: {
                invalidator.invalidate()
                return ["stale_collection"]
            }
        )
        let host = LocalCapabilityHost(executor: ToolRouter(routes: [:], fallback: query))
        _ = try! host.beginTurn(with: [
            AIToolSpec(
                name: "get_schema", description: "Schema",
                parametersJSON: #"{"type":"object"}"#
            ),
        ])
        try! host.setTransportMode(.legacy)
        invalidator.action = { host.invalidate() }

        let outcome = await host.execute(.init(id: "c", name: "get_schema", args: [:]))

        #expect(outcome.status == "denied")
        #expect(outcome.resultJSON == nil)
    }

    @Test func getOpenTabsListsNumberedPanes() async throws {
        let session = try await makeSession()
        let snapshot = OpenTabsSnapshot(panes: [
            .init(id: "editor:tab-1", number: 1, focused: true, kind: "editor", title: "a.sql", sql: "SELECT 1"),
            .init(id: "table:tab-2", number: 2, focused: false, kind: "table", title: "users", sql: nil),
        ])
        let executor = QueryToolExecutor(
            session: session,
            catalog: SchemaCatalog(session: session),
            gate: ScriptedGate(true),
            onPropose: { _, _ in },
            readOpenTabs: { snapshot }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_open_tabs", args: [:]))

        #expect(outcome.status == "ok")
        let object = decode(outcome)
        #expect(object["pane_count"] as? Int == 2)
        #expect(object["focused_pane"] as? Int == 1)
        let panes = object["panes"] as? [[String: Any]]
        #expect(panes?.count == 2)
        #expect(panes?[0]["tab_id"] as? String == "editor:tab-1")
        #expect(panes?[0]["kind"] as? String == "editor")
        #expect(panes?[0]["sql"] as? String == "SELECT 1")
        #expect(panes?[1]["tab_id"] as? String == "table:tab-2")
        #expect(panes?[1]["kind"] as? String == "table")
        #expect(panes?[1]["sql"] == nil)
    }

    // MARK: - get_schema mode="overview"|"ddl" (Task 6.1/6.2)

    @Test func getSchemaDefaultsToOverviewWithoutDDL() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(false)
        let executor = makeExecutor(session: session, gate: gate)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_schema", args: [:]))

        #expect(outcome.status == "ok")
        #expect(gate.asked.isEmpty)
        let objects = decode(outcome)["objects"] as? [[String: Any]] ?? []
        let table = objects.first { ($0["name"] as? String) == "t" }
        #expect(table?["kind"] as? String == "table")
        #expect(table?["schema"] as? String == "")
        // Task 6.1: the default (no mode / mode="overview") never fetches DDL.
        #expect(table?["ddl"] == nil)
    }

    @Test func getSchemaExplicitOverviewModeMatchesDefault() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_schema", args: ["mode": "overview"])
        )

        #expect(outcome.status == "ok")
        let objects = decode(outcome)["objects"] as? [[String: Any]] ?? []
        #expect(objects.contains { ($0["name"] as? String) == "t" && $0["ddl"] == nil })
    }

    @Test func getSchemaDDLModeReturnsDDLForNamedTables() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_schema", args: ["mode": "ddl", "tables": "t"])
        )

        #expect(outcome.status == "ok")
        let objects = decode(outcome)["objects"] as? [[String: Any]] ?? []
        #expect(objects.count == 1)
        #expect(objects.first?["name"] as? String == "t")
        let ddl = (objects.first?["ddl"] as? String ?? "").uppercased()
        #expect(ddl.contains("CREATE TABLE"))
    }

    @Test func getSchemaDDLModeRequiresNonEmptyTables() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_schema", args: ["mode": "ddl"])
        )

        #expect(outcome.status == "error")
    }

    @Test func getSchemaDDLModeRejectsTooManyTables() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))
        let tooMany = (0..<51).map { "table_\($0)" }.joined(separator: ",")

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_schema", args: ["mode": "ddl", "tables": tooMany])
        )

        #expect(outcome.status == "error")
    }

    @Test func getSchemaDDLModeSkipsUnknownTableNamesSilently() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_schema", args: ["mode": "ddl", "tables": "does_not_exist"])
        )

        #expect(outcome.status == "ok")
        let objects = decode(outcome)["objects"] as? [[String: Any]] ?? []
        #expect(objects.isEmpty)
    }

    @Test func getSchemaOverviewOrdersEntriesByName() async throws {
        let session = try await makeSession()
        try await drain("CREATE TABLE zeta (id INTEGER)", on: session)
        try await drain("CREATE TABLE alpha (id INTEGER)", on: session)
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_schema", args: [:]))

        let names = (decode(outcome)["objects"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("alpha") && names.contains("zeta"))
        #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    @Test func getSchemaOverviewIsBoundedInSize() async throws {
        let session = try await makeSession()
        for i in 0..<310 {
            try await drain("CREATE TABLE extra_\(i) (id INTEGER)", on: session)
        }
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_schema", args: [:]))

        let objects = decode(outcome)["objects"] as? [[String: Any]] ?? []
        #expect(objects.count == 300) // bounded (Self.overviewLimit), not 311
    }

    @Test func getSchemaOverviewCachesUnchangedSchema() async throws {
        let session = try await makeSession()
        let catalog = SchemaCatalog(session: session)
        let executor = QueryToolExecutor(session: session, catalog: catalog, gate: ScriptedGate(false), onPropose: { _, _ in })

        let first = await executor.execute(AIToolCall(id: "c1", name: "get_schema", args: [:]))
        let second = await executor.execute(AIToolCall(id: "c2", name: "get_schema", args: [:]))

        #expect(first.resultJSON == second.resultJSON)
        #expect(executor.overviewBuildCount == 1) // second call was a cache hit
    }

    @Test func getSchemaOverviewRebuildsAfterExplicitSchemaRefresh() async throws {
        let session = try await makeSession()
        let catalog = SchemaCatalog(session: session)
        let executor = QueryToolExecutor(session: session, catalog: catalog, gate: ScriptedGate(false), onPropose: { _, _ in })

        _ = await executor.execute(AIToolCall(id: "c1", name: "get_schema", args: [:]))
        #expect(executor.overviewBuildCount == 1)

 // Explicit schema refresh (WorkspaceViewModel.refreshSchema()
        // calls catalog.invalidate() on this same actor before re-reading objects).
        try await drain("CREATE TABLE fresh (id INTEGER)", on: session)
        await catalog.invalidate()

        let outcome = await executor.execute(AIToolCall(id: "c2", name: "get_schema", args: [:]))

        #expect(executor.overviewBuildCount == 2) // digest changed → cache rebuilt
        let names = (decode(outcome)["objects"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("fresh"))
    }

    @Test func getSchemaOverviewDedupesConcurrentCallers() async throws {
        let session = try await makeSession()
        let catalog = SchemaCatalog(session: session)
        let executor = QueryToolExecutor(session: session, catalog: catalog, gate: ScriptedGate(false), onPropose: { _, _ in })

        async let r1 = executor.execute(AIToolCall(id: "c1", name: "get_schema", args: [:]))
        async let r2 = executor.execute(AIToolCall(id: "c2", name: "get_schema", args: [:]))
        async let r3 = executor.execute(AIToolCall(id: "c3", name: "get_schema", args: [:]))
        let outcomes = await [r1, r2, r3]

        #expect(outcomes.allSatisfy { $0.status == "ok" })
        #expect(outcomes.allSatisfy { $0.resultJSON == outcomes.first?.resultJSON })
        // overviewFetchCount (not overviewBuildCount — the digest cache alone
        // could also hold that at 1) proves the 3 concurrent callers shared
        // one catalog.objects() fetch instead of racing 3 independent ones.
        #expect(executor.overviewFetchCount == 1)
    }

    @Test func proposeSQLInsertsIntoEditorWithoutRunning() async throws {
        let session = try await makeSession()
        var proposed: String?
        let executor = makeExecutor(session: session, gate: ScriptedGate(false)) { sql, _ in proposed = sql }

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "propose_sql", args: ["sql": "DELETE FROM t"])
        )

        #expect(outcome.status == "ok")
        #expect(proposed == "DELETE FROM t")
        // Nothing ran: both rows are still there.
        var count = 0
        for try await event in session.connection.execute("SELECT count(*) FROM t") {
            if case let .rows(batch) = event { count = batch.count }
        }
        #expect(count == 1) // one row: the count(*) scalar
    }

    @Test func runSQLAutoApprovesSafeSelectAndSamples() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(false) // would deny if consulted
        let executor = makeExecutor(session: session, gate: gate)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "run_sql", args: ["sql": "SELECT id, name FROM t ORDER BY id"])
        )

        #expect(outcome.status == "ok")
        #expect(gate.asked.isEmpty) // safe SELECT auto-approved, no prompt
        let object = decode(outcome)
        #expect(object["columns"] as? [String] == ["id", "name"])
        let rows = object["rows"] as? [[Any]] ?? []
        #expect(rows.count == 2)
        #expect(object["truncated"] as? Bool == false)
    }

    @Test func runSQLWriteAlwaysPromptsEvenWhenLexicallySafe() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(true)
        let executor = makeExecutor(session: session, gate: gate)

        // A plain INSERT is DangerLevel.safe on a non-production connection, yet
 // AI writes must always be approved.
        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "run_sql", args: ["sql": "INSERT INTO t (id, name) VALUES (3, 'cal')"])
        )

        #expect(outcome.status == "ok")
        #expect(gate.asked.count == 1)
        #expect(gate.asked.first?.autoApprovable == false)
    }

    private struct DenyAllConfirmer: DangerConfirmer {
        func confirm(_ level: DangerLevel, sql: String) async -> Bool { false }
    }

    /// Regression: without `dangerPreconfirmed: true` on QueryToolExecutor's
    /// QueryService.execute calls, a soft-delete statement (DELETE with a
    /// WHERE, non-production) already approved through the chat's own
    /// `gate` hit a SECOND confirmation inside QueryService itself — a
    /// blocking native alert invisible to the chat UI, which read as the
    /// whole tool call hanging. Installing a confirmer that denies
    /// everything proves QueryService's own gate is never consulted for
    /// this statement: it must still succeed.
    @Test func runSQLDoesNotDoubleConfirmASoftDeleteAlreadyApprovedByTheChatGate() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(true)
        let executor = makeExecutor(session: session, gate: gate)

        let previousConfirmer = QueryService.dangerConfirmer
        QueryService.dangerConfirmer = DenyAllConfirmer()
        defer { QueryService.dangerConfirmer = previousConfirmer }

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "run_sql", args: ["sql": "DELETE FROM t WHERE id = 1"])
        )

        #expect(outcome.status == "ok")
        #expect(gate.asked.count == 1)
        #expect(gate.asked.first?.danger == .confirm(.deleteData))

        QueryService.dangerConfirmer = previousConfirmer
        var rowCount = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rowCount += batch.count }
        }
        #expect(rowCount == 1, "the approved DELETE must actually have run")
    }

    @Test func runSQLDeniedByGateDoesNotRun() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(false)
        let executor = makeExecutor(session: session, gate: gate)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "run_sql", args: ["sql": "DELETE FROM t"])
        )

        #expect(outcome.status == "denied")
        #expect(gate.asked.count == 1)
        // Rows untouched.
        var rowCount = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rowCount += batch.count }
        }
        #expect(rowCount == 2)
    }

    /// Regression: a real database round-trip from run_sql must not be able
    /// to hang forever — PostgresNIO (and the other drivers) set no query
    /// timeout of their own, so a connection gone quietly dead mid-query
    /// (server already gone, socket wedged by a network blip) otherwise
    /// blocks indefinitely, and every later run_sql queues behind the same
    /// stuck connection. A `queryTimeoutSeconds` of 0 forces the timeout
    /// side of the race to win even against a normal, healthy query — this
    /// checks the race mechanism itself returns a clear error quickly rather
    /// than exercising an actual hang (which real drivers don't offer a
    /// clean way to simulate in a test).
    @Test func runSQLTimesOutInsteadOfHangingForever() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(true)
        let executor = makeExecutor(session: session, gate: gate, queryTimeoutSeconds: 0)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "run_sql", args: ["sql": "SELECT id, name FROM t ORDER BY id"])
        )

        #expect(outcome.status == "error")
        #expect(outcome.resultJSON?.contains("timed out") == true)
    }

    @Test func getSampleRowsDeniedWhenAI06Off() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(true))

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "t"])
        )

        #expect(outcome.status == "denied")
    }

    @Test func getSampleRowsRunsWhenAI06On() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(
            session: session,
            gate: ScriptedGate(false),
            options: .init(allowSampleRows: true)
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "t"])
        )

        #expect(outcome.status == "ok")
        let rows = decode(outcome)["rows"] as? [[Any]] ?? []
        #expect(rows.count == 2)
    }

    @Test func parseTableRefResolvesQualifiedAndUnambiguousNames() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "s1"),
            SchemaObject(kind: .table, name: "orders", database: "s1"),
            SchemaObject(kind: .table, name: "items", database: "s2")
        ]

        // 1. Explicit schema syntax
        let explicit = QueryToolExecutor.parseTableRef("s2.items", in: objects)
        if case .success(let ref) = explicit {
            #expect(ref.database == "s2")
            #expect(ref.name == "items")
        } else {
            Issue.record("Expected success for s2.items")
        }

        // 2. Unambiguous bare name
        let unambiguous = QueryToolExecutor.parseTableRef("orders", in: objects)
        if case .success(let ref) = unambiguous {
            #expect(ref.database == "s1")
            #expect(ref.name == "orders")
        } else {
            Issue.record("Expected success for unambiguous orders")
        }

        // 3. Ambiguous bare name
        let ambiguous = QueryToolExecutor.parseTableRef("items", in: objects)
        if case .failure(let error) = ambiguous {
            #expect(error.contains("ambiguous"))
            #expect(error.contains("s1") && error.contains("s2"))
        } else {
            Issue.record("Expected failure for ambiguous items")
        }
    }

    @Test func parseTableRefHandlesEdgeCases() {
        let objects = [
            SchemaObject(kind: .table, name: "Users", database: "auth"),
            SchemaObject(kind: .view, name: "Users", database: "public"),
            SchemaObject(kind: .table, name: "profiles", database: "public"),
            SchemaObject(kind: .table, name: "bare_only")
        ]

        // Quoted explicit table ref
        let quoted = QueryToolExecutor.parseTableRef("\"auth\".\"Users\"", in: objects)
        if case .success(let ref) = quoted {
            #expect(ref.database == "auth")
            #expect(ref.name == "Users")
        } else {
            Issue.record("Expected success for quoted ref")
        }

        // Case insensitivity for unambiguous
        let caseInsensitive = QueryToolExecutor.parseTableRef("PROFILES", in: objects)
        if case .success(let ref) = caseInsensitive {
            #expect(ref.database == "public")
            #expect(ref.name == "profiles")
        } else {
            Issue.record("Expected success for case-insensitive match")
        }

        // Ambiguous table across schemas returns error with both schemas
        let ambiguous = QueryToolExecutor.parseTableRef("users", in: objects)
        if case .failure(let error) = ambiguous {
            #expect(error.contains("Table 'users' is ambiguous across schemas (auth, public)"))
        } else {
            Issue.record("Expected failure for ambiguous users")
        }

        // Object with nil database resolves cleanly
        let bare = QueryToolExecutor.parseTableRef("bare_only", in: objects)
        if case .success(let ref) = bare {
            #expect(ref.database == nil)
            #expect(ref.name == "bare_only")
        } else {
            Issue.record("Expected success for bare_only")
        }

        // Unknown bare table falls back to TableRef with name
        let unknown = QueryToolExecutor.parseTableRef("nonexistent", in: objects)
        if case .success(let ref) = unknown {
            #expect(ref.database == nil)
            #expect(ref.name == "nonexistent")
        } else {
            Issue.record("Expected fallback for nonexistent")
        }
    }

    @Test func getSampleRowsRunsWithQualifiedTableName() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(
            session: session,
            gate: ScriptedGate(false),
            options: .init(allowSampleRows: true)
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_sample_rows", args: ["table": "main.t"])
        )

        #expect(outcome.status == "ok")
        let rows = decode(outcome)["rows"] as? [[Any]] ?? []
        #expect(rows.count == 2)
    }

    @Test func unknownToolIsAnError() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(true))
        let outcome = await executor.execute(AIToolCall(id: "c", name: "drop_everything", args: [:]))
        #expect(outcome.status == "error")
    }

 // MARK: - SQL-tab tools

    @Test func readCurrentTabReturnsSnapshot() async throws {
        let session = try await makeSession()
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            readActiveTab: {
                ActiveTabSnapshot(
                    tabID: "editor:tab-9", tabTitle: "Untitled", text: "SELECT 1;",
                    cursorLocation: 3, selectedRange: NSRange(location: 0, length: 0), pane: 1
                )
            }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "read_current_tab", args: [:]))

        #expect(outcome.status == "ok")
        let obj = decode(outcome)
        #expect(obj["tab_id"] as? String == "editor:tab-9")
        #expect(obj["tab_title"] as? String == "Untitled")
        #expect(obj["text"] as? String == "SELECT 1;")
        #expect(obj["cursor_location"] as? Int == 3)
        #expect(obj["pane"] as? Int == 1)
        let range = obj["selected_range"] as? [String: Any]
        #expect(range?["location"] as? Int == 0)
    }

    @Test func readCurrentTabFailsWhenNoEditorActive() async throws {
        let session = try await makeSession()
        // Default readActiveTab returns nil.
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))
        let outcome = await executor.execute(AIToolCall(id: "c", name: "read_current_tab", args: [:]))
        #expect(outcome.status == "error")
    }

    @Test func runTabStatementsRunsEachAndStopsOnDenial() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(false) // denies the write
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: gate,
            onPropose: { _, _ in },
            activeTabStatements: { _ in ["SELECT id FROM t ORDER BY id", "DELETE FROM t"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_tab_statements", args: ["which": "all"]))

        #expect(outcome.status == "ok")
        let obj = decode(outcome)
        let stmts = obj["statements"] as? [[String: Any]] ?? []
        #expect(stmts.count == 1) // SELECT auto-approved & ran; DELETE denied → stop
        #expect(stmts.first?["sql"] as? String == "SELECT id FROM t ORDER BY id")
        #expect(obj["stopped_early"] as? Bool == true)
        // The DELETE never ran: both rows remain.
        var rowCount = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rowCount += batch.count }
        }
        #expect(rowCount == 2)
    }

    @Test func runTabStatementsFailsWhenNoStatements() async throws {
        let session = try await makeSession()
        // Default activeTabStatements returns [].
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))
        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_tab_statements", args: ["which": "cursor"]))
        #expect(outcome.status == "error")
    }

    @Test func explainQueryReturnsPlanTree() async throws {
        let session = try await makeSession()
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(true),
            onPropose: { _, _ in },
            activeTabStatements: { mode in mode == "cursor" ? ["SELECT id, name FROM t WHERE id = 1"] : [] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "explain_query", args: [:]))

        #expect(outcome.status == "ok")
        // SQLite EXPLAIN QUERY PLAN → id/parent/detail → a PlanNode tree, not raw rows.
        let plan = decode(outcome)["plan"] as? [[String: Any]]
        #expect(plan != nil)
        #expect((plan?.isEmpty ?? true) == false)
    }

    @Test func explainQueryAlwaysAsksAndHonorsDenial() async throws {
        let session = try await makeSession()
        let gate = ScriptedGate(false)
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: gate,
            onPropose: { _, _ in },
            activeTabStatements: { _ in ["SELECT id FROM t"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "explain_query", args: [:]))

        // Even a plain SELECT is asked (EXPLAIN ANALYZE can run writes), and a
        // denial stops it.
        #expect(outcome.status == "denied")
        #expect(gate.asked.count == 1)
    }

    @Test func advertisesAllSqlAndTabTools() async throws {
        let session = try await makeSession()
        let executor = makeExecutor(session: session, gate: ScriptedGate(false))
        let names = executor.toolSpecs.map(\.name)
        for expected in [
            "get_schema", "run_sql", "read_current_tab", "run_tab_statements", "explain_query",
            "create_debug_tab", "open_mermaid_tab",
        ] {
            #expect(names.contains(expected), "advertises \(expected)")
        }
        // run_tab_statements exposes the which enum so the model picks a mode.
        let rts = executor.toolSpecs.first { $0.name == "run_tab_statements" }
        #expect(rts?.parametersJSON.contains("cursor") == true)
    }

    /// Reported live: the model had no tool that opened a `.mermaidDiagram`
    /// tab, so it reused `create_debug_tab` for a diagram, landing the raw
    /// Mermaid source in a plain SQL editor tab with no rendering at all.
    @Test func openMermaidTabForwardsDiagramAndTitle() async throws {
        let session = try await makeSession()
        var captured: (diagram: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            openMermaidTab: { diagram, title in captured = (diagram, title) }
        )

        let outcome = await executor.execute(
            AIToolCall(
                id: "c", name: "open_mermaid_tab",
                args: ["diagram": "erDiagram\n  A ||--o{ B : has", "title": "Schema overview"]
            )
        )

        #expect(outcome.status == "ok")
        #expect(captured?.diagram == "erDiagram\n  A ||--o{ B : has")
        #expect(captured?.title == "Schema overview")
    }

    @Test func openMermaidTabOmitsTitleWhenTheModelDoesNotSendOne() async throws {
        let session = try await makeSession()
        var captured: (diagram: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            openMermaidTab: { diagram, title in captured = (diagram, title) }
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "open_mermaid_tab", args: ["diagram": "flowchart TD\n  A --> B"])
        )

        #expect(outcome.status == "ok")
        #expect(captured?.title == nil)
    }

    @Test func openMermaidTabFailsWithoutADiagram() async throws {
        let session = try await makeSession()
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            openMermaidTab: { _, _ in Issue.record("must not open a tab without a diagram") }
        )

        let outcome = await executor.execute(AIToolCall(id: "c", name: "open_mermaid_tab", args: [:]))

        #expect(outcome.status == "error")
    }

    @Test func createDebugTabAlwaysCreatesNewTab() async throws {
        let session = try await makeSession()
        var captured: (sql: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            readActiveTab: {
                ActiveTabSnapshot(
                    tabID: "editor:tab-new", tabTitle: "Debug: slow query", text: "SELECT 1",
                    cursorLocation: 0, selectedRange: NSRange(location: 0, length: 0), pane: 1
                )
            },
            createDebugTab: { sql, title in captured = (sql, title) }
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "create_debug_tab", args: ["sql": "SELECT 1", "title": "Debug: slow query"])
        )

        #expect(outcome.status == "ok")
        #expect(captured?.sql == "SELECT 1")
        #expect(captured?.title == "Debug: slow query")
        let obj = decode(outcome)
        #expect(obj["tab_id"] as? String == "editor:tab-new")
        #expect(obj["tab_title"] as? String == "Debug: slow query")
        #expect(obj["pane"] as? Int == 1)
    }

    /// Reported: agent-created tabs were all named "Untitled", so a turn opening
    /// several left them indistinguishable. `title` is required by the backend
    /// schema now, but a model can still omit it — the client must not fall back
    /// to a generic name when the SQL itself says what the query is about.
    @Test func createDebugTabDerivesATitleWhenTheModelOmitsOne() async throws {
        let session = try await makeSession()
        var captured: (sql: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            readActiveTab: { nil },
            createDebugTab: { sql, title in captured = (sql, title) }
        )

        let outcome = await executor.execute(
            AIToolCall(
                id: "c", name: "create_debug_tab",
                args: ["sql": "SELECT relname, n_dead_tup FROM pg_stat_user_tables"]
            )
        )

        #expect(outcome.status == "ok")
        let title = try #require(captured?.title)
        #expect(title != "Untitled")
        #expect(
            title.localizedCaseInsensitiveContains("pg_stat_user_tables"),
            "the query's own subject is a better name than a generic one, got \(title)"
        )
    }

    /// Still reporting Untitled tabs after `create_debug_tab` was fixed, because
    /// `propose_sql` also opens a tab when none is present — and it passed no
    /// title at all, so that path always produced "Untitled".
    ///
    /// It has no `title` argument by design (it writes into whatever tab is
    /// already open, where renaming would be wrong), so the derived name is the
    /// only one available on the create-a-tab path.
    @Test func proposeCarriesADerivedTitleForWhenItHasToOpenATab() async throws {
        let session = try await makeSession()
        var captured: (sql: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { sql, title in captured = (sql, title) },
            readActiveTab: { nil },
            createDebugTab: { _, _ in }
        )

        let outcome = await executor.execute(
            AIToolCall(
                id: "c", name: "propose_sql",
                args: ["sql": "SELECT count(*) FROM pg_stat_user_tables"]
            )
        )

        #expect(outcome.status == "ok")
        let title = try #require(captured?.title)
        #expect(title.localizedCaseInsensitiveContains("pg_stat_user_tables"))
    }

    /// An explicit title always wins — the derivation is a fallback, not an
    /// override.
    @Test func createDebugTabPrefersTheModelsOwnTitle() async throws {
        let session = try await makeSession()
        var captured: (sql: String, title: String?)?
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            readActiveTab: { nil },
            createDebugTab: { sql, title in captured = (sql, title) }
        )

        _ = await executor.execute(
            AIToolCall(
                id: "c", name: "create_debug_tab",
                args: ["sql": "SELECT 1 FROM pg_stat_user_tables", "title": "Dead tuple bloat"]
            )
        )

        #expect(captured?.title == "Dead tuple bloat")
    }

 /// if the created tab's kind isn't covered by
    /// `readActiveTab()` (e.g. Qdrant today), the result still reports
    /// `created: true` — the tab_id/tab_title/pane fields are just omitted
    /// rather than failing the tool call.
    @Test func createDebugTabResultOmitsTabIdentityWhenActiveTabCannotBeRead() async throws {
        let session = try await makeSession()
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: ScriptedGate(false),
            onPropose: { _, _ in },
            createDebugTab: { _, _ in }
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "create_debug_tab", args: ["sql": "SELECT 1"])
        )

        #expect(outcome.status == "ok")
        let obj = decode(outcome)
        #expect(obj["created"] as? Bool == true)
        #expect(obj["tab_id"] == nil)
        #expect(obj["tab_title"] == nil)
    }

 // MARK: - Artifacts

    /// Minimal in-test stand-in for the tab/artifact-linking closures
    /// `WorkspaceViewModel`/`AIPanelController` normally provide in
    /// production — just enough mutable state to prove the executor's
    /// artifact recording end-to-end without pulling in BerryUI.
    @MainActor
    private final class FakeTabHost {
        var tabID: String
        var tabTitle: String
        var text: String
        var artifactID: UUID?
        /// false hides the tab entirely (readActiveTab returns nil) — the
        /// "no open tab" shape run_sql's ad-hoc path handles.
        var hasActiveTab = true

        init(tabID: String, tabTitle: String, text: String = "") {
            self.tabID = tabID
            self.tabTitle = tabTitle
            self.text = text
        }

        func snapshot() -> ActiveTabSnapshot? {
            guard hasActiveTab else { return nil }
            return ActiveTabSnapshot(
                tabID: tabID, tabTitle: tabTitle, text: text,
                cursorLocation: 0, selectedRange: NSRange(location: 0, length: 0)
            )
        }
    }

    private func makeArtifactExecutor(
        session: Session, gate: ScriptedGate, store: BerryStore, profileID: UUID, host: FakeTabHost
    ) -> QueryToolExecutor {
        QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: gate,
            onPropose: { text, _ in host.text = text },
            readActiveTab: { host.snapshot() },
            createDebugTab: { sql, title in
                host.text = sql
                if let title { host.tabTitle = title }
            },
            store: store, profileID: profileID,
            resolveArtifactID: { tabID in tabID == host.tabID ? host.artifactID : nil },
            linkArtifact: { tabID, artifactID in if tabID == host.tabID { host.artifactID = artifactID } }
        )
    }

    @Test func createDebugTabRecordsANewArtifactVersionAndLinksTheTab() async throws {
        let session = try await makeSession()
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let host = FakeTabHost(tabID: "editor:tab-1", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "create_debug_tab", args: ["sql": "SELECT 1", "title": "Slow query"])
        )

        let obj = decode(outcome)
        let artifactIDString = try #require(obj["artifact_id"] as? String)
        #expect(obj["artifact_version"] as? Int == 1)
        let artifactID = try #require(UUID(uuidString: artifactIDString))
        let artifact = try #require(try store.artifact(id: artifactID))
        #expect(artifact.kind == .editorTab)
        #expect(artifact.title == "Slow query")
        #expect(host.artifactID == artifactID) // linked back to the tab
        let version = try #require(try store.latestArtifactVersion(artifactID: artifactID))
        #expect(version.payload == "SELECT 1")
    }

    @Test func runningSQLOnALinkedTabAppendsAVersionInsteadOfANewArtifact() async throws {
        let session = try await makeSession()
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let host = FakeTabHost(tabID: "editor:tab-2", tabTitle: "Untitled", text: "SELECT * FROM t")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let first = decode(await executor.execute(
            AIToolCall(id: "c1", name: "run_sql", args: ["sql": "SELECT * FROM t"])
        ))
        let second = decode(await executor.execute(
            AIToolCall(id: "c2", name: "run_sql", args: ["sql": "SELECT * FROM t WHERE id = 1"])
        ))

        let artifactIDString = try #require(first["artifact_id"] as? String)
        #expect(second["artifact_id"] as? String == artifactIDString)
        #expect(first["artifact_version"] as? Int == 1)
        #expect(second["artifact_version"] as? Int == 2)
        let artifactID = try #require(UUID(uuidString: artifactIDString))
        #expect(try store.artifactVersions(artifactID: artifactID).count == 2)
    }

    @Test func runSQLWithNoActiveTabGroupsRepeatedAdHocRunsIntoOneArtifact() async throws {
        let session = try await makeSession()
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        host.hasActiveTab = false
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let first = decode(await executor.execute(
            AIToolCall(id: "c1", name: "run_sql", args: ["sql": "SELECT 1"])
        ))
        let second = decode(await executor.execute(
            AIToolCall(id: "c2", name: "run_sql", args: ["sql": "SELECT 2"])
        ))

        let artifactIDString = try #require(first["artifact_id"] as? String)
        #expect(second["artifact_id"] as? String == artifactIDString)
        #expect(first["artifact_version"] as? Int == 1)
        #expect(second["artifact_version"] as? Int == 2)
    }

    @Test func getArtifactReturnsMetadataAndLatestVersionByDefault() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1",
            resultSnapshotJSON: #"{"columns":["x"],"rows":[["1"]]}"#
        )
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 2")
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_artifact", args: ["artifact_id": artifact.id.uuidString])
        )

        let obj = decode(outcome)
        #expect(obj["title"] as? String == "Top customers")
        #expect(obj["kind"] as? String == "editorTab")
        #expect(obj["version_number"] as? Int == 2)
        #expect(obj["payload"] as? String == "SELECT 2")
    }

    @Test func getArtifactWithVersionNumberReturnsThatSpecificVersion() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 2")
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "get_artifact",
            args: ["artifact_id": artifact.id.uuidString, "version_number": "1"]
        ))

        let obj = decode(outcome)
        #expect(obj["version_number"] as? Int == 1)
        #expect(obj["payload"] as? String == "SELECT 1")
    }

    @Test func getArtifactOverviewReportsSingleChunkForAFlatResult() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1",
            resultSnapshotJSON: #"{"columns":["x"],"rows":[["1"]]}"#
        )
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_artifact_overview", args: ["artifact_id": artifact.id.uuidString])
        )

        let obj = decode(outcome)
        #expect(obj["title"] as? String == "Top customers")
        #expect(obj["version_number"] as? Int == 1)
        #expect(obj["chunk_count"] as? Int == 1)
        #expect(obj["payload_length"] as? Int == "SELECT 1".count)
        #expect(obj["payload"] == nil) // overview never includes full content
    }

    @Test func getArtifactOverviewReportsOneChunkPerStatementForATabRun() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Migration script")
        try store.saveArtifact(artifact)
        let statements = #"{"statements":[{"sql":"SELECT 1"},{"sql":"SELECT 2"},{"sql":"SELECT 3"}]}"#
        try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1\nSELECT 2\nSELECT 3", resultSnapshotJSON: statements
        )
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_artifact_overview", args: ["artifact_id": artifact.id.uuidString])
        )

        #expect(decode(outcome)["chunk_count"] as? Int == 3)
    }

    @Test func readArtifactChunkReturnsEachStatementInOrder() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Migration script")
        try store.saveArtifact(artifact)
        let statements = #"{"statements":[{"sql":"SELECT 1"},{"sql":"SELECT 2"}]}"#
        try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1\nSELECT 2", resultSnapshotJSON: statements
        )
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let first = decode(await executor.execute(AIToolCall(
            id: "c1", name: "read_artifact_chunk",
            args: ["artifact_id": artifact.id.uuidString, "chunk_index": "0"]
        )))
        let second = decode(await executor.execute(AIToolCall(
            id: "c2", name: "read_artifact_chunk",
            args: ["artifact_id": artifact.id.uuidString, "chunk_index": "1"]
        )))

        #expect(first["chunk_index"] as? Int == 0)
        #expect(first["total_chunks"] as? Int == 2)
        #expect((first["chunk"] as? [String: Any])?["sql"] as? String == "SELECT 1")
        #expect(second["chunk_index"] as? Int == 1)
        #expect((second["chunk"] as? [String: Any])?["sql"] as? String == "SELECT 2")
    }

    @Test func readArtifactChunkOutOfRangeFails() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1",
            resultSnapshotJSON: #"{"columns":["x"],"rows":[["1"]]}"#
        )
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "read_artifact_chunk",
            args: ["artifact_id": artifact.id.uuidString, "chunk_index": "5"]
        ))

        #expect(outcome.status == "error")
    }

    @Test func readArtifactChunkFailsWhenVersionHasNoResult() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Draft")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1", resultSnapshotJSON: nil)
        let session = try await makeSession()
        let host = FakeTabHost(tabID: "editor:unused", tabTitle: "Untitled")
        let executor = makeArtifactExecutor(
            session: session, gate: ScriptedGate(false), store: store, profileID: profileID, host: host
        )

        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "read_artifact_chunk",
            args: ["artifact_id": artifact.id.uuidString, "chunk_index": "0"]
        ))

        #expect(outcome.status == "error")
    }
}
