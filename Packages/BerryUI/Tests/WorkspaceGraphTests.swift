import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryGraph
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Harvest-on-refresh + live `graph_query` wiring,
/// end-to-end through the workspace against an in-process SQLite schema.
/// Serialized: every test calls `DriverRegistry.register(SQLiteDriver.self)`
/// (shared global state) — running them concurrently is a pre-existing race
/// that got more likely to manifest once a 6th test joined this suite.
@MainActor
@Suite("Workspace DSG harvest + graph_query", .serialized)
struct WorkspaceGraphTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    private func exec(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    private func decode(_ outcome: ToolOutcome) -> [String: Any] {
        guard let json = outcome.resultJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func makeSQLiteDB() -> String {
        DriverRegistry.register(SQLiteDriver.self)
        let path = tempPath("db")
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    @Test func harvestOnRefreshPopulatesDSGAndGraphQueryAnswers() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)

        try await exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)", on: session)
        try await exec("""
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                customer_id INTEGER REFERENCES customers(id)
            )
            """, on: session)

        // Refresh picks up the new tables; harvest runs off the UI path, so drive
        // it deterministically here.
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        // The live graph_query tool loads the persisted DSG and answers blast
        // radius — proving harvest persisted and the tool reads it back.
        let executor = try #require(vm.graphExecutor(profileID: profile.id))
        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "graph_query", args: ["op": "blast_radius", "node": "customers"]
        ))
        #expect(outcome.status == "ok")
        #expect(Set(decode(outcome)["impacted"] as? [String] ?? []).contains("orders"))

        vm.disconnect()
    }

    @Test func analyzeInsightsFlagsSchemaProblemsAfterHarvest() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        // No primary key and every column nullable → two structural insights.
        try await exec("CREATE TABLE logs (msg TEXT, note TEXT)", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        let insights = await vm.analyzeInsights()
        #expect(insights.contains { $0.id == "schema.missing_pk.logs" })
        #expect(insights.contains { $0.id == "schema.all_nullable.logs" })

        // Reveal selects the object in the sidebar.
        vm.revealObject(named: "logs")
        #expect(vm.selectedObjectID != nil)

        vm.disconnect()
    }

    @Test func analyzeInsightsEmptyWithoutHarvest() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let empty = await vm.analyzeInsights()
        #expect(empty.isEmpty)
    }

 /// `preview_migration` tool bridge: a
    /// real end-to-end pass through live introspection + the harvested graph
    /// + `MigrationPreviewAnalyzer` — proven via the analyzer's own
    /// "hidden FK" rule (MigrationPreviewAnalyzerTests.swift), which only
    /// fires when the proposed column is correctly combined with the
    /// table's real existing columns and cross-referenced against another
    /// real harvested table (`customers`), not evaluated in isolation.
    @Test func previewNewColumnFlagsAHiddenForeignKeyIntroducedByTheColumn() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE customers (id INTEGER PRIMARY KEY)", on: session)
        try await exec("CREATE TABLE orders (id INTEGER PRIMARY KEY)", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        let insights = try #require(await vm.previewNewColumn(
            table: "orders", column: ColumnDesign(name: "customer_id", type: "INTEGER")
        ))
        #expect(insights.contains { $0.id == "schema.hidden_fk.orders.customer_id" })

        vm.disconnect()
    }

    @Test func previewNewColumnReturnsNilForATableNotInTheHarvestedSchema() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE logs (msg TEXT, note TEXT)", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        let insights = await vm.previewNewColumn(
            table: "does_not_exist", column: ColumnDesign(name: "extra", type: "TEXT")
        )
        #expect(insights == nil)

        vm.disconnect()
    }

    @Test func dismissingAnInsightHidesItFromLaterAnalyses() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE logs (msg TEXT, note TEXT)", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        let before = await vm.analyzeInsights()
        #expect(before.contains { $0.id == "schema.missing_pk.logs" })

        vm.recordInsightDismissed("schema.missing_pk.logs")

        let after = await vm.analyzeInsights()
        #expect(!after.contains { $0.id == "schema.missing_pk.logs" })
        // A different, non-dismissed insight on the same table still shows.
        #expect(after.contains { $0.id == "schema.all_nullable.logs" })

        vm.disconnect()
    }

    @Test func graphOverviewReportsDependenciesAndBlastRadius() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)", on: session)
        try await exec("""
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                customer_id INTEGER REFERENCES customers(id)
            )
            """, on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        #expect(Set(vm.harvestedTableNames()) == ["customers", "orders"])
        // orders → customers (FK out); customers ← orders (blast radius).
        #expect(vm.graphOverview("orders").dependsOn.contains("customers"))
        #expect(vm.graphOverview("customers").blastRadius.contains("orders"))
        #expect(vm.graphOverview("customers").dependents.contains("orders"))

        vm.disconnect()
    }

 /// quantified impact complements
    /// `graphOverview`'s pure topology with real, recently-executed queries
    /// that touch the affected tables.
    @Test func simulateImpactFindsBlastRadiusAndMatchingRecentQueries() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)", on: session)
        try await exec("""
            CREATE TABLE orders (
                id INTEGER PRIMARY KEY,
                customer_id INTEGER REFERENCES customers(id)
            )
            """, on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        // A real SELECT against `orders`, run through the actual history-sink
        // path (not the raw connection the other tests use), so it lands in
        // query_history the same way a user's query would.
        for try await _ in QueryService.execute("SELECT * FROM orders", on: session) {}

        let report = try #require(vm.simulateImpact("customers"))

        #expect(report.affectedTables.sorted() == ["customers", "orders"])
        #expect(report.affectedQueries.contains { $0.sql.contains("orders") })
        #expect(report.totalCallCount == 1)

        vm.disconnect()
    }

    @Test func simulateImpactReturnsNilWithoutAnyHarvestedGraph() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(vm.simulateImpact("customers") == nil)
    }

 /// "Save for Replay" reuses the duration
    /// already measured by the run that just finished — the first save has
    /// nothing to compare against; the second reports the delta.
    @Test func saveQueryReplayComparesAgainstThePreviousSnapshot() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        _ = try #require(vm.session)
        let sql = "SELECT * FROM orders"

        let firstSave = await vm.saveQueryReplay(sql: sql, durationMS: 420)
        #expect(firstSave == nil)

        let secondSave = try #require(await vm.saveQueryReplay(sql: sql, durationMS: 63))
        #expect(secondSave.earlier.durationMS == 420)
        #expect(secondSave.later.durationMS == 63)
        #expect(secondSave.improved)
        #expect(secondSave.deltaMS == -357)

        vm.disconnect()
    }

    @Test func saveQueryReplayReturnsNilWithoutAnActiveProfile() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(await vm.saveQueryReplay(sql: "SELECT 1", durationMS: 10) == nil)
    }

    /// Query Replay's saved snapshot now also captures a fresh EXPLAIN QUERY
 /// PLAN — this exercises real capture
    /// end-to-end against SQLite (the only dialect available without an
    /// external server in this test environment).
    @Test func saveQueryReplayCapturesAPlanForAnExistingTable() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE orders (id INTEGER PRIMARY KEY)", on: session)
        let sql = "SELECT * FROM orders"

        _ = await vm.saveQueryReplay(sql: sql, durationMS: 100)
        let comparison = try #require(await vm.saveQueryReplay(sql: sql, durationMS: 80))

        let planJSON = try #require(comparison.later.planJSON)
        #expect(planJSON.contains("\"text\""))

        vm.disconnect()
    }

    @Test func productionProfileIsNotHarvested() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
 // envColor "production" →: harvester off.
        let profile = ConnectionProfile(
            driverID: "sqlite", name: "prod", envColor: "production", filePath: makeSQLiteDB()
        )
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: session)

        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        // Nothing was harvested, so the tool reports an empty DSG.
        let executor = try #require(vm.graphExecutor(profileID: profile.id))
        let outcome = await executor.execute(AIToolCall(id: "c", name: "graph_query", args: ["op": "scc"]))
        #expect(outcome.status == "error")
        vm.disconnect()
    }
}
