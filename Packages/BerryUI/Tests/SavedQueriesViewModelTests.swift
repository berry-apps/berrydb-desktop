import BerryDataSourceKit
import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// A no-op `DataSourceConnection` used only to make `connectDataSource`
/// succeed in-process (no real socket), so tests can put `WorkspaceViewModel`
/// into the "Mongo connected" state that `openSavedQuery`/`renameSavedQuery`/
/// `updateLinkedSavedQuery` branch on, without a live `mongod`.
private actor FakeMongoConnection: DataSourceConnection {
    nonisolated let id = UUID()
    func listCollections() async throws -> [CollectionRef] { [] }
    func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {}
    nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        DataSourceWriteResult(affectedCount: 0)
    }
    nonisolated func cancelCurrentQuery() {}
    nonisolated var introspector: any DataSourceIntrospector { FakeMongoIntrospector() }
    func ping() async -> Bool { true }
    func close() async {}
}

private struct FakeMongoIntrospector: DataSourceIntrospector {
    func collections() async throws -> [CollectionRef] { [] }
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] { [:] }
}

/// Registered under the real `.mongodb` `DriverID` so `ConnectionProfile(driverID:
/// "mongodb", ...)` resolves to it — `connectDataSource` has no other hook to
/// simulate a Mongo session (`dataSourceSession` is `public private(set)`).
private struct FakeMongoDriver: DataSourceDriver {
    static let id: DriverID = .mongodb
    static let displayName = "Fake Mongo"
    static let kind: DataSourceKind = .document
    static let capabilities = DataSourceCapabilities(write: true)
    init() {}
    func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection {
        FakeMongoConnection()
    }
}

