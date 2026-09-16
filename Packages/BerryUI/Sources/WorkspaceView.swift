import AppKit
import BerryAI
import BerryCore
import BerryDataSourceKit
import BerryDriverKit
import BerryGraph
import BerryKeyValueKit
import BerryLicense
import BerryStore
import SwiftUI
import UniformTypeIdentifiers

/// Main window: saved connections + object browser in the
/// sidebar; a tab strip of table grids and SQL editors in the detail pane
/// All strings go through `L(_:)` — the app follows the
/// system language.
public struct WorkspaceView: View {
    @State private var viewModel = WorkspaceViewModel()
    @State private var connectionSheetTarget: ConnectionSheetTarget?
    @State private var showLicense = false
    @State private var showAIPanel = false
    @State private var showAbout = false
    @State private var showQuickOpen = false
    @State private var showCommandPalette = false
    @State private var showNewCollectionSheet = false
    @State private var showImportSQLSheet = false
    @State private var showRestoreDumpSheet = false
    @State private var importSQLInitialURL: URL?
    @State private var license: LicenseManager
    @State private var aiController: AIPanelController
    @State private var processBuffer = ResultBuffer()
    @State private var usersBuffer = ResultBuffer()
    /// Forwarded to `AboutSheetView`'s "Check for Updates…" button — kept as
    /// a plain closure (not the app target's own `UpdaterControlling` type)
 /// so BerryUI stays decoupled from BerryApp (-way
    /// dependency direction). Defaults to a no-op so existing/test call sites
    /// that construct `WorkspaceView()` without it keep compiling.
    private let checkForUpdates: () -> Void
    private enum SidebarTab: String, CaseIterable, Identifiable {
        case connections
        case objects
        var id: String { rawValue }

        var title: String {
            switch self {
            case .connections: return L("Connections")
            case .objects: return L("Objects")
            }
        }

        var systemImage: String {
            switch self {
            case .connections: return "rectangle.stack"
            case .objects: return "cylinder.split.1x2"
            }
        }
    }

