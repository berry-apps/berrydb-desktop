import Foundation

/// One action offered in the Command Palette
/// ⌘K).
public struct CommandPaletteEntry: Identifiable {
    public var id: String { title }
    public let title: String
    public let subtitle: String
    public let isEnabled: Bool
    public let perform: () -> Void
 /// Stable, locale-independent identifier for AI routing ('s
    /// `perform_ui_action` tool) — `title` can't serve this role since it's
    /// localized. Defaulted so existing direct-construction call sites (tests)
    /// that predate AI routing keep compiling unchanged.
    public let action: String

    public init(
        title: String, subtitle: String, isEnabled: Bool = true, action: String = "",
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.action = action
        self.perform = perform
    }
}

public enum CommandPaletteEntries {
    /// Builds the palette from the same actions the menu bar uses
    /// (`WorkspaceMenuActions`) — one registry, two front doors (⌘K and the
    /// menu bar), so nothing added to the menu goes missing from the palette.
    /// v1 is a fixed, curated subset (the ones worth reaching without the
    /// mouse) rather than every menu item — natural-language routing to a
 /// wider action set is a documented v2.
    public static func build(from actions: WorkspaceMenuActions) -> [CommandPaletteEntry] {
        [
            CommandPaletteEntry(
                title: L("New SQL Tab"), subtitle: L("Open a new query editor"),
                isEnabled: actions.canOpenQueryTab, action: "new_sql_tab", perform: actions.newSQLTab
            ),
            CommandPaletteEntry(
                title: L("Go to Table…"), subtitle: L("Jump to a table or collection"),
                isEnabled: actions.hasAnySession, action: "go_to_table", perform: actions.goToTable
            ),
            CommandPaletteEntry(
                title: L("New Table…"), subtitle: L("Create a table"),
                isEnabled: actions.hasSession, action: "new_table", perform: actions.newTable
            ),
            CommandPaletteEntry(
                title: L("Refresh Schema"), subtitle: L("Re-read tables, views, and indexes"),
                isEnabled: actions.hasSession, action: "refresh_schema", perform: actions.refreshSchema
            ),
            CommandPaletteEntry(
                title: L("History"), subtitle: L("Recently run queries"),
                isEnabled: actions.hasAnySession, action: "history", perform: actions.showHistory
            ),
            CommandPaletteEntry(
                title: L("Saved Queries"), subtitle: L("Open a saved query"),
                isEnabled: actions.hasAnySession, action: "saved_queries", perform: actions.showSavedQueries
            ),
            CommandPaletteEntry(
                title: L("Insights"), subtitle: L("Schema and index findings"),
                isEnabled: actions.hasIntelligence, action: "insights", perform: actions.showInsights
            ),
            CommandPaletteEntry(
                title: L("Graph Explorer"), subtitle: L("Table dependencies and blast radius"),
                isEnabled: actions.hasIntelligence, action: "graph_explorer", perform: actions.showGraphExplorer
            ),
            CommandPaletteEntry(
                title: L("Time Machine"), subtitle: L("Schema change history"),
                isEnabled: actions.hasIntelligence, action: "timeline", perform: actions.showTimeline
            ),
            CommandPaletteEntry(
                title: L("Import CSV…"), subtitle: L("Load a CSV file into a table"),
                isEnabled: actions.canImport, action: "import_csv", perform: actions.importCSV
            ),
            CommandPaletteEntry(
                title: L("Backup…"), subtitle: L("Export a backup of this connection"),
                isEnabled: actions.hasAnySession, action: "backup", perform: actions.backup
            ),
            CommandPaletteEntry(
                title: L("AI Assistant"), subtitle: L("Ask about this schema"),
                isEnabled: actions.hasSession, action: "ai_assistant", perform: actions.toggleAI
            ),
            CommandPaletteEntry(
                title: L("New Connection…"), subtitle: L("Connect to a database"),
                isEnabled: true, action: "new_connection", perform: actions.newConnection
            ),
            CommandPaletteEntry(
                title: L("Disconnect"), subtitle: L("Close the current connection"),
                isEnabled: actions.hasSession, action: "disconnect", perform: actions.disconnect
            ),
        ]
    }

    /// Case-insensitive substring match on title or subtitle. Empty query
    /// matches everything — same convention as `ChatCommands.matching`.
    public static func matching(_ query: String, in entries: [CommandPaletteEntry]) -> [CommandPaletteEntry] {
        guard !query.isEmpty else { return entries }
        let needle = query.lowercased()
        return entries.filter {
            $0.title.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }
}
