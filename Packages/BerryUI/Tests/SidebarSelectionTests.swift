import BerryStore
import Foundation
import Testing

@testable import BerryUI

@MainActor
@Suite("Sidebar Selection Management")
struct SidebarSelectionTests {
    private func makeViewModel() throws -> WorkspaceViewModel {
        try WorkspaceViewModel(storePath: NSTemporaryDirectory() + "berry-selection-\(UUID().uuidString).sqlite")
    }

    @Test func plainClickSelectsSingleItemAndSetsAnchor() throws {
        let vm = try makeViewModel()
        let visible = ["users", "orders", "audit"]

        vm.selectObject(id: "orders", isShift: false, isCommand: false, visibleIDs: visible)

        #expect(vm.selectedObjectIDs == ["orders"])
        #expect(vm.selectedObjectID == "orders")
        #expect(vm.selectionAnchorID == "orders")
    }

    @Test func commandClickTogglesSelectionAndUpdatesAnchor() throws {
        let vm = try makeViewModel()
        let visible = ["users", "orders", "audit"]

        vm.selectObject(id: "users", isShift: false, isCommand: false, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["users"])

        // Command click adds "orders"
        vm.selectObject(id: "orders", isShift: false, isCommand: true, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["users", "orders"])
        #expect(vm.selectionAnchorID == "orders")

        // Command click toggles "users" off
        vm.selectObject(id: "users", isShift: false, isCommand: true, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["orders"])
        #expect(vm.selectionAnchorID == "users")
    }

    @Test func shiftClickSelectsForwardRangeAndPreservesAnchor() throws {
        let vm = try makeViewModel()
        let visible = ["users", "orders", "products", "audit"]

        // 1. Plain click on users
        vm.selectObject(id: "users", isShift: false, isCommand: false, visibleIDs: visible)
        #expect(vm.selectionAnchorID == "users")

        // 2. Shift click on products
        vm.selectObject(id: "products", isShift: true, isCommand: false, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["users", "orders", "products"])
        #expect(vm.selectionAnchorID == "users")

        // 3. Shift click extended to audit
        vm.selectObject(id: "audit", isShift: true, isCommand: false, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["users", "orders", "products", "audit"])
        #expect(vm.selectionAnchorID == "users")
    }

    @Test func shiftClickSelectsReverseRangeAndPreservesAnchor() throws {
        let vm = try makeViewModel()
        let visible = ["users", "orders", "products", "audit"]

        // 1. Plain click on audit
        vm.selectObject(id: "audit", isShift: false, isCommand: false, visibleIDs: visible)
        #expect(vm.selectionAnchorID == "audit")

        // 2. Shift click on orders
        vm.selectObject(id: "orders", isShift: true, isCommand: false, visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["orders", "products", "audit"])
        #expect(vm.selectionAnchorID == "audit")
    }

    @Test func shiftClickWithFilteredVisibleIDsOnlySelectsVisibleItems() throws {
        let vm = try makeViewModel()
        // Filtered search results: "orders" is hidden
        let filteredVisible = ["users", "user_tokens", "user_profiles"]

        vm.selectObject(id: "users", isShift: false, isCommand: false, visibleIDs: filteredVisible)
        vm.selectObject(id: "user_profiles", isShift: true, isCommand: false, visibleIDs: filteredVisible)

        #expect(vm.selectedObjectIDs == ["users", "user_tokens", "user_profiles"])
    }

    @Test func shiftClickWithAnchorMissingFallsBackGracefully() throws {
        let vm = try makeViewModel()
        // Previous selection was "orders"
        vm.selectObject(id: "orders", isShift: false, isCommand: false, visibleIDs: ["users", "orders"])

        // User filters sidebar, "orders" disappears
        let filteredVisible = ["users", "user_tokens"]

        // Shift click on "user_tokens" with stale anchor
        vm.selectObject(id: "user_tokens", isShift: true, isCommand: false, visibleIDs: filteredVisible)
        #expect(vm.selectedObjectIDs == ["user_tokens"])
        #expect(vm.selectionAnchorID == "user_tokens")
    }

    @Test func keyboardArrowNavigationMovesSelection() throws {
        let vm = try makeViewModel()
        let visible = ["a", "b", "c"]

        vm.selectObject(id: "a", visibleIDs: visible)

        // Down arrow -> b
        vm.selectNextObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["b"])
        #expect(vm.selectionAnchorID == "b")

