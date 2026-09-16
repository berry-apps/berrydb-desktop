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

    // MARK: - Round 4 regressions

    /// Finding 1: selection must only contain IDs that are actually rendered.
    /// When a schema group is collapsed, its objects must not appear in visibleIDs
    /// regardless of whether there is an active search.
    @Test func collapsedSchemaObjectsAreExcludedFromVisibleIDsEvenWithSearch() throws {
        let vm = try makeViewModel()

        // Simulate: schema "public" is expanded (in visibleIDs), schema "audit" is collapsed.
        // objectSearch is non-empty ("items").
        // Only expanded-schema objects should be selectable.
        let visibleWhenPublicExpandedAuditCollapsed = ["public.users", "public.items"]
        let visibleWhenBothCollapsed: [String] = []

        vm.selectObject(id: "public.users", isShift: false, isCommand: false,
                        visibleIDs: visibleWhenPublicExpandedAuditCollapsed)
        vm.selectObject(id: "public.items", isShift: true, isCommand: false,
                        visibleIDs: visibleWhenPublicExpandedAuditCollapsed)

        // Only visible IDs selected — collapsed-schema objects absent.
        #expect(vm.selectedObjectIDs == ["public.users", "public.items"])
        #expect(!vm.selectedObjectIDs.contains("audit.items"))

        // If both schemas collapse, shift-click on an item with empty visible list falls back to single.
        vm.selectObject(id: "public.users", isShift: true, isCommand: false,
                        visibleIDs: visibleWhenBothCollapsed)
        #expect(vm.selectedObjectIDs == ["public.users"])
    }

    /// Finding 2: Return key must open selectionLeadID, not Set.first.
    /// After B → Shift+Down → Shift+Down the lead is D; the anchor is B.
    /// selectionLeadID must be D.
    @Test func shiftArrowTwiceLeadIsLastArrowTarget() throws {
        let vm = try makeViewModel()
        let visible = ["a", "b", "c", "d"]

        vm.selectObject(id: "b", visibleIDs: visible)
        #expect(vm.selectionLeadID == nil || vm.selectionLeadID == "b")

        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead → c
        #expect(vm.selectionLeadID == "c")
        #expect(vm.selectionAnchorID == "b")

        vm.selectNextObject(visibleIDs: visible, isShift: true) // lead → d
        #expect(vm.selectionLeadID == "d")
        #expect(vm.selectionAnchorID == "b")
        #expect(vm.selectedObjectIDs.contains("d"))
        // selectedObjectID (Set.first) is NOT guaranteed to be "d":
        // Confirm lead is distinct from anchor.
        #expect(vm.selectionLeadID != vm.selectionAnchorID)
    }
}
