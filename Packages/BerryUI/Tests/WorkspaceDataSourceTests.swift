import BerryDataSourceKit
import BerryDriverKit
import BerryDriverMongo
import BerryDriverQdrant
import BerryDriverTestKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// End-to-end at the `WorkspaceViewModel` level: connect → list collections →
/// open a collection tab → run a query → see results in the buffer → insert →
/// delete. Headless, mirrors `WorkspaceGraphTests`'
/// pattern for the SQL side. Runs against real `mongo:7`/`qdrant` containers
/// from `Tests/docker/compose.yml`, skipped cleanly when the env vars are unset.
private struct AllowAllDataSourceWrites: DataSourceWriteConfirming {
    func confirm(_ level: DataSourceDangerLevel, preview: String) async -> Bool { true }
}

private func tempStorePath() -> String {
    NSTemporaryDirectory() + "berry-ds-store-\(UUID().uuidString).sqlite"
}

@MainActor
// `.serialized`: this suite's tests all call `DataSourceRegistry.register(MongoDriver.self)`
// under the shared `.mongodb` `DriverID` slot — the same key `SavedQueriesViewModelTests`
// registers a fake driver under. Serializing each suite's own tests shrinks the window in
// which the two suites' registrations could interleave (Swift Testing parallelizes across
// suites by default); see `SavedQueriesViewModelTests`'s matching trait for the full note.
@Suite("Workspace Mongo data source", .enabled(if: TestServer.mongo != nil), .serialized)
struct WorkspaceMongoDataSourceTests {
    private var server: TestServer { TestServer.mongo! }

    @Test func connectListInsertQueryDeleteRoundTrip() async throws {
        DataSourceRegistry.register(MongoDriver.self)
        let previousConfirmer = WorkspaceViewModel.dataSourceWriteConfirmer
        WorkspaceViewModel.dataSourceWriteConfirmer = AllowAllDataSourceWrites()
        defer { WorkspaceViewModel.dataSourceWriteConfirmer = previousConfirmer }

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "test-mongo",
            host: server.host, port: server.port,
            username: server.username, database: server.database,
            // The test container speaks plain TCP — tlsMode defaults to
 // prefer, which both drivers treat as "use TLS"
 // TLS is a binary on/off, not a prefer/require spectrum).
            tlsMode: TLSMode.disable.rawValue
        )
        KeychainService.savePassword(server.password, kind: .database, profileID: profile.id)
        defer { KeychainService.deleteSecrets(profileID: profile.id) }

        await vm.connectDataSource(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.dataSourceSession)
        #expect(session.kind == .document)

        let name = "berry_ui_conf_\(UUID().uuidString.prefix(8))"
        let ref = CollectionRef(database: server.database, name: name)
        // `.document` collections open a Mongo shell tab, not a `.collection`
 // tab (Task 8's `openCollection` split) — the
        // tab is pre-seeded with a `find({}).limit(50)` that has already run
        // once by the time `openCollection` returns control here.
        vm.openCollection(ref)
        let shell = try #require(mongoShellTabState(vm))
        while shell.isRunning { await Task.yield() }
        #expect(shell.results.last?.buffer.itemCount == 0)

        let insertError = await vm.applyDataSourceWrite(
            .insert(collection: name, document: .object([("seed", .bool(true))]))
        )
        #expect(insertError == nil)

        shell.text = "db.\(name).find({});"
        shell.run(session: session, applyWrite: { _ in .succeeded })
        while shell.isRunning { await Task.yield() }
        #expect(shell.results.last?.buffer.itemCount == 1)

        let inserted = try #require(shell.results.last?.buffer.items.first)
        let id = CollectionTabState.id(of: inserted, kind: .document)
        #expect(id != .null)

        let deleteError = await vm.applyDataSourceWrite(.delete(collection: name, id: id))
        #expect(deleteError == nil)

        shell.run(session: session, applyWrite: { _ in .succeeded })
        while shell.isRunning { await Task.yield() }
        #expect(shell.results.last?.buffer.itemCount == 0)

