// SidebarExpansionLogic.swift
// Pure helpers shared by WorkspaceView and its unit tests.
// No SwiftUI, no @State — functions only depend on their arguments.

import Foundation

/// Returns whether a schema group should be visible (expanded) given the current search query
/// and the set of manually collapsed group keys.
///
/// Policy: when `search` is non-empty, all schemas auto-expand so matching rows are visible.
/// When `search` is empty, the group is visible only if it has not been manually collapsed.
///
/// - Parameters:
///   - schemaID: The schema group's identifier.
///   - search: The current raw search query string (non-empty triggers auto-expand).
///   - collapsedKeys: The set of collapsed group key strings (format: `"schema:<id>"`).
/// - Returns: `true` if the schema's content rows should be rendered and selectable.
public func schemaGroupIsExpanded(
    schemaID: String,
    search: String,
    collapsedKeys: Set<String>
) -> Bool {
    !search.isEmpty || !collapsedKeys.contains("schema:\(schemaID)")
}

/// Resolves the keyboard Return key's target object ID from the current selection and visible rows.
///
/// Priority:
/// 1. `leadID` when it is both in `selectedIDs` and in `visibleIDs`.
/// 2. The first ID in `visibleIDs` that is also in `selectedIDs`.
/// 3. `nil` when no visible-selected item exists (caller should ignore the key press).
///
/// - Parameters:
///   - leadID: The current `selectionLeadID` from the view model (may be `nil`).
///   - selectedIDs: The full `selectedObjectIDs` set.
///   - visibleIDs: The ordered list of currently rendered object IDs (`currentVisibleObjectIDs`).
/// - Returns: The ID to open, or `nil` if nothing valid is visible and selected.
public func returnKeyTargetID(
    leadID: String?,
    selectedIDs: Set<String>,
    visibleIDs: [String]
) -> String? {
    // Lead must be visible AND selected.
    if let lead = leadID, selectedIDs.contains(lead), visibleIDs.contains(lead) {
        return lead
    }
    // Fall back to first visible-selected item in visible order.
    return visibleIDs.first(where: { selectedIDs.contains($0) })
}
