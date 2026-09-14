import SwiftUI

/// Actions the workspace publishes to the macOS menu bar. The window fills this
/// in and exposes it via `.focusedSceneValue`; `WorkspaceCommands` reads it so
/// every feature has a real menu-bar home with a keyboard shortcut, instead of
/// hiding behind toolbar chevrons.
public struct WorkspaceMenuActions {
    // State that gates menu items.
    public var hasSession: Bool
    /// True when a query tab can be opened right now: a SQL session, OR a
    /// Mongo `dataSourceSession` (Qdrant stays out — it has no shell-script
 /// "New Query" concept in this plan). Gates
    /// "New SQL Tab" so Mongo users can reach `newQueryTab()` via menu/⌘T,
    /// not just by double-clicking a collection in the sidebar.
    public var canOpenQueryTab: Bool
    /// True for SQL, Mongo, OR Qdrant sessions — gates History/Saved Queries,
    /// which are meaningful regardless of which kind of session is active
    /// (history recording and the saved-queries panel both work for all three).
    public var hasAnySession: Bool
    public var hasIntelligence: Bool
    public var canImport: Bool
    public var processListSupported: Bool
 /// User & permission management.
    public var userManagementSupported: Bool
    public var focusedTabIsEditor: Bool
    /// True for `.editor` OR `.mongoShell` tabs — gates Run/Save SQL, which
    /// work on both (Q15). `focusedTabIsEditor` above stays editor-only and
    /// keeps gating Format/Toggle Comment, which Mongo shell doesn't have.
    public var focusedTabIsQueryable: Bool

    // Commands.
    public var newConnection: () -> Void
    public var openFile: () -> Void
    public var newSQLTab: () -> Void
    public var runCurrent: () -> Void
    public var runAll: () -> Void
    public var format: () -> Void
    public var toggleComment: () -> Void
    public var saveCurrentSQL: () -> Void
    public var splitEditor: () -> Void
 /// Soft data-deletion warnings switch — production rules stay on.
    public var warnsOnDataDeletion: Bool
    public var toggleDeleteWarnings: () -> Void
 /// Label mode for icon action buttons.
    public var showsButtonLabels: Bool
    public var toggleButtonLabels: () -> Void
    public var showHistory: () -> Void
    public var showSavedQueries: () -> Void
    public var showInsights: () -> Void
    public var showGraphExplorer: () -> Void
 /// Time Machine Timeline.
    public var showTimeline: () -> Void
    public var unlockIntelligence: () -> Void
    public var newTable: () -> Void
    public var importCSV: () -> Void
    public var importSQL: () -> Void
    public var showProcesses: () -> Void
    public var showUsers: () -> Void
    public var refreshSchema: () -> Void
    public var showAbout: () -> Void
    public var disconnect: () -> Void
    public var toggleAI: () -> Void
    /// Backup manager (feature/04) — enabled for any session (SQL dump, or a
    /// Mongo/Qdrant bundle).
    public var backup: () -> Void
    /// Restore database from dump or backup file
    public var restoreDump: () -> Void
 /// Global quick-open: fuzzy-search tables/views/collections from
    /// anywhere, not just via the sidebar's own filter field.
    public var goToTable: () -> Void
 /// Global command palette (⌘K): fuzzy-search and run a workspace
    /// action from anywhere.
    public var commandPalette: () -> Void