        vm.disconnect()
        #expect(vm.dataSourceSession == nil)
    }

    /// The gap this covers: a fresh Mongo connection can start with zero
    /// collections and — unlike SQL's "New Table…" — there was previously no
    /// explicit UI action to create one (Mongo's implicit
    /// creation-via-insert covers it only once you already have a tab open on
 /// a name). `createCollection` is the explicit
    /// fix: runs the `create` admin command up front, `refreshCollections()`
    /// picks it up, then the usual insert/query flow works exactly as above.
    /// Leaves the created (now non-empty, then re-emptied) collection behind
    /// — same accepted test debris as `connectListInsertQueryDeleteRoundTrip`
    /// above (Mongo has no `drop` exposed anywhere in scope for this task).
    @Test func createCollectionThenInsertQueryRoundTrip() async throws {
        DataSourceRegistry.register(MongoDriver.self)
        let previousConfirmer = WorkspaceViewModel.dataSourceWriteConfirmer
        WorkspaceViewModel.dataSourceWriteConfirmer = AllowAllDataSourceWrites()
        defer { WorkspaceViewModel.dataSourceWriteConfirmer = previousConfirmer }

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "test-mongo",
            host: server.host, port: server.port,
            username: server.username, database: server.database,
            tlsMode: TLSMode.disable.rawValue
        )
        KeychainService.savePassword(server.password, kind: .database, profileID: profile.id)
        defer { KeychainService.deleteSecrets(profileID: profile.id) }

        await vm.connectDataSource(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.dataSourceSession)

        let name = "berry_ui_create_\(UUID().uuidString.prefix(8))"
        #expect(!vm.collections.contains { $0.name == name })

        let createError = await vm.createCollection(CollectionRef(name: name), options: .object([]))
        #expect(createError == nil)
        #expect(vm.collections.contains { $0.name == name })

        let ref = CollectionRef(database: server.database, name: name)
        vm.openCollection(ref)
        let shell = try #require(mongoShellTabState(vm))
        while shell.isRunning { await Task.yield() }
        #expect(shell.results.last?.buffer.itemCount == 0)

        let insertError = await vm.applyDataSourceWrite(
            .insert(collection: name, document: .object([("seed", .bool(true))]))
        )
        #expect(insertError == nil)

        shell.text = "db.\(name).find({});"
        shell.run(session: session, applyWrite: { _ in .succeeded })
        while shell.isRunning { await Task.yield() }
        #expect(shell.results.last?.buffer.itemCount == 1)

        let inserted = try #require(shell.results.last?.buffer.items.first)
        let id = CollectionTabState.id(of: inserted, kind: .document)
        let deleteError = await vm.applyDataSourceWrite(.delete(collection: name, id: id))
        #expect(deleteError == nil)

        vm.disconnect()
        #expect(vm.dataSourceSession == nil)
    }

 /// Aggregation-pipeline mode (query UI): a Mongo
    /// shell tab's `db.<coll>.aggregate([...])` statement resolves to
    /// `.mongoAggregate` (`MongoShellResolver`, Task 6) — this exercises that
    /// path end-to-end against a real `mongod`, not just the pure
    /// parser/resolver branching already covered by `MongoShellParserTests`/
    /// `MongoShellResolverTests`.
    @Test func aggregationPipelineFiltersAndSorts() async throws {
        DataSourceRegistry.register(MongoDriver.self)
        let previousConfirmer = WorkspaceViewModel.dataSourceWriteConfirmer
        WorkspaceViewModel.dataSourceWriteConfirmer = AllowAllDataSourceWrites()
        defer { WorkspaceViewModel.dataSourceWriteConfirmer = previousConfirmer }

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "test-mongo",
            host: server.host, port: server.port,
            username: server.username, database: server.database,
            tlsMode: TLSMode.disable.rawValue
        )
        KeychainService.savePassword(server.password, kind: .database, profileID: profile.id)
        defer { KeychainService.deleteSecrets(profileID: profile.id) }

        await vm.connectDataSource(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.dataSourceSession)

        let name = "berry_ui_agg_\(UUID().uuidString.prefix(8))"
        let ref = CollectionRef(database: server.database, name: name)
        vm.openCollection(ref)
        let shell = try #require(mongoShellTabState(vm))
        while shell.isRunning { await Task.yield() }

        for (active, price) in [(true, 10), (true, 20), (false, 30)] {
            let insertError = await vm.applyDataSourceWrite(
                .insert(collection: name, document: .object([
                    ("active", .bool(active)), ("price", .int(Int64(price))),
                ]))
            )
            #expect(insertError == nil)
        }

        shell.text = "db.\(name).aggregate([{ $match: { active: true } }, { $sort: { price: 1 } }]);"
        shell.run(session: session, applyWrite: { _ in .succeeded })
        while shell.isRunning { await Task.yield() }

        let aggregated = try #require(shell.results.last)
        #expect(aggregated.buffer.itemCount == 2)
        #expect(aggregated.buffer.items.map { $0["price"] ?? .null } == [.int(10), .int(20)])

        // Cleanup via `find({})` (match all) — the pipeline's own $match
        // intentionally excludes one of the three inserted documents, so a
        // plain find is needed to see (and delete) all of them.
        shell.text = "db.\(name).find({});"
        shell.run(session: session, applyWrite: { _ in .succeeded })
        while shell.isRunning { await Task.yield() }
        for doc in shell.results.last?.buffer.items ?? [] {
            _ = await vm.applyDataSourceWrite(.delete(collection: name, id: CollectionTabState.id(of: doc, kind: .document)))
        }

        vm.disconnect()
        #expect(vm.dataSourceSession == nil)
    }

    /// Regression: opening a query from history on a Mongo connection must land
    /// in a runnable Mongo shell tab, not a SQL editor tab (which has no session
    /// to execute against, so past queries silently failed to run).
    @Test func openQueryFromHistoryOnMongoOpensRunnableShellTab() async throws {
        DataSourceRegistry.register(MongoDriver.self)
        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "test-mongo",
            host: server.host, port: server.port,
            username: server.username, database: server.database,
            tlsMode: TLSMode.disable.rawValue
        )
        KeychainService.savePassword(server.password, kind: .database, profileID: profile.id)
        defer { KeychainService.deleteSecrets(profileID: profile.id) }

        await vm.connectDataSource(profile: profile)
        #expect(vm.dataSourceSession?.kind == .document)

        vm.openQueryFromHistory("db.users.find({});")
        let shell = try #require(mongoShellTabState(vm), "history must open a Mongo shell tab, not a SQL editor")
        #expect(shell.text == "db.users.find({});")

        vm.disconnect()
    }

    /// The active tab right after `vm.openCollection(ref)` for a `.document`
    /// session is a fresh `.mongoShell` tab, keyed by a UUID unknown ahead of
    /// time (unlike `.collection`'s `CollectionRef`-derived id) — so this
    /// looks the tab up via `activeTabID` instead of a predictable id string.
    private func mongoShellTabState(_ vm: WorkspaceViewModel) -> MongoShellTabState? {
        guard let activeTabID = vm.activeTabID, case .mongoShell(let state)? = vm.tab(for: activeTabID) else { return nil }
        return state
    }
}

