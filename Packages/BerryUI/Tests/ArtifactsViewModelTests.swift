import BerryDriverKit
import BerryDriverSQLite
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Artifacts (AI-29, docs/draft/09.md) at the `WorkspaceViewModel` level:
/// opening an artifact creates and links a tab of the right kind, and
/// re-opening the same artifact focuses that tab instead of duplicating it —
/// mirrors the equivalent `openSavedQuery` coverage in
/// `SavedQueriesViewModelTests`. Unlike `SavedQuery`, `Artifact` carries its
/// own `kind`, so these branches don't need a live/fake data source
/// connection the way `openSavedQuery`'s Mongo/Qdrant branches do — except
/// the `.table`/`.view` live-pointer case below, which does need one.
/// Serialized: the live-pointer test calls
/// `DriverRegistry.register(SQLiteDriver.self)` (shared global state, same
/// as `WorkspaceGraphTests`/`QueryToolExecutorTests`) — see those suites'
/// comments for why running concurrently is a pre-existing race.
@MainActor
@Suite("Artifacts (WorkspaceViewModel)", .serialized)
struct ArtifactsViewModelTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    /// `WorkspaceViewModel.store` is `private`, not just `internal` — even
    /// `@testable import` can't reach it. Seeding through a second `BerryStore`
    /// opened at the same file path (created after `vm`, so its `init` has
    /// already run migrations) round-trips through the real persistence layer
    /// instead of needing a test-only injection point on the view model.
    private func makeViewModelAndStore(_ tag: String) throws -> (WorkspaceViewModel, BerryStore) {
        let path = tempPath(tag)
        let vm = try WorkspaceViewModel(storePath: path)
        let store = try BerryStore(path: path)
        return (vm, store)
    }

    @Test func openingAnEditorTabArtifactCreatesAndLinksANewTab() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "select * from customers;")

        vm.openArtifact(artifact)

        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.text == "select * from customers;")
        #expect(document.title == artifact.title)
        #expect(document.artifactID == artifact.id)
    }

    @Test func reopeningAnEditorTabArtifactFocusesTheExistingTabInsteadOfDuplicating() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "select 1;")

        vm.openArtifact(artifact)
        let firstTabID = vm.activeTabID
        vm.newEditorTab() // something else becomes active in between
        #expect(vm.activeTabID != firstTabID)

        vm.openArtifact(artifact)

        #expect(vm.activeTabID == firstTabID)
        #expect(vm.tabs.count == 2) // still just the original artifact tab + the new blank one
    }

    @Test func openingAMongoShellArtifactCreatesAndLinksAMongoShellTab() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .mongoShell, title: "Recent orders")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "db.orders.find()")

        vm.openArtifact(artifact)

        guard case .mongoShell(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .mongoShell")
            return
        }
        #expect(state.text == "db.orders.find()")
        #expect(state.artifactID == artifact.id)

        // Re-opening focuses the same tab rather than creating a second one.
        vm.newMongoShellTab()
        #expect(vm.tabs.count == 2)
        vm.openArtifact(artifact)
        #expect(vm.tabs.count == 2)
        if case .mongoShell(let refocused) = vm.activeTab {
            #expect(refocused.artifactID == artifact.id)
        } else {
            Issue.record("expected the active tab to be the linked .mongoShell tab")
        }
    }

    @Test func openingAQdrantQueryArtifactCreatesAndLinksAQdrantQueryTab() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .qdrantQuery, title: "Similar products")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "{\"collection\":\"products\"}")

        vm.openArtifact(artifact)

        guard case .qdrantQuery(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .qdrantQuery")
            return
        }
        #expect(state.rawJSON == "{\"collection\":\"products\"}")
        #expect(state.artifactID == artifact.id)
    }

    @Test func openingAnArtifactWithNoVersionsDoesNothing() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Never run")
        try store.saveArtifact(artifact) // no appendArtifactVersion call

        vm.openArtifact(artifact)

        #expect(vm.tabs.isEmpty)
    }

    /// AI-31's chat bubble chip only carries the artifact's `id` (`AIPanelController
    /// .openArtifact: ((UUID) -> Void)?` wired to `openArtifact(id:)` in
    /// `WorkspaceView`) — every other test in this suite calls `openArtifact(_:)`
    /// directly with an already-resolved `Artifact`, which never exercises the
    /// `store?.artifact(id:)` lookup that the actual click path depends on.
    @Test func openingAnArtifactByIDResolvesItFromStoreAndFocusesItsTab() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "select * from customers;")

        vm.openArtifact(id: artifact.id)

        guard case .editor(let document) = vm.activeTab else {
            Issue.record("expected the active tab to be .editor")
            return
        }
        #expect(document.text == "select * from customers;")
        #expect(document.artifactID == artifact.id)
    }

    @Test func openingAnArtifactByIDTwiceFocusesTheExistingTabInsteadOfDuplicating() throws {
        let (vm, store) = try makeViewModelAndStore("artifacts")
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "select 1;")

        vm.openArtifact(id: artifact.id)
        let firstTabID = vm.activeTabID
        vm.newEditorTab() // something else becomes active in between, as if the user kept working
        #expect(vm.activeTabID != firstTabID)

        vm.openArtifact(id: artifact.id)

        #expect(vm.activeTabID == firstTabID)
        #expect(vm.tabs.count == 2)
    }

    @Test func openingAnUnknownArtifactIDDoesNothing() throws {
        let (vm, _) = try makeViewModelAndStore("artifacts")

        vm.openArtifact(id: UUID())

        #expect(vm.tabs.isEmpty)
    }

    /// The other branch of AI-31's chip click: a `.table`/`.view`/`.trigger`/
    /// `.function` artifact is a live pointer (`objectRef` = `SchemaObject.id`,
    /// the plan's decision #2) — it resolves against `vm.objects` and opens
    /// via `select(_:)` instead of creating/linking a tab. Needs a real
    /// session (unlike the editor/mongo/qdrant cases above) since `objects`
    /// only populates from `refreshObjects()` against a live connection.
    @Test func openingATableArtifactByIDResolvesTheLivePointerAndOpensIt() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let dbPath = tempPath("db")
        FileManager.default.createFile(atPath: dbPath, contents: nil)
        let (vm, store) = try makeViewModelAndStore("artifacts-table")
        let profile = ConnectionProfile(driverID: "sqlite", name: "test", filePath: dbPath)
        await vm.connect(profile: profile)
        let session = try #require(vm.session)
        for try await _ in session.connection.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)") {}
        try await vm.refreshObjects()

        let object = try #require(vm.objects.first { $0.name == "customers" && $0.kind == .table })
        let artifact = Artifact(profileID: UUID(), kind: .table, title: "customers", objectRef: object.id)
        try store.saveArtifact(artifact)

        vm.openArtifact(id: artifact.id)

        guard case .table(let state) = vm.activeTab else {
            Issue.record("expected the active tab to be .table")
            return
        }
        #expect(state.object.id == object.id)
    }

    @Test func openingATableArtifactByIDWhenTheObjectNoLongerExistsDoesNothing() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let dbPath = tempPath("db")
        FileManager.default.createFile(atPath: dbPath, contents: nil)
        let (vm, store) = try makeViewModelAndStore("artifacts-table-missing")
        let profile = ConnectionProfile(driverID: "sqlite", name: "test", filePath: dbPath)
        await vm.connect(profile: profile)
        try await vm.refreshObjects() // no tables created — vm.objects stays empty

        let artifact = Artifact(
            profileID: UUID(), kind: .table, title: "dropped_table",
            objectRef: ".table.dropped_table"
        )
        try store.saveArtifact(artifact)

        vm.openArtifact(id: artifact.id)

        #expect(vm.tabs.isEmpty)
    }
}