    public init(
        hasSession: Bool,
        canOpenQueryTab: Bool,
        hasAnySession: Bool,
        hasIntelligence: Bool,
        canImport: Bool,
        processListSupported: Bool,
        userManagementSupported: Bool,
        focusedTabIsEditor: Bool,
        focusedTabIsQueryable: Bool,
        newConnection: @escaping () -> Void,
        openFile: @escaping () -> Void,
        newSQLTab: @escaping () -> Void,
        runCurrent: @escaping () -> Void,
        runAll: @escaping () -> Void,
        format: @escaping () -> Void,
        toggleComment: @escaping () -> Void,
        saveCurrentSQL: @escaping () -> Void,
        splitEditor: @escaping () -> Void,
        warnsOnDataDeletion: Bool,
        toggleDeleteWarnings: @escaping () -> Void,
        showsButtonLabels: Bool,
        toggleButtonLabels: @escaping () -> Void,
        showHistory: @escaping () -> Void,
        showSavedQueries: @escaping () -> Void,
        showInsights: @escaping () -> Void,
        showGraphExplorer: @escaping () -> Void,
        showTimeline: @escaping () -> Void,
        unlockIntelligence: @escaping () -> Void,
        newTable: @escaping () -> Void,
        importCSV: @escaping () -> Void,
        importSQL: @escaping () -> Void = {},
        showProcesses: @escaping () -> Void,
        showUsers: @escaping () -> Void,
        refreshSchema: @escaping () -> Void,
        showAbout: @escaping () -> Void,
        disconnect: @escaping () -> Void,
        toggleAI: @escaping () -> Void,
        backup: @escaping () -> Void,
        restoreDump: @escaping () -> Void = {},
        goToTable: @escaping () -> Void,
        commandPalette: @escaping () -> Void
    ) {
        self.hasSession = hasSession
        self.canOpenQueryTab = canOpenQueryTab
        self.hasAnySession = hasAnySession
        self.hasIntelligence = hasIntelligence
        self.canImport = canImport
        self.processListSupported = processListSupported
        self.userManagementSupported = userManagementSupported
        self.focusedTabIsEditor = focusedTabIsEditor
        self.focusedTabIsQueryable = focusedTabIsQueryable
        self.newConnection = newConnection
        self.openFile = openFile
        self.newSQLTab = newSQLTab
        self.runCurrent = runCurrent
        self.runAll = runAll
        self.format = format
        self.toggleComment = toggleComment
        self.saveCurrentSQL = saveCurrentSQL
        self.splitEditor = splitEditor
        self.warnsOnDataDeletion = warnsOnDataDeletion
        self.toggleDeleteWarnings = toggleDeleteWarnings
        self.showsButtonLabels = showsButtonLabels
        self.toggleButtonLabels = toggleButtonLabels
        self.showHistory = showHistory
        self.showSavedQueries = showSavedQueries
        self.showInsights = showInsights
        self.showGraphExplorer = showGraphExplorer
        self.showTimeline = showTimeline
        self.unlockIntelligence = unlockIntelligence
        self.newTable = newTable
        self.importCSV = importCSV
        self.importSQL = importSQL
        self.showProcesses = showProcesses
        self.showUsers = showUsers
        self.refreshSchema = refreshSchema
        self.showAbout = showAbout
        self.disconnect = disconnect
        self.toggleAI = toggleAI
        self.backup = backup
        self.restoreDump = restoreDump
        self.goToTable = goToTable
        self.commandPalette = commandPalette
    }
}

private struct WorkspaceMenuActionsKey: FocusedValueKey {
    typealias Value = WorkspaceMenuActions
}

public extension FocusedValues {
    var workspaceMenu: WorkspaceMenuActions? {
        get { self[WorkspaceMenuActionsKey.self] }
        set { self[WorkspaceMenuActionsKey.self] = newValue }
    }
}