@MainActor
@Suite("Workspace Qdrant data source", .enabled(if: QdrantTestServer.qdrant != nil))
struct WorkspaceQdrantDataSourceTests {
    private var server: QdrantTestServer { QdrantTestServer.qdrant! }

    /// Qdrant collection DELETION still has no driver-level surface (out of
 /// scope for this task) — teardown still goes
    /// directly over the base REST API, same as `QdrantConformanceTests`.
    /// Creation no longer needs this workaround: `connectListInsertQueryDeleteRoundTrip`
    /// below creates its throwaway collection through `WorkspaceViewModel.createCollection`
    /// (the real gap this task closes — a fresh Qdrant connection used to have
    /// no in-app way to create a first collection at all).
    private func deleteCollection(_ name: String) async {
        var req = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/collections/\(name)")!)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    @Test func connectListInsertQueryDeleteRoundTrip() async throws {
        DataSourceRegistry.register(QdrantDriver.self)
        let previousConfirmer = WorkspaceViewModel.dataSourceWriteConfirmer
        WorkspaceViewModel.dataSourceWriteConfirmer = AllowAllDataSourceWrites()
        defer { WorkspaceViewModel.dataSourceWriteConfirmer = previousConfirmer }

        let name = "berry_ui_conf_\(UUID().uuidString.prefix(8))"
        // `defer` can't `await`, and a fire-and-forget `Task` inside `defer`
        // races the test process exit (observed leaving debris behind on the
        // shared Qdrant container) — so cleanup is awaited explicitly on both
        // the success and failure paths instead.
        do {
            try await connectListInsertQueryDelete(name: name)
        } catch {
            await deleteCollection(name)
            throw error
        }
        await deleteCollection(name)
    }

    private func connectListInsertQueryDelete(name: String) async throws {
        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "qdrant", name: "test-qdrant", host: server.host, port: server.port,
            // The test container serves plain HTTP — see the Mongo suite's
            // comment above for why tlsMode must be explicit here.
            tlsMode: TLSMode.disable.rawValue
        )

        await vm.connectDataSource(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.dataSourceSession)
        #expect(session.kind == .vector)
        #expect(!vm.collections.contains { $0.name == name })

        // The gap this covers: Qdrant has NO implicit creation-on-insert the
 // way Mongo does, so before `createCollection`
 // there was no in-app way to get from zero collections to one.
        let createError = await vm.createCollection(
            CollectionRef(name: name),
            options: .object([("vectorSize", .int(4)), ("distance", .string("Cosine"))])
        )
        #expect(createError == nil)
        #expect(vm.collections.contains { $0.name == name })

