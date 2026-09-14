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
/// documented caution around `WorkspaceViewModel()` construction by not
/// touching any global confirmer.
@MainActor
@Suite("Query tab AI wiring (read_current_tab/run_tab_statements)", .serialized)
struct WorkspaceQueryTabAIWiringTests {
    @Test func activeTabSnapshotReadsAQdrantQueryTab() {
        let viewModel = WorkspaceViewModel()
        let json = "{\n  \"collection\": \"points\"\n}"
        viewModel.newQdrantQueryTab(rawJSON: json, title: "Qdrant Query")

        let snapshot = viewModel.activeTabSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot?.text == json)
        #expect(snapshot?.tabTitle == "Qdrant Query")
        #expect(snapshot?.cursorLocation == json.count)
    }

    @Test func activeTabSnapshotReadsAnElasticsearchQueryTab() {
        let viewModel = WorkspaceViewModel()
        let json = "{\n  \"index\": \"logs\"\n}"
        viewModel.newElasticsearchQueryTab(rawJSON: json, title: "ES Query")

        let snapshot = viewModel.activeTabSnapshot()
        #expect(snapshot != nil)
        #expect(snapshot?.text == json)
        #expect(snapshot?.tabTitle == "ES Query")
        #expect(snapshot?.cursorLocation == json.count)
    }

    @Test func activeEditorStatementsReturnsTheQdrantQueryTabsRawJSON() {
        let viewModel = WorkspaceViewModel()
        let json = "{ \"collection\": \"points\", \"vector\": [1, 0] }"
        viewModel.newQdrantQueryTab(rawJSON: json)

        #expect(viewModel.activeEditorStatements(for: "all") == [json])
    }

    @Test func activeEditorStatementsReturnsTheElasticsearchQueryTabsRawJSON() {
        let viewModel = WorkspaceViewModel()
        let json = "{ \"index\": \"logs\", \"query\": { \"match_all\": {} } }"
        viewModel.newElasticsearchQueryTab(rawJSON: json)

        #expect(viewModel.activeEditorStatements(for: "all") == [json])
    }

    @Test func activeEditorStatementsIsEmptyForABlankElasticsearchQueryTab() {
        let viewModel = WorkspaceViewModel()
        viewModel.newElasticsearchQueryTab(rawJSON: "   \n  ")
        #expect(viewModel.activeEditorStatements(for: "all").isEmpty)
    }
}