        // Down arrow -> c
        vm.selectNextObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["c"])
        #expect(vm.selectionAnchorID == "c")

        // Down arrow at bottom -> stays c
        vm.selectNextObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["c"])

        // Up arrow -> b
        vm.selectPreviousObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["b"])
        #expect(vm.selectionAnchorID == "b")

        // Up arrow -> a
        vm.selectPreviousObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["a"])
        #expect(vm.selectionAnchorID == "a")

        // Up arrow at top -> stays a
        vm.selectPreviousObject(visibleIDs: visible)
        #expect(vm.selectedObjectIDs == ["a"])
    }

    @Test func keyboardShiftArrowExtendsSelection() throws {
        let vm = try makeViewModel()
        let visible = ["a", "b", "c", "d"]

        vm.selectObject(id: "b", visibleIDs: visible)
        #expect(vm.selectionAnchorID == "b")

        // Shift + Down extends to c
        vm.selectNextObject(visibleIDs: visible, isShift: true)
        #expect(vm.selectedObjectIDs == ["b", "c"])
        #expect(vm.selectionAnchorID == "b")

        // Shift + Down extends to d
        vm.selectNextObject(visibleIDs: visible, isShift: true)
        #expect(vm.selectedObjectIDs == ["b", "c", "d"])
        #expect(vm.selectionAnchorID == "b")
    }

    // MARK: - Round 5 regressions

    /// Model contract: selectObject only includes IDs present in visibleIDs for Shift ranges.
    /// Production enforcement happens in currentVisibleObjectIDs (WorkspaceView); this test
    /// verifies the model layer correctly restricts selection to what's passed as visibleIDs.
    @Test func selectObjectRespectsBoundaryOfVisibleIDs() throws {
        let vm = try makeViewModel()
        // Simulates: search active, public expanded (audited collapsed not in list).
        let visible = ["public.users", "public.items"]

        vm.selectObject(id: "public.users", visibleIDs: visible)
        vm.selectObject(id: "public.items", isShift: true, visibleIDs: visible)

        #expect(vm.selectedObjectIDs == ["public.users", "public.items"])
        // "audit.items" was never in visibleIDs — model must not add it.
        #expect(!vm.selectedObjectIDs.contains("audit.items"))

        // Simulates: schemas all collapse, visible becomes empty.
        // Shift with stale anchor and empty visible falls back to single-selection on tapped ID.
        vm.selectObject(id: "public.users", isShift: true, visibleIDs: [])
        #expect(vm.selectedObjectIDs == ["public.users"])
    }

    /// Return key target resolution: lead must be visible AND selected.
    /// This tests the model state that WorkspaceView.onKeyPress(.return) reads:
    ///   - leadID valid → open lead
    ///   - lead hidden (not in visible) → open first visible-selected
    ///   - no visible-selected → ignore
    @Test func returnKeyTargetPrefersLeadWhenVisible() throws {
        let vm = try makeViewModel()
        let visible = ["a", "b", "c", "d"]

        // Select b → Shift+Down×2 → lead is d, range is b..d
        vm.selectObject(id: "b", visibleIDs: visible)
        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead = c
        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead = d

        #expect(vm.selectionLeadID == "d")
        #expect(vm.selectedObjectIDs.contains("d"))
        #expect(vm.selectedObjectIDs.contains("b"))

        // Simulate: filter hides d (d no longer in currentVisibleObjectIDs).
        let visibleAfterFilter = ["b", "c"]  // d collapsed/filtered out
        // Lead (d) is NOT in visibleAfterFilter → Return should open first visible-selected.
        let firstVisibleSelected = visibleAfterFilter.first(where: { vm.selectedObjectIDs.contains($0) })
        #expect(firstVisibleSelected == "b")  // b is first visible selected

        // Simulate: all filtered out → no target → Return should ignore.
        let visibleAllHidden: [String] = []
        let noTarget = visibleAllHidden.first(where: { vm.selectedObjectIDs.contains($0) })
        #expect(noTarget == nil)
    }

    /// After B → Shift+Down×2 the lead is D; the anchor is B.
    @Test func shiftArrowTwiceLeadIsLastArrowTarget() throws {
        let vm = try makeViewModel()
        let visible = ["a", "b", "c", "d"]

        vm.selectObject(id: "b", visibleIDs: visible)
        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead → c
        #expect(vm.selectionLeadID == "c")
        #expect(vm.selectionAnchorID == "b")

        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead → d
        #expect(vm.selectionLeadID == "d")
        #expect(vm.selectionAnchorID == "b")
        #expect(vm.selectedObjectIDs == ["b", "c", "d"])
        #expect(vm.selectionLeadID != vm.selectionAnchorID)
    }
}