        let ref = CollectionRef(name: name)
        vm.openCollection(ref)
        let state = try #require(tabState(vm, id: "collection:\(ref.id)"))
        await state.buffer.waitUntilFinished()
        #expect(state.buffer.itemCount == 0)

        let document = BerryDocument.object([
            ("vector", .vector([1, 0, 0, 0])),
            ("payload", .object([("label", .string("hello"))])),
        ])
        let insertError = await vm.applyDataSourceWrite(.insert(collection: name, document: document))
        #expect(insertError == nil)

        state.run()
        await state.buffer.waitUntilFinished()
        #expect(state.buffer.itemCount == 1)

        let id = CollectionTabState.id(of: state.buffer.items[0], kind: .vector)
        #expect(id != .null)

        let deleteError = await vm.applyDataSourceWrite(.delete(collection: name, id: id))
        #expect(deleteError == nil)

        state.run()
        await state.buffer.waitUntilFinished()
        #expect(state.buffer.itemCount == 0)

        vm.disconnect()
        #expect(vm.dataSourceSession == nil)
    }

 /// Score-threshold and payload-filter wiring
    /// query UI): both were always `nil` from `CollectionTabState.run()`
    /// before this task — this exercises both real `.qdrantSearch` params
    /// end-to-end against a real Qdrant, not just the pure branching already
    /// covered by `CollectionTabStateTests`.
    @Test func searchWithScoreThresholdAndPayloadFilter() async throws {
        DataSourceRegistry.register(QdrantDriver.self)
        let previousConfirmer = WorkspaceViewModel.dataSourceWriteConfirmer
        WorkspaceViewModel.dataSourceWriteConfirmer = AllowAllDataSourceWrites()
        defer { WorkspaceViewModel.dataSourceWriteConfirmer = previousConfirmer }

        let name = "berry_ui_score_\(UUID().uuidString.prefix(8))"
        do {
            try await searchWithScoreThresholdAndPayloadFilter(name: name)
        } catch {
            await deleteCollection(name)
            throw error
        }
        await deleteCollection(name)
    }

    private func searchWithScoreThresholdAndPayloadFilter(name: String) async throws {
        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "qdrant", name: "test-qdrant", host: server.host, port: server.port,
            tlsMode: TLSMode.disable.rawValue
        )

        await vm.connectDataSource(profile: profile)
        #expect(vm.errorMessage == nil)

        let createError = await vm.createCollection(
            CollectionRef(name: name),
            options: .object([("vectorSize", .int(4)), ("distance", .string("Cosine"))])
        )
        #expect(createError == nil)

        let ref = CollectionRef(name: name)
        vm.openCollection(ref)
        let state = try #require(tabState(vm, id: "collection:\(ref.id)"))
        await state.buffer.waitUntilFinished()

        // `close` scores ~1.0 against the query vector (identical axis);
        // `far` is orthogonal, scoring ~0.0 — the threshold/filter below
        // should each exclude `far` on their own.
        let close = BerryDocument.object([
            ("vector", .vector([1, 0, 0, 0])),
            ("payload", .object([("category", .string("docs"))])),
        ])
        let far = BerryDocument.object([
            ("vector", .vector([0, 1, 0, 0])),
            ("payload", .object([("category", .string("other"))])),
        ])
        #expect(await vm.applyDataSourceWrite(.insert(collection: name, document: close)) == nil)
        #expect(await vm.applyDataSourceWrite(.insert(collection: name, document: far)) == nil)

        state.vectorText = "[1, 0, 0, 0]"
        state.topK = 10
        state.scoreThresholdText = "0.5"
        state.run()
        await state.buffer.waitUntilFinished()
        #expect(state.buffer.itemCount == 1)
        #expect(state.buffer.items[0]["payload"]?["category"] == .string("docs"))

        // Same query, threshold cleared, payload filter narrowing instead —
        // exercises the other new param down the same `.qdrantSearch` path.
        state.scoreThresholdText = ""
        state.payloadFilterText = "{\"must\": [{\"key\": \"category\", \"match\": {\"value\": \"docs\"}}]}"
        state.run()
        await state.buffer.waitUntilFinished()
        #expect(state.buffer.itemCount == 1)
        #expect(state.buffer.items[0]["payload"]?["category"] == .string("docs"))

        vm.disconnect()
        #expect(vm.dataSourceSession == nil)
    }

    private func tabState(_ vm: WorkspaceViewModel, id: String) -> CollectionTabState? {
        guard case .collection(let state)? = vm.tab(for: id) else { return nil }
        return state
    }
}
