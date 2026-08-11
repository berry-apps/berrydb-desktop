import Foundation
import Testing

@testable import BerryUI

/// Editor groups = the VS Code-style unlimited split (ui.md §1). Each group is
/// an independent pane over its own subset of the open tabs.
@MainActor
@Suite("Editor groups (split panes)")
struct EditorGroupTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    @Test func newTabsLandInFocusedGroup() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "select 1")
        vm.newEditorTab(text: "select 2")
        #expect(vm.groups.count == 1)
        #expect(vm.groups[0].tabIDs.count == 2)
        #expect(vm.activeTabID == vm.tabs.last?.id)
    }

    @Test func splitRightOpensAFreshTabInNewColumn() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b") // active = b, group0 = [a, b]
        let bID = vm.tabs.last!.id
        vm.splitRight(vm.groups[0].id)

        #expect(vm.groups.count == 2)
        // Split opens a NEW independent tab, not a second view of the active one
        // that would edit in lock-step (docs/ui/03 §1).
        #expect(vm.groups[1].tabIDs.count == 1)
        #expect(vm.groups[1].tabIDs != [bID])
        #expect(vm.tabs.count == 3)
        #expect(vm.focusedGroupID == vm.groups[1].id)  // focus follows the split
        // Split right = same row, two columns.
        #expect(vm.layoutRows.count == 1)
        #expect(vm.layoutRows[0].groupIDs.count == 2)
        #expect(vm.groups[0].tabIDs.count == 2)        // first pane untouched

        // A tab opened now lands in the focused (second) group.
        vm.newEditorTab(text: "c")
        #expect(vm.groups[0].tabIDs.count == 2)
        #expect(vm.groups[1].tabIDs.count == 2)
    }

    /// Splitting a Mongo shell pane must open a NEW Mongo shell tab, not a SQL
    /// editor — a hardcoded SQL tab had no session to run against and offered
    /// SQL-dialect autocomplete in a script language it doesn't apply to.
    @Test func splitRightOfAMongoShellPaneOpensAnotherMongoShellTab() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newMongoShellTab(text: "db.users.find({})")
        #expect(vm.groups.count == 1)

        vm.splitRight(vm.groups[0].id)

        #expect(vm.groups.count == 2)
        let newTabID = try #require(vm.groups[1].tabIDs.first)
        let newTab = try #require(vm.tabs.first { $0.id == newTabID })
        guard case .mongoShell = newTab else {
            Issue.record("expected a new .mongoShell tab, got \(newTab)")
            return
        }
    }

    /// Same as above for Qdrant — the vector sibling of Mongo shell.
    @Test func splitRightOfAQdrantPaneOpensAnotherQdrantTab() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newQdrantQueryTab()
        #expect(vm.groups.count == 1)

        vm.splitRight(vm.groups[0].id)

        #expect(vm.groups.count == 2)
        let newTabID = try #require(vm.groups[1].tabIDs.first)
        let newTab = try #require(vm.tabs.first { $0.id == newTabID })
        guard case .qdrantQuery = newTab else {
            Issue.record("expected a new .qdrantQuery tab, got \(newTab)")
            return
        }
    }

    // docs/ui/02 §4: tools open as singleton tabs, not modals.
    @Test func openToolCreatesASingletonTab() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.openTool(.history)
        vm.openTool(.history) // same kind again → focus, don't duplicate
        #expect(vm.tabs.filter { $0.id == "tool:history" }.count == 1)
        #expect(vm.activeTabID == "tool:history")

        vm.openTool(.processes)
        #expect(vm.tabs.contains { $0.id == "tool:processes" })
        #expect(vm.activeTabID == "tool:processes")
    }

    // docs/ui/01 D2: dropping a tab on a pane edge splits a new pane off it.
    @Test func droppingATabOnAnEdgeSplitsANewColumn() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b") // group0 = [a, b]
        let g0 = vm.groups[0].id
        let aID = vm.tabs[0].id
        vm.dropTab("\(g0)::\(aID)", onto: g0, zone: .right)

        #expect(vm.groups.count == 2)
        #expect(vm.layoutRows.count == 1)
        #expect(vm.layoutRows[0].groupIDs.count == 2) // two columns now
        #expect(vm.group(for: g0)?.tabIDs.contains(aID) == false) // moved out of g0
        #expect(vm.tabs.contains { $0.id == aID })     // still open, in the new pane
    }

    @Test func droppingATabOnTheBottomEdgeSplitsANewRow() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b")
        let g0 = vm.groups[0].id
        let aID = vm.tabs[0].id
        vm.dropTab("\(g0)::\(aID)", onto: g0, zone: .bottom)
        #expect(vm.layoutRows.count == 2) // stacked into two rows
    }

    @Test func droppingATabInTheCenterMovesItIntoThePane() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b")     // g0 = [a, b]
        vm.splitRight(vm.groups[0].id) // g1 holds a fresh tab; g0 keeps [a, b]
        let g0 = vm.groups[0].id
        let g1 = vm.groups[1].id
        let aID = vm.tabs[0].id         // 'a', still in g0
        vm.dropTab("\(g0)::\(aID)", onto: g1, zone: .center)
        #expect(vm.group(for: g1)?.tabIDs.contains(aID) == true)  // moved into g1
        #expect(vm.group(for: g0)?.tabIDs.contains(aID) == false)
        #expect(vm.layoutRows[0].groupIDs.count == 2)             // g0 survives (has b)
    }

    // docs/ui/03: dragging a pane's only tab out closes that pane (standard).
    @Test func draggingTheLastTabOutClosesTheSourcePane() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")     // g0 = [a]
        vm.splitRight(vm.groups[0].id) // g1 = [fresh]; g0 = [a]
        let g0 = vm.groups[0].id
        let g1 = vm.groups[1].id
        let aID = vm.tabs.first { vm.groups[0].tabIDs.contains($0.id) }!.id

        vm.dropTab("\(g0)::\(aID)", onto: g1, zone: .center)

        #expect(vm.group(for: g0) == nil)                      // source pane closed
        #expect(vm.group(for: g1)?.tabIDs.contains(aID) == true)
        #expect(vm.layoutRows.count == 1)
        #expect(vm.layoutRows[0].groupIDs.count == 1)          // collapsed to one pane
    }

    @Test func splitDownAddsANewRow() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.splitDown(vm.groups[0].id)
        #expect(vm.groups.count == 2)
        #expect(vm.layoutRows.count == 2)              // two rows, one column each
        #expect(vm.layoutRows[0].groupIDs.count == 1)
        #expect(vm.layoutRows[1].groupIDs.count == 1)
    }

    @Test func moveTabRelocatesToTargetPane() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b") // group0 = [a, b]
        let aID = vm.tabs[0].id
        let bID = vm.tabs[1].id
        vm.splitRight(vm.groups[0].id) // group1 = [b]
        let g0 = vm.groups[0].id
        let g1 = vm.groups[1].id
        vm.moveTab(aID, from: g0, to: g1)
        #expect(vm.group(for: g0)?.tabIDs == [bID])
        #expect(vm.group(for: g1)?.tabIDs.contains(aID) == true)
        #expect(vm.focusedGroupID == g1)
    }

    @Test func movingLastTabOutPrunesTheEmptyPane() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")     // group0 = [a]
        let aID = vm.tabs[0].id
        vm.splitDown(vm.groups[0].id)  // group1 = [fresh tab], 2 rows, focused g1
        let g0 = vm.layoutRows[0].groupIDs[0]
        let g1 = vm.layoutRows[1].groupIDs[0]
        vm.moveTab(aID, from: g0, to: g1) // g0 empties → pruned; rows collapse to 1
        #expect(vm.group(for: g0) == nil)
        #expect(vm.layoutRows.count == 1)
        #expect(vm.group(for: g1)?.tabIDs.contains(aID) == true)
    }

    @Test func draggingATabIntoAnotherPaneThenClosingKeepsItAliveWhileShown() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b")     // group0 = [a, b]
        let aID = vm.tabs[0].id
        vm.splitRight(vm.groups[0].id) // group1 = [fresh tab]
        let g0 = vm.groups[0].id
        let g1 = vm.groups[1].id

        // Close 'a' in its only pane → the document is disposed.
        vm.closeTab(id: aID, inGroup: g0)
        #expect(!vm.tabs.contains { $0.id == aID })
        // Both panes remain (g0 still has b, g1 has its fresh tab).
        #expect(vm.group(for: g0)?.tabIDs.count == 1)
        #expect(vm.group(for: g1) != nil)
    }

    @Test func closingActiveTabActivatesNeighbor() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("groups"))
        vm.newEditorTab(text: "a")
        vm.newEditorTab(text: "b")
        vm.newEditorTab(text: "c")
        let ids = vm.tabs.map(\.id)
        vm.closeTab(id: ids[2], inGroup: vm.groups[0].id) // close the active tab
        #expect(vm.groups[0].activeTabID == ids[1])
    }
}