    private enum ObjectTypeFilter: String, CaseIterable, Identifiable {
        case all
        case table
        case view
        case function
        case trigger

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return L("All")
            case .table: return L("Tables")
            case .view: return L("Views")
            case .function: return L("Funcs")
            case .trigger: return L("Triggers")
            }
        }

        var systemImage: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .table: return "tablecells"
            case .view: return "rectangle.on.rectangle"
            case .function: return "function"
            case .trigger: return "bolt"
            }
        }
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sidebarTab: SidebarTab = .connections
    @State private var objectTypeFilter: ObjectTypeFilter = .all
 /// Sidebar filter over table/view names.
    @State private var objectSearch = ""
 /// Collapsed schema-tree groups — expanded by default.
    @State private var collapsedKinds: Set<SchemaObjectKind> = []
    @State private var collapsedGroupKeys: Set<String> = []
 /// Object whose DDL is being shown.
    @State private var ddlObject: SchemaObject?
 /// Object whose quick-info stats are being shown.
    @State private var statsObject: SchemaObject?
    /// The pane a tab is currently being dragged over (D2 drop zones).
    @State private var dropTargetGroup: String?
 /// ⌘S save-query prompt.
    @State private var showSaveSQL = false
    @State private var saveSQLName = ""
 /// Soft data-deletion warnings switch — persisted; production
 /// rules are unaffected.
    @AppStorage("berry.warnDataDeletion") private var warnDataDeletion = true
 /// Label mode for the icon action buttons: show titles next to
    /// the icons in the header and exec clusters.
    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false
 /// Opens detached-tab windows (D1).
    @Environment(\.openWindow) private var openWindow

    public init(checkForUpdates: @escaping () -> Void = {}) {
        // License and AI panel share ONE LicenseManager so activation updates
        // both the toolbar badge and the AI entitlement/token together.
        let license = LicenseManager.makeDefault()
        _license = State(initialValue: license)
        _aiController = State(initialValue: AIPanelController(
            license: license, backendURL: LicenseManager.backendURL()
        ))
        self.checkForUpdates = checkForUpdates
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            connectionSheetTarget = .new
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L("New Connection…"))
                        .accessibilityLabel(L("New Connection…"))
                    }
                }
        } detail: {
            HStack(spacing: 0) {
                if columnVisibility == .detailOnly {
                    collapsedSidebarRail
                    Divider()
                }
                // `HSplitView` (not a hand-rolled DragGesture, as an earlier
                // cut of this had) so the AI panel divider is a real
                // NSSplitView drag, same as the left sidebar's
                // `NavigationSplitView` column — the resize happens at the
                // AppKit/layer level, so it doesn't re-run SwiftUI's body
                // for the chat panel on every reported drag delta the way a
                // `@State`-driven `.frame(width:)` does, which is what made
                // that first attempt visibly lag once the chat history had
                // any real content.
                if showAIPanel {
                    HSplitView {
                        detail
 .background(BerryTheme.canvas) // main canvas
                        AIPanelView(
                            controller: aiController,
                            onUpgrade: {
                                showAIPanel = false
                                showLicense = true
                            },
                            onClose: {
                                showAIPanel = false
                            }
                        )
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 720)
                    }
                } else {
                    detail
 .background(BerryTheme.canvas) // main canvas
                }
            }
        }
 .tint(BerryTheme.accent) // macOS blue accent everywhere
 .focusEffectDisabled() // no focus outline on buttons
        // Also drives AppKit's native tab-strip label (View > Show Tab Bar) —
        // NSWindow.title is the only source that UI reads. An empty title
        // here previously left native tabs blank.
        .navigationTitle(viewModel.connectionTitle)
        .toolbar { toolbarContent }
        .focusedSceneValue(\.workspaceMenu, menuActions)
        // History / Saved Queries / New Table / Import / Processes / Insights /
 // Graph Explorer are all tabs now, not sheets — see
        // toolTabView.
        .sheet(isPresented: $showLicense) {
            LicenseView(license: license, initialBalance: aiController.balance)
        }
        .sheet(isPresented: $showAbout) {
            AboutSheetView(checkForUpdates: checkForUpdates)
        }
        .sheet(isPresented: $showQuickOpen) {
            QuickOpenView(
                objects: viewModel.objects,
                collections: viewModel.collections,
                onSelect: { item in
                    switch item {
                    case .object(let object): open(object)
                    case .collection(let ref): viewModel.openCollection(ref)
                    }
                    showQuickOpen = false
                },
                onCancel: { showQuickOpen = false }
            )
        }
        .sheet(isPresented: $showCommandPalette) {
            CommandPaletteView(
                entries: CommandPaletteEntries.build(from: menuActions),
                onCancel: { showCommandPalette = false },
                onAskAI: { query in await aiController.routeCommandPaletteQuery(query) }
            )
        }
        .sheet(item: $ddlObject) { object in
            DDLSheet(object: object, load: { await viewModel.ddl(of: object) })
        }
        .sheet(item: $statsObject) { object in
            TableStatsSheet(object: object, load: { await viewModel.tableStats(of: object) })
        }
        .sheet(isPresented: $showNewCollectionSheet) {
            NewCollectionSheet(
                kind: viewModel.dataSourceSession?.kind ?? .document,
                existingNames: Set(viewModel.collections.map(\.name)),
                onCreate: { ref, options in await viewModel.createCollection(ref, options: options) }
            )
        }
        .sheet(isPresented: $showImportSQLSheet) {
            if let session = viewModel.session {
                ImportSQLSheet(
                    session: session,
                    initialFileURL: importSQLInitialURL,
                    onDismiss: {
                        showImportSQLSheet = false
                        importSQLInitialURL = nil
                    },
                    onSuccess: {
                        viewModel.refreshSchema()
                    }
                )
            }
        }
        .sheet(isPresented: $showRestoreDumpSheet) {
            RestoreDumpSheet(
                session: viewModel.session,
                dataSourceSession: viewModel.dataSourceSession,
                onDismiss: { showRestoreDumpSheet = false },
                onSuccess: {
                    viewModel.refreshSchema()
                }
            )
        }
        .sheet(item: $connectionSheetTarget) { target in
            // item-based so editing a profile builds a fresh sheet with that
            // profile's fields, instead of reusing the "new" sheet's empty state
 // (Edit was showing the New form).
            ConnectionSheet(
                profile: target.profile,
 // All three driver families
                // offer connection types here — the unified `DriverID` enum
                // is what makes this a plain concatenation instead of a
                // union type.
                availableDrivers: (DriverRegistry.registered + DataSourceRegistry.registered + KeyValueRegistry.registered)
                    .sorted { $0.rawValue < $1.rawValue },
                onTest: { config in await viewModel.testConnection(config) },
                onSave: { profile, secrets in
                    viewModel.save(profile: profile, secrets: secrets)
                }
            )
        }
        .alert(
            L("SSH host key changed"),
            isPresented: Binding(
                get: { viewModel.hostKeyChange != nil },
                set: { if !$0 { viewModel.dismissHostKeyChange() } }
            )
        ) {
            Button(L("Cancel"), role: .cancel) { viewModel.dismissHostKeyChange() }
            Button(L("Trust New Key & Reconnect"), role: .destructive) {
                guard let profile = viewModel.admitTrustChangedHostKey() else { return }
                Task { await viewModel.connect(profile: profile) }
            }
        } message: {
            if let change = viewModel.hostKeyChange {
                Text(hostKeyChangeMessage(change))
            }
        }
        .alert(L("Save SQL"), isPresented: $showSaveSQL) {
            TextField(L("Name"), text: $saveSQLName)
            Button(L("Save")) {
                let name = saveSQLName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, let sql = activeQuery?.sql else { return }
                viewModel.saveSavedQuery(name: name, sql: sql, folder: nil, global: false)
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Name this query to save it"))
        }
        .alert(
            L("Couldn't complete the action"),
            isPresented: Binding(
                get: { viewModel.quickActionError != nil },
                set: { if !$0 { viewModel.quickActionError = nil } }
            )
        ) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(viewModel.quickActionError ?? "")
        }
        .alert(
            L("Large SQL File"),
            isPresented: Binding(
                get: { viewModel.pendingLargeFile != nil },
                set: { if !$0 { viewModel.pendingLargeFile = nil } }
            )
        ) {
            if let warning = viewModel.pendingLargeFile {
                Button(L("Open in Editor")) {
                    let url = warning.url
                    viewModel.pendingLargeFile = nil
                    Task {
                        do {
                            _ = try await viewModel.openSQLFile(at: url, bypassLargeCheck: true)
                        } catch {
                            viewModel.fileOpenError = error.localizedDescription
                        }
                    }
                }
                if viewModel.session != nil {
                    Button(L("Import Directly")) {
                        let url = warning.url
                        viewModel.pendingLargeFile = nil
                        importSQLInitialURL = url
                        showImportSQLSheet = true
                    }
                }
                Button(L("Cancel"), role: .cancel) {
                    viewModel.pendingLargeFile = nil
                }
            }
        } message: {
            if let warning = viewModel.pendingLargeFile {
                Text(String(format: L("This file is %.1f MB. Opening large SQL files in the interactive editor may cause sluggishness. Would you like to open it anyway?"), warning.sizeInMB))
            }
        }
        .alert(
            L("Unable to Open SQL File"),
            isPresented: Binding(
                get: { viewModel.fileOpenError != nil },
                set: { if !$0 { viewModel.fileOpenError = nil } }
            )
        ) {
            Button(L("OK"), role: .cancel) { viewModel.fileOpenError = nil }
        } message: {
            Text(viewModel.fileOpenError ?? "")
        }
        .task {
            // propose_sql inserts/edits the active query tab, or reuses an
 // open query tab if none is active. create_debug_tab
 // has its own, separate closure below that never reuses.
            // `title` names a tab this has to CREATE. An existing tab keeps its
            // own name — `renameOnReuse` is false for propose_sql, because
            // renaming a tab the user is working in would be wrong, and true for
            // the callers that pass a title the model chose explicitly.
            let applyQueryToTab = { (sql: String, title: String?, renameOnReuse: Bool) in
                let reuseTitle = renameOnReuse ? title : nil
                switch viewModel.activeTab {
                case .editor(let document):
                    document.text = sql
                    if let reuseTitle, !reuseTitle.isEmpty { document.title = reuseTitle }
                case .mongoShell(let state):
                    state.text = sql
                    if let reuseTitle, !reuseTitle.isEmpty { state.title = reuseTitle }
                case .qdrantQuery(let state):
                    state.rawJSON = sql
                    if let reuseTitle, !reuseTitle.isEmpty { state.title = reuseTitle }
                case .elasticsearchQuery(let state):
                    state.rawJSON = sql
                    if let reuseTitle, !reuseTitle.isEmpty { state.title = reuseTitle }
                default:
                    // If a query tab is already open in the workspace, reuse and focus it:
                    if let existing = viewModel.tabs.compactMap({ tab -> (id: String, apply: (String, String?) -> Void)? in
                        switch tab {
                        case .editor(let doc):
                            return (tab.id, { newText, newTitle in
                                doc.text = newText
                                if let t = newTitle, !t.isEmpty { doc.title = t }
                            })
                        case .mongoShell(let state):
                            return (tab.id, { newText, newTitle in
                                state.text = newText
                                if let t = newTitle, !t.isEmpty { state.title = t }
                            })
                        case .qdrantQuery(let state):
                            return (tab.id, { newText, newTitle in
                                state.rawJSON = newText
                                if let t = newTitle, !t.isEmpty { state.title = t }
                            })
                        case .elasticsearchQuery(let state):
                            return (tab.id, { newText, newTitle in
                                state.rawJSON = newText
                                if let t = newTitle, !t.isEmpty { state.title = t }
                            })
                        default:
                            return nil
                        }
                    }).first {
                        viewModel.activeTabID = existing.id
                        existing.apply(sql, reuseTitle)
                    } else {
                        // Otherwise open a single new query tab, matching this
 // connection's native query shape (-adjacent fix:
                        // Qdrant/Elasticsearch used to fall through to a SQL
                        // editor tab here, which can't run their queries).
                        switch viewModel.dataSourceSession?.kind {
                        case .document: viewModel.newMongoShellTab(text: sql)
                        case .vector: viewModel.newQdrantQueryTab(rawJSON: sql, title: title)
                        case .search: viewModel.newElasticsearchQueryTab(rawJSON: sql, title: title)
                        case nil: viewModel.newEditorTab(text: sql, title: title)
                        }
                    }
                }
            }

            // The title only takes effect where `applyQueryToTab` has to CREATE a
            // tab — an already-open tab keeps its own name, since renaming a tab
            // the user is working in would be wrong. Without it, every tab
 // propose_sql opened landed as "Untitled".
            aiController.onPropose = { sql, title in
                applyQueryToTab(sql, title, false)
            }
            aiController.createDebugTab = { sql, title in
 // always a fresh
                // tab — never reuses/overwrites an existing one, unlike
                // propose_sql/applyQueryToTab above. A debug tab has no
                // stable identity to match against (not a saved query, not a
                // table/tool), so any reuse heuristic risks clobbering
                // unsaved user edits in an already-open tab.
                switch viewModel.dataSourceSession?.kind {
                case .document: viewModel.newMongoShellTab(text: sql, title: title)
                case .vector: viewModel.newQdrantQueryTab(rawJSON: sql, title: title)
                case .search: viewModel.newElasticsearchQueryTab(rawJSON: sql, title: title)
                case nil: viewModel.newEditorTab(text: sql, title: title)
                }
            }
            aiController.onRefreshSchema = { viewModel.refreshSchema() }
            aiController.readActiveTab = { viewModel.activeTabSnapshot() }
            aiController.readOpenTabs = { viewModel.openTabsSnapshot() }
            aiController.activeTabStatements = { which in viewModel.activeEditorStatements(for: which) }
            aiController.resolveArtifactID = { tabID in viewModel.artifactID(forTab: tabID) }
            aiController.linkArtifact = { tabID, artifactID in viewModel.setArtifactID(artifactID, forTab: tabID) }
            aiController.openArtifact = { artifactID in viewModel.openArtifact(id: artifactID) }
            aiController.openObject = { objectID in viewModel.selectObject(id: objectID) }
            aiController.openTextInTab = { text in viewModel.newEditorTab(text: text) }
            aiController.openMermaidInTab = { source in viewModel.openMermaidDiagram(source: source) }
            aiController.openMermaidTab = { source, title in viewModel.openMermaidDiagram(source: source, title: title) }
            aiController.mentionCandidates = { query in viewModel.matchingArtifactMentions(query: query) }
            aiController.uiGraphSnapshot = { viewModel.uiGraphSnapshot() }
 // AI Command Palette NL routing
 // — same registry the ⌘K palette/menu bar use.
            aiController.uiActionEntries = {
                CommandPaletteEntries.build(from: menuActions).map {
                    UIActionEntry(action: $0.action, title: $0.title, isEnabled: $0.isEnabled, perform: $0.perform)
                }
            }
            aiController.previewNewColumn = { table, column in
                await viewModel.previewNewColumn(table: table, column: column)
            }
            aiController.simulateImpact = { viewModel.simulateImpact($0) }
            aiController.maybeGenerateDailyReview = { await viewModel.maybeGenerateDailyReview() }
            aiController.latestDailyReview = { viewModel.latestDailyReview() }
            aiController.slowestQueries = { viewModel.slowestQueries(limit: $0) }
 // Persist per-connection AI settings (+ consent).
            aiController.loadSettings = { profileID in
                viewModel.loadAISetting(profileID: profileID).map {
                    let decode = { (json: String) -> Set<String> in
                        Set((try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? [])
                    }
                    return AIPanelController.AIConnectionSettings(
                        enabled: $0.aiEnabled,
                        allowSampleRows: $0.allowSampleRows,
                        autoApproveSelects: $0.autoApproveSelects,
                        consentGiven: $0.consentGiven,
                        enabledMCPServers: decode($0.enabledMcpServers),
                        trustedMCPServers: decode($0.trustedMcpServers)
                    )
                }
            }
            aiController.saveSettings = { profileID, settings in
                let encode = { (ids: Set<String>) -> String in
                    (try? JSONEncoder().encode(Array(ids).sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                }
                viewModel.saveAISetting(AIConnectionSetting(
                    profileID: profileID,
                    aiEnabled: settings.enabled,
                    allowSampleRows: settings.allowSampleRows,
                    autoApproveSelects: settings.autoApproveSelects,
                    consentGiven: settings.consentGiven,
                    enabledMcpServers: encode(settings.enabledMCPServers),
                    trustedMcpServers: encode(settings.trustedMCPServers)
                ))
            }
 // Local graph_query tool over the persisted DSG — only when
            // the license unlocks Intelligence (Q15 tier gate).
            aiController.makeGraphExecutor = { profileID in
                license.hasFeature(LicenseFeature.intelligence)
                    ? viewModel.graphExecutor(profileID: profileID) : nil
            }
            // Detached-tab windows resolve their tab through this workspace
 // (D1).
            DetachedWorkspace.shared.viewModel = viewModel
            syncIntelligenceEntitlement()
 // Apply the persisted data-deletion-warning switch.
            QueryService.confirmsDataDeletion = warnDataDeletion
            // Pull a subscription the backend already granted this device (e.g. a
            // Paddle payment whose post-checkout poll had timed out) so AI unlocks
 // on launch without reopening the license sheet.
            await license.syncFromBackend()
            // Unconditional (not gated by refreshWindow like refreshIfNeeded):
 // renews the blob early so a lapsed network keeps AI alive,
            // and — the reason this must not wait for near-expiry — catches a
            // revoked key/device promptly instead of only near the blob's own
 // (possibly months-away) natural expiry. A no-op
            // (silent, license stays as cached) for an unlicensed user (no
            // token yet) or while offline.
            await license.refreshNow()
        }
        .onChange(of: viewModel.session?.id, initial: true) {
            bindAI()
        }
        .onChange(of: viewModel.dataSourceSession?.id, initial: true) {
            bindAI()
        }
        .onChange(of: viewModel.collections.map(\.name)) {
            bindAI()
        }
        .onChange(of: viewModel.objects.map(\.name)) {
            bindAI()
        }
        .onChange(of: license.status) {
            // Rebuild after activation so the AI session picks up the new token,
            // but never disrupt a conversation that is already running.
            if !aiController.isBuilt { bindAI() }
            syncIntelligenceEntitlement()
        }
        .task {
            if !WorkspaceViewModel.pendingOpenURLs.isEmpty {
                let pending = WorkspaceViewModel.pendingOpenURLs
                WorkspaceViewModel.pendingOpenURLs.removeAll()
                for url in pending {
                    do {
                        _ = try await viewModel.openSQLFile(at: url)
                    } catch {
                        viewModel.fileOpenError = error.localizedDescription
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            var handled = false
            for url in urls where url.pathExtension.lowercased() == "sql" {
                Task {
                    do {
                        _ = try await viewModel.openSQLFile(at: url)
                    } catch {
                        viewModel.fileOpenError = error.localizedDescription
                    }
                }
                handled = true
            }
            return handled
        }
        .onReceive(NotificationCenter.default.publisher(for: .berryDBOpenSQLFile)) { note in
            if let url = note.object as? URL {
                WorkspaceViewModel.pendingOpenURLs.removeAll(where: { $0 == url })
                Task {
                    do {
                        _ = try await viewModel.openSQLFile(at: url)
                    } catch {
                        viewModel.fileOpenError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// The toolbar license badges below read raw `license.status`
    /// otherwise, which shows "Unlicensed" even when Apple Intelligence
    /// bypass access is what's actually making the AI panel usable —
    /// mirrors `LicenseView`'s own `isAppleIntelligenceActive`.
    private var isAppleIntelligenceLicenseActive: Bool {
        aiController.appleIntelligenceGranted
    }

    /// SQL/script text + tab title for the active tab, when it's a kind that
    /// can be saved as a query (`.editor` or `.mongoShell`) — nil otherwise.
    /// Shared by "Save SQL" (⌘S) and the naming alert below (Q15: Mongo shell
 /// tabs save the same way SQL editor tabs do, item 2).
    private var activeQuery: (sql: String, title: String)? {
        switch viewModel.activeTab {
        case .editor(let document): return (document.text, document.title)
        case .mongoShell(let state): return (state.text, state.title)
        default: return nil
        }
    }

 /// ⌘S: a tab linked to a saved query writes back to that same
    /// record, like saving a file; an unlinked tab prompts for a name once and
    /// links from then on.
    private func beginSaveSQL() {
        if case .editor(let doc) = viewModel.activeTab, doc.fileURL != nil {
            do {
                try doc.saveToFile()
                return
            } catch {
                viewModel.fileOpenError = error.localizedDescription
                return
            }
        }
        guard let query = activeQuery,
              !query.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if viewModel.updateLinkedSavedQuery() { return }
        saveSQLName = query.title == L("Untitled") ? "" : query.title
        showSaveSQL = true
    }

    private func hostKeyChangeMessage(_ change: WorkspaceViewModel.HostKeyChange) -> String {
        L("The host key for this server differs from the one you trusted before. Continue only if you expected this — for example, the server was reinstalled. Otherwise the connection may be intercepted.")
            + "\n\n\(change.host):\(change.port)\n"
            + L("Trusted:") + " \(change.stored)\n"
            + L("New:") + " \(change.presented)"
    }

    private func bindAI() {
        aiController.bind(
            session: viewModel.session,
            dataSourceSession: viewModel.dataSourceSession,
            collections: viewModel.collections,
            catalog: viewModel.catalog,
            objects: viewModel.objects,
            profileID: viewModel.activeProfileID
        )
    }

    /// Q15: keep the DSG harvest/analyze gate in sync with the license tier.
    private func syncIntelligenceEntitlement() {
        viewModel.intelligenceEntitled = license.hasFeature(LicenseFeature.intelligence)
    }

    // MARK: - Toolbar

    // The title bar keeps only the three app-level actions (they never overflow);
    // every workspace action lives in `actionHeaderBar` inside the content so
 // macOS can't collapse them into a ">>" overflow menu. The
    // same actions also live in the menu bar, which carries the shortcuts.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                viewModel.newQueryTab()
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .disabled(viewModel.session == nil && viewModel.dataSourceSession == nil)
            .help(L("New SQL/Query Tab"))

            Button {
                viewModel.openTool(.history)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .disabled(viewModel.session == nil && viewModel.dataSourceSession == nil)
            .help(L("History"))

            Button {
                viewModel.openTool(.savedQueries)
            } label: {
                Image(systemName: "bookmark")
            }
            .disabled(viewModel.session == nil && viewModel.dataSourceSession == nil)
            .help(L("Saved Queries"))

            if viewModel.session != nil {
                Button {
                    viewModel.openTool(.newTable)
                } label: {
                    Image(systemName: "tablecells.badge.ellipsis")
                }
                .help(L("New Table…"))
            }

            if viewModel.dataSourceSession != nil {
                Button {
                    showNewCollectionSheet = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(L("New Collection…"))
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showAIPanel.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, isActive: showAIPanel)
                    Text(L("AI"))
                }
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(showAIPanel ? BerryTheme.accent : Color(nsColor: .controlColor))
            .disabled(viewModel.session == nil && viewModel.dataSourceSession == nil)
            .help(showAIPanel ? L("Close AI Assistant") : L("AI Assistant"))

            // Insights / Graph Explorer / Time Machine / Backup: previously
            // menu-bar-only entry points, added here in the AI icon cluster
            // per request. Application-menu commands (WorkspaceCommands.swift)
            // are untouched; these route through the same
            // `viewModel.openTool(_:)` calls as the menu and `actionHeaderBar`.
            if license.hasFeature(LicenseFeature.intelligence) {
                Button {
                    viewModel.openTool(.insights)
                } label: {
                    Image(systemName: "lightbulb")
                }
                .disabled(viewModel.session == nil)
                .help(L("Insights"))

                Button {
                    viewModel.openTool(.graphExplorer)
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .disabled(viewModel.session == nil)
                .help(L("Graph Explorer"))

                Button {
                    viewModel.openTool(.timeline)
                } label: {
                    Image(systemName: "clock.arrow.2.circlepath")
                }
                .disabled(viewModel.session == nil)
                .help(L("Time Machine"))
            }

            Button {
                viewModel.openTool(.backup)
            } label: {
                Image(systemName: "externaldrive")
            }
            .disabled(viewModel.session == nil && viewModel.dataSourceSession == nil)
            .help(L("Backup"))

            Button {
                showLicense = true
            } label: {
                Label(
                    isAppleIntelligenceLicenseActive ? L("Active") : license.status.shortLabel,
                    systemImage: isAppleIntelligenceLicenseActive ? "apple.intelligence" : license.status.systemImage
                )
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
            }
        }

    }


    /// Everything the menu bar can trigger (WorkspaceCommands reads this via
    /// `.focusedSceneValue`). Rebuilt each render so the gating flags stay live.
    private var menuActions: WorkspaceMenuActions {
        WorkspaceMenuActions(
            hasSession: viewModel.session != nil,
            // SQL, OR Mongo (not Qdrant — no shell-script "New Query" concept
 // in this plan) — lets Mongo users reach
            // `newQueryTab()` from the menu/⌘T, not just by double-clicking a
            // collection in the sidebar.
            canOpenQueryTab: viewModel.session != nil || viewModel.dataSourceSession != nil,
            // History recording and the saved-queries panel are meaningful for
            // SQL, Mongo, AND Qdrant sessions alike.
            hasAnySession: viewModel.session != nil || viewModel.dataSourceSession != nil,
            hasIntelligence: license.hasFeature(LicenseFeature.intelligence),
            canImport: !viewModel.importableTables().isEmpty,
            processListSupported: viewModel.processListSupported,
            userManagementSupported: viewModel.userManagementSupported,
            focusedTabIsEditor: viewModel.focusedTabIsEditor,
            // Run/Save SQL also work on `.mongoShell` tabs (Q15); Format/Toggle
            // Comment stay editor-only above — Mongo shell has no formatter or
            // comment-toggler (this plan's Global Constraints).
            focusedTabIsQueryable: {
                switch viewModel.activeTab {
                case .editor, .mongoShell: return true
                default: return false
                }
            }(),
            newConnection: { connectionSheetTarget = .new },
            openFile: { openFilePanel() },
            newSQLTab: { viewModel.newQueryTab() },
            runCurrent: { viewModel.runFocusedEditor() },
            runAll: {
                // Selection or all, for SQL; Mongo shell/Qdrant have no
                // selection concept, so Run always runs every statement.
                switch viewModel.activeTab {
                case .mongoShell(let state):
                    if let dataSourceSession = viewModel.dataSourceSession {
                        state.run(session: dataSourceSession, applyWrite: { change in
                            await viewModel.applyDataSourceWriteOutcome(change)
                        })
                    }
                case .qdrantQuery(let state):
                    if let dataSourceSession = viewModel.dataSourceSession {
                        state.run(session: dataSourceSession, applyWrite: { change in
                            await viewModel.applyDataSourceWriteOutcome(change)
                        })
                    }
                case .elasticsearchQuery(let state):
                    if let dataSourceSession = viewModel.dataSourceSession {
                        state.run(session: dataSourceSession, applyWrite: { change in
                            await viewModel.applyDataSourceWriteOutcome(change)
                        })
                    }
                default:
                    viewModel.runFocusedEditor()
                }
            },
            format: { viewModel.formatFocusedEditor() },
            toggleComment: { viewModel.toggleCommentFocusedEditor() },
            saveCurrentSQL: { beginSaveSQL() },
            splitEditor: { viewModel.splitFocusedGroup() },
            warnsOnDataDeletion: warnDataDeletion,
            toggleDeleteWarnings: {
                warnDataDeletion.toggle()
                QueryService.confirmsDataDeletion = warnDataDeletion
            },
            showsButtonLabels: showButtonLabels,
            toggleButtonLabels: { showButtonLabels.toggle() },
            showHistory: { viewModel.openTool(.history) },
            showSavedQueries: { viewModel.openTool(.savedQueries) },
            showInsights: { viewModel.openTool(.insights) },
            showGraphExplorer: { viewModel.openTool(.graphExplorer) },
            showTimeline: { viewModel.openTool(.timeline) },
            unlockIntelligence: { showLicense = true },
            newTable: { viewModel.openTool(.newTable) },
            importCSV: { viewModel.openTool(.importCSV) },
            importSQL: { showImportSQLSheet = true },
            showProcesses: { viewModel.openTool(.processes) },
            showUsers: { viewModel.openTool(.users) },
            refreshSchema: { viewModel.refreshSchema() },
            showAbout: { showAbout = true },
            disconnect: { viewModel.disconnect() },
            toggleAI: { showAIPanel.toggle() },
            backup: { viewModel.openTool(.backup) },
            restoreDump: { showRestoreDumpSheet = true },
            goToTable: { showQuickOpen = true },
            commandPalette: { showCommandPalette = true }
        )
    }

    // MARK: - Sidebar

    private var sidebarTabHeader: some View {
        HStack(spacing: 4) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    sidebarTab = tab
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 10, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: sidebarTab == tab ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                    .background(sidebarTab == tab ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                    .foregroundStyle(sidebarTab == tab ? Color.accentColor : Color.secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(sidebarTab == tab ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if viewModel.session != nil || viewModel.dataSourceSession != nil {
                Button {
                    viewModel.refreshSchema()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 22)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .foregroundStyle(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(L("Refresh schema"))
                .accessibilityLabel(L("Refresh schema"))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var collapsedSidebarRail: some View {
        VStack(spacing: 10) {
            ForEach(SidebarTab.allCases) { tab in
                Button {
                    sidebarTab = tab
                    withAnimation(.easeInOut(duration: 0.2)) {
                        columnVisibility = .all
                    }
                } label: {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(sidebarTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .foregroundStyle(sidebarTab == tab ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(sidebarTab == tab ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarTabHeader

            Divider()

            if sidebarTab == .connections {
                connectionList
            } else {
                objectList
            }
        }
        .font(BerryTheme.Typeface.sidebarRow)
        .overlay(alignment: .bottom) {
            if let storeError = viewModel.storeError {
                Text(storeError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
            }
        }
    }

    private var connectionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if viewModel.profiles.isEmpty {
                    sectionHeader(L("Connections"), paddingTop: 6, onAdd: { connectionSheetTarget = .new })
                    Text(L("No connections yet — press ＋"))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                } else {
                    let firstGroupName = viewModel.connectionGroups.first?.name
                    ForEach(viewModel.connectionGroups, id: \.name) { group in
                        let key = group.name ?? "__default__"
                        let isFirst = group.name == firstGroupName
                        let isExpanded = !collapsedGroupKeys.contains(key)
                        sectionHeader(
                            group.name ?? L("Connections"),
                            binding: groupExpanded(key),
                            paddingTop: isFirst ? 6 : 4,
                            onAdd: { connectionSheetTarget = .new }
                        )
                        if isExpanded {
                            ForEach(Array(group.profiles.enumerated()), id: \.element.id) { index, profile in
                                profileRow(profile, group: group, index: index)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private var objectTypeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ObjectTypeFilter.allCases) { filter in
                    Button {
                        objectTypeFilter = filter
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: filter.systemImage)
                                .font(.system(size: 10))
                            Text(filter.title)
                                .font(.system(size: 10, weight: objectTypeFilter == filter ? .semibold : .regular))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(objectTypeFilter == filter ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .foregroundStyle(objectTypeFilter == filter ? Color.accentColor : Color.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(objectTypeFilter == filter ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private var objectList: some View {
        Group {
            if viewModel.session == nil && viewModel.dataSourceSession == nil && viewModel.keyValueSession == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(L("No Active Connection"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(L("Double-click a connection in the Connections tab to view tables and objects."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button(L("Go to Connections")) {
                        sidebarTab = .connections
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    if viewModel.session != nil {
                        objectTypeFilterBar
                        if !viewModel.objects.isEmpty {
                            objectFilterField
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if viewModel.session != nil {
                                let hasSchemas = viewModel.session?.capabilities.schemas ?? false
                                let schemaGroups = SchemaTree.group(objects: viewModel.objects, hasSchemaCapability: hasSchemas)
                                if schemaGroups.count == 1 && schemaGroups[0].name == nil {
                                    flatSchemaContent(schemaGroups[0])
                                } else {
                                    ForEach(schemaGroups) { group in
                                        schemaGroupHeader(group)
                                        if !collapsedGroupKeys.contains("schema:\(group.id)") {
                                            schemaGroupContent(group)
                                                .padding(.leading, 12)
                                        }
                                    }
                                }
                            } else if let dataSourceSession = viewModel.dataSourceSession {
                                dataSourceContent(dataSourceSession)
                            } else if let keyValueSession = viewModel.keyValueSession {
                                keyValueSidebarContent(keyValueSession)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    .onKeyPress(.downArrow) {
                        #if os(macOS)
                        let isShift = NSEvent.modifierFlags.contains(.shift)
                        #else
                        let isShift = false
                        #endif
                        viewModel.selectNextObject(visibleIDs: currentVisibleObjectIDs, isShift: isShift)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        #if os(macOS)
                        let isShift = NSEvent.modifierFlags.contains(.shift)
                        #else
                        let isShift = false
                        #endif
                        viewModel.selectPreviousObject(visibleIDs: currentVisibleObjectIDs, isShift: isShift)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        if let selectedID = viewModel.selectedObjectID,
                           let object = viewModel.objects.first(where: { $0.id == selectedID }) {
                            open(object)
                            return .handled
                        } else if let selectedColID = viewModel.selectedCollectionID,
                                  let col = viewModel.collections.first(where: { $0.id == selectedColID }) {
                            viewModel.openCollection(col)
                            return .handled
                        }
                        return .ignored
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func flatSchemaContent(_ flat: SchemaTreeGroup) -> some View {
        let tables = filteredObjects(in: flat.tables, kind: .table)
        let views = filteredObjects(in: flat.views, kind: .view)
        let functions = filteredObjects(in: flat.functions, kind: .function)
        let procedures = filteredObjects(in: flat.procedures, kind: .procedure)
        let triggers = filteredObjects(in: flat.triggers, kind: .trigger)

        if objectTypeFilter == .all || objectTypeFilter == .table {
            sectionHeader(L("Tables (\(tables.count))"), binding: expanded(.table))
            if expanded(.table).wrappedValue {
                ForEach(tables) { object in
                    objectRow(object, icon: "tablecells")
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .view {
            if !views.isEmpty || objectTypeFilter == .view {
                sectionHeader(L("Views (\(views.count))"), binding: expanded(.view), onAdd: { createViewTemplate() })
                if expanded(.view).wrappedValue {
                    ForEach(views) { object in
                        objectRow(object, icon: "rectangle.on.rectangle")
                    }
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .function {
            if !functions.isEmpty || objectTypeFilter == .function {
                sectionHeader(L("Functions (\(functions.count))"), binding: expanded(.function), onAdd: { createFunctionTemplate() })
                if expanded(.function).wrappedValue {
                    ForEach(functions) { object in
                        objectRow(object, icon: "function")
                    }
                }
            }
            if !procedures.isEmpty || objectTypeFilter == .function {
                sectionHeader(L("Procedures (\(procedures.count))"), binding: expanded(.procedure), onAdd: { createProcedureTemplate() })
                if expanded(.procedure).wrappedValue {
                    ForEach(procedures) { object in
                        objectRow(object, icon: "gearshape.2")
                    }
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .trigger {
            if !triggers.isEmpty || objectTypeFilter == .trigger {
                sectionHeader(L("Triggers (\(triggers.count))"), binding: expanded(.trigger), onAdd: { createTriggerTemplate() })
                if expanded(.trigger).wrappedValue {
                    ForEach(triggers) { object in
                        objectRow(object, icon: "bolt")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dataSourceContent(_ dataSourceSession: DataSourceSession) -> some View {
        ForEach(DataSourceTree.group(viewModel.collections)) { group in
            let key = group.database ?? "__default_ds__"
            let isExpanded = groupExpanded(key).wrappedValue
            sectionHeader(
                group.database.map { "\($0) (\(group.collections.count))" }
                    ?? L("Collections (\(group.collections.count))"),
                binding: groupExpanded(key)
            )
            if isExpanded {
                ForEach(group.collections) { ref in
                    collectionRow(ref, kind: dataSourceSession.kind)
                }
            }
        }
    }

    @ViewBuilder
    private func keyValueSidebarContent(_ session: KeyValueSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(session.displayName, paddingTop: 6)
            HStack {
                Text(L("Driver"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.driverDisplayName)
            }
            .font(BerryTheme.Typeface.sidebarRow)
            .padding(.horizontal, 8)
            if session.isProduction {
                Label(L("Production"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
            }
            Text(L("Redis has no table/collection tree — browse and search keys directly in the main panel (Scan)."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 4)
        }
    }

    private func schemaGroupHeader(_ group: SchemaTreeGroup) -> some View {
        let isExpanded = schemaExpanded(group.id).wrappedValue
        return HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    schemaExpanded(group.id).wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(group.name ?? "")
                        .font(BerryTheme.Typeface.sidebarSection)
                    Spacer()
                    Text("(\(group.totalCount))")
                        .font(BerryTheme.Typeface.sidebarSection)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private func groupExpanded(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedGroupKeys.contains(key) },
            set: { isExpanded in
                if isExpanded { collapsedGroupKeys.remove(key) } else { collapsedGroupKeys.insert(key) }
            }
        )
    }

    private func sectionHeader(
        _ title: String,
        binding: Binding<Bool>? = nil,
        paddingTop: CGFloat = 0,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 4) {
            if let binding {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        binding.wrappedValue.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: binding.wrappedValue ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(title)
                            .font(BerryTheme.Typeface.sidebarSection)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(title)
                    .font(BerryTheme.Typeface.sidebarSection)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let onAdd {
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("New"))
            }
        }
        .padding(.top, paddingTop)
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

 /// Inline filter over the table/view lists.
    private var objectFilterField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(L("Filter tables"), text: $objectSearch)
                .textFieldStyle(.plain)
                .font(BerryTheme.Typeface.sidebarRow)
            if !objectSearch.isEmpty {
                Button {
                    objectSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L("Clear"))
            }
            Button {
                viewModel.refreshSchema()
            } label: {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Refresh Schema"))
            .accessibilityLabel(L("Refresh Schema"))
        }
    }

 /// Expand/collapse binding for a schema-tree group. An active
    /// search force-expands so matches are never hidden in a collapsed group.
    private func expanded(_ kind: SchemaObjectKind) -> Binding<Bool> {
        Binding(
            get: { !objectSearch.isEmpty || !collapsedKinds.contains(kind) },
            set: { isExpanded in
                if isExpanded { collapsedKinds.remove(kind) } else { collapsedKinds.insert(kind) }
            }
        )
    }

    private func schemaExpanded(_ id: String) -> Binding<Bool> {
        let key = "schema:\(id)"
        return Binding(
            get: { !objectSearch.isEmpty || !collapsedGroupKeys.contains(key) },
            set: { isExpanded in
                if isExpanded { collapsedGroupKeys.remove(key) } else { collapsedGroupKeys.insert(key) }
            }
        )
    }

    private func isKindExpanded(_ kind: SchemaObjectKind) -> Bool {
        !objectSearch.isEmpty || !collapsedKinds.contains(kind)
    }

    private func subgroupHeader(_ title: String, kind: SchemaObjectKind, onAdd: (() -> Void)? = nil) -> some View {
        HStack(spacing: 4) {
            Button {
                DispatchQueue.main.async {
                    if collapsedKinds.contains(kind) {
                        collapsedKinds.remove(kind)
                    } else {
                        collapsedKinds.insert(kind)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isKindExpanded(kind) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(BerryTheme.Typeface.sidebarSection)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onAdd {
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("New"))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func schemaGroupContent(_ group: SchemaTreeGroup) -> some View {
        let tables = filteredObjects(in: group.tables, kind: .table)
        let views = filteredObjects(in: group.views, kind: .view)
        let functions = filteredObjects(in: group.functions, kind: .function)
        let procedures = filteredObjects(in: group.procedures, kind: .procedure)
        let triggers = filteredObjects(in: group.triggers, kind: .trigger)
        let hasMultipleKinds = [!tables.isEmpty, !views.isEmpty, !functions.isEmpty, !procedures.isEmpty, !triggers.isEmpty].filter { $0 }.count > 1

        if objectTypeFilter == .all || objectTypeFilter == .table {
            if !tables.isEmpty {
                if hasMultipleKinds && objectTypeFilter == .all {
                    subgroupHeader(L("Tables (\(tables.count))"), kind: .table)
                }
                if isKindExpanded(.table) || objectTypeFilter == .table {
                    ForEach(tables) { object in
                        objectRow(object, icon: "tablecells")
                    }
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .view {
            if !views.isEmpty || objectTypeFilter == .view {
                if hasMultipleKinds && objectTypeFilter == .all {
                    subgroupHeader(L("Views (\(views.count))"), kind: .view, onAdd: { createViewTemplate() })
                }
                if isKindExpanded(.view) || objectTypeFilter == .view {
                    ForEach(views) { object in
                        objectRow(object, icon: "rectangle.on.rectangle")
                    }
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .function {
            if !functions.isEmpty || objectTypeFilter == .function {
                if hasMultipleKinds && objectTypeFilter == .all {
                    subgroupHeader(L("Functions (\(functions.count))"), kind: .function, onAdd: { createFunctionTemplate() })
                }
                if isKindExpanded(.function) || objectTypeFilter == .function {
                    ForEach(functions) { object in
                        objectRow(object, icon: "function")
                    }
                }
            }
            if !procedures.isEmpty || objectTypeFilter == .function {
                if hasMultipleKinds && objectTypeFilter == .all {
                    subgroupHeader(L("Procedures (\(procedures.count))"), kind: .procedure, onAdd: { createProcedureTemplate() })
                }
                if isKindExpanded(.procedure) || objectTypeFilter == .function {
                    ForEach(procedures) { object in
                        objectRow(object, icon: "gearshape.2")
                    }
                }
            }
        }
        if objectTypeFilter == .all || objectTypeFilter == .trigger {
            if !triggers.isEmpty || objectTypeFilter == .trigger {
                if hasMultipleKinds && objectTypeFilter == .all {
                    subgroupHeader(L("Triggers (\(triggers.count))"), kind: .trigger, onAdd: { createTriggerTemplate() })
                }
                if isKindExpanded(.trigger) || objectTypeFilter == .trigger {
                    ForEach(triggers) { object in
                        objectRow(object, icon: "bolt")
                    }
                }
            }
        }
    }

    private func filteredObjects(_ kind: SchemaObjectKind) -> [SchemaObject] {
        filteredObjects(in: viewModel.objects, kind: kind)
    }

    private func filteredObjects(in objects: [SchemaObject], kind: SchemaObjectKind) -> [SchemaObject] {
        let base = objects.filter { $0.kind == kind }
        let query = objectSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.database?.localizedCaseInsensitiveContains(query) ?? false)
                || "\($0.database ?? "").\($0.name)".localizedCaseInsensitiveContains(query)
        }
    }

    private var currentVisibleObjectIDs: [String] {
        if viewModel.session != nil {
            let schemaGroups = SchemaTree.group(
                objects: viewModel.objects,
                hasSchemaCapability: viewModel.session?.capabilities.schemas ?? false
            )
            var ids: [String] = []
            if schemaGroups.count == 1 && schemaGroups[0].name == nil {
                let flat = schemaGroups[0]
                if (objectTypeFilter == .all || objectTypeFilter == .table) && isKindExpanded(.table) {
                    ids.append(contentsOf: filteredObjects(in: flat.tables, kind: .table).map(\.id))
                }
                if (objectTypeFilter == .all || objectTypeFilter == .view) && isKindExpanded(.view) {
                    ids.append(contentsOf: filteredObjects(in: flat.views, kind: .view).map(\.id))
                }
                if objectTypeFilter == .all || objectTypeFilter == .function {
                    if isKindExpanded(.function) {
                        ids.append(contentsOf: filteredObjects(in: flat.functions, kind: .function).map(\.id))
                    }
                    if isKindExpanded(.procedure) {
                        ids.append(contentsOf: filteredObjects(in: flat.procedures, kind: .procedure).map(\.id))
                    }
                }
                if (objectTypeFilter == .all || objectTypeFilter == .trigger) && isKindExpanded(.trigger) {
                    ids.append(contentsOf: filteredObjects(in: flat.triggers, kind: .trigger).map(\.id))
                }
            } else {
                for group in schemaGroups {
                    let schemaKey = "schema:\(group.id)"
                    if !objectSearch.isEmpty || !collapsedGroupKeys.contains(schemaKey) {
                        let tables = filteredObjects(in: group.tables, kind: .table)
                        let views = filteredObjects(in: group.views, kind: .view)
                        let functions = filteredObjects(in: group.functions, kind: .function)
                        let procedures = filteredObjects(in: group.procedures, kind: .procedure)
                        let triggers = filteredObjects(in: group.triggers, kind: .trigger)

                        if objectTypeFilter == .all || objectTypeFilter == .table {
                            if !tables.isEmpty && (isKindExpanded(.table) || objectTypeFilter == .table) {
                                ids.append(contentsOf: tables.map(\.id))
                            }
                        }
                        if objectTypeFilter == .all || objectTypeFilter == .view {
                            if !views.isEmpty && (isKindExpanded(.view) || objectTypeFilter == .view) {
                                ids.append(contentsOf: views.map(\.id))
                            }
                        }
                        if objectTypeFilter == .all || objectTypeFilter == .function {
                            if !functions.isEmpty && (isKindExpanded(.function) || objectTypeFilter == .function) {
                                ids.append(contentsOf: functions.map(\.id))
                            }
                            if !procedures.isEmpty && (isKindExpanded(.procedure) || objectTypeFilter == .function) {
                                ids.append(contentsOf: procedures.map(\.id))
                            }
                        }
                        if objectTypeFilter == .all || objectTypeFilter == .trigger {
                            if !triggers.isEmpty && (isKindExpanded(.trigger) || objectTypeFilter == .trigger) {
                                ids.append(contentsOf: triggers.map(\.id))
                            }
                        }
                    }
                }
            }
            return ids
        } else if viewModel.dataSourceSession != nil {
            var ids: [String] = []
            for group in DataSourceTree.group(viewModel.collections) {
                let key = group.database ?? "__default_ds__"
                let isExpanded = groupExpanded(key).wrappedValue
                if isExpanded {
                    ids.append(contentsOf: group.collections.map(\.id))
                }
            }
            return ids
        }
        return []
    }

    private func profileRow(_ profile: ConnectionProfile, group: WorkspaceViewModel.ConnectionGroup, index: Int) -> some View {
        let isSelected = viewModel.activeProfileID == profile.id
        return HStack(spacing: 6) {
            Image(systemName: profile.driver == .sqlite ? "internaldrive" : "cylinder.split.1x2")
                .foregroundStyle(isSelected ? .green : .secondary)
                .font(.system(size: 12))
                .frame(width: 18)
            Text(profile.name)
                .font(BerryTheme.Typeface.sidebarRow)
                .fontWeight(isSelected ? .semibold : .regular)
            Spacer()
            if profile.envColor == "production" {
                ProductionBadge()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .draggable(profile.id.uuidString)
        .dropDestination(for: String.self) { (items: [String], _) -> Bool in
            guard let idStr = items.first,
                  let sourceID = UUID(uuidString: idStr),
                  sourceID != profile.id else { return false }
            guard let fromIdx = group.profiles.firstIndex(where: { $0.id == sourceID }),
                  let toIdx = group.profiles.firstIndex(where: { $0.id == profile.id }) else {
                return false
            }
            let destOffset = toIdx > fromIdx ? toIdx + 1 : toIdx
            viewModel.moveProfiles(group: group.name, from: IndexSet(integer: fromIdx), to: destOffset)
            return true
        }
        .onTapGesture(count: 2) {
            DispatchQueue.main.async {
                guard viewModel.beginConnect() else { return }
                Task { await connect(profile) }
            }
        }
        .contextMenu {
            Button(L("Connect")) {
                guard viewModel.beginConnect() else { return }
                Task { await connect(profile) }
            }
            Button(L("Edit…")) {
                connectionSheetTarget = .edit(profile)
            }
            Button(L("Duplicate")) {
                viewModel.duplicate(profile: profile)
            }
            Divider()
            if index > 0 {
                Button(L("Move Up")) {
                    viewModel.moveProfileUp(id: profile.id)
                }
                .accessibilityLabel(L("Move Up"))
            }
            if index < group.profiles.count - 1 {
                Button(L("Move Down")) {
                    viewModel.moveProfileDown(id: profile.id)
                }
                .accessibilityLabel(L("Move Down"))
            }
            Divider()
            Button(L("Delete"), role: .destructive) {
                viewModel.delete(profile: profile)
            }
        }
    }

    private func objectRow(_ object: SchemaObject, icon: String) -> some View {
        let isSelected = viewModel.selectedObjectIDs.contains(object.id)
        return HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
                .allowsHitTesting(false)
            Text(object.name)
                .font(BerryTheme.Typeface.sidebarRow)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(object.name)
        .accessibilityValue(isSelected ? L("selected") : "")
        .onTapGesture {
            #if os(macOS)
            let flags = NSEvent.modifierFlags
            let isShift = flags.contains(.shift)
            let isCommand = flags.contains(.command)
            if isShift || isCommand {
                viewModel.selectObject(id: object.id, isShift: isShift, isCommand: isCommand, visibleIDs: currentVisibleObjectIDs)
                return
            }
            #endif
            viewModel.selectObject(id: object.id, isShift: false, isCommand: false, visibleIDs: currentVisibleObjectIDs)
            open(object)
        }
        .contextMenu {
            if object.kind.isRelational {
                Button(L("Open Data")) { viewModel.select(object) }
            }
            if object.kind == .table {
                Button(L("Edit Table…")) {
                    Task {
                        if let design = await viewModel.tableDesign(of: object) {
                            viewModel.openAlterTable(design)
                        }
                    }
                }
            }
            if object.kind == .view {
                Button(L("Edit View…")) {
                    Task { await viewModel.openRoutineTab(of: object) }
                }
            }
            if object.kind == .function || object.kind == .procedure {
                Button(L("Edit Function…")) {
                    Task { await viewModel.openRoutineTab(of: object) }
                }
            }
            if object.kind == .trigger {
                Button(L("Edit Trigger…")) {
                    Task { await viewModel.openRoutineTab(of: object) }
                }
            }
            Button(L("Copy Name")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(object.name, forType: .string)
            }
            Button(L("Copy Qualified Name")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(object.qualifiedName, forType: .string)
            }
            Button(L("Show DDL")) { ddlObject = object }
            if object.kind.isRelational {
                Button(L("Quick Info…")) { statsObject = object }
            }
            Divider()
            if object.kind == .table {
                Button(L("Truncate Table…"), role: .destructive) {
                    guard let session = viewModel.session else { return }
                    let sql = session.dialect.truncateSQL(TableRef(database: object.database, name: object.name))
                    viewModel.runDestructiveStatements([sql])
                }
                Button(L("Drop Table…"), role: .destructive) {
                    viewModel.runDestructiveStatements(["DROP TABLE IF EXISTS \(object.name);"])
                }
            }
            if object.kind == .view {
                Button(L("Drop View…"), role: .destructive) {
                    viewModel.runDestructiveStatements(["DROP VIEW IF EXISTS \(object.name);"])
                }
            }
            if object.kind == .function {
                Button(L("Drop Function…"), role: .destructive) {
                    viewModel.runDestructiveStatements(["DROP FUNCTION IF EXISTS \(object.name);"])
                }
            }
            if object.kind == .procedure {
                Button(L("Drop Procedure…"), role: .destructive) {
                    viewModel.runDestructiveStatements(["DROP PROCEDURE IF EXISTS \(object.name);"])
                }
            }
            if object.kind == .trigger {
                Button(L("Drop Trigger…"), role: .destructive) {
                    viewModel.runDestructiveStatements(["DROP TRIGGER IF EXISTS \(object.name);"])
                }
            }
            if viewModel.selectedObjectIDs.count > 1 {
                Divider()
                Button(L("Drop Selected Objects (\(viewModel.selectedObjectIDs.count))…"), role: .destructive) {
                    viewModel.dropSelectedObjects()
                }
            }
        }
    }

 /// One row in the Mongo/Qdrant collection tree
    /// — the `CollectionRef` sibling of `objectRow`.
    private func collectionRow(_ ref: CollectionRef, kind: DataSourceKind) -> some View {
        let isSelected = viewModel.selectedObjectIDs.contains(ref.id)
        return HStack(spacing: 6) {
            Image(systemName: kind == .vector ? "point.3.filled.connected.trianglepath.dotted" : "tray.full")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 18)
                .allowsHitTesting(false)
            Text(ref.name)
                .font(BerryTheme.Typeface.sidebarRow)
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ref.name)
        .accessibilityValue(isSelected ? L("selected") : "")
        .onTapGesture {
            #if os(macOS)
            let flags = NSEvent.modifierFlags
            let isShift = flags.contains(.shift)
            let isCommand = flags.contains(.command)
            if isShift || isCommand {
                viewModel.selectObject(id: ref.id, isShift: isShift, isCommand: isCommand, visibleIDs: currentVisibleObjectIDs)
                return
            }
            #endif
            viewModel.selectObject(id: ref.id, isShift: false, isCommand: false, visibleIDs: currentVisibleObjectIDs)
            viewModel.openCollection(ref)
        }
        .contextMenu {
            Button(L("Copy Name")) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(ref.name, forType: .string)
            }
            Button(L("Open Collection")) { viewModel.openCollection(ref) }
            switch viewModel.dataSourceSession?.kind {
            case .vector:
                // Qdrant has no shell syntax — its actions use the JSON query tab
 // and the point write path, not `db.x.…` scripts.
                Button(L("New Qdrant Query")) {
                    viewModel.newQdrantQueryTab(collection: ref.name, title: ref.name)
                }
                Divider()
                // Same "truncate" concept as the SQL/Mongo cases below — all
                // points removed, the collection itself (and its vector
                // config) stays — just named/labeled to match, since Qdrant
                // has no separate "drop vs. clear" pair of its own commands.
                Button(L("Truncate Collection…"), role: .destructive) {
                    Task {
                        if let error = await viewModel.applyDataSourceWrite(.delete(collection: ref.name, id: .null)) {
                            viewModel.quickActionError = error
                        }
                    }
                }
            case .search:
                // Elasticsearch has no shell syntax either — its actions use
 // the JSON query tab, but unlike
                // Qdrant it DOES support a real truncate (delete_by_query)
                // and drop (delete index), same shape as Mongo below.
                Button(L("New Elasticsearch Query")) {
                    viewModel.newElasticsearchQueryTab(index: ref.name, title: ref.name)
                }
                Divider()
                Button(L("Truncate Collection…"), role: .destructive) {
                    Task {
                        if let error = await viewModel.applyDataSourceWrite(
                            .deleteByFilter(collection: ref.name, filter: .object([]), multi: true)
                        ) {
                            viewModel.quickActionError = error
                        }
                    }
                }
                Button(L("Drop Collection…"), role: .destructive) {
                    Task {
                        if let error = await viewModel.applyDataSourceWrite(.dropCollection(collection: ref.name)) {
                            viewModel.quickActionError = error
                        }
                    }
                }
                if viewModel.selectedObjectIDs.count > 1 {
                    Divider()
                    Button(L("Drop Selected Collections (\(viewModel.selectedObjectIDs.count))…"), role: .destructive) {
                        viewModel.dropSelectedObjects()
                    }
                }
            case .document, nil:
                Button(L("Mongo Shell Query")) { viewModel.newMongoShellTab(text: "db.\(ref.name).find({})", title: ref.name) }
                Divider()
                Button(L("Truncate Collection…"), role: .destructive) {
                    Task {
                        if let error = await viewModel.applyDataSourceWrite(
                            .deleteByFilter(collection: ref.name, filter: .object([]), multi: true)
                        ) {
                            viewModel.quickActionError = error
                        }
                    }
                }
                Button(L("Drop Collection…"), role: .destructive) {
                    Task {
                        if let error = await viewModel.applyDataSourceWrite(.dropCollection(collection: ref.name)) {
                            viewModel.quickActionError = error
                        }
                    }
                }
                if viewModel.selectedObjectIDs.count > 1 {
                    Divider()
                    Button(L("Drop Selected Collections (\(viewModel.selectedObjectIDs.count))…"), role: .destructive) {
                        viewModel.dropSelectedObjects()
                    }
                }
            }
        }
    }

    /// Tables/views open a data grid; routines and triggers open a DDL Editor Tab.
    private func open(_ object: SchemaObject) {
        if object.kind == .table || object.kind == .view {
            viewModel.select(object)
        } else {
            Task {
                await viewModel.openRoutineTab(of: object)
            }
        }
    }

    private func createViewTemplate() {
        let sql = """
        CREATE VIEW new_view AS
        SELECT * FROM table_name;
        """
        viewModel.newEditorTab(text: sql, title: "new_view.sql")
    }

    private func createFunctionTemplate() {
        let driver = viewModel.session?.config.driver
        let sql: String
        switch driver {
        case .postgres:
            sql = """
            CREATE OR REPLACE FUNCTION new_function()
            RETURNS void AS $$
            BEGIN
                -- Function logic here
            END;
            $$ LANGUAGE plpgsql;
            """
        case .mysql:
            sql = """
            CREATE FUNCTION `new_function`()
            RETURNS INT
            DETERMINISTIC
            BEGIN
                RETURN 0;
            END;
            """
        default:
            sql = """
            -- Note: SQLite does not support CREATE FUNCTION via DDL.
            """
        }
        viewModel.newEditorTab(text: sql, title: "new_function.sql")
    }

    private func createProcedureTemplate() {
        let driver = viewModel.session?.config.driver
        let sql: String
        switch driver {
        case .postgres:
            sql = """
            CREATE OR REPLACE PROCEDURE new_procedure()
            LANGUAGE plpgsql
            AS $$
            BEGIN
                -- Procedure logic here
            END;
            $$;
            """
        case .mysql:
            sql = """
            CREATE PROCEDURE `new_procedure`()
            BEGIN
                -- Procedure logic here
            END;
            """
        default:
            sql = """
            -- Note: Engine does not support CREATE PROCEDURE via DDL.
            """
        }
        viewModel.newEditorTab(text: sql, title: "new_procedure.sql")
    }

    private func createTriggerTemplate() {
        let driver = viewModel.session?.config.driver
        let sql: String
        switch driver {
        case .postgres:
            sql = """
            CREATE TRIGGER new_trigger
            BEFORE INSERT ON table_name
            FOR EACH ROW
            EXECUTE FUNCTION trigger_function();
            """
        case .mysql:
            sql = """
            CREATE TRIGGER `new_trigger`
            BEFORE INSERT ON `table_name`
            FOR EACH ROW
            BEGIN
                -- Trigger logic here
            END;
            """
        default: // sqlite
            sql = """
            CREATE TRIGGER new_trigger
            AFTER INSERT ON table_name
            BEGIN
                -- Trigger logic here
            END;
            """
        }
        viewModel.newEditorTab(text: sql, title: "new_trigger.sql")
    }

    /// Routes a saved-profile connect to the SQL or NoSQL/vector path by
 /// driver — the two `DriverRegistry`/
    /// `DataSourceRegistry` families stay separate all the way up to here.
    private func connect(_ profile: ConnectionProfile) async {
        switch profile.driver {
        case .mongodb, .qdrant, .elasticsearch:
            await viewModel.connectDataSource(profile: profile, alreadyBegun: true)
        case .redis:
            await viewModel.connectKeyValue(profile: profile, alreadyBegun: true)
        default:
            await viewModel.connect(profile: profile, alreadyBegun: true)
        }
        if viewModel.session != nil || viewModel.dataSourceSession != nil || viewModel.keyValueSession != nil {
            DispatchQueue.main.async {
                sidebarTab = .objects
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        detailContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let error = viewModel.errorMessage {
            ContentUnavailableView(
                L("Connection Error"),
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if viewModel.isConnecting {
            ProgressView(L("Connecting…"))
        } else if let keyValueSession = viewModel.keyValueSession {
            // Redis has no tabs/collections — shown directly as the main
 // content, bypassing paneContainer entirely.
            KeyValueBrowserView(
                capabilities: keyValueSession.capabilities,
                initialDatabase: keyValueSession.database,
                onScan: { pattern, cursor in try await viewModel.scanKeys(pattern: pattern, cursor: cursor) },
                onGet: { key in try await viewModel.getKeyValue(key) },
                onTTL: { key in await viewModel.keyTTL(key) },
                preview: { change in KeyValueCommandPreview.render(change) },
                onWrite: { change in await viewModel.writeKeyValue(change) },
                onSelectDatabase: { index in await viewModel.selectKeyValueDatabase(index) }
            )
        } else if !viewModel.tabs.isEmpty {
            paneContainer
        } else if viewModel.session == nil && viewModel.dataSourceSession == nil {
            ContentUnavailableView(
                L("No connection"),
                systemImage: "cylinder.split.1x2",
                description: Text(L("Create a connection (⇧⌘N) or open a SQLite file (⌘O)"))
            )
        } else {
            ContentUnavailableView(
                L("Select a table"),
                systemImage: "tablecells",
                description: Text(viewModel.dataSourceSession != nil
                    ? L("Pick a collection from the sidebar")
                    : L("Pick a table from the sidebar, or open an SQL tab (⌘T)"))
            )
        }
    }

    /// Every workspace action as a direct, always-visible icon button
 /// macOS collapses an overcrowded window toolbar into a
    /// ">>" overflow menu, so these live in the content instead — nothing is
 /// ever hidden behind an extra click. Icon-only with hover tooltips.
    private var actionHeaderBar: some View {
        HStack(spacing: 3) {
            headerButton(L("New SQL Tab"), "plus.square.on.square",
 // SQL, OR Mongo (Q15) — mirrors
                         // `canOpenQueryTab` in `menuActions` above so this header
                         // button stays consistent with the menu-bar entry point.
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil) { viewModel.newQueryTab() }
            headerButton(L("History"), "clock.arrow.circlepath",
                         // SQL, Mongo, or Qdrant — mirrors `hasAnySession` in
                         // `menuActions` above (history recording works for all three).
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                         isActive: isToolActive(.history)) { viewModel.openTool(.history) }
            headerButton(L("Saved Queries"), "bookmark",
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                         isActive: isToolActive(.savedQueries)) { viewModel.openTool(.savedQueries) }
            headerButton(L("Artifacts"), "shippingbox",
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                         isActive: isToolActive(.artifacts)) { viewModel.openTool(.artifacts) }

            headerDivider

            headerButton(L("New Table…"), "tablecells.badge.ellipsis",
                         enabled: viewModel.session != nil,
                         isActive: isToolActive(.newTable)) { viewModel.openTool(.newTable) }
            headerButton(L("New Collection…"), "folder.badge.plus",
                         enabled: viewModel.dataSourceSession != nil) { showNewCollectionSheet = true }
            headerButton(L("Import CSV…"), "square.and.arrow.down",
                         enabled: !viewModel.importableTables().isEmpty,
                         isActive: isToolActive(.importCSV)) { viewModel.openTool(.importCSV) }
 // Backup manager (feature/04) opens as a tab: a list of
            // this connection's backups with New Backup / Restore. SQL → .sql dump;
            // Mongo/Qdrant → bundle.
            headerButton(L("Backup"), "externaldrive",
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                         isActive: isToolActive(.backup)) { viewModel.openTool(.backup) }
            if viewModel.processListSupported {
                headerButton(L("Processes"), "cpu",
                             enabled: viewModel.session != nil,
                             isActive: isToolActive(.processes)) { viewModel.openTool(.processes) }
            }
            if viewModel.userManagementSupported || viewModel.userManagementInfoMessage != nil {
                headerButton(L("Users"), "person.2",
                             enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                             isActive: isToolActive(.users)) { viewModel.openTool(.users) }
            }

            headerDivider

            if license.hasFeature(LicenseFeature.intelligence) {
                headerButton(L("Insights"), "lightbulb",
                             enabled: viewModel.session != nil,
                             isActive: isToolActive(.insights)) { viewModel.openTool(.insights) }
                headerButton(L("Graph Explorer"), "point.3.connected.trianglepath.dotted",
                             enabled: viewModel.session != nil,
                             isActive: isToolActive(.graphExplorer)) { viewModel.openTool(.graphExplorer) }
                headerButton(L("Time Machine"), "clock.arrow.2.circlepath",
                             enabled: viewModel.session != nil,
                             isActive: isToolActive(.timeline)) { viewModel.openTool(.timeline) }
            } else {
                headerButton(L("Unlock Intelligence…"), "lock", enabled: true) { showLicense = true }
            }
            headerButton(L("Disconnect"), "bolt.slash",
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil
                             || viewModel.keyValueSession != nil) { viewModel.disconnect() }

            // AI Assistant button sits on its own at the far right — independent
            // block separated by dividers so it's visually distinct from the
            // action cluster on the left and the license label on the right.
            Spacer(minLength: 8)

            headerDivider

            headerButton(L("AI Assistant"), "sparkles",
                         enabled: viewModel.session != nil || viewModel.dataSourceSession != nil,
                         isActive: showAIPanel) { showAIPanel.toggle() }

            headerDivider
            Button {
                showLicense = true
            } label: {
                Label(
                    isAppleIntelligenceLicenseActive ? L("Active") : license.status.shortLabel,
                    systemImage: isAppleIntelligenceLicenseActive ? "apple.intelligence" : license.status.systemImage
                )
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .tint(isAppleIntelligenceLicenseActive ? .green : license.status.tint)
            .help(L("License"))
            .accessibilityLabel(L("License"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var headerDivider: some View {
        Divider().frame(height: 16).padding(.horizontal, 2)
    }

    private func headerButton(
        _ title: String,
        _ systemImage: String,
        enabled: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
        .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels, isActive: isActive))
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }

    /// Whether `kind`'s tab is the focused group's active tab — the header
    /// button that opened it stays highlighted while it's the one in view.
    private func isToolActive(_ kind: WorkspaceToolKind) -> Bool {
        viewModel.activeTabID == "tool:\(kind.rawValue)"
    }

 /// The split grid (VS Code-style): rows stack vertically, each row
    /// is a horizontal strip of panes. "Split right" adds a column; "split down"
    /// adds a row. Drag a tab onto another pane to move it there.
    private var paneContainer: some View {
 // Custom resizable split: drag a divider to resize, double-
        // click it to collapse; the hairline turns macOS-blue on hover. Rows
        // stack vertically; each row splits into columns horizontally.
        ResizableSplit(axis: .vertical, ids: viewModel.layoutRows.map(\.id), minExtent: 140) { rowID in
            if let row = viewModel.layoutRows.first(where: { $0.id == rowID }) {
                ResizableSplit(axis: .horizontal, ids: row.groupIDs, minExtent: 320) { gid in
                    if let group = viewModel.group(for: gid) {
                        pane(group)
                    }
                }
            }
        }
    }

    private func pane(_ group: EditorGroup) -> some View {
        let isFocused = group.id == viewModel.focusedGroupID && viewModel.groups.count > 1
        return GeometryReader { geo in
            VStack(spacing: 0) {
                tabStrip(group)
                Divider()
                tabContent(viewModel.tab(for: group.activeTabID ?? ""), groupID: group.id)
            }
            // A slim accent line marks the focused pane when more than one is open.
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(BerryTheme.accent)
                    .frame(height: 2)
                    .opacity(isFocused ? 1 : 0)
            }
            // Highlight the pane while a tab is dragged over it (D2). isTargeted
            // reliably clears — a DropDelegate can get swallowed by the editor.
            .overlay {
                if dropTargetGroup == group.id {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(BerryTheme.accent.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(BerryTheme.accent, lineWidth: 2))
                        .allowsHitTesting(false)
                }
            }
            // Clicking anywhere in the pane focuses it (VS Code) — simultaneous so
            // it doesn't swallow clicks headed for the editor/grid.
            .simultaneousGesture(TapGesture().onEnded {
                viewModel.focusedGroupID = group.id
            })
            // Drop a tab: near an edge splits a new pane off that side, the
 // middle moves it into this pane (D2). A wide center
            // keeps ordinary moves reliable; only the outer 18% is a split edge.
            // Dropping a tab on a pane MOVES it there — always. Deriving a split
            // edge from the drop point proved unreliable across coordinate spaces
            // and kept hijacking ordinary moves; splitting is on the Split
 // Right/Down buttons instead.
            // The drop location is pane-local (verified). Near an edge splits a
            // new pane off that side; the wide center moves the tab here (D2).
            .dropDestination(for: String.self) { items, location in
                dropTargetGroup = nil
                guard let payload = items.first else { return false }
                viewModel.dropTab(payload, onto: group.id, zone: Self.dropZone(for: location, in: geo.size))
                return true
            } isTargeted: { targeted in
                if targeted { dropTargetGroup = group.id }
                else if dropTargetGroup == group.id { dropTargetGroup = nil }
            }
        }
    }


    /// Which edge (or the center) of a pane a pane-local drop point falls in.
    /// The tab-strip band at the top ALWAYS means "move here" — dropping onto
 /// another pane's tabs must never split. Below that, a wide
 /// center moves and only the outer 12% is a split edge (D2).
    static func dropZone(for point: CGPoint, in size: CGSize) -> WorkspaceViewModel.DropZone {
        if point.y < 44 { return .center } // tab strip + margin
        let x = min(max(point.x / max(size.width, 1), 0), 1)
        let y = min(max(point.y / max(size.height, 1), 0), 1)
        if x < 0.12 { return .left }
        if x > 0.88 { return .right }
        if y < 0.12 { return .top }
        if y > 0.88 { return .bottom }
        return .center
    }

    private func tabStrip(_ group: EditorGroup) -> some View {
        HStack(spacing: 0) {
            // Pane number (top pane = 1) so the user and the AI can refer to the
 // same pane when a split is open (get_open_tabs).
            if viewModel.groups.count > 1, let number = viewModel.paneNumber(of: group.id) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(group.id == viewModel.focusedGroupID ? Color.white : .secondary)
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(group.id == viewModel.focusedGroupID
                            ? AnyShapeStyle(BerryTheme.accent)
                            : AnyShapeStyle(.quaternary))
                    )
                    .padding(.leading, 6)
                    .help(L("Pane \(number)"))
                    .accessibilityLabel(L("Pane \(number)"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(group.tabIDs, id: \.self) { id in
                        if let tab = viewModel.tab(for: id) {
                            tabChip(tab, group: group)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            // Tapping the empty strip area also focuses the pane.
            .contentShape(Rectangle())
            .onTapGesture { viewModel.focusedGroupID = group.id }

            Divider().frame(height: 18)
            Button {
                viewModel.splitRight(group.id)
            } label: {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .help(L("Split Right"))
            .accessibilityLabel(L("Split Right"))

            Button {
                viewModel.splitDown(group.id)
            } label: {
                Image(systemName: "rectangle.split.1x2").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(L("Split Down"))
            .accessibilityLabel(L("Split Down"))

        }
        .background(.bar)
    }

    private func tabChip(_ tab: WorkspaceTab, group: EditorGroup) -> some View {
        let isActive = group.activeTabID == tab.id
        return HStack(alignment: .center, spacing: 4) {
            Image(systemName: tab.systemImage)
                .font(.caption)
            Text(tab.title)
                .font(.callout)
                .lineLimit(1)
            Button {
                closeTabWithConfirmation([tab]) {
                    viewModel.closeTab(id: tab.id, inGroup: group.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .opacity(isActive ? 0.85 : 0.45)
            .help(L("Close Tab"))
            .accessibilityLabel(L("Close Tab"))
        }
        .frame(height: 24)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .background(
            isActive ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
 // Smooth hover for inactive chips; sits behind the active
        // selection fill, so it only shows when the chip isn't selected.
        .hoverHighlight(cornerRadius: 6)
        .contentShape(Rectangle())
        .onTapGesture { viewModel.focusTab(tab.id, inGroup: group.id) }
        .contextMenu {
 // D1 — a tab can live in its own window; tools stay in
            // the main window (singleton chrome).
            if case .tool = tab {} else {
                Button(L("Move to New Window")) {
                    viewModel.detachTab(tab.id)
                    openWindow(id: "detached-tab", value: tab.id)
                }
                Divider()
            }
            Button(L("Close Tab")) {
                closeTabWithConfirmation([tab]) {
                    viewModel.closeTab(id: tab.id, inGroup: group.id)
                }
            }
            Button(L("Close Other Tabs")) {
                let otherTabs = viewModel.tabs.filter { $0.id != tab.id }
                closeTabWithConfirmation(otherTabs) {
                    viewModel.closeOtherTabs(except: tab.id)
                }
            }
            Button(L("Close All Tabs")) {
                closeTabWithConfirmation(viewModel.tabs) {
                    viewModel.closeAllTabs()
                }
            }
        }
        // Drag a tab to another pane to move it there (VS Code).
        .draggable("\(group.id)::\(tab.id)")
    }

    private func closeTabWithConfirmation(_ targetTabs: [WorkspaceTab], action: @escaping () -> Void) {
        let unsavedCount = targetTabs.filter { viewModel.hasUnsavedChanges($0) }.count
        guard unsavedCount > 0 else {
            action()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Unsaved Changes", bundle: berryModuleBundle)
        alert.informativeText = String(
            localized: "There are \(unsavedCount) tab(s) with unsaved changes. Are you sure you want to close them?",
            bundle: berryModuleBundle
        )
        alert.addButton(withTitle: String(localized: "Close Anyway", bundle: berryModuleBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: berryModuleBundle))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    action()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                action()
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: WorkspaceTab?, groupID: String) -> some View {
        @Bindable var viewModel = viewModel
        switch tab {
        case .table(let state):
            TableTabView(
                state: state,
                session: viewModel.session,
                isProduction: viewModel.isProductionSession,
                onOpenReference: { fk, value in viewModel.jumpToReference(fk, value: value) }
            )
        case .editor(let document):
            EditorTabView(
                document: document,
                session: viewModel.session,
                isProduction: viewModel.isProductionSession,
                objects: viewModel.objects,
                catalog: viewModel.catalog,
                transaction: viewModel.transaction,
                onFocus: { viewModel.focusedGroupID = groupID },
                onPersist: { viewModel.persistEditor(document) },
                onRefreshSchema: { viewModel.refreshSchema() },
                availableProfiles: viewModel.profiles,
                onAttachProfile: { profile in Task { await viewModel.connect(profile: profile) } },
                onSaveQueryReplay: { sql, durationMS in await viewModel.saveQueryReplay(sql: sql, durationMS: durationMS) }
            )
        case .tool(let kind):
            toolTabView(kind, groupID: groupID)
        case .alterTable(let original):
 // ALTER designer as a tab: prefilled from the live
            // table, preview shows the diff, apply runs the single SQL path.
            TableDesignerSheet(
                preview: { edited in
                    viewModel.alterStatements(original: original, edited: edited)
                },
                onApply: { edited in
                    await viewModel.applyAlteration(original: original, edited: edited)
                },
                onClose: {
                    viewModel.closeTab(id: "alter:\(original.database ?? "").\(original.name)", inGroup: groupID)
                },
                editingExisting: original,
                alterWarnings: { edited in
                    viewModel.alterWarnings(original: original, edited: edited)
                },
                migrationPreview: { edited in
                    viewModel.migrationPreview(editing: edited)
                },
                tableNames: viewModel.relationalTableNames,
                columnsProvider: { await viewModel.columns(ofTableNamed: $0) },
                driver: viewModel.session?.config.driver ?? .sqlite,
                availableSchemas: viewModel.availableSchemas
            )
        case .collection(let state):
            CollectionTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                onWrite: { change in await viewModel.applyDataSourceWrite(change) }
            )
        case .mongoShell(let state):
            MongoShellTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) },
                onRefreshSchema: { viewModel.refreshSchema() },
                onFocus: { viewModel.focusedGroupID = groupID }
            )
        case .qdrantQuery(let state):
            QdrantQueryTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) },
                onRefreshSchema: { viewModel.refreshSchema() },
                onSave: { viewModel.saveActiveQdrantQuery() },
                onFocus: { viewModel.focusedGroupID = groupID }
            )
        case .elasticsearchQuery(let state):
            ElasticsearchQueryTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) },
                onRefreshSchema: { viewModel.refreshSchema() },
                onSave: { viewModel.saveActiveElasticsearchQuery() },
                onFocus: { viewModel.focusedGroupID = groupID }
            )
        case .mermaidDiagram(let state):
            MermaidTabView(source: state.source)
        case nil:
            EmptyView()
        }
    }

 /// Tools that used to be modals now render as tabs. Their
    /// "Close" closes the tab in this pane.
    @ViewBuilder
    private func toolTabView(_ kind: WorkspaceToolKind, groupID: String) -> some View {
        let close = { viewModel.closeTab(id: "tool:\(kind.rawValue)", inGroup: groupID) }
        switch kind {
        case .history:
            HistoryView(
                entries: viewModel.historyEntries,
                hasMore: viewModel.hasMoreHistory,
                onSearch: { viewModel.refreshHistory(search: $0) },
                onLoadMore: { viewModel.loadMoreHistory() },
                onInsert: { sql in viewModel.openQueryFromHistory(sql) },
                onClear: { viewModel.clearHistory() },
                onClose: close
            )
        case .savedQueries:
            SavedQueriesView(
                queries: viewModel.savedQueries,
                currentSQL: viewModel.activeEditorSQL,
                onOpen: { query in viewModel.openSavedQuery(query) },
                onSave: { name, sql, folder, global in
                    viewModel.saveSavedQuery(name: name, sql: sql, folder: folder, global: global)
                },
                onDelete: { id in viewModel.deleteSavedQuery(id: id) },
                onRename: { id, name in viewModel.renameSavedQuery(id: id, to: name) },
                reload: { viewModel.refreshSavedQueries(); return viewModel.savedQueries },
                onClose: close
            )
        case .artifacts:
            ArtifactsView(
                artifacts: viewModel.artifacts,
                currentPayload: viewModel.activeArtifactPayload,
                onOpen: { artifact in viewModel.openArtifact(artifact) },
                onSave: { title in viewModel.saveArtifact(title: title) },
                onDelete: { id in viewModel.deleteArtifact(id: id) },
                reload: { viewModel.refreshArtifacts(); return viewModel.artifacts },
                onClose: close
            )
        case .newTable:
            TableDesignerSheet(
                preview: { design in viewModel.designPreview(design) },
                onApply: { design in await viewModel.applyTableDesign(design) },
                onClose: close,
                tableNames: viewModel.relationalTableNames,
                columnsProvider: { await viewModel.columns(ofTableNamed: $0) },
                driver: viewModel.session?.config.driver ?? .sqlite,
                availableSchemas: viewModel.availableSchemas
            )
        case .importCSV:
            ImportCSVSheet(
                tables: viewModel.importableTables(),
                loadColumns: { object in await viewModel.columns(of: object) },
                onImport: { records, table, mapping, batchSize in
                    await viewModel.runImport(
                        records: records, into: table, mapping: mapping, batchSize: batchSize
                    )
                },
                onClose: close
            )
        case .processes:
            ProcessListView(
                buffer: processBuffer,
                onReload: { viewModel.loadProcessList(into: processBuffer) },
                onKill: { pid in await viewModel.killSession(id: pid) },
                onClose: close
            )
        case .users:
            if viewModel.session != nil, viewModel.userManagementSupported {
                UserManagementView(
                    buffer: usersBuffer,
                    driver: viewModel.session?.config.driver ?? .sqlite,
                    onReload: { viewModel.loadUsers(into: usersBuffer) },
                    onDrop: { username, host in await viewModel.dropUser(username: username, host: host) },
                    designPreview: { design in viewModel.userDesignPreview(design) },
                    onCreate: { design in await viewModel.applyUserDesign(design) },
                    onClose: close
                )
            } else if viewModel.dataSourceSession != nil, viewModel.userManagementSupported {
                DataSourceUserManagementView(
                    onLoad: { try await viewModel.loadDataSourceUsers() },
                    onDrop: { username in await viewModel.dropDataSourceUser(username: username) },
                    preview: { username, password, roles in
                        DataSourceUserCommandPreview.render(username: username, password: password, roles: roles)
                    },
                    onCreate: { username, password, roles in
                        await viewModel.createDataSourceUser(username: username, password: password, roles: roles)
                    },
                    onClose: close
                )
            } else if let message = viewModel.userManagementInfoMessage {
                UserManagementInfoView(message: message, onClose: close)
            }
        case .backup:
            BackupManagerView(viewModel: viewModel, onClose: close)
        case .insights:
            InsightPanelView(
                load: { await viewModel.analyzeInsights() },
                dailyReview: { viewModel.latestDailyReview() },
                onReveal: { viewModel.revealObject(named: $0) },
                onOpenSQL: { viewModel.newEditorTab(text: $0) },
                onApply: { viewModel.recordInsightApplied($0) },
                onDismissInsight: { viewModel.recordInsightDismissed($0) },
                onClose: close
            )
        case .graphExplorer:
            GraphExplorerView(
                tables: { viewModel.harvestedTableNames() },
                overview: { viewModel.graphOverview($0) },
                simulateImpact: { viewModel.simulateImpact($0) },
                onReveal: { viewModel.revealObject(named: $0) },
                onClose: close
            )
        case .timeline:
            TimeMachineView(
                snapshots: { viewModel.timelineSnapshots() },
                changes: { viewModel.timelineChanges(from: $0, to: $1) },
                onReveal: { viewModel.revealObject(named: $0) },
                onClose: close
            )
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite"), UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite3"), UTType(filenameExtension: "db3"),
            UTType(filenameExtension: "sql")
        ].compactMap(\.self)
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            if url.pathExtension.lowercased() == "sql" {
                Task {
                    do {
                        _ = try await viewModel.openSQLFile(at: url)
                    } catch {
                        viewModel.fileOpenError = error.localizedDescription
                    }
                }
            } else {
                guard viewModel.beginConnect() else { return }
                Task { await viewModel.openSQLiteFile(at: url, alreadyBegun: true) }
            }
        }
    }
}

/// What the connection sheet is editing — drives `.sheet(item:)` so New and Edit
/// each build a fresh sheet instead of reusing stale @State.
private enum ConnectionSheetTarget: Identifiable {
    case new
    case edit(ConnectionProfile)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let profile): return profile.id.uuidString
        }
    }

    var profile: ConnectionProfile? {
        switch self {
        case .new: return nil
        case .edit(let profile): return profile
        }
    }
}
