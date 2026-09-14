import Testing

@testable import BerryUI

@Suite("Command Palette")
struct CommandPaletteEntryTests {
    private func entries() -> [CommandPaletteEntry] {
        [
            CommandPaletteEntry(title: "New SQL Tab", subtitle: "Open a new query editor", perform: {}),
            CommandPaletteEntry(title: "Refresh Schema", subtitle: "Re-read tables, views, and indexes", perform: {}),
            CommandPaletteEntry(title: "Backup…", subtitle: "Export a backup of this connection", perform: {}),
        ]
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(CommandPaletteEntries.matching("", in: entries()).count == 3)
    }

    @Test func matchesCaseInsensitiveSubstringInTitle() {
        let matches = CommandPaletteEntries.matching("refresh", in: entries())
        #expect(matches.map(\.title) == ["Refresh Schema"])
    }

    @Test func matchesCaseInsensitiveSubstringInSubtitleToo() {
        // "tables" only appears in Refresh Schema's subtitle, not its title.
        let matches = CommandPaletteEntries.matching("tables", in: entries())
        #expect(matches.map(\.title) == ["Refresh Schema"])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(CommandPaletteEntries.matching("xyz-nonexistent", in: entries()).isEmpty)
    }

    @Test func buildGatesEntriesByTheirCorrespondingFlag() {
        var didRun: [String] = []
        let actions = WorkspaceMenuActions(
            hasSession: false,
            canOpenQueryTab: true,
            hasAnySession: false,
            hasIntelligence: false,
            canImport: false,
            processListSupported: false,
            userManagementSupported: false,
            focusedTabIsEditor: false,
            focusedTabIsQueryable: false,
            newConnection: { didRun.append("newConnection") },
            openFile: {},
            newSQLTab: { didRun.append("newSQLTab") },
            runCurrent: {},
            runAll: {},
            format: {},
            toggleComment: {},
            saveCurrentSQL: {},
            splitEditor: {},
            warnsOnDataDeletion: true,
            toggleDeleteWarnings: {},
            showsButtonLabels: false,
            toggleButtonLabels: {},
            showHistory: {},
            showSavedQueries: {},
            showInsights: {},
            showGraphExplorer: {},
            showTimeline: {},
            unlockIntelligence: {},
            newTable: {},
            importCSV: {},
            showProcesses: {},
            showUsers: {},
            refreshSchema: {},
            showAbout: {},
            disconnect: {},
            toggleAI: {},
            backup: {},
            goToTable: {},
            commandPalette: {}
        )
        let built = CommandPaletteEntries.build(from: actions)

        // canOpenQueryTab is true -> "New SQL Tab" is enabled and runs its closure.
        let newSQLTab = built.first { $0.title == "New SQL Tab" }
        #expect(newSQLTab?.isEnabled == true)
        newSQLTab?.perform()
        #expect(didRun == ["newSQLTab"])

        // hasSession is false -> "New Table…" is disabled.
        #expect(built.first { $0.title == "New Table…" }?.isEnabled == false)

        // hasIntelligence is false -> "Insights"/"Graph Explorer" are disabled.
        #expect(built.first { $0.title == "Insights" }?.isEnabled == false)
        #expect(built.first { $0.title == "Graph Explorer" }?.isEnabled == false)

        // No gating flag -> "New Connection…" is always enabled.
        #expect(built.first { $0.title == "New Connection…" }?.isEnabled == true)
    }

    /// Every built-in entry needs a non-empty, unique `action` id — it's the
 /// only thing `perform_ui_action` has to address an entry by,
    /// since `title` is localized and can't serve as a stable identifier.
    @Test func everyBuiltEntryHasAUniqueNonEmptyActionID() {
        let actions = WorkspaceMenuActions(
            hasSession: true, canOpenQueryTab: true, hasAnySession: true, hasIntelligence: true,
            canImport: true, processListSupported: true, userManagementSupported: true,
            focusedTabIsEditor: true, focusedTabIsQueryable: true,
            newConnection: {}, openFile: {}, newSQLTab: {}, runCurrent: {}, runAll: {}, format: {},
            toggleComment: {}, saveCurrentSQL: {}, splitEditor: {}, warnsOnDataDeletion: true,
            toggleDeleteWarnings: {}, showsButtonLabels: false, toggleButtonLabels: {}, showHistory: {},
            showSavedQueries: {}, showInsights: {}, showGraphExplorer: {}, showTimeline: {}, unlockIntelligence: {},
            newTable: {}, importCSV: {}, showProcesses: {}, showUsers: {}, refreshSchema: {}, showAbout: {},
            disconnect: {}, toggleAI: {}, backup: {}, goToTable: {}, commandPalette: {}
        )
        let ids = CommandPaletteEntries.build(from: actions).map(\.action)
        #expect(ids.allSatisfy { !$0.isEmpty })
        #expect(Set(ids).count == ids.count)
    }
}
