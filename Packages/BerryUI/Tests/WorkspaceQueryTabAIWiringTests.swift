import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryUI

/// `WorkspaceViewModel.activeTabSnapshot()`/`activeEditorStatements(for:)` for
/// `.qdrantQuery`/`.elasticsearchQuery` tabs — the AI `read_current_tab`/
/// `run_tab_statements` tools' data path. Before
/// this fix both switches only handled `.editor`/`.mongoShell`, falling to
/// `default: nil`/`[]` for a Qdrant or Elasticsearch query tab — the AI could
/// propose a query into one of these tabs but could never read it back or run
/// it. Pure tab-state assertions, no real connection needed (`newQdrantQueryTab`/
/// `newElasticsearchQueryTab` only touch in-memory `tabs`), so this doesn't need
/// Docker/a real server — mirrors `WorkspaceViewModelDestructiveStatementsTests`'
/// documented caution around constructing a `WorkspaceViewModel` by not
/// touching any global confirmer. Each view model gets a store file of its
/// own, never the application's default store.
@MainActor
@Suite("Query tab AI wiring (read_current_tab/run_tab_statements)", .serialized)
struct WorkspaceQueryTabAIWiringTests {
    @Test func activeTabSnapshotReadsAQdrantQueryTab() throws {
        let store = TemporaryStoreFile()
        defer { store.remove() }
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        let json = "{\n  \"collection\": \"points\"\n}"
        viewModel.newQdrantQueryTab(rawJSON: json, title: "Qdrant Query")

        let snapshot = viewModel.activeTabSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot?.text == json)
        #expect(snapshot?.tabTitle == "Qdrant Query")
        #expect(snapshot?.cursorLocation == json.count)
    }

    @Test func activeTabSnapshotReadsAnElasticsearchQueryTab() throws {
        let store = TemporaryStoreFile()
        defer { store.remove() }
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        let json = "{\n  \"index\": \"logs\"\n}"
        viewModel.newElasticsearchQueryTab(rawJSON: json, title: "ES Query")

        let snapshot = viewModel.activeTabSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot?.text == json)
        #expect(snapshot?.tabTitle == "ES Query")
        #expect(snapshot?.cursorLocation == json.count)
    }

    @Test func activeEditorStatementsReturnsTheQdrantQueryTabsRawJSON() throws {
        let store = TemporaryStoreFile()
        defer { store.remove() }
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        let json = "{ \"collection\": \"points\", \"vector\": [1, 0] }"
        viewModel.newQdrantQueryTab(rawJSON: json)

        #expect(viewModel.activeEditorStatements(for: "all") == [json])
    }

    @Test func activeEditorStatementsReturnsTheElasticsearchQueryTabsRawJSON() throws {
        let store = TemporaryStoreFile()
        defer { store.remove() }
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        let json = "{ \"index\": \"logs\", \"query\": { \"match_all\": {} } }"
        viewModel.newElasticsearchQueryTab(rawJSON: json)

        #expect(viewModel.activeEditorStatements(for: "all") == [json])
    }

    @Test func activeEditorStatementsIsEmptyForABlankElasticsearchQueryTab() throws {
        let store = TemporaryStoreFile()
        defer { store.remove() }
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        viewModel.newElasticsearchQueryTab(rawJSON: "   \n  ")
        #expect(viewModel.activeEditorStatements(for: "all").isEmpty)
    }
}
