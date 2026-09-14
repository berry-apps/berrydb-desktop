import BerryStore
import Foundation
import Testing

@testable import BerryAI
@testable import BerryUI

/// Bounded recent-actions log + the in-memory UI
/// graph snapshot — both new, deliberately narrow additions: only tab
/// opened/closed/pane-split are logged, and nothing is persisted beyond the
/// cap ('s rejected explains why).
@MainActor
@Suite("Workspace action log + UI graph snapshot")
struct WorkspaceActionLogTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    @Test func openingATabRecordsAWorkspaceAction() throws {
        let path = tempPath("action-log")
        let vm = try WorkspaceViewModel(storePath: path)
        vm.newEditorTab(text: "select 1", title: "Debug: slow query")

        let actions = try BerryStore(path: path).recentWorkspaceActions(profileID: nil)

        #expect(actions.count == 1)
        #expect(actions.first?.kind == "tab_opened")
        #expect(actions.first?.description.contains("Debug: slow query") == true)
    }

    @Test func splittingAPaneRecordsAWorkspaceAction() throws {
        let path = tempPath("action-log")
        let vm = try WorkspaceViewModel(storePath: path)
        vm.newEditorTab(text: "select 1")
        vm.splitRight(vm.groups[0].id)

        let actions = try BerryStore(path: path).recentWorkspaceActions(profileID: nil)

        #expect(actions.contains { $0.kind == "pane_split" })
    }

    @Test func closingATabRecordsAWorkspaceAction() throws {
        let path = tempPath("action-log")
        let vm = try WorkspaceViewModel(storePath: path)
        vm.newEditorTab(text: "select 1")
        let tabID = vm.tabs.last!.id

        vm.closeTab(id: tabID)

        let actions = try BerryStore(path: path).recentWorkspaceActions(profileID: nil)
        #expect(actions.contains { $0.kind == "tab_closed" })
    }

    @Test func theActionLogIsCappedAtFiftyRowsPerProfile() throws {
        let path = tempPath("action-log")
        let vm = try WorkspaceViewModel(storePath: path)
        for i in 0..<60 { vm.newEditorTab(text: "select \(i)") }

        let actions = try BerryStore(path: path).recentWorkspaceActions(profileID: nil, limit: 100)

        #expect(actions.count == 50)
    }

    /// Unlike `openTabsSnapshot()` (which only reports each pane's active
    /// tab), `uiGraphSnapshot()` must report every tab in every pane.
    @Test func uiGraphSnapshotReportsAllTabsPerPaneNotJustTheActiveOne() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("action-log"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b") // both land in the same (only) pane

        let snapshot = try #require(vm.uiGraphSnapshot())

        #expect(snapshot.panes.count == 1)
        #expect(snapshot.panes[0].tabIDs.count == 2)
        #expect(snapshot.tabs.count == 2)
        #expect(snapshot.activeTabID == vm.tabs.last?.id)

        // openTabsSnapshot(), by contrast, only surfaces the pane's active tab.
        let flatSnapshot = try #require(vm.openTabsSnapshot())
        #expect(flatSnapshot.panes.count == 1)
    }

    @Test func uiGraphSnapshotIsNilWithNoOpenTabs() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("action-log"))
        #expect(vm.uiGraphSnapshot() == nil)
    }
}