/// The BerryDB menu bar. Add to the scene with `.commands { WorkspaceCommands() }`.
public struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceMenu) private var actions
    /// Bumped by ShortcutStore on every remap so the menu rebuilds with the
 /// user's combos (shortcut editor).
    @AppStorage("berry.shortcutsRev") private var shortcutsRev = 0

    public init() {}

    private func combo(_ action: ShortcutAction) -> KeyboardShortcut {
        _ = shortcutsRev // menu re-evaluates when a shortcut changes
        return ShortcutStore.shared.shortcut(for: action).keyboardShortcut
            ?? action.defaultShortcut.keyboardShortcut!
    }

    public var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About BerryDB")) { actions?.showAbout() }
        }

        CommandGroup(replacing: .help) {
            Button(L("BerryDB Documentation")) {
                if let url = URL(string: "https://db.berryhub.app") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button(L("About BerryDB")) { actions?.showAbout() }
        }
        // File → connection / tab / open, next to the system "New" group.
        CommandGroup(after: .newItem) {
            Button(L("New Connection…")) { actions?.newConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button(L("New SQL Tab")) { actions?.newSQLTab() }
                .keyboardShortcut(combo(.newSQLTab))
                .disabled(actions?.canOpenQueryTab != true)
            Button(L("Open Database or SQL File…")) { actions?.openFile() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
        }

        CommandMenu(L("Query")) {
 // One exec action: Run executes every statement in the
            // active editor.
            Button(L("Run")) { actions?.runAll() }
                .keyboardShortcut(combo(.run))
                .disabled(actions?.focusedTabIsQueryable != true)
            Button(L("Format")) { actions?.format() }
                .keyboardShortcut(combo(.format))
                .disabled(actions?.focusedTabIsEditor != true)
            Button(L("Toggle Comment")) { actions?.toggleComment() }
                .keyboardShortcut(combo(.toggleComment))
                .disabled(actions?.focusedTabIsEditor != true)
            Button(L("Save SQL")) { actions?.saveCurrentSQL() }
                .keyboardShortcut(combo(.saveSQL))
                .disabled(actions?.focusedTabIsQueryable != true)
            Divider()
            Toggle(L("Warn Before Deleting Data"), isOn: Binding(
                get: { actions?.warnsOnDataDeletion ?? true },
                set: { _ in actions?.toggleDeleteWarnings() }
            ))
            Divider()
            Button(L("Split Editor")) { actions?.splitEditor() }
                .keyboardShortcut(combo(.splitEditor))
                .disabled(actions?.hasSession != true)
            Divider()
            Button(L("History")) { actions?.showHistory() }
                .keyboardShortcut(combo(.history))
                .disabled(actions?.hasAnySession != true)
            Button(L("Saved Queries")) { actions?.showSavedQueries() }
                .keyboardShortcut(combo(.savedQueries))
                .disabled(actions?.hasAnySession != true)
        }

        CommandMenu(L("Database")) {
            Button(L("Go to Table…")) { actions?.goToTable() }
                .keyboardShortcut(combo(.goToTable))
                .disabled(actions?.hasAnySession != true)
            Divider()
            Button(L("New Table…")) { actions?.newTable() }
                .disabled(actions?.hasSession != true)
            Button(L("Import CSV…")) { actions?.importCSV() }
                .disabled(actions?.canImport != true)
            Button(L("Import SQL File…")) { actions?.importSQL() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(actions?.hasSession != true)
            if actions?.processListSupported == true {
                Button(L("Processes")) { actions?.showProcesses() }
            }
            if actions?.userManagementSupported == true {
                Button(L("Users")) { actions?.showUsers() }
            }
            Divider()
            Button(L("Backup…")) { actions?.backup() }
                .disabled(actions?.hasAnySession != true)
            Button(L("Restore Database from File…")) { actions?.restoreDump() }
                .disabled(actions?.hasAnySession != true)
            Divider()
            Button(L("Refresh Schema")) { actions?.refreshSchema() }
                .keyboardShortcut(combo(.refreshSchema))
                .disabled(actions?.hasSession != true)
            Button(L("Disconnect")) { actions?.disconnect() }
                .disabled(actions?.hasSession != true)
        }

        CommandMenu(L("Intelligence")) {
            if actions?.hasIntelligence == true {
                Button(L("Insights")) { actions?.showInsights() }
                Button(L("Graph Explorer")) { actions?.showGraphExplorer() }
                Button(L("Time Machine")) { actions?.showTimeline() }
                Divider()
                Button(L("License Details…")) { actions?.unlockIntelligence() }
            } else {
                Button(L("Unlock Intelligence…")) { actions?.unlockIntelligence() }
            }
        }

        // AI panel + label mode + tab bar toggle live under the standard View menu.
        CommandGroup(after: .sidebar) {
            Toggle(L("Show Button Labels"), isOn: Binding(
                get: { actions?.showsButtonLabels ?? false },
                set: { _ in actions?.toggleButtonLabels() }
            ))
            Button(L("Command Palette")) { actions?.commandPalette() }
                .keyboardShortcut(combo(.commandPalette))
            Button(L("AI Assistant")) { actions?.toggleAI() }
                .keyboardShortcut(combo(.aiAssistant))
                .disabled(actions?.hasSession != true)
            Divider()
            Button(L("Show Tab Bar")) {
                NSApp.sendAction(#selector(NSWindow.toggleTabBar(_:)), to: nil, from: nil)
            }
        }
    }
}
