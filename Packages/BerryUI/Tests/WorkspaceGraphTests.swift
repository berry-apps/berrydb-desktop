import BerryAI
@testable import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryGraph
@testable import BerryStore
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

        #expect(Set(await vm.harvestedTableNames()) == ["customers", "orders"])
        // orders → customers (FK out); customers ← orders (blast radius).
        #expect(await vm.graphOverview("orders").dependsOn.contains("customers"))
        #expect(await vm.graphOverview("customers").blastRadius.contains("orders"))
        #expect(await vm.graphOverview("customers").dependents.contains("orders"))

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

        let report = try #require(await vm.simulateImpact("customers"))

        #expect(report.affectedTables.sorted() == ["customers", "orders"])
        #expect(report.affectedQueries.contains { $0.sql.contains("orders") })
        #expect(report.totalCallCount == 1)

        vm.disconnect()
    }

    @Test func simulateImpactReturnsNilWithoutAnyHarvestedGraph() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(await vm.simulateImpact("customers") == nil)
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
        #expect(await vm.metadataConnections.cachedSessionCount == 0)
        vm.disconnect()
    }

    /// Both tables in one transaction, so a pass running meanwhile sees
    /// neither or both and the schema history holds one change for them.
    private func createCustomersAndOrders(on session: Session) async throws {
        try await exec("""
            BEGIN;
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id));
            COMMIT;
            """, on: session)
    }

    private func connectedWorkspace(_ profile: ConnectionProfile) async throws -> (WorkspaceViewModel, Session) {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        await vm.connect(profile: profile)
        return (vm, try #require(vm.session))
    }

    @Test func harvestStoresTheGraphTheWorkspaceAndTheAgentRead() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)

        await vm.harvestGraphNow()

        #expect(await vm.harvestedTableNames() == ["customers", "orders"])
        #expect(await vm.graphOverview("orders").dependsOn == ["customers"])
        #expect(await vm.timelineSnapshots().count == 1)
        #expect(vm.graphChangedAt != nil)
        let executor = try #require(vm.graphExecutor(profileID: profile.id))
        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "graph_query", args: ["op": "neighbors", "node": "orders"]
        ))
        #expect(outcome.status == "ok")
        #expect(decode(outcome)["depends_on"] as? [String] == ["customers"])

        let firstChange = vm.graphChangedAt
        try await exec("ALTER TABLE customers ADD COLUMN email TEXT", on: session)
        await vm.harvestGraphNow()

        #expect(vm.graphChangedAt != firstChange)
        let marks = await vm.timelineSnapshots()
        try #require(marks.count == 2)
        let changes = await vm.timelineChanges(from: marks[1].at, to: marks[0].at)
        #expect(changes.map(\.name) == ["email"])
        #expect(changes.first?.tableName == "customers")
        #expect(changes.first?.isAdded == true)

        vm.disconnect()
    }

    @Test func disconnectingClosesTheCatalogConnection() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        #expect(await vm.metadataConnections.cachedSessionCount == 1)

        vm.disconnect()
        await vm.closingGraphWork?.value

        #expect(await vm.metadataConnections.cachedSessionCount == 0)
        await vm.harvestGraphNow()
        #expect(await vm.metadataConnections.cachedSessionCount == 0)
    }

    /// A window's workspace goes away with the window: its passes and drains
    /// stop, its catalog connection closes and the full graph it cached is
    /// dropped, and nothing reopens a connection for it afterwards.
    @Test func closingTheWorkspaceStopsItsGraphWork() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        vm.openGraphView()
        _ = await vm.harvestedTableNames()
        #expect(await vm.metadataConnections.cachedSessionCount == 1)

        vm.closeWorkspace()
        await vm.closingGraphWork?.value

        #expect(await vm.metadataConnections.cachedSessionCount == 0)
        #expect(vm.statisticsRefresh == nil)
        await vm.harvestGraphNow()
        #expect(await vm.metadataConnections.cachedSessionCount == 0)
        let before = vm.graphLoads
        _ = await vm.harvestedTableNames()
        _ = await vm.harvestedTableNames()
        #expect(vm.graphLoads - before == 2)
        vm.disconnect()
    }

    /// Closing the last window terminates the app, and the quit path then
    /// finds no open workspace: it must still wait for the catalog connection
    /// closes the closed window's teardown started.
    @Test func quitWaitsForAClosedWorkspacesCatalogConnectionToClose() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        #expect(await vm.metadataConnections.cachedSessionCount == 1)

        let hold = TeardownHold()
        vm.beforeClosingConnections = { await hold.wait() }
        vm.closeWorkspace()
        let quit = Task { @MainActor in
            await WorkspaceViewModel.closeAllMetadataConnections()
            await hold.markQuitReturned()
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !hold.quitReturned)

        await hold.open()
        await quit.value
        #expect(await vm.metadataConnections.cachedSessionCount == 0)
    }

    /// A pass that fails after committing its listing leaves the change time
    /// where it was although the stored tables moved. The graph a graph view
    /// keeps is keyed on the stored schema's revision, which that listing
    /// moved, so the next read loads it again.
    @Test func aListingCommittedByAPassThatThenFailedReplacesTheKeptGraph() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        vm.openGraphView()
        #expect(Set(await vm.harvestedTableNames()) == ["customers", "orders"])
        let changedAt = vm.graphChangedAt
        let store = try #require(vm.store)

        _ = try store.applySchemaListing(
            profileID: profile.id,
            objects: ["customers", "orders", "invoices"].map {
                SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: nil)
            },
            relations: nil, now: Date()
        )

        #expect(vm.graphChangedAt == changedAt)
        #expect(Set(await vm.harvestedTableNames()) == ["customers", "invoices", "orders"])
        vm.closeGraphView()
        vm.disconnect()
    }

    /// The kernel raises memory pressure; a test cannot, so it calls the
    /// handler the pressure source runs. The full graph a graph view keeps
    /// is dropped, so the next read loads it again, and the store gives its
    /// caches back.
    @Test func memoryPressureDropsTheCachedGraphAndReleasesTheStore() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        vm.openGraphView()
        _ = await vm.harvestedTableNames()
        let loaded = vm.graphLoads
        _ = await vm.harvestedTableNames()
        #expect(vm.graphLoads == loaded)
        let store = try #require(vm.store)
        let releases = store.releaseCount

        try #require(vm.storeMemory).handleMemoryPressure()

        #expect(store.releaseCount > releases)
        // A minute, not ten seconds: a parallel run on a three-core CI runner
        // left awaiting tests unscheduled for up to 18 seconds.
        let deadline = ContinuousClock.now + .seconds(60)
        while vm.graphLoads == loaded, ContinuousClock.now < deadline {
            _ = await vm.harvestedTableNames()
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.graphLoads == loaded + 1)
        vm.closeGraphView()
        vm.disconnect()
    }

    /// Every window on one store takes turns through one gate and one set of
    /// drains; a store elsewhere, such as another test's, has its own.
    @Test func workspacesOnOneStoreShareTheirPassGateAndDrains() throws {
        let path = tempPath("store")
        let first = try WorkspaceViewModel(storePath: path)
        let second = try WorkspaceViewModel(storePath: path)
        let elsewhere = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(first.passGate === second.passGate)
        #expect(first.embeddingDrains === second.embeddingDrains)
        #expect(first.passGate !== elsewhere.passGate)
        #expect(first.embeddingDrains !== elsewhere.embeddingDrains)
    }

    /// The full graph is cached only while a view that shows it is open, and
    /// a schema change replaces it.
    @Test func aGraphViewLoadsTheGraphOncePerSchemaChange() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()

        vm.openGraphView()
        var before = vm.graphLoads
        _ = await vm.harvestedTableNames()
        _ = await vm.graphOverview("orders")
        _ = await vm.analyzeInsights()
        #expect(vm.graphLoads - before == 1)

        try await exec("ALTER TABLE customers ADD COLUMN email TEXT", on: session)
        await vm.harvestGraphNow()
        before = vm.graphLoads
        _ = await vm.harvestedTableNames()
        _ = await vm.graphOverview("orders")
        #expect(vm.graphLoads - before == 1)

        vm.closeGraphView()
        before = vm.graphLoads
        _ = await vm.harvestedTableNames()
        _ = await vm.harvestedTableNames()
        #expect(vm.graphLoads - before == 2)

        vm.disconnect()
    }

    @Test func aHarvestEmbedsTheNewNamesThroughTheConnectionsTransport() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let stub = NameEmbeddingStub()
        vm.schemaEmbeddingAllowed = { _ in true }
        vm.makeSchemaEmbeddingTransport = { SchemaEmbeddingTransport(transport: stub) }
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        try await createCustomersAndOrders(on: session)

        await vm.harvestGraphNow()
        while let drain = vm.embeddingDrains.drain(of: profile.id) { await drain.value }

        #expect(Set(stub.requests) == ["customers", "orders"])
        vm.disconnect()
    }

    /// Consent is asked for on every drain, so names leave the machine only
    /// while the connection allows it, and a later pass picks up the names
    /// that waited.
    @Test func namesAreEmbeddedOnlyWhileTheConnectionAllowsIt() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let stub = NameEmbeddingStub()
        let consent = Consent(allowed: false)
        vm.schemaEmbeddingAllowed = { _ in consent.allowed }
        vm.makeSchemaEmbeddingTransport = { SchemaEmbeddingTransport(transport: stub) }
        await vm.connect(profile: profile)
        try await createCustomersAndOrders(on: try #require(vm.session))

        await vm.harvestGraphNow()
        while let drain = vm.embeddingDrains.drain(of: profile.id) { await drain.value }
        #expect(stub.requests.isEmpty)

        consent.allowed = true
        await vm.harvestGraphNow()
        while let drain = vm.embeddingDrains.drain(of: profile.id) { await drain.value }
        #expect(Set(stub.requests) == ["customers", "orders"])
        vm.disconnect()
    }

    /// The catalog connection idles between passes while the session stays
    /// busy, so it is the one a server or a tunnel closes. The pass that
    /// finds it dead fails, and the next pass connects again instead of
    /// failing on it forever.
    @Test func aCatalogConnectionThatDiesIsReplacedByTheNextPass() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        let dead = try await vm.metadataConnections.connection(for: session)
        await dead.close()

        try await exec("ALTER TABLE customers ADD COLUMN email TEXT", on: session)
        await vm.harvestGraphNow()
        let replacement = try await vm.metadataConnections.connection(for: session)
        #expect(replacement.id != dead.id)

        let before = vm.graphChangedAt
        await vm.harvestGraphNow()
        #expect(vm.graphChangedAt != before)
        vm.disconnect()
    }

    /// A search embeds only a bounded number of names as it runs, so names
    /// harvested while the connection did not allow embedding would wait for
    /// the next completed pass; allowing it starts a drain at once.
    @Test func allowingEmbeddingStartsADrain() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let stub = NameEmbeddingStub()
        let consent = Consent(allowed: false)
        vm.schemaEmbeddingAllowed = { _ in consent.allowed }
        vm.makeSchemaEmbeddingTransport = { SchemaEmbeddingTransport(transport: stub) }
        await vm.connect(profile: profile)
        try await createCustomersAndOrders(on: try #require(vm.session))
        await vm.harvestGraphNow()
        #expect(vm.embeddingDrains.drain(of: profile.id) == nil)

        consent.allowed = true
        vm.schemaEmbeddingConsentChanged(profileID: profile.id)
        while let drain = vm.embeddingDrains.drain(of: profile.id) { await drain.value }
        #expect(Set(stub.requests) == ["customers", "orders"])

        // Withdrawing it stops the drain and starts none.
        consent.allowed = false
        vm.schemaEmbeddingConsentChanged(profileID: profile.id)
        #expect(vm.embeddingDrains.drain(of: profile.id) == nil)
        vm.disconnect()
    }

    @Test func aClosedSessionsCatalogConnectionIsNeverReopened() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()

        vm.disconnect()
        await vm.closingGraphWork?.value

        await #expect(throws: CancellationError.self) { _ = try await vm.metadataConnections.connection(for: session) }
        #expect(await vm.metadataConnections.cachedSessionCount == 0)
    }

    @Test func switchingProfilesLeavesNoCatalogConnectionForTheFirst() async throws {
        let first = ConnectionProfile(driverID: "sqlite", name: "first", filePath: makeSQLiteDB())
        let second = ConnectionProfile(driverID: "sqlite", name: "second", filePath: makeSQLiteDB())
        let (vm, firstSession) = try await connectedWorkspace(first)
        try await createCustomersAndOrders(on: firstSession)
        await vm.harvestGraphNow()

        await vm.connect(profile: second)
        await vm.closingGraphWork?.value
        try await createCustomersAndOrders(on: try #require(vm.session))
        await vm.harvestGraphNow()

        await #expect(throws: CancellationError.self) {
            _ = try await vm.metadataConnections.connection(for: firstSession)
        }
        #expect(await vm.metadataConnections.cachedSessionCount == 1)
        vm.disconnect()
    }

    @Test func closingTheSessionCancelsItsStatisticsRefresh() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)

        await vm.harvestGraphNow()
        let refresh = try #require(vm.statisticsRefresh)
        vm.disconnect()

        #expect(refresh.isCancelled)
        #expect(vm.statisticsRefresh == nil)
    }

    @Test func savingTheOpenConnectionsScopeRunsAPass() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let (vm, session) = try await connectedWorkspace(profile)
        try await createCustomersAndOrders(on: session)
        await vm.harvestGraphNow()
        let model = try #require(vm.schemaScopeModel(profileID: profile.id))
        await model.load()

        try await exec("ALTER TABLE customers ADD COLUMN email TEXT", on: session)
        let before = vm.graphChangedAt
        #expect(await model.save())

        #expect(vm.graphChangedAt != before)
        #expect(await vm.timelineSnapshots().count == 2)
        vm.disconnect()
    }

    /// The hint is written by the pass that lists the catalog; the workspace
    /// learns it after each completed pass and marks the connection.
    @Test func aLargeCatalogHintMarksTheConnection() async throws {
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        let storePath = tempPath("store")
        let vm = try WorkspaceViewModel(storePath: storePath)
        await vm.connect(profile: profile)
        try await createCustomersAndOrders(on: try #require(vm.session))
        await vm.harvestGraphNow()
        #expect(!vm.profilesNeedingSchemaScope.contains(profile.id))

        // A pass over an unchanged catalog does not list it, so the hint a
        // listing wrote stands.
        let store = try BerryStore(path: storePath)
        try store.updateSchemaGraphState(profileID: profile.id) { $0.hint = "selectSchemas" }
        await vm.harvestGraphNow()
        #expect(vm.profilesNeedingSchemaScope.contains(profile.id))

        try store.updateSchemaGraphState(profileID: profile.id) { $0.hint = nil }
        await vm.harvestGraphNow()
        #expect(!vm.profilesNeedingSchemaScope.contains(profile.id))
        vm.disconnect()
    }

    /// A pass for a profile the workspace has just left can still be waiting
    /// for its session; that pass was cancelled with the session, and must
    /// not be recorded as a connection failure with a backoff.
    @Test func aPassForAProfileBeingLeftIsCancelledNotFailed() async throws {
        let first = ConnectionProfile(driverID: "sqlite", name: "first", filePath: makeSQLiteDB())
        let second = ConnectionProfile(driverID: "sqlite", name: "second", filePath: makeSQLiteDB())
        let (vm, firstSession) = try await connectedWorkspace(first)
        #expect(try vm.harvestSession(for: first.id).id == firstSession.id)
        #expect(throws: WorkspaceViewModel.NoOpenSession.self) { try vm.harvestSession(for: second.id) }

        await vm.connect(profile: second)
        let secondSession = try #require(vm.session)

        #expect(throws: CancellationError.self) { try vm.harvestSession(for: first.id) }
        #expect(try vm.harvestSession(for: second.id).id == secondSession.id)

        vm.disconnect()
        #expect(throws: CancellationError.self) { try vm.harvestSession(for: second.id) }

        await vm.connect(profile: first)
        #expect(try vm.harvestSession(for: first.id).id == vm.session?.id)
        vm.disconnect()
    }
}

/// Holds a closed workspace's teardown before it closes its connections.
private actor TeardownHold {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var quitReturned = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func markQuitReturned() { quitReturned = true }
}