/// Saved queries (ED-07) at the `WorkspaceViewModel` level: opening, linking,
/// renaming, and re-saving. Covers both the pre-existing `.editor` (SQL)
/// branches — which had no test coverage anywhere before this task, even
/// though this task edits them — and the new `.mongoShell` branches added by
/// Task 13 so a Mongo shell tab can be saved/opened/renamed the same way a
/// SQL editor tab can.
@MainActor
// `.serialized`: `connectFakeMongo` registers `FakeMongoDriver` under the real
// `.mongodb` `DriverID` slot in the process-global `DataSourceRegistry`, the same
// key `WorkspaceMongoDataSourceTests` registers the real `MongoDriver` under when
// `BERRYDB_TEST_MONGO` is set. Serializing this suite's own tests (and that suite's,
// which carries the same trait) shrinks the concurrent-overlap window from "many
// tests from both suites at once" down to "at most one test per suite at a time" —
// Swift Testing's `.serialized` only serializes a suite's own subtree, not against a
// *different* top-level suite, so this reduces rather than eliminates the race; a
// fully watertight fix would need the two suites nested under one shared serialized
// parent, or a real cross-suite mutex, which is disproportionate to this low-severity,
// opt-in-only (BERRYDB_TEST_MONGO) local-dev race.
@Suite("Saved queries (WorkspaceViewModel)", .serialized)
struct SavedQueriesViewModelTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    /// Connects `vm` to a fake Mongo data source in-process, so `dataSourceSession?.kind
    /// == .document` afterward without any real network I/O.
    private func connectFakeMongo(_ vm: WorkspaceViewModel) async {
        DataSourceRegistry.register(FakeMongoDriver.self)
        await vm.connectDataSource(profile: ConnectionProfile(driverID: "mongodb", name: "fake-mongo"))
    }

    // MARK: - .editor (SQL) — baseline coverage protecting existing behavior

    @Test func openingASavedSQLQueryCreatesAndLinksAnEditorTab() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        let saved = SavedQuery(profileID: nil, name: "recent users", sql: "select * from users;")
        vm.openSavedQuery(saved)
        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.text == saved.sql)
        #expect(document.title == saved.name)
        #expect(document.savedQueryID == saved.id)
    }

    @Test func reopeningALinkedSQLSavedQueryFocusesTheExistingTabInsteadOfDuplicating() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        let saved = SavedQuery(profileID: nil, name: "recent users", sql: "select * from users;")
        vm.openSavedQuery(saved)
        let countAfterFirstOpen = vm.tabs.count
        vm.newEditorTab(text: "select 2") // steal focus onto another tab
        vm.openSavedQuery(saved)
        #expect(vm.tabs.count == countAfterFirstOpen + 1) // no duplicate of the saved query's tab
        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.savedQueryID == saved.id)
    }

    @Test func activeEditorSavedQueryIDReturnsTheLinkedIDForAnEditorTab() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        let saved = SavedQuery(profileID: nil, name: "q", sql: "select 1;")
        vm.openSavedQuery(saved)
        #expect(vm.activeEditorSavedQueryID == saved.id)
    }

    @Test func activeEditorSavedQueryIDReturnsNilForATabThatIsNeitherEditorNorMongoShell() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        vm.openTool(.history)
        #expect(vm.activeEditorSavedQueryID == nil)
    }

    @Test func renamingASavedQueryUpdatesTheLinkedEditorTabTitle() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        // Persisted (not just constructed in memory): renameSavedQuery looks
        // the record up by id in the store before it will touch any tab.
        vm.saveSavedQuery(name: "old name", sql: "select 1;", folder: nil, global: true)
        let saved = try #require(vm.loadSavedQueries().first)
        vm.openSavedQuery(saved)
        vm.renameSavedQuery(id: saved.id, to: "new name")
        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.title == "new name")
    }

    @Test func updateLinkedSavedQueryPersistsTheEditorsCurrentTextUnderTheSameID() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        vm.saveSavedQuery(name: "q", sql: "select 1;", folder: nil, global: true)
        let saved = try #require(vm.loadSavedQueries().first)

        vm.openSavedQuery(saved)
        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        document.text = "select 2;"
        #expect(vm.updateLinkedSavedQuery() == true)

        let reloaded = vm.loadSavedQueries().first { $0.id == saved.id }
        #expect(reloaded?.sql == "select 2;")
    }

    @Test func savingASnippetLinksTheActiveEditorTabWhenItsTextMatches() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        vm.newEditorTab(text: "select 1;")
        vm.saveSavedQuery(name: "my query", sql: "select 1;", folder: nil, global: true)
        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.title == "my query")
        #expect(document.savedQueryID != nil)
    }

    // MARK: - .mongoShell — new coverage (Task 13)

    @Test func openingASavedMongoShellQueryLinksTheNewTab() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        #expect(vm.dataSourceSession?.kind == .document)

        let saved = SavedQuery(profileID: nil, name: "recent admins", sql: #"db.users.find({ role: "admin" });"#)
        vm.openSavedQuery(saved)
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        #expect(state.text == saved.sql)
        #expect(state.savedQueryID == saved.id)
    }

    @Test func reopeningALinkedMongoSavedQueryFocusesTheExistingTabInsteadOfDuplicating() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        let saved = SavedQuery(profileID: nil, name: "q", sql: "db.users.find({});")
        vm.openSavedQuery(saved)
        let countAfterFirstOpen = vm.tabs.count
        vm.openSavedQuery(saved)
        #expect(vm.tabs.count == countAfterFirstOpen) // focused, not duplicated
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        #expect(state.savedQueryID == saved.id)
    }

    @Test func activeEditorSavedQueryIDReturnsTheLinkedIDForAMongoShellTab() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        vm.newMongoShellTab(text: "db.users.find({});")
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        let linkedID = UUID()
        state.savedQueryID = linkedID
        #expect(vm.activeEditorSavedQueryID == linkedID)
    }

    @Test func renamingASavedQueryUpdatesTheLinkedMongoShellTabTitle() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        vm.saveSavedQuery(name: "old", sql: "db.users.find({});", folder: nil, global: true)
        let saved = try #require(vm.loadSavedQueries().first)
        vm.openSavedQuery(saved)
        vm.renameSavedQuery(id: saved.id, to: "new")
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        #expect(state.title == "new")
    }

    @Test func updateLinkedSavedQueryPersistsTheMongoShellTabsCurrentTextUnderTheSameID() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        vm.saveSavedQuery(name: "q", sql: "db.users.find({});", folder: nil, global: true)
        let saved = try #require(vm.loadSavedQueries().first)

        vm.openSavedQuery(saved)
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        state.text = "db.users.find({ active: true });"
        #expect(vm.updateLinkedSavedQuery() == true)

        let reloaded = vm.loadSavedQueries().first { $0.id == saved.id }
        #expect(reloaded?.sql == "db.users.find({ active: true });")
    }

    @Test func savingASnippetLinksTheActiveMongoShellTabWhenItsTextMatches() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("saved-queries"))
        await connectFakeMongo(vm)
        vm.newMongoShellTab(text: "db.users.find({});")
        vm.saveSavedQuery(name: "my mongo query", sql: "db.users.find({});", folder: nil, global: true)
        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        #expect(state.title == "my mongo query")
        #expect(state.savedQueryID != nil)
    }
}
