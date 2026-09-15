import BerryAI
import BerryCore
import BerryDataSourceKit
import BerryDriverKit
import BerryGraph
import BerryKeyValueKit
import BerryStore
import BerryTunnel
import Foundation
import Observation

/// A workspace tool that opens as a tab instead of a modal.
/// The `kind` lets the tab strip and the content switch behave per type.
public enum WorkspaceToolKind: String, Sendable, CaseIterable {
    case history
    case savedQueries
 /// Artifacts library — durable, linkable
    /// references to queries/tabs the AI agent (or the user) created.
    case artifacts
    case newTable
    case importCSV
    case processes
    case backup
 /// Database Insights, Architecture Score,
 /// Database Memory, Daily Review — a tab, not a modal
 /// same as every other former-sheet tool here.
    case insights
 /// Graph Explorer + Impact Simulator — a tab, not
    /// a modal, same reasoning as `.insights`.
    case graphExplorer
 /// Time Machine Timeline — a tab, not a
    /// modal, same reasoning as `.insights`.
    case timeline
 /// User & permission management — a tab,
    /// not a modal, same reasoning as `.insights`.
    case users

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .savedQueries: "bookmark"
        case .artifacts: "shippingbox"
        case .newTable: "tablecells.badge.ellipsis"
        case .importCSV: "square.and.arrow.down"
        case .processes: "cpu"
        case .backup: "externaldrive"
        case .insights: "lightbulb"
        case .graphExplorer: "point.3.connected.trianglepath.dotted"
        case .timeline: "clock.arrow.2.circlepath"
        case .users: "person.2"
        }
    }

    var title: String {
        switch self {
        case .history: L("History")
        case .savedQueries: L("Saved Queries")
        case .artifacts: L("Artifacts")
        case .newTable: L("New Table")
        case .importCSV: L("Import CSV")
        case .processes: L("Processes")
        case .backup: L("Backup")
        case .insights: L("Database Insights")
        case .graphExplorer: L("Graph Explorer")
        case .timeline: L("Time Machine")
        case .users: L("Users")
        }
    }
}

/// A Mermaid diagram opened from the AI chat into its own tab
/// — plain data, not `@Observable`: unlike the other
/// tab states, the diagram never changes after the chat rendered it, so
/// there's nothing here for a tab view to mutate in place.
public struct MermaidTabState: Identifiable, Sendable {
    public let id: UUID
    public let source: String
    public let title: String

    public init(id: UUID = UUID(), source: String, title: String) {
        self.id = id
        self.source = source
        self.title = title
    }
}

/// One tab in the workspace: a table grid, an SQL editor, or a tool
/// (History, Saved Queries, …) that used to be a modal.
@MainActor
public enum WorkspaceTab: @preconcurrency Identifiable {
    case table(TableTabState)
    case editor(EditorDocument)
    case tool(WorkspaceToolKind)
 /// ALTER designer for an existing table — a tab, not a modal
 /// payload is the table's current design.
    case alterTable(TableDesign)
 /// A Mermaid diagram from the AI chat, opened full-size with zoom.
    case mermaidDiagram(MermaidTabState)
 /// A Mongo collection / Qdrant point-collection tab.
    case collection(CollectionTabState)
 /// A Mongo shell query tab (item 2) — sibling of
    /// `.editor` for the NoSQL side.
    case mongoShell(MongoShellTabState)
 /// A Qdrant query tab — the vector sibling of `.mongoShell`,
    /// hybrid Form/JSON query surface with scriptable read + upsert/delete.
    case qdrantQuery(QdrantQueryTabState)
 /// An Elasticsearch query tab — the search-engine
    /// sibling of `.mongoShell`/`.qdrantQuery`, a JSON-only Query DSL surface.
    case elasticsearchQuery(ElasticsearchQueryTabState)

    public var id: String {
        switch self {
        case .table(let state): "table:\(state.object.id)"
        case .editor(let document): "editor:\(document.id.uuidString)"
        case .tool(let kind): "tool:\(kind.rawValue)"
        case .alterTable(let design): "alter:\(design.database ?? "").\(design.name)"
        case .collection(let state): "collection:\(state.ref.id)"
        case .mongoShell(let state): "mongoShell:\(state.id.uuidString)"
        case .qdrantQuery(let state): "qdrantQuery:\(state.id.uuidString)"
        case .elasticsearchQuery(let state): "elasticsearchQuery:\(state.id.uuidString)"
        case .mermaidDiagram(let state): "mermaidDiagram:\(state.id.uuidString)"
        }
    }

    public var title: String {
        switch self {
        case .table(let state): state.object.name
        case .editor(let document): document.title
        case .tool(let kind): kind.title
        case .alterTable(let design): L("Edit Table") + ": \(design.name)"
        case .collection(let state): state.ref.name
        case .mongoShell(let state): state.title
        case .qdrantQuery(let state): state.title
        case .elasticsearchQuery(let state): state.title
        case .mermaidDiagram(let state): state.title
        }
    }

    public var systemImage: String {
        switch self {
        case .table: "tablecells"
        case .editor: "curlybraces.square"
        case .tool(let kind): kind.systemImage
        case .alterTable: "tablecells.badge.ellipsis"
        case .collection(let state): state.kind == .vector ? "point.3.filled.connected.trianglepath.dotted" : "tray.full"
        case .mongoShell: "curlybraces.square"
        case .qdrantQuery: "point.3.filled.connected.trianglepath.dotted"
        case .elasticsearchQuery: "magnifyingglass"
        case .mermaidDiagram: "point.3.connected.trianglepath.dotted"
        }
    }
}

/// One editor group = one pane in the split. Holds an ordered subset
/// of the open tabs and its own active tab, so groups stay independent.
public struct EditorGroup: Identifiable, Sendable {
    public let id: String
    public var tabIDs: [String]
    public var activeTabID: String?
}

/// One row of the split grid: a horizontal strip of groups. Rows
/// stack vertically, so the whole layout is a rows-of-columns grid like VS Code
/// — "split right" adds a column to a row, "split down" adds a new row.
public struct EditorLayoutRow: Identifiable, Sendable {
    public let id: String
    public var groupIDs: [String]
}

/// Dependency overview for one table over the DSG (Graph Explorer).
public struct TableGraphOverview: Sendable, Equatable {
    public let table: String
    /// Tables this one references (FK/derive out).
    public let dependsOn: [String]
    /// Tables that directly reference this one.
    public let dependents: [String]
    /// Everything that would be affected if this table changed (transitive).
    public let blastRadius: [String]
}

/// One existence change between two Digital-Twin snapshots (Time Machine
/// Timeline) — a table/column/index that appeared or
/// disappeared. Existence-only: `graph_node`'s attrs are upserted in place
/// with no history, and the snapshot digest itself only covers node/edge
/// existence, so an attribute-only change (e.g. a column's type) never even
/// creates a new snapshot to diff against — not tracked here, not a UI gap.
public struct TimelineChange: Identifiable, Sendable, Equatable {
    public let id: String
    public let isAdded: Bool
    public let kind: NodeKind
    public let name: String
    /// The owning table, for a column/index change — nil for a table-level change.
    public let tableName: String?
}

/// ViewModel for one workspace (1 window)
/// Owns the saved-profile list, the single active session (M1;
/// multiple concurrent sessions arrive later) and the tab strip.
@MainActor
@Observable
public final class WorkspaceViewModel {
 // MARK: Saved profiles

    public private(set) var profiles: [ConnectionProfile] = []
    public private(set) var storeError: String?

    // MARK: Active session

    public private(set) var session: Session?
    public private(set) var activeProfileID: UUID?
    public private(set) var catalog: SchemaCatalog?
 /// Manual transaction control for the editor — reset per session
    /// because a transaction is scoped to one physical connection.
    public private(set) var transaction = TransactionController()
    public private(set) var objects: [SchemaObject] = []
    public var selectedObjectIDs: Set<String> = [] {
        didSet {
            selectedObjectID = selectedObjectIDs.first
            selectedCollectionID = selectedObjectIDs.first
        }
    }
    public var selectedObjectID: SchemaObject.ID?
    public private(set) var errorMessage: String?
    public private(set) var isConnecting = false

 /// Q15 tier gating: when false, the Database
    /// Intelligence layer (DSG harvest, analyzers, Graph Explorer) stays off.
    /// The view keeps this in sync with the license entitlement; defaults on so
    /// tests and profileless quick-open aren't gated.
    public var intelligenceEntitled = true

 // MARK: Active NoSQL/vector session — mutually
    // exclusive with `session` above: connecting to one tears down the other
    // (one active connection per workspace, SQL XOR NoSQL).

    public private(set) var dataSourceSession: DataSourceSession?
    public private(set) var collections: [CollectionRef] = []
 // Key-value (Redis) — third sibling, mutually
    // exclusive with both `session` and `dataSourceSession` above.
    public private(set) var keyValueSession: KeyValueSession?
    /// Sidebar/tree selection for collections — kept separate from
    /// `selectedObjectID` (SQL-shaped `SchemaObject.ID`) even though both
    /// happen to be `String`, so the two session kinds' state stays distinct.
    public var selectedCollectionID: String?

    /// Confirmation gate for `DataSourceChangeSet` writes — swappable so
    /// tests can inject a non-blocking stub instead of a real alert (mirrors
    /// `QueryService.dangerConfirmer`). See `DataSourceWriteConfirmer.swift`.
    public static var dataSourceWriteConfirmer: any DataSourceWriteConfirming = AlertDataSourceWriteConfirmer()

 // MARK: Tabs

    /// All open tabs (the documents/grids themselves) — the source of truth.
    /// Which pane shows which tab is tracked by `groups`, not here.
    public private(set) var tabs: [WorkspaceTab] = []

 /// Editor groups (VS Code-style). Each group owns an ordered
    /// subset of `tabs` and its own active tab, so the panes are independent.
    /// `focusedGroupID` is where new tabs land. `groups` is the data store;
    /// `layoutRows` is the 2D arrangement (which group sits where in the grid).
    public private(set) var groups: [EditorGroup] = []
    public private(set) var layoutRows: [EditorLayoutRow] = []
    public var focusedGroupID: String = ""
    private var editorCounter = 0
    private var mermaidDiagramCounter = 0

    private var store: BerryStore?
    private var snapshotSink: (any SchemaSnapshotSink)?

 /// Digital-Twin graph store, backed by the same store.sqlite.
    private var graphStore: GraphStore? { store.map(GraphStore.init(store:)) }

    public init() {
        do {
            store = try BerryStore.open()
            profiles = try store?.allProfiles() ?? []
        } catch {
            storeError = error.localizedDescription
        }
        wireSinks()
    }

    /// Test-only initializer with an injected store path.
    public init(storePath: String) throws {
        store = try BerryStore(path: storePath)
        profiles = try store?.allProfiles() ?? []
        wireSinks()
    }

 /// Single wiring point for the core → store sinks and the
 /// DangerGuard confirmation gate.
    private func wireSinks() {
        QueryService.dangerConfirmer = AlertDangerConfirmer()
        guard let store else { return }
        QueryService.historySink = StoreHistorySink(store: store)
        snapshotSink = StoreSnapshotSink(store: store)
    }

    /// Bounded recent-actions log for the AI `get_ui_state` tool
 /// Deliberately narrow — only tab
    /// opened/closed/pane-split, not every tab/pane mutation (see
 /// See the rejected alternative for why an unbounded
    /// version of this would be a mistake).
    private func logWorkspaceAction(_ kind: String, description: String) {
        guard let store else { return }
        try? store.recordWorkspaceAction(WorkspaceActionRecord(
            profileID: activeProfileID, kind: kind, description: description
        ))
    }

    public var connectionTitle: String {
        if let session { return "\(session.displayName) — \(session.driverDisplayName)" }
        if let dataSourceSession { return "\(dataSourceSession.displayName) — \(dataSourceSession.driverDisplayName)" }
        if let keyValueSession { return "\(keyValueSession.displayName) — \(keyValueSession.driverDisplayName)" }
        return "BerryDB"
    }

    public var isProductionSession: Bool {
        guard let activeProfileID else { return false }
        return profiles.first { $0.id == activeProfileID }?.envColor == "production"
    }

    /// The tab object for a given id.
    public func tab(for id: String) -> WorkspaceTab? {
        tabs.first { $0.id == id }
    }

    /// The group (pane) with a given id.
    public func group(for id: String) -> EditorGroup? {
        groups.first { $0.id == id }
    }

    private var focusedGroup: EditorGroup? {
        groups.first { $0.id == focusedGroupID } ?? groups.first
    }

    /// (row, column) of a group in the layout grid.
    private func position(of groupID: String) -> (row: Int, col: Int)? {
        for (r, row) in layoutRows.enumerated() {
            if let c = row.groupIDs.firstIndex(of: groupID) { return (r, c) }
        }
        return nil
    }

    /// The active tab of the focused group. The setter is the single entry point
    /// every "open/focus a tab" call site already uses: it makes `id` active in
    /// whichever group holds it, or files a freshly-appended tab into the focused
    /// group (creating one when none exists yet).
    public var activeTabID: String? {
        get { focusedGroup?.activeTabID }
        set { setActiveTab(newValue) }
    }

    public var activeTab: WorkspaceTab? {
        tabs.first { $0.id == activeTabID } ?? tabs.first
    }

    private func setActiveTab(_ id: String?) {
        guard let id else { return }
        if let gi = groups.firstIndex(where: { $0.tabIDs.contains(id) }) {
            focusedGroupID = groups[gi].id
            groups[gi].activeTabID = id
            return
        }
        // A just-appended tab that isn't in any group yet → focused group.
        ensureFocusedGroup()
        guard let gi = groups.firstIndex(where: { $0.id == focusedGroupID }) else { return }
        groups[gi].tabIDs.append(id)
        groups[gi].activeTabID = id
    }

    /// Make `id` active inside a specific group, and focus that group. Used when
    /// the same tab is open in more than one group (VS Code duplicate split).
    public func focusTab(_ id: String, inGroup groupID: String) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        focusedGroupID = groupID
        groups[gi].activeTabID = id
    }

    private func ensureFocusedGroup() {
        if groups.isEmpty {
            let group = EditorGroup(id: UUID().uuidString, tabIDs: [], activeTabID: nil)
            groups = [group]
            layoutRows = [EditorLayoutRow(id: UUID().uuidString, groupIDs: [group.id])]
            focusedGroupID = group.id
        } else if !groups.contains(where: { $0.id == focusedGroupID }) {
            focusedGroupID = groups[0].id
        }
    }

    /// Open the group's active tab in a new pane to the RIGHT (VS Code ⌘\).
    public func splitRight(_ groupID: String) {
        guard let group = makeSplitGroup(from: groupID),
              let pos = position(of: groupID) else { return }
        groups.append(group)
        layoutRows[pos.row].groupIDs.insert(group.id, at: pos.col + 1)
        focusedGroupID = group.id
        logWorkspaceAction("pane_split", description: "Split pane created (pane \(paneNumber(of: group.id) ?? 0))")
    }

    /// Open the group's active tab in a new pane BELOW (a new grid row).
    public func splitDown(_ groupID: String) {
        guard let group = makeSplitGroup(from: groupID),
              let pos = position(of: groupID) else { return }
        groups.append(group)
        layoutRows.insert(
            EditorLayoutRow(id: UUID().uuidString, groupIDs: [group.id]),
            at: pos.row + 1
        )
        focusedGroupID = group.id
        logWorkspaceAction("pane_split", description: "Split pane created (pane \(paneNumber(of: group.id) ?? 0))")
    }

    private func makeSplitGroup(from groupID: String) -> EditorGroup? {
        guard let sourceGroup = groups.first(where: { $0.id == groupID }) else { return nil }
        // A split opens a fresh, independent tab in the new pane — not a
        // second view of the same document, which would edit in lock-step
 // Drag a tab across panes to move an existing one.
        //
        // The new tab matches the pane's OWN active tab's type (Mongo shell
        // stays Mongo shell, Qdrant stays Qdrant) instead of always being a
        // SQL editor: a hardcoded SQL tab in a Mongo/Qdrant pane had no
        // session to run against and offered SQL-dialect autocomplete in a
        // script language it doesn't apply to. Any other tab type (table,
        // tool, …) falls back to a SQL editor, same as the original
        // unconditional behavior.
        let sourceTab = sourceGroup.activeTabID.flatMap { id in tabs.first { $0.id == id } }
        let tab: WorkspaceTab
        switch sourceTab {
        case .mongoShell:
            let state = MongoShellTabState(title: L("Untitled"), text: "")
            state.pendingFocus = true
            tab = .mongoShell(state)
        case .qdrantQuery:
            let state = QdrantQueryTabState(title: L("Untitled"), rawJSON: "", collection: "")
            state.pendingFocus = true
            tab = .qdrantQuery(state)
        case .elasticsearchQuery:
            let state = ElasticsearchQueryTabState(title: L("Untitled"), rawJSON: "", index: "")
            state.pendingFocus = true
            tab = .elasticsearchQuery(state)
        default:
            editorCounter += 1
            let document = EditorDocument(title: L("Untitled"), text: "")
 document.pendingFocus = true // caret lands in the new pane
            tab = .editor(document)
            persistEditor(document)
        }
        tabs.append(tab)
        return EditorGroup(id: UUID().uuidString, tabIDs: [tab.id], activeTabID: tab.id)
    }

    /// Move a tab from one pane to another (drag-drop). No-op onto the same
    /// pane. An emptied source pane is removed afterward.
 /// Where a tab is dropped over a pane (D2, VS Code style): the
    /// center moves it into the pane; an edge splits a new pane off that side.
    public enum DropZone: Sendable, Equatable {
        case center, left, right, top, bottom
    }

    /// Handle a "groupID::tabID" drop payload onto `targetGroupID` in `zone`.
    public func dropTab(_ payload: String, onto targetGroupID: String, zone: DropZone) {
        let parts = payload.components(separatedBy: "::")
        guard parts.count >= 2 else { return }
        let sourceGroupID = parts[0]
        let tabID = parts.dropFirst().joined(separator: "::")
        // The tab must be a real, open tab and the target must exist.
        guard tabs.contains(where: { $0.id == tabID }),
              let pos = position(of: targetGroupID) else { return }

        if zone == .center {
            // Move into the target pane. If the source pane had only this tab, it
 // empties and closes — standard split behavior.
            moveTab(tabID, from: sourceGroupID, to: targetGroupID)
            return
        }

        // Edge split: a brand-new pane that already holds the dragged tab, so a
 // split can never show an empty artboard. Remove the tab
        // from its old pane and drop the empties.
        let newGroup = EditorGroup(id: UUID().uuidString, tabIDs: [tabID], activeTabID: tabID)
        if let si = groups.firstIndex(where: { $0.id == sourceGroupID }) {
            removeTab(tabID, fromGroupAt: si)
        }
        groups.append(newGroup)
        switch zone {
        case .left:   layoutRows[pos.row].groupIDs.insert(newGroup.id, at: pos.col)
        case .right:  layoutRows[pos.row].groupIDs.insert(newGroup.id, at: pos.col + 1)
        case .top:    layoutRows.insert(EditorLayoutRow(id: UUID().uuidString, groupIDs: [newGroup.id]), at: pos.row)
        case .bottom: layoutRows.insert(EditorLayoutRow(id: UUID().uuidString, groupIDs: [newGroup.id]), at: pos.row + 1)
        case .center: break
        }
        focusedGroupID = newGroup.id
        pruneEmptyGroups()
    }

    public func moveTab(_ tabID: String, from sourceGroupID: String, to targetGroupID: String) {
        guard sourceGroupID != targetGroupID,
              let si = groups.firstIndex(where: { $0.id == sourceGroupID }),
              let ti = groups.firstIndex(where: { $0.id == targetGroupID }) else { return }
        removeTab(tabID, fromGroupAt: si)
        if !groups[ti].tabIDs.contains(tabID) {
            groups[ti].tabIDs.append(tabID)
        }
        groups[ti].activeTabID = tabID
        focusedGroupID = targetGroupID
        pruneEmptyGroups()
    }

 // MARK: - Profile CRUD

    public func save(profile: ConnectionProfile, secrets: ConnectionSecrets) {
        do {
            try store?.save(profile)
 // Single Keychain write point — only freshly typed secrets
            // are written; empty means "keep what is stored".
            if let dbPassword = secrets.dbPassword {
                KeychainService.savePassword(dbPassword, kind: .database, profileID: profile.id)
            }
            if let sshPassword = secrets.sshPassword {
                KeychainService.savePassword(sshPassword, kind: .ssh, profileID: profile.id)
            }
            if let passphrase = secrets.sshPassphrase {
                KeychainService.savePassword(passphrase, kind: .sshPassphrase, profileID: profile.id)
            }
            if let apiKey = secrets.elasticsearchAPIKey {
                KeychainService.savePassword(apiKey, kind: .elasticsearchAPIKey, profileID: profile.id)
            }
            reloadProfiles()
        } catch {
            storeError = error.localizedDescription
        }
    }

    public func delete(profile: ConnectionProfile) {
        do {
            try store?.deleteProfile(id: profile.id)
 // Never leave orphaned secrets behind.
            KeychainService.deleteSecrets(profileID: profile.id)
            if activeProfileID == profile.id {
                disconnect()
            }
            reloadProfiles()
        } catch {
            storeError = error.localizedDescription
        }
    }

 /// Clone a saved connection. Copies the config and its stored
    /// secrets so the duplicate connects without re-entering the password.
    public func duplicate(profile: ConnectionProfile) {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " " + L("copy")
        copy.sortOrder = (profiles.map(\.sortOrder).max() ?? 0) + 1
        copy.createdAt = Date()
        do {
            try store?.save(copy)
            reloadProfiles() // show the copy immediately — don't wait on Keychain
        } catch {
            storeError = error.localizedDescription
            return
        }
        // Clone the Keychain secrets off the main thread: the SecItem calls can be
        // slow or pop an access prompt, and doing them inline froze the UI. The
        // task is tracked so connecting to the copy WAITS for its secrets —
        // otherwise a quick Duplicate → Connect raced the clone and failed with
 // authMechanismRequiresPassword.
        let sourceID = profile.id
        let destID = copy.id
        let clone = Task.detached {
            for kind in KeychainService.SecretKind.allCases {
                if let secret = KeychainService.readPassword(kind: kind, profileID: sourceID) {
                    KeychainService.savePassword(secret, kind: kind, profileID: destID)
                }
            }
        }
        pendingSecretClones[destID] = clone
        Task { [weak self] in
            await clone.value
            self?.pendingSecretClones[destID] = nil
        }
    }

    /// In-flight Keychain clones from `duplicate` — awaited by `connect`.
    private var pendingSecretClones: [UUID: Task<Void, Never>] = [:]

 /// Manually re-read the live schema — clears the per-session cache
    /// so newly created objects show up without reconnecting.
    public func refreshSchema() {
        Task {
            await catalog?.invalidate()
            try? await refreshObjects()
            try? await refreshCollections()
        }
    }

 /// Saved connections grouped by `groupName`. Ungrouped profiles come
    /// first (nil group); within a group, order follows `sortOrder`.
    public var connectionGroups: [(name: String?, profiles: [ConnectionProfile])] {
        Dictionary(grouping: profiles) { $0.groupName }
            .map { (name: $0.key, profiles: $0.value.sorted { $0.sortOrder < $1.sortOrder }) }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

 /// Reorder connections within a group (drag-to-reorder) and persist
    /// the new `sortOrder`.
    public func moveProfiles(group: String?, from source: IndexSet, to destination: Int) {
        var inGroup = profiles
            .filter { $0.groupName == group }
            .sorted { $0.sortOrder < $1.sortOrder }
        inGroup.move(fromOffsets: source, toOffset: destination)
        for (index, profile) in inGroup.enumerated() {
            var updated = profile
            updated.sortOrder = index
            try? store?.save(updated)
        }
        reloadProfiles()
    }

    private func reloadProfiles() {
        profiles = (try? store?.allProfiles()) ?? profiles
    }

 // MARK: - Connect

    /// Must be called directly from a tap/menu handler, before creating the
    /// `Task` that awaits `connect`/`connectDataSource`/`openSQLiteFile` —
    /// setting `isConnecting` (which drives the "Connecting…" state,
    /// `WorkspaceView.swift`) from *inside* one of those `async` functions
    /// only takes effect once that Task gets its turn on a possibly-busy
    /// MainActor, which reads as "double-clicking Connect does nothing."
    /// Worse than a cosmetic delay here: with no guard at all, a second tap
    /// before that turn comes up could start a second, fully concurrent
    /// connection attempt racing the first to set `session`/
    /// `dataSourceSession`. Returns false (caller should not proceed) if a
    /// connection attempt is already in flight.
    public func beginConnect() -> Bool {
        guard !isConnecting else { return false }
        isConnecting = true
        errorMessage = nil
        return true
    }

    /// `alreadyBegun`: true when the caller already called `beginConnect()`
    /// synchronously (see its doc comment) — skips the redundant guard so
    /// this doesn't immediately bail out seeing `isConnecting` already true.
    /// Defaults to false so every existing direct caller (every test in this
    /// package included) keeps working exactly as before, self-guarding via
    /// its own `beginConnect()` call.
    public func connect(profile: ConnectionProfile, alreadyBegun: Bool = false) async {
        guard alreadyBegun || beginConnect() else { return }
        defer { isConnecting = false }
        if let driver = profile.driver, driver == .mongodb || driver == .qdrant || driver == .elasticsearch {
            await connectDataSource(profile: profile, alreadyBegun: true)
            return
        }
        if let driver = profile.driver, driver == .redis {
            await connectKeyValue(profile: profile, alreadyBegun: true)
            return
        }
        // A freshly duplicated profile may still be cloning its secrets in the
        // background — wait so the first connect doesn't miss the password.
        if let clone = pendingSecretClones[profile.id] {
            await clone.value
        }
 // Single Keychain read point: secrets go straight into
        // the in-RAM config, never stored on the profile.
        let config = profile.makeConfig(
            password: KeychainService.readPassword(kind: .database, profileID: profile.id),
            sshPassword: KeychainService.readPassword(kind: .ssh, profileID: profile.id),
            sshPassphrase: KeychainService.readPassword(kind: .sshPassphrase, profileID: profile.id)
        )
        await open(
            config: config,
            profileID: profile.id,
            isProduction: profile.envColor == "production",
            recordHistory: profile.historyEnabled,
            alreadyBegun: true
        )
    }

    /// Quick open for a SQLite file (⌘O) without saving a profile.
    public func openSQLiteFile(at url: URL, alreadyBegun: Bool = false) async {
        await open(config: ConnectionConfig.sqlite(path: url.path), profileID: nil, alreadyBegun: alreadyBegun)
    }

    private func open(
        config: ConnectionConfig,
        profileID: UUID?,
        isProduction: Bool = false,
        recordHistory: Bool = true,
        alreadyBegun: Bool = false
    ) async {
        guard alreadyBegun || beginConnect() else { return }
        defer { isConnecting = false }
        do {
            if let old = session {
                await ConnectionManager.shared.close(old.id)
            }
            // One active connection per workspace, SQL XOR NoSQL XOR key-value
 //
            if let old = dataSourceSession {
                await old.connection.close()
                await old.tunnel?.close()
                dataSourceSession = nil
                collections = []
            }
            if let old = keyValueSession {
                await old.connection.close()
                await old.tunnel?.close()
                keyValueSession = nil
            }
            let newSession = try await ConnectionManager.shared.open(
                config, profileID: profileID, isProduction: isProduction,
                recordHistory: recordHistory
            )
            session = newSession
            activeProfileID = profileID
            catalog = SchemaCatalog(session: newSession, snapshotSink: snapshotSink)
            transaction = TransactionController()
            tabs = []
            groups = []
            layoutRows = []
            focusedGroupID = ""
            editorCounter = 0
            selectedObjectID = nil
            restoreEditorSessions(profileID: profileID)
            try await refreshObjects()
        } catch {
            session = nil
            activeProfileID = nil
            catalog = nil
            objects = []
            tabs = []
            errorMessage = error.localizedDescription
 // A changed SSH host key is recoverable: offer to trust the
            // new key and reconnect. Only saved profiles use SSH, so profileID
            // is present.
            if case let DriverError.sshHostKeyChanged(host, port, stored, presented) = error,
               let profileID {
                hostKeyChange = HostKeyChange(host: host, port: port, stored: stored, presented: presented)
                retryProfileID = profileID
            }
        }
    }

 // MARK: - SSH host-key change

    public struct HostKeyChange: Equatable, Sendable {
        public let host: String
        public let port: Int
        public let stored: String
        public let presented: String
    }

    /// Non-nil after a connect refused by a changed host key — drives the alert.
    public private(set) var hostKeyChange: HostKeyChange?
    private var retryProfileID: UUID?

    /// Non-nil after a context-menu Truncate/Drop (`runDestructiveStatements`)
    /// fails — drives a one-off alert. Separate from `errorMessage` (a whole
    /// detail-pane replacement for connection failures, not a transient
    /// action result).
    public var quickActionError: String?

    public struct LargeFileWarning: Equatable, Sendable {
        public let url: URL
        public let sizeInBytes: Int64
        public var sizeInMB: Double { Double(sizeInBytes) / (1024 * 1024) }

        public init(url: URL, sizeInBytes: Int64) {
            self.url = url
            self.sizeInBytes = sizeInBytes
        }
    }

    /// Non-nil when a user attempts to open an SQL file exceeding `largeSQLFileThreshold`.
    public var pendingLargeFile: LargeFileWarning?

    /// Non-nil when an SQL file open attempt throws an error.
    public var fileOpenError: String?

    /// Synchronous prefix of `trustChangedHostKeyAndReconnect()` — trusts the
    /// key and dismisses the alert (`hostKeyChange = nil`) directly on the
    /// button tap's call stack, before any `Task`, so the alert closes
    /// instantly instead of sitting there until that Task's MainActor turn.
    /// Returns the profile to reconnect to, or nil if there's nothing
    /// pending (defensive — the alert wouldn't be showing otherwise).
    public func admitTrustChangedHostKey() -> ConnectionProfile? {
        guard let change = hostKeyChange, let profileID = retryProfileID,
              let profile = profiles.first(where: { $0.id == profileID }) else { return nil }
        SSHTrust.trustHostKey(host: change.host, port: change.port, fingerprint: change.presented)
        hostKeyChange = nil
        retryProfileID = nil
        return profile
    }

    /// Trusts the newly-presented host key and reconnects (user-confirmed).
    public func trustChangedHostKeyAndReconnect() async {
        guard let profile = admitTrustChangedHostKey() else { return }
        await connect(profile: profile)
    }

    public func dismissHostKeyChange() {
        hostKeyChange = nil
        retryProfileID = nil
    }

    public func testConnection(_ config: ConnectionConfig) async -> ConnectionTestReport {
        switch config.driver {
        case .mongodb, .qdrant, .elasticsearch:
            return await testDataSourceConnection(config)
        default:
            return await ConnectionManager.shared.testReport(config)
        }
    }

 /// `DataSourceDriver` sibling of `ConnectionManager.testReport`
    /// same tunnel → connect → ping breakdown reported through the same
    /// `ConnectionTestReport` type the sheet already renders generically.
    private func testDataSourceConnection(_ config: ConnectionConfig) async -> ConnectionTestReport {
        guard let driverType = DataSourceRegistry.driverType(for: config.driver) else {
            return ConnectionTestReport(
                steps: [], errorMessage: "Driver \(config.driver.rawValue) is not registered"
            )
        }
        let clock = ContinuousClock()
        var steps: [ConnectionTestReport.StepResult] = []

        let effectiveConfig: ConnectionConfig
        let tunnel: SSHTunnel?
        if config.ssh != nil {
            let started = clock.now
            do {
                (effectiveConfig, tunnel) = try await prepareDataSourceEndpoint(config)
                steps.append(.init(step: .tunnel, passed: true, seconds: Self.seconds(clock.now - started)))
            } catch {
                steps.append(.init(step: .tunnel, passed: false, seconds: Self.seconds(clock.now - started)))
                return ConnectionTestReport(steps: steps, errorMessage: error.localizedDescription)
            }
        } else {
            (effectiveConfig, tunnel) = (config, nil)
        }

        let connection: any DataSourceConnection
        let connectStarted = clock.now
        do {
            connection = try await driverType.init().connect(effectiveConfig)
            steps.append(.init(step: .connect, passed: true, seconds: Self.seconds(clock.now - connectStarted)))
        } catch {
            steps.append(.init(step: .connect, passed: false, seconds: Self.seconds(clock.now - connectStarted)))
            await tunnel?.close()
            return ConnectionTestReport(steps: steps, errorMessage: error.localizedDescription)
        }

        let pingStarted = clock.now
        let alive = await connection.ping()
        steps.append(.init(step: .ping, passed: alive, seconds: Self.seconds(clock.now - pingStarted)))
        await connection.close()
        await tunnel?.close()
        return ConnectionTestReport(
            steps: steps,
            errorMessage: alive ? nil : "Connection opened but ping failed"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public func disconnect() {
        if let old = session {
            // Best-effort rollback of any open manual transaction before the
 // socket closes — an abandoned BEGIN must not leak.
            let tx = transaction
            Task {
                if tx.isActive { _ = await tx.rollback(session: old) }
                await ConnectionManager.shared.close(old.id)
            }
        }
        if let old = dataSourceSession {
            Task {
                await old.connection.close()
                await old.tunnel?.close()
            }
        }
        if let old = keyValueSession {
            Task {
                await old.connection.close()
                await old.tunnel?.close()
            }
        }
        session = nil
        dataSourceSession = nil
        keyValueSession = nil
        activeProfileID = nil
        catalog = nil
        transaction = TransactionController()
        objects = []
        collections = []
        for tab in tabs {
            switch tab {
            case .table(let state): state.buffer.cancel()
            case .editor(let document): document.cancel(session: session)
            case .collection(let state): state.cancel()
            case .mongoShell(let state): state.cancel()
            case .qdrantQuery(let state): state.cancel()
            case .elasticsearchQuery(let state): state.cancel()
            case .tool, .alterTable, .mermaidDiagram: break
            }
        }
        tabs = []
        groups = []
        layoutRows = []
        focusedGroupID = ""
        selectedObjectID = nil
        selectedCollectionID = nil
    }

    public func refreshObjects() async throws {
        guard let catalog else { return }
        objects = try await catalog.objects(forceRefresh: true)
 // Seed/refresh the Digital Twin off the UI path — metadata only
 // (Q6), deduped by digest, off on production. Never blocks or
        // fails the refresh.
        Task { await harvestGraphNow() }
 // Daily Review digest — same off-UI-path pattern; only does
        // real work when due, so this is a cheap no-op most of the time.
        Task { await maybeGenerateDailyReview() }
    }

    /// Harvests the DSG for the active saved profile and records a Digital-Twin
 /// snapshot. Metadata only (Q6); silently a
 /// no-op on a production profile or a profileless quick-open.
    /// Best-effort — a harvest error never surfaces to the session.
    public func harvestGraphNow() async {
 guard intelligenceEntitled else { return } // Q15 tier gate
        guard let session, let catalog, let profileID = activeProfileID, let graphStore else { return }
        _ = try? await SchemaHarvester.harvest(
            session: session, catalog: catalog, into: graphStore,
            profileID: profileID, now: Date()
        )
    }

 /// Generates and persists a Daily Review digest if due
 /// — a fixed, BerryDB-defined cadence, not a
 /// background job ("not a 24/7 agent": this only runs when the app is
    /// open and a profile refreshes, never while closed). Best-effort, never
    /// surfaces an error to the session.
    public func maybeGenerateDailyReview() async {
        guard intelligenceEntitled, let profileID = activeProfileID, let store else { return } // Q15 tier gate
        let last = try? store.latestDailyReview(profileID: profileID)
        guard DailyReviewBuilder.isDue(lastGeneratedAt: last?.generatedAt, now: Date()) else { return }
        let summary = DailyReviewBuilder.summarize(await analyzeInsights())
        try? store.saveDailyReview(DailyReviewRecord(
            profileID: profileID, generatedAt: Date(), summaryJSON: DailyReviewBuilder.encode(summary)
        ))
    }

    /// The most recent Daily Review digest for the active profile, decoded —
 /// nil if none exists yet.
    public func latestDailyReview() -> DailyReviewSummary? {
        guard let profileID = activeProfileID, let store,
              let record = try? store.latestDailyReview(profileID: profileID) else { return nil }
        return DailyReviewBuilder.decode(record.summaryJSON)
    }

 /// Local `graph_query` executor for the AI panel,
    /// or nil when no DSG can be persisted (quick-open / no store).
    public func graphExecutor(profileID: UUID) -> (any AIToolExecutor)? {
        graphStore.map { GraphToolExecutor(store: $0, profileID: profileID) }
    }

 /// Runs the analyzers for the active profile.
    /// Three sources, merged severity-first:
 /// offline graph analyzers (Schema, Index) over the latest
    ///     harvested DSG — deterministic, no DBMS access;
 /// Convention Memory, naming mismatches against the schema's
    ///     own established convention;
 /// the Query Analyzer, which EXPLAINs the recent workload (plan
    ///     only, no user data — Q6).
 /// Insights the user has dismissed are filtered out. Empty when
    /// nothing is harvested and no workload exists.
    public func analyzeInsights() async -> [Insight] {
        guard intelligenceEntitled, let session else { return [] } // Q15 tier gate
        var result: [Insight] = []
        if let profileID = activeProfileID, let graphStore,
           let graph = try? graphStore.loadGraph(profileID: profileID), graph.nodeCount > 0 {
            result += InsightEngine.analyze(graph, dialect: session.config.driver)
            result += ConventionMemory.namingMismatches(graph, history: recentHistoricalGraphs())
        }
        let workload = (try? store?.history(profileID: activeProfileID))?
            .filter { $0.status == "success" }.map(\.sql) ?? []
        result += await PlanHarvester.analyze(statements: workload, session: session)
        if let profileID = activeProfileID, let dismissed = try? store?.dismissedInsightIDs(profileID: profileID),
           !dismissed.isEmpty {
            result = result.filter { !dismissed.contains($0.id) }
        }
        return result.sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id
        }
    }

 /// Records that the user applied an insight's suggested fix.
    public func recordInsightApplied(_ insightID: String) {
        guard let profileID = activeProfileID else { return }
        try? store?.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID, insightID: insightID, action: .applied, ts: Date())
        )
    }

    /// Records that the user dismissed an insight — it won't be shown again
 /// by `analyzeInsights()`.
    public func recordInsightDismissed(_ insightID: String) {
        guard let profileID = activeProfileID else { return }
        try? store?.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID, insightID: insightID, action: .dismissed, ts: Date())
        )
    }

    /// Reveals an object by name in the sidebar/tabs — the Insight Panel's
    /// jump-to-node target.
    public func revealObject(named name: String) {
        guard let object = objects.first(where: { $0.name == name }) else { return }
        select(object)
    }

    /// Harvested table names for the active profile, for the Graph Explorer picker.
    public func harvestedTableNames() -> [String] {
        guard let graph = latestGraph() else { return [] }
        return graph.nodes.values.filter { $0.kind == .table }.map(\.name).sorted()
    }

 /// Dependency overview for one table over the DSG
 /// what it depends on (FK/derive out), what depends on it
    /// directly, and its full blast radius (transitive reverse reachability).
    /// Names, not node ids. Empty when nothing is harvested / table unknown.
    public func graphOverview(_ table: String) -> TableGraphOverview {
        guard let graph = latestGraph(),
              let node = graph.nodes.values.first(where: { $0.kind == .table && $0.name == table })
        else { return TableGraphOverview(table: table, dependsOn: [], dependents: [], blastRadius: []) }
        let kinds: Set<EdgeKind> = [.references, .derivesFrom]
        func names(_ ids: [String]) -> [String] { ids.compactMap { graph.nodes[$0]?.name }.sorted() }
        return TableGraphOverview(
            table: table,
            dependsOn: names(graph.neighbors(of: node.id, direction: .outgoing, kinds: kinds)),
            dependents: names(graph.neighbors(of: node.id, direction: .incoming, kinds: kinds)),
            blastRadius: names(Array(graph.blastRadius(of: node.id)))
        )
    }

 /// Quantified impact of a hypothetical change to `table`
 /// recent, actually-executed queries (history) that
    /// touch it or anything in its blast radius, ranked by call frequency.
    /// Complements `graphOverview`'s pure topology with real workload
    /// evidence. `nil` only when the feature itself is unavailable (no
    /// entitlement, nothing harvested yet) — an unmatched table name or no
    /// matching queries still returns a real, simply-empty `Report`
    /// (`ImpactSimulator.simulate`'s own fallback, Q15 tier gate).
    public func simulateImpact(_ table: String) -> ImpactSimulator.Report? {
        guard intelligenceEntitled, let graph = latestGraph() else { return nil }
        let nodeID = graph.nodes.values.first { $0.kind == .table && $0.name == table }?.id ?? ""
        let workload = (try? store?.history(profileID: activeProfileID))?
            .filter { $0.status == "success" }.map(\.sql) ?? []
        return ImpactSimulator.simulate(changing: nodeID, in: graph, workload: workload)
    }

    /// Saves the just-completed run of `sql` as a Query Replay snapshot
 /// user-initiated only ("Save for
    /// Replay"), distinct from the automatic `query_history` log. Reuses the
    /// duration already measured by the run that just finished, but also
 /// captures a fresh EXPLAIN ANALYZE plan:
 /// unlike's harvester probe (plain EXPLAIN, never executes),
    /// EXPLAIN ANALYZE genuinely runs `sql` again, so it goes through the
    /// normal `QueryService`/DangerGuard path (N1) like any other statement —
    /// a mutating query re-prompts for confirmation exactly as it would if
    /// the user ran it by hand a second time. Returns how it compares to the
    /// previous saved snapshot of the same query, if any — nil on the first
    /// save, or when the feature is unavailable (Q15 tier gate / no active
    /// profile).
    @discardableResult
    public func saveQueryReplay(sql: String, durationMS: Double) async -> QueryReplayComparator.Comparison? {
        guard intelligenceEntitled, let profileID = activeProfileID, let store else { return nil }
        let hash = QueryReplayRecord.hash(of: sql)
        let previous = (try? store.queryReplaySnapshots(profileID: profileID, queryHash: hash))?.first
        let planJSON = await Self.explainAnalyzePlanJSON(sql: sql, session: session)
        let snapshot = QueryReplaySnapshotRecord(
            profileID: profileID, queryHash: hash, sql: sql, ts: Date(), durationMS: durationMS, planJSON: planJSON
        )
        try? store.saveQueryReplaySnapshot(snapshot)
        return previous.map { QueryReplayComparator.compare(earlier: $0, later: snapshot) }
    }

    /// Runs `EXPLAIN ANALYZE sql` through the real SQL path and parses it into
 /// a plan tree. Nil on anything short of a recognized plan — no
    /// session, a dialect without EXPLAIN (`Capabilities.explain == false`),
    /// a declined/failed run, or an unrecognized result shape — since a
    /// replay snapshot without a plan is still useful (matches pre-existing
    /// behavior before this field existed).
    private static func explainAnalyzePlanJSON(sql: String, session: Session?) async -> String? {
        guard let session, session.capabilities.explain else { return nil }
        let explainSQL = "\(session.dialect.explainPrefix(analyze: true)) \(sql)"
        var columns: [ColumnMeta] = []
        var rows: [[BerryValue]] = []
        do {
            for try await event in QueryService.execute(explainSQL, on: session, autoLimit: nil) {
                switch event {
                case let .columns(metas): columns = metas
                case let .rows(batch): rows.append(contentsOf: batch)
                case .complete: break
                }
            }
        } catch {
            return nil
        }
        guard let plan = ExplainTreeParser.parse(columns: columns, rows: rows) else { return nil }
        return PlanNode.jsonString(of: plan)
    }

    private func latestGraph() -> SchemaGraph? {
        guard let profileID = activeProfileID, let graphStore,
              let graph = try? graphStore.loadGraph(profileID: profileID), graph.nodeCount > 0
        else { return nil }
        return graph
    }

    /// Bounded window of PRIOR snapshots (not including the current one) for
 /// convention-consistency checks ("Database
    /// Memory") — capped so a long-lived, frequently-changed profile doesn't
    /// make every insight refresh reload dozens of full historical graphs.
    /// `graphSnapshots` is already newest-first, so `dropFirst()` skips the
    /// current snapshot `latestGraph()` already represents.
    private static let conventionHistoryLimit = 5

    private func recentHistoricalGraphs() -> [SchemaGraph] {
        guard let profileID = activeProfileID, let graphStore,
              let snapshots = try? graphStore.snapshots(profileID: profileID), snapshots.count > 1
        else { return [] }
        return snapshots.dropFirst().prefix(Self.conventionHistoryLimit).compactMap {
            try? graphStore.loadGraph(profileID: profileID, asOf: $0.takenAt)
        }
    }

 /// Digital-Twin snapshot history for the Time Machine Timeline
 /// newest first — already digest-deduped at write time
    /// (`BerryStore.saveGraph`), so every entry represents a real structural
    /// change, not refresh noise.
    public func timelineSnapshots() -> [GraphSnapshotRecord] {
        guard let profileID = activeProfileID, let graphStore else { return [] }
        return (try? graphStore.snapshots(profileID: profileID)) ?? []
    }

    /// Tables/columns/indexes that appeared or disappeared between two
    /// snapshots, sorted by owning table then name.
    public func timelineChanges(from earlier: Date, to later: Date) -> [TimelineChange] {
        guard let profileID = activeProfileID, let graphStore,
              let earlierGraph = try? graphStore.loadGraph(profileID: profileID, asOf: earlier),
              let laterGraph = try? graphStore.loadGraph(profileID: profileID, asOf: later)
        else { return [] }
        let diff = earlierGraph.diff(to: laterGraph)
        var changes: [TimelineChange] = []
        for id in diff.addedNodes {
            guard let node = laterGraph.nodes[id] else { continue }
            changes.append(TimelineChange(
                id: id, isAdded: true, kind: node.kind, name: node.name,
                tableName: node.kind == .table ? nil : Self.owningTable(of: id, in: laterGraph)
            ))
        }
        for id in diff.removedNodes {
            guard let node = earlierGraph.nodes[id] else { continue }
            changes.append(TimelineChange(
                id: id, isAdded: false, kind: node.kind, name: node.name,
                tableName: node.kind == .table ? nil : Self.owningTable(of: id, in: earlierGraph)
            ))
        }
        return changes.sorted {
            ($0.tableName ?? $0.name, $0.name) < ($1.tableName ?? $1.name, $1.name)
        }
    }

    private static func owningTable(of nodeID: String, in graph: SchemaGraph) -> String? {
        graph.neighbors(of: nodeID, direction: .incoming, kinds: [.hasColumn, .hasIndex])
            .first.flatMap { graph.nodes[$0]?.name }
    }

    // MARK: - Tabs

 /// Open (or focus) a table tab.
    public func select(_ object: SchemaObject) {
        guard let session else { return }
        selectedObjectID = object.id
        let tabID = "table:\(object.id)"
        if tabs.contains(where: { $0.id == tabID }) {
            activeTabID = tabID
            return
        }
        let state = TableTabState(object: object)
        state.load(session: session, catalog: catalog)
        tabs.append(.table(state))
        activeTabID = tabID
    }

 // MARK: - ALTER TABLE designer

    /// The current design of an existing table, as the ALTER designer's
    /// starting point.
    public func tableDesign(of object: SchemaObject) async -> TableDesign? {
        guard let catalog else { return nil }
        let ref = TableRef(database: object.database, name: object.name)
        guard let detail = try? await catalog.tableDetail(ref) else { return nil }
        return TableDesign(detail: detail)
    }

    public func alterStatements(original: TableDesign, edited: TableDesign) -> [String] {
        guard let session else { return [] }
        return TableAlteration(original: original, edited: edited, driver: session.config.driver)
            .statements(dialect: session.dialect)
    }

    public func alterWarnings(original: TableDesign, edited: TableDesign) -> [String] {
        guard let session else { return [] }
        return TableAlteration(original: original, edited: edited, driver: session.config.driver)
            .warnings
    }

 /// AI Schema Review for an in-progress edit
 /// runs the same analyzer rules Insight Panel uses against a
    /// hypothetical graph with `edited`'s columns/indexes/foreign keys, before
    /// any DDL runs. Empty when nothing is harvested yet — nothing to compare
    /// the edit against.
    public func migrationPreview(editing edited: TableDesign) -> [Insight] {
        guard intelligenceEntitled, let session, let graph = latestGraph() else { return [] } // Q15 tier gate
        return MigrationPreviewAnalyzer.preview(current: graph, editing: edited, dialect: session.config.driver)
    }

    /// AI Schema Review for a proposed NEW column on an existing table
 /// (`preview_migration` tool) — reconstructs the
    /// table's current design via a live catalog lookup (`tableDesign(of:)`,
    /// the same starting point the ALTER designer uses), appends the
    /// proposed column, and runs the same analyzer `migrationPreview(editing:)`
    /// already exposes to the designer. Nil when the table can't be found
    /// (nothing to compare against) rather than a guess — `tableDesign(of:)`
    /// alone can't signal this: SQLite's introspection returns an empty
    /// column list for an unknown table instead of failing, so existence is
    /// checked against the already-refreshed object list first.
    public func previewNewColumn(table: String, column: ColumnDesign) async -> [Insight]? {
        guard objects.contains(where: { $0.kind == .table && $0.name.caseInsensitiveCompare(table) == .orderedSame })
        else { return nil }
        guard var design = await tableDesign(of: SchemaObject(kind: .table, name: table)) else { return nil }
        design.columns.append(column)
        return migrationPreview(editing: design)
    }

    /// Apply the diff and refresh the schema; returns an error message or nil.
    public func applyAlteration(original: TableDesign, edited: TableDesign) async -> String? {
        guard let session else { return nil }
        do {
            try await TableAlteration(
                original: original, edited: edited, driver: session.config.driver
            ).apply(on: session)
            refreshSchema()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

 /// The CREATE DDL for an object, or nil if the driver can't produce
    /// one. Runs off the SQL path via the driver introspector.
    public func ddl(of object: SchemaObject) async -> String? {
        guard let catalog else { return nil }
        return try? await catalog.ddl(of: object)
    }

 /// quick-info panel.
    public func tableStats(of object: SchemaObject) async -> TableStats? {
        guard let catalog else { return nil }
        return try? await catalog.tableStats(TableRef(database: object.database, name: object.name))
    }

    /// Open (or focus existing) DDL editor tab for a View, Function, Procedure, or Trigger.
    public func openRoutineTab(of object: SchemaObject) async {
        selectedObjectID = object.id
        if let existingTab = tabs.first(where: {
            if case .editor(let doc) = $0, doc.title == object.name {
                return true
            }
            return false
        }) {
            activeTabID = existingTab.id
            return
        }
        if let ddl = await ddl(of: object) {
            newEditorTab(text: ddl, title: object.name)
        }
    }

 // MARK: - CSV import

    public func importableTables() -> [SchemaObject] {
        objects.filter { $0.kind == .table }
    }

 /// Column names of a table, for building the import mapping.
    public func columns(of object: SchemaObject) async -> [String] {
        guard let catalog else { return [] }
        let ref = TableRef(database: object.database, name: object.name)
        return (try? await catalog.tableDetail(ref))?.columns.map(\.name) ?? []
    }

    /// Columns of a table by (possibly schema-qualified) name — for the FK
 /// designer's referenced-column suggestions.
    public func columns(ofTableNamed name: String) async -> [String] {
        let parts = name.split(separator: ".").map(String.init)
        let bare = parts.last ?? name
        guard let object = objects.first(where: {
            $0.kind.isRelational && $0.name.caseInsensitiveCompare(bare) == .orderedSame
        }) else { return [] }
        return await columns(of: object)
    }

    /// Relational object names for the designer's referenced-table suggestions.
    public var relationalTableNames: [String] {
        objects.filter { $0.kind.isRelational }.map(\.name).sorted()
    }

    /// Runs a CSV import through the importer and formats a user-facing result
 /// `records` are the data rows (header already stripped).
    public func runImport(
        records: [CSVParser.Record],
        into object: SchemaObject,
        mapping: [CSVImporter.ColumnMapping],
        batchSize: Int
    ) async -> String {
        guard let session else { return L("No connection") }
        do {
            let result = try await CSVImporter.import(
                records: records,
                into: TableRef(database: object.database, name: object.name),
                mapping: mapping,
                batchSize: batchSize,
                on: session
            )
            if let failure = result.failure {
                return L("Import failed at line \(failure.line): \(failure.message)")
            }
            // Reload the table tab if it's open so imported rows show up.
            if case .table(let state)? = tabs.first(where: { $0.id == "table:\(object.id)" }) {
                state.reload(session: session)
            }
            return L("Imported \(result.insertedRows) rows")
        } catch {
            return error.localizedDescription
        }
    }

 // MARK: - Process list

    public var processListSupported: Bool {
        guard let session else { return false }
        return session.capabilities.processList && session.dialect.processListSQL() != nil
    }

 /// Streams the server's process/activity list into a buffer,
    /// through the single SQL path (N1).
    public func loadProcessList(into buffer: ResultBuffer) {
        guard let session, let sql = session.dialect.processListSQL() else { return }
        buffer.consume(QueryService.execute(sql, on: session, autoLimit: nil))
    }

 /// Terminates a server session by pid. Returns an error message on
    /// failure, nil on success.
    public func killSession(id: String) async -> String? {
        guard let session, let sql = session.dialect.killSessionSQL(id: id) else {
            return L("Cannot terminate this session")
        }
        do {
            for try await _ in QueryService.execute(sql, on: session, autoLimit: nil) {}
            return nil
        } catch {
            return error.localizedDescription
        }
    }

 // MARK: - User management

    public var userManagementSupported: Bool {
        if let session { return session.capabilities.userManagement && session.dialect.listUsersSQL() != nil }
        if let dataSourceSession { return dataSourceSession.capabilities.userManagement }
        return false
    }

    /// A static, read-only note shown in the Users tab in place of real
 /// management (Phase D) — for a connection with no in-DB user
    /// system: DynamoDB (`capabilities.userManagement == true` but no real
    /// `listUsersSQL()` — access is AWS IAM) or Qdrant
    /// (`DataSourceCapabilities.userManagementInfo` — access is an API key).
    /// nil whenever `userManagementSupported` is true (real management wins)
    /// or the active connection has no user-management story at all.
    public var userManagementInfoMessage: String? {
        if let session, session.capabilities.userManagement, session.dialect.listUsersSQL() == nil {
            return L("Access to this table is managed via AWS IAM — manage users and permissions in the AWS Console.")
        }
        if let dataSourceSession, dataSourceSession.capabilities.userManagementInfo {
            return L("This connection authenticates with an API key — there is no separate database user system to manage.")
        }
        return nil
    }

 /// Streams the server's user/role list into a buffer, through the
    /// single SQL path (N1). Columns normalized to: user, host, superuser,
 /// can_login.
    public func loadUsers(into buffer: ResultBuffer) {
        guard let session, let sql = session.dialect.listUsersSQL() else { return }
        buffer.consume(QueryService.execute(sql, on: session, autoLimit: nil))
    }

 /// Drops a user/role. Returns an error message on failure, nil on
    /// success — including the DB's own error when the user still owns
 /// objects (no automatic REASSIGN/DROP OWNED).
    public func dropUser(username: String, host: String?) async -> String? {
        guard let session, let sql = session.dialect.dropUserSQL(username: username, host: host) else {
            return L("Cannot drop this user")
        }
        do {
            for try await _ in QueryService.execute(sql, on: session, autoLimit: nil) {}
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func userDesignPreview(_ design: UserDesign) -> [String] {
        guard let session else { return [] }
        return design.statements(dialect: session.dialect)
    }

    public func applyUserDesign(_ design: UserDesign) async -> String? {
        guard let session else { return L("No connection") }
        do {
            try await design.apply(on: session)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

 // MARK: - User management, DataSource family (Phase C)
    //
    // Mongo's `createUser` command takes its initial role list directly (one
    // round trip), unlike SQL's CREATE USER + N separate GRANT statements —
    // no design/statements-preview model needed here, `connection.createUser`
    // is called directly, same shape as `writeKeyValue`.

    public func loadDataSourceUsers() async throws -> [DataSourceUserInfo] {
        guard let dataSourceSession else { throw DataSourceError.notConnected }
        return try await dataSourceSession.connection.listUsers()
    }

    public func createDataSourceUser(username: String, password: String, roles: [String]) async -> String? {
        guard let dataSourceSession else { return L("No connection") }
        do {
            try await dataSourceSession.connection.createUser(username: username, password: password, roles: roles)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

 /// Drops a user (Phase C). Returns an error message on failure, nil
    /// on success — same "surface the server's own error" contract as the
    /// SQL side's `dropUser(username:host:)`.
    public func dropDataSourceUser(username: String) async -> String? {
        guard let dataSourceSession else { return L("No connection") }
        do {
            try await dataSourceSession.connection.dropUser(username: username)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

 // MARK: - Table designer

 /// SQL preview for the designer — always shown before applying.
    public func designPreview(_ design: TableDesign) -> [String] {
        guard let session else { return [] }
        return design.statements(dialect: session.dialect)
    }

    /// Applies a table design through the single SQL path (N1), then refreshes
    /// the sidebar. Returns an error message on failure, nil on success.
    public func applyTableDesign(_ design: TableDesign) async -> String? {
        guard let session else { return L("No connection") }
        do {
            try await design.apply(on: session)
            try await refreshObjects()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Opens the table referenced by a foreign key, filtered to the referenced
 /// row. No-op if the referenced table isn't in the object list.
    public func jumpToReference(_ fk: ForeignKeyInfo, value: BerryValue) {
        guard let session else { return }
        guard let object = objects.first(where: {
            $0.kind == .table
                && (fk.referencedSchema == nil || $0.database?.caseInsensitiveCompare(fk.referencedSchema!) == .orderedSame)
                && $0.name.caseInsensitiveCompare(fk.referencedTable) == .orderedSame
        }) else { return }
        let clause = "\(session.dialect.quoteIdentifier(fk.referencedColumn)) = \(session.dialect.literal(value))"
        let tabID = "table:\(object.id)"
        selectedObjectID = object.id
        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            if case .table(let state) = tabs[index] {
                state.setFilterAndReload(clause, session: session)
            }
            activeTabID = tabID
            return
        }
        let state = TableTabState(object: object)
        state.filterClause = clause
        state.load(session: session, catalog: catalog)
        tabs.append(.table(state))
        activeTabID = tabID
    }

 /// New SQL editor tab (⌘T). Optional initial text — used by the
 /// history viewer's "insert into new tab" action.
 // MARK: - Detached tab windows (D1)

    /// Tabs currently living in their own window — still in `tabs` (their
    /// documents stay alive) but in no pane.
    public private(set) var detachedTabIDs: Set<String> = []

    /// Move a tab out of its pane into an independent window. The caller opens
    /// the window; the document keeps running against the shared session.
    public func detachTab(_ tabID: String) {
        for gi in groups.indices {
            removeTab(tabID, fromGroupAt: gi)
        }
        pruneEmptyGroups()
        detachedTabIDs.insert(tabID)
    }

    /// The detached window closed → the tab is gone for real (same as closing
    /// it in a pane).
    public func closeDetachedTab(_ tabID: String) {
        guard detachedTabIDs.remove(tabID) != nil else { return }
        if !groups.contains(where: { $0.tabIDs.contains(tabID) }) {
            disposeTab(tabID)
        }
    }

 /// Open (or focus) the ALTER designer for a table as a tab.
    public func openAlterTable(_ design: TableDesign) {
        let tabID = "alter:\(design.database ?? "").\(design.name)"
        if !tabs.contains(where: { $0.id == tabID }) {
            tabs.append(.alterTable(design))
        }
        activeTabID = tabID
    }

 /// Open (or focus) a tool as a tab instead of a modal.
    /// Tools are singletons — one History tab, one Processes tab, etc.
    public func openTool(_ kind: WorkspaceToolKind) {
        let tabID = "tool:\(kind.rawValue)"
        if !tabs.contains(where: { $0.id == tabID }) {
            tabs.append(.tool(kind))
        }
        activeTabID = tabID
    }

 /// Opens a chat-rendered Mermaid diagram as its own tab — the
    /// zoomable, full-size counterpart to the small inline chat block. Always
    /// creates a new tab (mirrors `newEditorTab`), since re-opening the same
    /// diagram from a different message is a distinct thing to look at.
    public func openMermaidDiagram(source: String, title: String? = nil) {
        mermaidDiagramCounter += 1
        let state = MermaidTabState(source: source, title: title ?? L("Diagram") + " \(mermaidDiagramCounter)")
        tabs.append(.mermaidDiagram(state))
        activeTabID = "mermaidDiagram:\(state.id.uuidString)"
    }

    public func newEditorTab(text: String = "", title: String? = nil) {
        editorCounter += 1
        let resolved = SnippetPlaceholder.resolve(text)
        let document = EditorDocument(title: title ?? L("Untitled"), text: resolved.text)
 document.pendingFocus = true // caret lands in the new editor
 document.pendingSelection = resolved.selection // pre-select the snippet's first placeholder
        tabs.append(.editor(document))
        activeTabID = "editor:\(document.id.uuidString)"
        persistEditor(document)
        logWorkspaceAction("tab_opened", description: "Opened SQL tab \"\(document.title)\"")
    }

    /// Maximum file size (1 MB) before warning user about sluggish interactive editing.
    public static let largeSQLFileThreshold: Int64 = 1 * 1024 * 1024
    /// Buffers URLs opened before WorkspaceView mounts (cold start from Finder)
    public static var pendingOpenURLs: [URL] = []

    @discardableResult
    public func openSQLFile(at url: URL, bypassLargeCheck: Bool = false) async throws -> EditorDocument? {
        // If already open, focus that tab
        for tab in tabs {
            if case .editor(let doc) = tab, doc.fileURL == url {
                activeTabID = "editor:\(doc.id.uuidString)"
                return doc
            }
        }

        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(resourceValues?.fileSize ?? 0)

        if size > Self.largeSQLFileThreshold && !bypassLargeCheck {
            // Large file safeguard: caller or UI triggers advisory warning
            pendingLargeFile = LargeFileWarning(url: url, sizeInBytes: size)
            return nil
        }

        // Offload file I/O to background cooperative thread
        let data = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value

        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let doc = EditorDocument(title: url.lastPathComponent, text: content)
        doc.fileURL = url
        doc.isDetached = (session == nil)
        tabs.append(.editor(doc))
        activeTabID = "editor:\(doc.id.uuidString)"
        persistEditor(doc)
        logWorkspaceAction("tab_opened", description: "Opened SQL file \"\(doc.title)\"")
        return doc
    }

    /// Close a tab. With `groupID`, closes it in that pane only (VS Code); the
    /// underlying document survives while it is still open in another pane.
    /// Without `groupID`, closes it everywhere. The document is torn down once
    /// it is no longer shown in any group.
    public func closeTab(id: String, inGroup groupID: String? = nil) {
        if let groupID, let gi = groups.firstIndex(where: { $0.id == groupID }) {
            removeTab(id, fromGroupAt: gi)
        } else {
            for gi in groups.indices { removeTab(id, fromGroupAt: gi) }
        }
        pruneEmptyGroups()
        // Fully dispose the tab only when no pane shows it anymore.
        if !groups.contains(where: { $0.tabIDs.contains(id) }) {
            disposeTab(id)
        }
    }

    public func closeOtherTabs(except tabID: String) {
        let idsToClose = tabs.map(\.id).filter { $0 != tabID }
        for id in idsToClose {
            closeTab(id: id)
        }
    }

    public func closeAllTabs() {
        let idsToClose = tabs.map(\.id)
        for id in idsToClose {
            closeTab(id: id)
        }
    }

    public func hasUnsavedChanges(_ tab: WorkspaceTab) -> Bool {
        switch tab {
        case .table(let state):
            return state.pendingCount > 0
        case .editor(let doc):
            return doc.isDirty
        default:
            return false
        }
    }

    private func removeTab(_ id: String, fromGroupAt gi: Int) {
        guard let ti = groups[gi].tabIDs.firstIndex(of: id) else { return }
        groups[gi].tabIDs.remove(at: ti)
        if groups[gi].activeTabID == id {
            groups[gi].activeTabID = groups[gi].tabIDs.indices.contains(ti)
                ? groups[gi].tabIDs[ti]
                : groups[gi].tabIDs.last
        }
    }

    private func pruneEmptyGroups() {
        let emptyIDs = Set(groups.filter { $0.tabIDs.isEmpty }.map(\.id))
        if !emptyIDs.isEmpty {
            groups.removeAll { emptyIDs.contains($0.id) }
            for i in layoutRows.indices {
                layoutRows[i].groupIDs.removeAll { emptyIDs.contains($0) }
            }
            layoutRows.removeAll { $0.groupIDs.isEmpty }
        }
        if !groups.isEmpty, !groups.contains(where: { $0.id == focusedGroupID }) {
            focusedGroupID = groups[0].id
        }
    }

    private func disposeTab(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index] {
        case .table(let state):
            state.buffer.cancel()
        case .editor(let document):
            document.cancel(session: session)
            // Closing an editor tab discards its persisted session — it must
 // not resurrect on the next connect.
            try? store?.deleteEditorSession(id: document.id)
            logWorkspaceAction("tab_closed", description: "Closed tab \"\(document.title)\"")
        case .tool, .alterTable, .mermaidDiagram:
            break // no per-tab resources to tear down
        case .collection(let state):
            state.cancel()
        case .mongoShell(let state):
            state.cancel()
            logWorkspaceAction("tab_closed", description: "Closed tab \"\(state.title)\"")
        case .qdrantQuery(let state):
            state.cancel()
            logWorkspaceAction("tab_closed", description: "Closed tab \"\(state.title)\"")
        case .elasticsearchQuery(let state):
            state.cancel()
            logWorkspaceAction("tab_closed", description: "Closed tab \"\(state.title)\"")
        }
        tabs.remove(at: index)
    }

    // MARK: - Menu-bar actions on the focused editor pane

    /// Run the focused editor from the menu bar (Query menu). `all` runs every
    /// statement; otherwise the statement at the cursor. Mirrors the editor
 /// toolbar's transaction gate so manual transactions still wrap it.
    public func runFocusedEditor(all: Bool = false) {
        guard case .editor(let document) = activeTab, let session else { return }
        // Query exec: the menu Run honors a selection when one
        // exists, otherwise runs everything.
        let mode: EditorDocument.RunMode
        if !all, document.selectedRange.length > 0 {
            mode = .current(selection: document.selectedRange)
        } else {
            mode = .all
        }
        if !transaction.autoCommit {
            Task {
                if await transaction.beginIfNeeded(session: session) {
                    document.run(mode, on: session)
                }
            }
        } else {
            document.run(mode, on: session)
        }
    }

 /// Pretty-print the focused editor from the menu bar. The editor
    /// view does the formatting so the caret/selection is preserved.
    public func formatFocusedEditor() {
        guard case .editor(let document) = activeTab else { return }
        document.formatRequestID += 1
    }

 /// Split the focused group into a new pane (⌘\). `down` opens a
    /// new grid row; otherwise a new column to the right.
    public func splitFocusedGroup(down: Bool = false) {
        ensureFocusedGroup()
        guard let id = focusedGroup?.id else { return }
        if down { splitDown(id) } else { splitRight(id) }
    }

 /// ⌘/ — toggle line comments in the focused editor.
    public func toggleCommentFocusedEditor() {
        if case .editor(let document) = activeTab {
            document.commentToggleRequestID += 1
        }
    }

    /// Whether the focused pane currently shows an editor (menu-item gating).
    public var focusedTabIsEditor: Bool {
        if case .editor = activeTab { return true }
        return false
    }

 // MARK: - Editor session persistence

    public func persistEditor(_ document: EditorDocument) {
        // Files on disk (fileURL != nil) stay on disk and must not duplicate their content in store.sqlite.
        // Also avoid writing huge documents (>512 KB) into the local SQLite store so app relaunch stays instantaneous.
        guard document.fileURL == nil && document.text.utf8.count <= 512 * 1024 else { return }
        try? store?.saveEditorSession(EditorSessionRecord(
            id: document.id,
            profileID: activeProfileID,
            title: document.title,
            text: document.text,
            savedQueryID: document.savedQueryID,
            artifactID: document.artifactID
        ))
    }

    private func restoreEditorSessions(profileID: UUID?) {
        guard let store, let records = try? store.editorSessions(profileID: profileID),
              !records.isEmpty else { return }
        for record in records {
            // Guard against oversized sessions from past versions that freeze the UI
            if record.text.utf8.count > 512 * 1024 {
                try? store.deleteEditorSession(id: record.id)
                continue
            }
            let document = EditorDocument(id: record.id, title: record.title, text: record.text)
            document.savedQueryID = record.savedQueryID
            document.artifactID = record.artifactID
            tabs.append(.editor(document))
        }
        // Keep "SQL n" numbering monotonic after restore.
        editorCounter = records.count
        // Restore all tabs into a single group (the split is not persisted).
        let group = EditorGroup(
            id: UUID().uuidString,
            tabIDs: tabs.map(\.id),
            activeTabID: tabs.last?.id
        )
        groups = [group]
        layoutRows = [EditorLayoutRow(id: UUID().uuidString, groupIDs: [group.id])]
        focusedGroupID = group.id
    }

 // MARK: - Saved queries

    public private(set) var savedQueries: [SavedQuery] = []

    public func refreshSavedQueries() {
        savedQueries = (try? store?.savedQueries(profileID: activeProfileID)) ?? []
    }

    /// Snippets visible from the active connection: profile-scoped + global.
    public func loadSavedQueries() -> [SavedQuery] {
        (try? store?.savedQueries(profileID: activeProfileID)) ?? []
    }

    /// Persists a snippet. `global == true` makes it usable from any
    /// connection (profileID nil); otherwise it is scoped to the active one.
    public func saveSavedQuery(name: String, sql: String, folder: String?, global: Bool) {
        let trimmedFolder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = SavedQuery(
            profileID: global ? nil : activeProfileID,
            name: name,
            sql: sql,
            folder: (trimmedFolder?.isEmpty ?? true) ? nil : trimmedFolder
        )
        try? store?.saveSavedQuery(query)
 // Link the tab to its saved query and take the saved name:
        // later ⌘S saves update the same record, like a file.
        if case .editor(let document) = activeTab, document.text == sql {
            document.title = name
            document.savedQueryID = query.id
            persistEditor(document)
        }
        if case .mongoShell(let state) = activeTab, state.text == sql {
            state.title = name
            state.savedQueryID = query.id
        }
    }

    /// ⌘S — save the active editor's SQL to saved queries under its tab name,
    /// upserting by name so repeated saves update rather than duplicate
 ///
    public func saveCurrentSQL() {
        guard case .editor(let document) = activeTab,
              !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let name = document.title
        let existing = (try? store?.savedQueries(profileID: activeProfileID))?
            .first { $0.name == name }
        let query = SavedQuery(
            id: existing?.id ?? UUID(),
            profileID: existing?.profileID ?? activeProfileID,
            name: name,
            sql: document.text,
            folder: existing?.folder,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date()
        )
        try? store?.saveSavedQuery(query)
    }

    // MARK: - Backups (feature/04)

    /// Past backups for the active connection, newest first.
    public private(set) var backupFiles: [BackupFile] = []

    /// Per-connection key for the backups directory — stable across restarts
    /// (profile id) so a connection's backups persist, falling back to its name.
    private var backupKey: String {
        session?.profileID?.uuidString
            ?? dataSourceSession?.profileID?.uuidString
            ?? session?.displayName
            ?? dataSourceSession?.displayName
            ?? "default"
    }

    public var backupDirectory: URL { BackupsFolder.directory(forKey: backupKey) }

    public func refreshBackups() {
        let dir = backupDirectory
        Task {
            let files = await Task.detached { BackupsFolder.list(in: dir) }.value
            self.backupFiles = files
        }
    }

    public func deleteBackup(_ file: BackupFile) {
        try? FileManager.default.removeItem(at: file.url)
        refreshBackups()
    }

    public func deleteSavedQuery(id: UUID) {
        try? store?.deleteSavedQuery(id: id)
    }

 /// Save button on a Qdrant query tab: update the linked
    /// saved query if any, otherwise create one under the tab title carrying the
    /// canonical JSON — the vector analogue of `saveCurrentSQL`.
    public func saveActiveQdrantQuery() {
        guard case .qdrantQuery(let state) = activeTab,
              !state.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if updateLinkedSavedQuery() { return }
        let name = state.title
        let existing = (try? store?.savedQueries(profileID: activeProfileID))?.first { $0.name == name }
        let query = SavedQuery(
            id: existing?.id ?? UUID(),
            profileID: existing?.profileID ?? activeProfileID,
            name: name, sql: state.rawJSON, folder: existing?.folder,
            createdAt: existing?.createdAt ?? Date(), updatedAt: Date()
        )
        state.savedQueryID = query.id
        try? store?.saveSavedQuery(query)
    }

    public func saveActiveElasticsearchQuery() {
        guard case .elasticsearchQuery(let state) = activeTab,
              !state.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if updateLinkedSavedQuery() { return }
        let name = state.title
        let existing = (try? store?.savedQueries(profileID: activeProfileID))?.first { $0.name == name }
        let query = SavedQuery(
            id: existing?.id ?? UUID(),
            profileID: existing?.profileID ?? activeProfileID,
            name: name, sql: state.rawJSON, folder: existing?.folder,
            createdAt: existing?.createdAt ?? Date(), updatedAt: Date()
        )
        state.savedQueryID = query.id
        try? store?.saveSavedQuery(query)
    }

 // MARK: - Per-connection AI settings

    public func loadAISetting(profileID: UUID) -> AIConnectionSetting? {
        try? store?.aiSetting(profileID: profileID)
    }

    public func saveAISetting(_ setting: AIConnectionSetting) {
        try? store?.saveAISetting(setting)
    }

    /// SQL currently in the active editor tab — used by "Save Query…".
    public var activeEditorSQL: String? {
        if case .editor(let document) = activeTab { return document.text }
        return nil
    }

 /// Snapshot of the active editor tab for the AI `read_current_tab` tool.
    public func activeTabSnapshot() -> ActiveTabSnapshot? {
        guard let tab = activeTab else { return nil }
        switch tab {
        case .editor(let document):
            return ActiveTabSnapshot(
                tabID: tab.id,
                tabTitle: document.title,
                text: document.text,
                cursorLocation: document.cursorLocation,
                selectedRange: document.selectedRange,
                pane: paneNumber(of: focusedGroupID)
            )
        case .mongoShell(let state):
            return ActiveTabSnapshot(
                tabID: tab.id,
                tabTitle: state.title,
                text: state.text,
                cursorLocation: state.text.count,
                selectedRange: NSRange(location: state.text.count, length: 0),
                pane: paneNumber(of: focusedGroupID)
            )
        case .qdrantQuery(let state):
            return ActiveTabSnapshot(
                tabID: tab.id,
                tabTitle: state.title,
                text: state.rawJSON,
                cursorLocation: state.rawJSON.count,
                selectedRange: NSRange(location: state.rawJSON.count, length: 0),
                pane: paneNumber(of: focusedGroupID)
            )
        case .elasticsearchQuery(let state):
            return ActiveTabSnapshot(
                tabID: tab.id,
                tabTitle: state.title,
                text: state.rawJSON,
                cursorLocation: state.rawJSON.count,
                selectedRange: NSRange(location: state.rawJSON.count, length: 0),
                pane: paneNumber(of: focusedGroupID)
            )
        default:
            return nil
        }
    }

    /// Panes in the order the UI numbers them: rows top→bottom, groups within a
 /// row left→right, so pane 1 is the top(-left) one.
    private var orderedGroups: [EditorGroup] {
        layoutRows.flatMap(\.groupIDs).compactMap { id in groups.first { $0.id == id } }
    }

    /// The pane number the UI shows for a group (1 = top), or nil if not laid out.
    public func paneNumber(of groupID: String) -> Int? {
        orderedGroups.firstIndex { $0.id == groupID }.map { $0 + 1 }
    }

    /// Every open pane, numbered as the UI shows them, for the AI `get_open_tabs`
 /// tool so it can disambiguate a split before acting.
    public func openTabsSnapshot() -> OpenTabsSnapshot? {
        let ordered = orderedGroups
        guard !ordered.isEmpty else { return nil }
        let panes: [OpenTabsSnapshot.Pane] = ordered.enumerated().compactMap { index, group in
            guard let tab = tab(for: group.activeTabID ?? "") else { return nil }
            let kind: String
            var sql: String?
            switch tab {
            case .editor(let document): kind = "editor"; sql = document.text
            case .table: kind = "table"
            case .tool: kind = "tool"
            case .alterTable: kind = "table"
            case .collection: kind = "collection"
            case .mongoShell: kind = "mongoShell"
            case .qdrantQuery(let state): kind = "qdrantQuery"; sql = state.rawJSON
            case .elasticsearchQuery(let state): kind = "elasticsearchQuery"; sql = state.rawJSON
            case .mermaidDiagram: kind = "mermaidDiagram"
            }
            return OpenTabsSnapshot.Pane(
                id: tab.id,
                number: index + 1,
                focused: group.id == focusedGroupID,
                kind: kind,
                title: tab.title,
                sql: sql
            )
        }
        return OpenTabsSnapshot(panes: panes)
    }

    /// Every open tab across every pane (unlike `openTabsSnapshot()`, which
    /// only carries each pane's active tab), for the AI `get_ui_state`/
 /// `query_ui_graph` tools.
    public func uiGraphSnapshot() -> UIGraphSnapshot? {
        let ordered = orderedGroups
        guard !ordered.isEmpty else { return nil }
        let panes = ordered.enumerated().map { index, group in
            UIGraphSnapshot.Pane(
                id: group.id, number: index + 1, focused: group.id == focusedGroupID,
                tabIDs: group.tabIDs
            )
        }
        let tabInfos = tabs.map { tab -> UIGraphSnapshot.Tab in
            let kind: String
            switch tab {
            case .editor: kind = "editor"
            case .table: kind = "table"
            case .tool: kind = "tool"
            case .alterTable: kind = "alterTable"
            case .collection: kind = "collection"
            case .mongoShell: kind = "mongoShell"
            case .qdrantQuery: kind = "qdrantQuery"
            case .elasticsearchQuery: kind = "elasticsearchQuery"
            case .mermaidDiagram: kind = "mermaidDiagram"
            }
            return UIGraphSnapshot.Tab(id: tab.id, kind: kind, title: tab.title)
        }
        return UIGraphSnapshot(panes: panes, tabs: tabInfos, activeTabID: activeTabID)
    }

    /// Statements for the AI `run_tab_statements`/`explain_query` tools, mapping
 /// the tool's "all"/"selection"/"cursor" onto `EditorDocument.RunMode`.
    public func activeEditorStatements(for which: String) -> [String] {
        switch activeTab {
        case .editor(let document):
            let mode: EditorDocument.RunMode
            switch which {
            case "selection": mode = .current(selection: document.selectedRange)
            case "cursor": mode = .current(selection: nil)
            default: mode = .all
            }
            return document.statements(for: mode)
        case .mongoShell(let state):
            let text = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        case .qdrantQuery(let state):
            let text = state.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        case .elasticsearchQuery(let state):
            let text = state.rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        default:
            return []
        }
    }

 /// The saved query the active editor is linked to, if any.
    public var activeEditorSavedQueryID: UUID? {
        switch activeTab {
        case .editor(let document): return document.savedQueryID
        case .mongoShell(let state): return state.savedQueryID
        case .qdrantQuery(let state): return state.savedQueryID
        case .elasticsearchQuery(let state): return state.savedQueryID
        default: return nil
        }
    }

 /// Open a saved query as a linked tab: re-opening focuses the
    /// existing tab; otherwise a new tab is created carrying the query's name
    /// and the link used by ⌘S. Branches on whether a SQL or Mongo session is
    /// active (mirrors `newQueryTab()`, Task 8).
    public func openSavedQuery(_ query: SavedQuery) {
        for tab in tabs {
            switch tab {
            case .editor(let document) where document.savedQueryID == query.id:
                activeTabID = tab.id
                return
            case .mongoShell(let state) where state.savedQueryID == query.id:
                activeTabID = tab.id
                return
            case .qdrantQuery(let state) where state.savedQueryID == query.id:
                activeTabID = tab.id
                return
            case .elasticsearchQuery(let state) where state.savedQueryID == query.id:
                activeTabID = tab.id
                return
            default:
                continue
            }
        }
        switch dataSourceSession?.kind {
        case .document:
            let state = MongoShellTabState(title: query.name, text: query.sql)
            state.savedQueryID = query.id
            state.pendingFocus = true
            tabs.append(.mongoShell(state))
            activeTabID = "mongoShell:\(state.id.uuidString)"
        case .vector:
 // Qdrant saved queries persist the canonical JSON in `sql`.
            let state = QdrantQueryTabState(title: query.name, rawJSON: query.sql)
            state.savedQueryID = query.id
            state.pendingFocus = true
            tabs.append(.qdrantQuery(state))
            activeTabID = "qdrantQuery:\(state.id.uuidString)"
        case .search:
            // Elasticsearch saved queries persist the canonical JSON in `sql`
 // same as Qdrant.
            let state = ElasticsearchQueryTabState(title: query.name, rawJSON: query.sql)
            state.savedQueryID = query.id
            state.pendingFocus = true
            tabs.append(.elasticsearchQuery(state))
            activeTabID = "elasticsearchQuery:\(state.id.uuidString)"
        case nil:
            let document = EditorDocument(title: query.name, text: query.sql)
            document.savedQueryID = query.id
            document.pendingFocus = true
            tabs.append(.editor(document))
            activeTabID = "editor:\(document.id.uuidString)"
            persistEditor(document)
        }
    }

 // MARK: - Artifacts

    public private(set) var artifacts: [Artifact] = []

    public func refreshArtifacts() {
        guard let profileID = activeProfileID else { artifacts = []; return }
        artifacts = (try? store?.artifacts(profileID: profileID)) ?? []
    }

    public func deleteArtifact(id: UUID) {
        try? store?.deleteArtifact(id: id)
    }

 /// Candidates for the composer's `@{...}` mention autocomplete
 /// this connection's artifacts plus its relational
    /// schema objects, filtered by `query`. Reads artifacts fresh from the
    /// store each call rather than the cached `artifacts` property (which
    /// only updates on an explicit `refreshArtifacts()`) so a mention typed
    /// right after saving/running something sees it immediately.
    public func matchingArtifactMentions(query: String) -> [ArtifactMentionItem] {
        guard let profileID = activeProfileID else { return [] }
        let artifacts = (try? store?.artifacts(profileID: profileID)) ?? []
        return ArtifactMentionItem.filter(artifacts: artifacts, objects: objects, query: query)
    }

 /// Look up the artifact linked to a tab by its `WorkspaceTab.id`
    /// — lets the AI's tool executor accumulate versions onto the same
    /// artifact across repeated tool calls against the same tab instead of
    /// creating a new one each time.
    public func artifactID(forTab tabID: String) -> UUID? {
        for tab in tabs where tab.id == tabID {
            switch tab {
            case .editor(let document): return document.artifactID
            case .mongoShell(let state): return state.artifactID
            case .qdrantQuery(let state): return state.artifactID
            case .elasticsearchQuery(let state): return state.artifactID
            default: return nil
            }
        }
        return nil
    }

 /// Links a tab to an artifact the AI's tool executor just created
    /// — mirrors how `openSavedQuery`/`saveArtifact` set the link from the UI side.
    public func setArtifactID(_ artifactID: UUID, forTab tabID: String) {
        for tab in tabs where tab.id == tabID {
            switch tab {
            case .editor(let document):
                document.artifactID = artifactID
                persistEditor(document)
            case .mongoShell(let state):
                state.artifactID = artifactID
            case .qdrantQuery(let state):
                state.artifactID = artifactID
            case .elasticsearchQuery(let state):
                state.artifactID = artifactID
            default:
                break
            }
            return
        }
    }

    /// The active tab's raw text/JSON, for any of the three query/tab kinds
    /// an artifact can be saved from — unlike `activeEditorSQL` (SQL-only,
    /// used by "Save Query…"), this also covers Mongo shell/Qdrant tabs.
    public var activeArtifactPayload: String? {
        switch activeTab {
        case .editor(let document): document.text
        case .mongoShell(let state): state.text
        case .qdrantQuery(let state): state.rawJSON
        case .elasticsearchQuery(let state): state.rawJSON
        default: nil
        }
    }

    /// Open an artifact as a linked tab: re-opening focuses the existing tab
    /// if one is still open for it; otherwise loads the latest version into a
    /// new tab of the right kind and links it (mirrors `openSavedQuery`
    /// exactly). A schema-object artifact (table/view/trigger/function) has
    /// no separate linking state — it's a live pointer, so "opening" it is
    /// just opening the live object itself via `select(_:)`, the same as
    /// `TableTabState`/`CollectionTabState` already do from stable
    /// name-derived ids.
 /// Opens an artifact by id — resolves it from local storage
    /// first, since a chat bubble's chip only carries the id/version, not
    /// the full record.
 /// Entry point for an artifact chip click in the AI panel.
    ///
    /// `[AIARTIFACT]` tracing: every failure below is a silent `return`, and
    /// `try? store?.artifact(id:)` collapses three distinct causes into one —
    /// no store, a throwing query, or no such row. A chip that does nothing on
    /// click is indistinguishable between them from the UI, so log which.
    public func openArtifact(id: UUID) {
        guard let store else {
            DiagnosticLog.default.event("artifact open failed", detail: "no store id=\(id.uuidString)")
            return
        }
        let found: Artifact?
        do {
            found = try store.artifact(id: id)
        } catch {
            DiagnosticLog.default.event(
                "artifact open failed", detail: "store threw id=\(id.uuidString) error=\(error)"
            )
            return
        }
        guard let artifact = found else {
            DiagnosticLog.default.event("artifact open failed", detail: "no row id=\(id.uuidString)")
            return
        }
        DiagnosticLog.default.event(
            "artifact open",
            detail: "kind=\(artifact.kind) title=\(artifact.title) objectRef=\(artifact.objectRef ?? "nil")"
        )
        openArtifact(artifact)
    }

 /// Opens a table/view by its `SchemaObject.id` — a user's own
    /// chat bubble linkifies an `@{Name}` mention that resolves to a live
    /// object the same way an artifact chip does, but only ever carries the
    /// id string, not the full object.
    public func selectObject(id: String) {
        guard let object = objects.first(where: { $0.id == id }) else { return }
        select(object)
    }

    public func openArtifact(_ artifact: Artifact) {
        switch artifact.kind {
        case .table, .view, .trigger, .function:
            // Schema-object artifact: needs a live `SchemaObject` with a
            // matching id. `objects` is empty until the schema has loaded, so
            // an early click (or a renamed/dropped object) silently no-ops.
            guard let objectRef = artifact.objectRef else {
                DiagnosticLog.default.event(
                    "artifact open failed",
                    detail: "kind=\(artifact.kind) has no objectRef title=\(artifact.title)"
                )
                return
            }
            guard let object = objects.first(where: { $0.id == objectRef }) else {
                DiagnosticLog.default.event(
                    "artifact open failed",
                    detail: "objectRef=\(objectRef) not among \(objects.count) loaded objects title=\(artifact.title)"
                )
                return
            }
            select(object)
            return
        case .other:
            DiagnosticLog.default.event(
                "artifact open failed", detail: "kind=.other not openable title=\(artifact.title)"
            )
            return
        case .editorTab, .mongoShell, .qdrantQuery, .elasticsearchQuery:
            break
        }

        // An already-open tab for this artifact is only re-focused. Logged
        // because this path is otherwise indistinguishable from a no-op: if the
        // focus does not visibly land, the click looks ignored.
        for tab in tabs {
            switch tab {
            case .editor(let document) where document.artifactID == artifact.id:
                DiagnosticLog.default.event(
                    "artifact refocus existing tab", detail: "tab=\(tab.id)"
                )
                activeTabID = tab.id
                DiagnosticLog.default.event(
                    "artifact refocus result",
                    detail: "activeTabID=\(activeTabID ?? "nil") groups=\(groups.count)"
                )
                return
            case .mongoShell(let state) where state.artifactID == artifact.id:
                DiagnosticLog.default.event("artifact refocus existing tab", detail: "tab=\(tab.id)")
                activeTabID = tab.id
                return
            case .qdrantQuery(let state) where state.artifactID == artifact.id:
                DiagnosticLog.default.event("artifact refocus existing tab", detail: "tab=\(tab.id)")
                activeTabID = tab.id
                return
            case .elasticsearchQuery(let state) where state.artifactID == artifact.id:
                DiagnosticLog.default.event("artifact refocus existing tab", detail: "tab=\(tab.id)")
                activeTabID = tab.id
                return
            default:
                continue
            }
        }
        DiagnosticLog.default.event(
            "artifact has no open tab yet",
            detail: "tabs=\(tabs.count) building a new one"
        )

        // No existing tab matched, so a new one must be built from the latest
        // stored version. An artifact row with no version row yet — the tool
        // recorded the artifact but its version write did not land, or landed
        // under a different id — leaves nothing to open and no visible reason.
        guard let store else {
            DiagnosticLog.default.event(
                "artifact open failed", detail: "no store for new tab title=\(artifact.title)"
            )
            return
        }
        guard let version = try? store.latestArtifactVersion(artifactID: artifact.id) else {
            DiagnosticLog.default.event(
                "artifact open failed",
                detail: "no version rows id=\(artifact.id.uuidString) title=\(artifact.title)"
            )
            return
        }

        switch artifact.kind {
        case .mongoShell:
            let state = MongoShellTabState(title: artifact.title, text: version.payload)
            state.artifactID = artifact.id
            state.pendingFocus = true
            tabs.append(.mongoShell(state))
            activeTabID = "mongoShell:\(state.id.uuidString)"
        case .qdrantQuery:
            let state = QdrantQueryTabState(title: artifact.title, rawJSON: version.payload)
            state.artifactID = artifact.id
            state.pendingFocus = true
            tabs.append(.qdrantQuery(state))
            activeTabID = "qdrantQuery:\(state.id.uuidString)"
        case .elasticsearchQuery:
            let state = ElasticsearchQueryTabState(title: artifact.title, rawJSON: version.payload)
            state.artifactID = artifact.id
            state.pendingFocus = true
            tabs.append(.elasticsearchQuery(state))
            activeTabID = "elasticsearchQuery:\(state.id.uuidString)"
        case .editorTab:
            let document = EditorDocument(title: artifact.title, text: version.payload)
            document.artifactID = artifact.id
            document.pendingFocus = true
            if let resultJSON = version.resultSnapshotJSON {
                document.loadSnapshotResults(
                    Self.parseResultSnapshots(resultJSON, fallbackSQL: version.payload)
                )
            }
            tabs.append(.editor(document))
            activeTabID = "editor:\(document.id.uuidString)"
            persistEditor(document)
            // The whole point of the click. If this reports the tab was added
            // and made active but nothing appears on screen, the failure is in
            // the view layer's group/tab rendering, not in this lookup chain.
            DiagnosticLog.default.event(
                "artifact opened new editor tab",
                detail: "tab=editor:\(document.id.uuidString) activeTabID=\(activeTabID ?? "nil") "
                    + "tabs=\(tabs.count) groups=\(groups.count) payloadBytes=\(version.payload.utf8.count)"
            )
        case .table, .view, .trigger, .function, .other:
            break // handled above
        }
    }

 /// Parses a `resultSnapshotJSON` ('s `run_sql` single-statement shape
    /// `{"columns":[...],"rows":[...]}`, or `run_tab_statements`'s
    /// `{"statements":[{"sql":...,"columns":...,"rows":...}, ...]}`) into the
    /// shape `EditorDocument.loadSnapshotResults` expects — one entry per
 /// statement,.
    private static func parseResultSnapshots(
        _ json: String, fallbackSQL: String
    ) -> [(sql: String, columns: [String], rows: [[String?]])] {
        func extract(_ dict: [String: Any], sql: String) -> (sql: String, columns: [String], rows: [[String?]])? {
            guard let columns = dict["columns"] as? [String], let rawRows = dict["rows"] as? [[Any]] else { return nil }
            return (sql, columns, rawRows.map { row in row.map { $0 as? String } })
        }
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let statements = object["statements"] as? [[String: Any]] {
            return statements.compactMap { extract($0, sql: $0["sql"] as? String ?? fallbackSQL) }
        }
        return extract(object, sql: fallbackSQL).map { [$0] } ?? []
    }

    /// Saves the active query/tab as a brand-new artifact — the manual entry
 /// point into the same model will wire the agent's own tools into.
    /// Links the active tab the same way `saveSavedQuery` does.
    @discardableResult
    public func saveArtifact(title: String) -> Artifact? {
        guard let store, let profileID = activeProfileID else { return nil }
        let kind: Artifact.Kind
        let payload: String
        switch activeTab {
        case .editor(let document):
            kind = .editorTab
            payload = document.text
        case .mongoShell(let state):
            kind = .mongoShell
            payload = state.text
        case .qdrantQuery(let state):
            kind = .qdrantQuery
            payload = state.rawJSON
        case .elasticsearchQuery(let state):
            kind = .elasticsearchQuery
            payload = state.rawJSON
        default:
            return nil
        }
        let artifact = Artifact(profileID: profileID, kind: kind, title: title)
        guard (try? store.saveArtifact(artifact)) != nil else { return nil }
        _ = try? store.appendArtifactVersion(artifactID: artifact.id, payload: payload)
        switch activeTab {
        case .editor(let document):
            document.artifactID = artifact.id
            persistEditor(document)
        case .mongoShell(let state):
            state.artifactID = artifact.id
        case .qdrantQuery(let state):
            state.artifactID = artifact.id
        case .elasticsearchQuery(let state):
            state.artifactID = artifact.id
        default:
            break
        }
        return artifact
    }

    /// ⌘S on a linked tab: write the editor's SQL back into ITS saved query
 /// Returns false when the tab isn't linked yet (caller prompts
    /// for a name instead).
    @discardableResult
    public func updateLinkedSavedQuery() -> Bool {
        let linked: (text: String, title: String, savedQueryID: UUID?)
        switch activeTab {
        case .editor(let document):
            linked = (document.text, document.title, document.savedQueryID)
        case .mongoShell(let state):
            linked = (state.text, state.title, state.savedQueryID)
        case .qdrantQuery(let state):
            linked = (state.rawJSON, state.title, state.savedQueryID)
        case .elasticsearchQuery(let state):
            linked = (state.rawJSON, state.title, state.savedQueryID)
        default:
            return false
        }
        guard let linkedID = linked.savedQueryID,
              var query = (try? store?.savedQueries(profileID: activeProfileID))?
                  .first(where: { $0.id == linkedID })
        else { return false }
        query.sql = linked.text
        query.name = linked.title
        query.updatedAt = Date()
        try? store?.saveSavedQuery(query)
        return true
    }

 /// Rename a saved query; any open tab linked to it follows.
    /// `.mongoShell` tabs aren't restored across app restarts the way
    /// `.editor` tabs are via `persistEditor` — Mongo shell session
    /// persistence is out of scope here, so renaming just updates the
    /// in-memory tab title.
    public func renameSavedQuery(id: UUID, to name: String) {
        guard var query = (try? store?.savedQueries(profileID: activeProfileID))?
            .first(where: { $0.id == id }) else { return }
        query.name = name
        query.updatedAt = Date()
        try? store?.saveSavedQuery(query)
        for tab in tabs {
            switch tab {
            case .editor(let document) where document.savedQueryID == id:
                document.title = name
                persistEditor(document)
            case .mongoShell(let state) where state.savedQueryID == id:
                state.title = name
            case .qdrantQuery(let state) where state.savedQueryID == id:
                state.title = name
            case .elasticsearchQuery(let state) where state.savedQueryID == id:
                state.title = name
            default:
                continue
            }
        }
    }

 // MARK: - Query history

    /// The loaded page(s) of history for the tab. DB-side search + keyset paging
    /// keep RAM flat and let search hit the whole table (not just a slice).
    public private(set) var historyEntries: [QueryHistoryEntry] = []
    public private(set) var hasMoreHistory = true
    public private(set) var isLoadingHistory = false
    public private(set) var historySearch = ""
    private let historyPageSize = 100

    /// (Re)load the first page for the current/updated search term.
    public func refreshHistory(search: String) {
        historySearch = search
        let page = fetchHistoryPage(before: nil)
        historyEntries = page
        hasMoreHistory = page.count >= historyPageSize
    }

    /// Append the next keyset page as the list scrolls to its end.
    public func loadMoreHistory() {
        guard hasMoreHistory, !isLoadingHistory, let last = historyEntries.last else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let page = fetchHistoryPage(before: last)
        historyEntries.append(contentsOf: page)
        hasMoreHistory = page.count >= historyPageSize
    }

    private func fetchHistoryPage(before cursor: QueryHistoryEntry?) -> [QueryHistoryEntry] {
        (try? store?.history(
            profileID: activeProfileID,
            search: historySearch.isEmpty ? nil : historySearch,
            beforeStartedAt: cursor?.startedAt,
            beforeID: cursor?.id,
            limit: historyPageSize
        )) ?? []
    }

    public func clearHistory() {
        try? store?.clearHistory()
        historyEntries = []
        hasMoreHistory = false
    }

    /// The slowest recent successful queries (`get_slow_queries` tool
 /// bridge) — re-ranks the same `query_history` the
    /// History tab already shows by duration instead of recency. Base "ai"
    /// tier like History itself, not Intelligence-gated. Bounded to the most
    /// recent 500 entries (matching `ImpactSimulator`'s own workload window)
    /// rather than scanning the full 10k/profile cap.
    public func slowestQueries(limit: Int = 10) -> [QueryHistoryEntry] {
        guard let store, let profileID = activeProfileID else { return [] }
        let recent = (try? store.history(profileID: profileID, limit: 500)) ?? []
        return Array(
            recent.filter { $0.status == "success" }
                .sorted { $0.durationMS > $1.durationMS }
                .prefix(limit)
        )
    }

    public func cancelCurrentQuery() {
        session?.connection.cancelCurrentQuery()
        if case .table(let state) = activeTab {
            state.buffer.cancel()
        }
        if case .editor(let document) = activeTab {
            document.cancel(session: session)
        }
    }

 // MARK: - NoSQL/vector: connect (design decision #1/#2)

    /// Connect to a Mongo/Qdrant profile — the `DataSourceDriver` sibling of
    /// `connect(profile:)`. One active connection per workspace, SQL XOR
    /// NoSQL: tears down any active SQL session first, mirroring `open`'s
    /// reverse teardown of `dataSourceSession`.
    public func connectDataSource(profile: ConnectionProfile, alreadyBegun: Bool = false) async {
        guard alreadyBegun || beginConnect() else { return }
        defer { isConnecting = false }

        if let old = session {
            await ConnectionManager.shared.close(old.id)
        }
        if let old = dataSourceSession {
            await old.connection.close()
            await old.tunnel?.close()
        }
        if let old = keyValueSession {
            await old.connection.close()
            await old.tunnel?.close()
        }
        session = nil
        dataSourceSession = nil
        keyValueSession = nil
        activeProfileID = nil
        catalog = nil
        objects = []
        collections = []

        guard let driverType = profile.driver.flatMap(DataSourceRegistry.driverType(for:)) else {
            errorMessage = "Driver \(profile.driverID) is not registered"
            return
        }
        let config = profile.makeConfig(
            password: KeychainService.readPassword(kind: .database, profileID: profile.id),
            elasticsearchAPIKey: KeychainService.readPassword(kind: .elasticsearchAPIKey, profileID: profile.id)
        )
        do {
            let (effectiveConfig, tunnel) = try await prepareDataSourceEndpoint(config)
            do {
                let connection = try await driverType.init().connect(effectiveConfig)
                dataSourceSession = DataSourceSession(
                    profileID: profile.id,
                    isProduction: profile.envColor == "production",
                    connection: connection,
                    kind: driverType.kind,
                    capabilities: driverType.capabilities,
                    driverDisplayName: driverType.displayName,
                    displayName: profile.name,
                    tunnel: tunnel
                )
                activeProfileID = profile.id
                tabs = []
                groups = []
                layoutRows = []
                focusedGroupID = ""
                selectedCollectionID = nil
                try await refreshCollections()
            } catch {
                await tunnel?.close()
                throw error
            }
        } catch {
            dataSourceSession = nil
            activeProfileID = nil
            collections = []
            errorMessage = error.localizedDescription
        }
    }

    /// SSH tunnel setup for a Mongo/Qdrant/Elasticsearch config — mirrors
    /// `Session.prepareEndpoint` (BerryCore), duplicated here because
    /// `DataSourceDriver` has no `ConnectionManager` equivalent to share it
 /// through.
    private func prepareDataSourceEndpoint(
        _ config: ConnectionConfig
    ) async throws -> (ConnectionConfig, SSHTunnel?) {
        guard let ssh = config.ssh else { return (config, nil) }
        guard let targetHost = config.host else {
            throw DataSourceError.connectionFailed("Missing host")
        }
        let targetPort = config.port ?? (config.driver == .qdrant ? 6333 : config.driver == .elasticsearch ? 9200 : 27017)
        let tunnel = try await SSHTunnel.open(ssh, targetHost: targetHost, targetPort: targetPort)
        return (config.replacingEndpoint(host: "127.0.0.1", port: tunnel.localPort), tunnel)
    }

    /// Read-path failure when no key-value session is active — separate from
 /// `DataSourceError` since it's a different family.
    enum KeyValueViewModelError: LocalizedError {
        case noConnection
        var errorDescription: String? { L("No connection") }
    }

 // MARK: - Key-value: connect

    /// Connect to a Redis profile — the `KeyValueDriver` sibling of
    /// `connect(profile:)`/`connectDataSource(profile:)`. One active
    /// connection per workspace, SQL XOR NoSQL XOR key-value: tears down any
    /// active SQL/NoSQL session first.
    ///
    /// A missing registry entry surfaces as the same "Driver … is not
    /// registered" error `connectDataSource` already produces, with no
    /// special-casing needed.
    public func connectKeyValue(profile: ConnectionProfile, alreadyBegun: Bool = false) async {
        guard alreadyBegun || beginConnect() else { return }
        defer { isConnecting = false }

        if let old = session {
            await ConnectionManager.shared.close(old.id)
        }
        if let old = dataSourceSession {
            await old.connection.close()
            await old.tunnel?.close()
        }
        if let old = keyValueSession {
            await old.connection.close()
            await old.tunnel?.close()
        }
        session = nil
        dataSourceSession = nil
        keyValueSession = nil
        activeProfileID = nil
        catalog = nil
        objects = []
        collections = []

        guard let driverType = profile.driver.flatMap(KeyValueRegistry.driverType(for:)) else {
            errorMessage = "Driver \(profile.driverID) is not registered"
            return
        }
        let config = profile.makeConfig(
            password: KeychainService.readPassword(kind: .database, profileID: profile.id)
        )
        do {
            let (effectiveConfig, tunnel) = try await prepareKeyValueEndpoint(config)
            do {
                let connection = try await driverType.init().connect(effectiveConfig)
                keyValueSession = KeyValueSession(
                    profileID: profile.id,
                    isProduction: profile.envColor == "production",
                    connection: connection,
                    capabilities: driverType.capabilities,
                    driverDisplayName: driverType.displayName,
                    displayName: profile.name,
                    database: effectiveConfig.database.flatMap(Int.init) ?? 0,
                    tunnel: tunnel
                )
                activeProfileID = profile.id
                tabs = []
                groups = []
                layoutRows = []
                focusedGroupID = ""
            } catch {
                await tunnel?.close()
                throw error
            }
        } catch {
            keyValueSession = nil
            activeProfileID = nil
            errorMessage = error.localizedDescription
        }
    }

    /// SSH tunnel setup for a Redis config — mirrors `prepareDataSourceEndpoint`.
    private func prepareKeyValueEndpoint(
        _ config: ConnectionConfig
    ) async throws -> (ConnectionConfig, SSHTunnel?) {
        guard let ssh = config.ssh else { return (config, nil) }
        guard let targetHost = config.host else {
            throw DataSourceError.connectionFailed("Missing host")
        }
        let targetPort = config.port ?? 6379
        let tunnel = try await SSHTunnel.open(ssh, targetHost: targetHost, targetPort: targetPort)
        return (config.replacingEndpoint(host: "127.0.0.1", port: tunnel.localPort), tunnel)
    }

 // MARK: - Key-value: browse & write

    /// Cursor-paginated key scan (N3: never `KEYS`) — `cursor: nil` starts a
    /// fresh scan.
    public func scanKeys(pattern: String, cursor: String?) async throws -> KeyValueScanPage {
        guard let keyValueSession else { throw KeyValueViewModelError.noConnection }
        return try await keyValueSession.connection.scan(pattern: pattern, cursor: cursor)
    }

    public func getKeyValue(_ key: String) async throws -> KeyValueValue {
        guard let keyValueSession else { throw KeyValueViewModelError.noConnection }
        return try await keyValueSession.connection.get(key)
    }

    public func keyTTL(_ key: String) async -> TimeInterval? {
        guard let keyValueSession else { return nil }
        return try? await keyValueSession.connection.ttl(key)
    }

    /// Switches the active numbered database (Redis/Valkey: 0–15) without
    /// reconnecting — the caller (`KeyValueBrowserView`) is responsible for
    /// resetting/re-scanning its key list afterward, the key space is
    /// entirely different on success.
    public func selectKeyValueDatabase(_ index: Int) async -> String? {
        guard let keyValueSession else { return L("No connection") }
        do {
            try await keyValueSession.connection.selectDatabase(index)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Every write is previewed as a literal command string before this is
    /// ever called (N1, mirrors `applyDataSourceWriteOutcome`) — the caller
    /// owns confirmation, this just runs it.
    public func writeKeyValue(_ change: KeyValueChangeSet) async -> String? {
        guard let keyValueSession else { return L("No connection") }
        do {
            try await keyValueSession.connection.write(change)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Re-lists collections for the active NoSQL/vector session (mirrors
    /// `refreshObjects()`).
    public func refreshCollections() async throws {
        guard let dataSourceSession else { return }
        collections = try await dataSourceSession.connection.listCollections()
    }

    // MARK: - NoSQL/vector: tabs (design decision #6)

    /// Open (or focus) a collection tab — the `CollectionRef` sibling of
    /// `select(_:)`.
    public func openCollection(_ ref: CollectionRef) {
        guard let dataSourceSession else { return }
        selectedCollectionID = ref.id
        selectedObjectID = ref.id
        let tabID = "collection:\(ref.id)"
        if tabs.contains(where: { $0.id == tabID }) {
            activeTabID = tabID
            return
        }
        let state = CollectionTabState(ref: ref, kind: dataSourceSession.kind, connection: dataSourceSession.connection)
        state.run()
        tabs.append(.collection(state))
        activeTabID = tabID
    }

    /// Opens a Mongo shell tab pre-seeded with a starter query for `ref`
    /// (Double-clicking a table opens `SELECT * FROM t LIMIT 1000` in a
    /// SQL tab — this is the Mongo-shell equivalent).
    /// Re-focuses the existing tab for the same collection instead of duplicating it.
    private func openMongoShellTab(for ref: CollectionRef, session: DataSourceSession) {
        let existing = tabs.compactMap { tab -> MongoShellTabState? in
            guard case .mongoShell(let state) = tab, state.sourceCollectionName == ref.name else { return nil }
            return state
        }.first
        if let existing {
            activeTabID = "mongoShell:\(existing.id.uuidString)"
            return
        }
        let state = MongoShellTabState(title: ref.name, text: "db.\(ref.name).find({}).limit(50);")
        state.sourceCollectionName = ref.name
        tabs.append(.mongoShell(state))
        activeTabID = "mongoShell:\(state.id.uuidString)"
        state.run(session: session, applyWrite: { [weak self] change in
            await self?.applyDataSourceWriteOutcome(change) ?? .cancelled
        })
    }

    /// Blank Mongo shell tab ("New Query" for Mongo), mirroring
    /// `newEditorTab()`. Doesn't auto-run — a blank tab has nothing to execute.
    public func newMongoShellTab(text: String = "", title: String? = nil) {
        let state = MongoShellTabState(title: title ?? L("Untitled"), text: text)
        state.pendingFocus = true
        tabs.append(.mongoShell(state))
        activeTabID = "mongoShell:\(state.id.uuidString)"
        logWorkspaceAction("tab_opened", description: "Opened Mongo shell tab \"\(state.title)\"")
    }

 /// Contextual "New Query" (item 2): SQL when
    /// connected to a relational session, Mongo shell when connected to a Mongo
    /// data source, the JSON query surface for Qdrant/Elasticsearch (kept off
    /// a shell language — see this plan's Global Constraints), and a no-op
    /// when nothing is connected.
    public func newQueryTab() {
        if session != nil {
            newEditorTab()
        } else {
            switch dataSourceSession?.kind {
            case .document: newMongoShellTab()
            case .vector: newQdrantQueryTab()
            case .search: newElasticsearchQueryTab()
            case nil: break
            }
        }
    }

 /// Blank Qdrant query tab — the "New Query" surface for a
    /// vector connection, sibling of `newMongoShellTab()`. Collection is chosen
    /// inside the query (JSON/form), so this isn't bound to one collection.
    public func newQdrantQueryTab(rawJSON: String = "", collection: String = "", title: String? = nil) {
        let state = QdrantQueryTabState(
            title: title ?? L("Untitled"), rawJSON: rawJSON, collection: collection
        )
        state.pendingFocus = true
        tabs.append(.qdrantQuery(state))
        activeTabID = "qdrantQuery:\(state.id.uuidString)"
        logWorkspaceAction("tab_opened", description: "Opened Qdrant query tab \"\(state.title)\"")
    }

 /// Blank Elasticsearch query tab — the "New Query"
    /// surface for a search connection, sibling of `newQdrantQueryTab()`. Index
    /// is chosen inside the query JSON, so this isn't bound to one index.
    public func newElasticsearchQueryTab(rawJSON: String = "", index: String = "", title: String? = nil) {
        let state = ElasticsearchQueryTabState(
            title: title ?? L("Untitled"), rawJSON: rawJSON, index: index
        )
        state.pendingFocus = true
        tabs.append(.elasticsearchQuery(state))
        activeTabID = "elasticsearchQuery:\(state.id.uuidString)"
        logWorkspaceAction("tab_opened", description: "Opened Elasticsearch query tab \"\(state.title)\"")
    }

 /// Open a query-history entry into a *runnable* surface for the current
    /// connection — mirroring `newQueryTab()`. History always opened a SQL editor
    /// tab, which can't execute against a Mongo/Qdrant/Elasticsearch data source
    /// (no SQL session), so re-running past queries silently failed there.
    /// - SQL session: a SQL editor tab.
    /// - Mongo (`.document`): a Mongo shell tab (the entry is the verbatim script).
 /// Qdrant (`.vector`): the entry is the canonical query JSON
    ///   → a Qdrant query tab. Legacy entries were readable descriptions, not JSON;
    ///   those fall back to re-opening the referenced collection's tab by name.
    /// - Elasticsearch (`.search`): same JSON-canonical shape as Qdrant
 /// → an Elasticsearch query tab.
    public func openQueryFromHistory(_ sql: String) {
        if session != nil {
            newEditorTab(text: sql)
            return
        }
        switch dataSourceSession?.kind {
        case .document:
            newMongoShellTab(text: sql)
        case .vector:
            if let query = try? QdrantQueryScript.parse(sql) {
                newQdrantQueryTab(rawJSON: sql, title: query.collection)
            } else if let ref = collections.first(where: { sql.contains($0.name) }) {
                openCollection(ref) // legacy description-style history entry
            }
        case .search:
            if let query = try? ElasticsearchQueryScript.parse(sql) {
                newElasticsearchQueryTab(rawJSON: sql, title: query.index)
            } else if let ref = collections.first(where: { sql.contains($0.name) }) {
                openCollection(ref) // legacy description-style history entry
            }
        case nil:
            break
        }
    }

    // MARK: - NoSQL/vector: create collection

 /// Explicit collection/point-set creation
    /// called directly from `NewCollectionSheet`'s submit action, NOT through
    /// `applyDataSourceWrite`: creating a collection is schema-ish, not a
    /// destructive data change, so it skips `DataSourceDangerGuard`/the write
    /// confirmer. Returns an error message on failure, nil on success.
    public func createCollection(_ ref: CollectionRef, options: BerryDocument) async -> String? {
        guard let dataSourceSession else { return L("No connection") }
        do {
            try await dataSourceSession.connection.createCollection(ref, options: options)
            try await refreshCollections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - NoSQL/vector: write funnel (design decision #8)

    /// The single call site every `DataSourceChangeSet` write goes through
    /// (N1 sibling — SQL's equivalent funnel is `QueryService`, which has no
 /// direct analogue for `DataSourceConnection.write`): classify →
    /// render the native-command preview → confirm → apply. Returns an error
    /// message on failure, nil on success OR user cancel.
    @discardableResult
    public func applyDataSourceWrite(_ change: DataSourceChangeSet) async -> String? {
        switch await applyDataSourceWriteOutcome(change) {
        case .succeeded:
            refreshSchema()
            return nil
        case .cancelled:
            return nil
        case .failed(let message):
            return message
        }
    }

    /// Same danger-gated write path as `applyDataSourceWrite`, but distinguishes
    /// a user cancel from a real success — used by `MongoShellTabState`'s write
    /// loop so it can stop and report accurately instead of silently counting a
    /// cancelled write as succeeded.
    public func applyDataSourceWriteOutcome(_ change: DataSourceChangeSet) async -> DataSourceWriteOutcome {
        guard let dataSourceSession else { return .failed(L("No connection")) }
        let level = DataSourceDangerGuard.classify(change)
        let preview = DataSourceCommandPreview.render(change, kind: dataSourceSession.kind)
        guard await Self.dataSourceWriteConfirmer.confirm(level, preview: preview) else { return .cancelled }
        do {
            _ = try await dataSourceSession.connection.write(change)
            return .succeeded
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func dropSelectedObjects() {
        if dataSourceSession != nil {
            let names = collections.filter { selectedObjectIDs.contains($0.id) }.map(\.name)
            guard !names.isEmpty else { return }
            Task {
                for name in names {
                    if let error = await applyDataSourceWrite(.dropCollection(collection: name)) {
                        quickActionError = error
                        return
                    }
                }
            }
        } else if session != nil {
            let selected = objects.filter { selectedObjectIDs.contains($0.id) }
            guard !selected.isEmpty else { return }
            let statements = selected.map { obj -> String in
                switch obj.kind {
                case .table: return "DROP TABLE IF EXISTS \(obj.name);"
                case .view: return "DROP VIEW IF EXISTS \(obj.name);"
                case .function: return "DROP FUNCTION IF EXISTS \(obj.name);"
                case .procedure: return "DROP PROCEDURE IF EXISTS \(obj.name);"
                case .trigger: return "DROP TRIGGER IF EXISTS \(obj.name);"
                case .index: return "DROP INDEX IF EXISTS \(obj.name);"
                }
            }
            runDestructiveStatements(statements)
        }
    }

    /// Runs a fixed, non-editable Truncate/Drop statement directly from a
    /// context menu instead of opening an editor tab to review first — the
    /// statement is exactly what the menu item says, so there's nothing to
 /// review. `QueryService`'s existing DangerGuard confirm still
    /// gates each one with a native alert before anything runs; more than one
    /// statement (Drop Selected Objects) gets ONE summary confirm up front,
    /// mirroring `EditorDocument.runStatements`'s batching exactly, instead of
    /// one alert per object. The actual work is `DestructiveStatementRunner`
    /// (below) — a free function over an explicit `Session`, not `self`, so
    /// it's testable without a `WorkspaceViewModel` (see its doc comment).
    public func runDestructiveStatements(_ statements: [String], onCompleted: (() -> Void)? = nil) {
        guard let session, !statements.isEmpty else { return }
        Task {
            if let error = await DestructiveStatementRunner.run(statements, on: session) {
                quickActionError = error
            }
            refreshSchema()
            onCompleted?()
        }
    }
}

/// `WorkspaceViewModel.runDestructiveStatements`'s logic, extracted as a pure
/// function over an explicit `Session` (not `self.session`) so it's testable
/// without constructing a `WorkspaceViewModel` — every `WorkspaceViewModel`
/// init resets `QueryService.dangerConfirmer` to the real, NSAlert-based one
/// as a side effect (`wireSinks()`), which races against any other
/// concurrently-running test doing the same and can block forever on
/// `NSAlert.runModal()` in a headless test run (confirmed by reproducing it:
/// `make test` hung reliably with a `WorkspaceViewModel`-based test for this,
/// and passed reliably once rewritten against a bare `Session` instead, the
/// same way `DangerGuardTests.deniedStatementDoesNotExecute` already does).
enum DestructiveStatementRunner {
    /// Returns an error message on failure, nil on success OR user cancel
    /// (same "can't distinguish, and doesn't need to" shape as
    /// `WorkspaceViewModel.applyDataSourceWrite`).
    static func run(_ statements: [String], on session: Session) async -> String? {
        var preconfirmed = false
        if statements.count > 1, QueryService.confirmsDataDeletion, !session.isProduction {
            let destructive = statements.filter {
                if case .confirm(let reason) = DangerGuard.classify($0, isProduction: false),
                   reason.isSoftDataDeletion { return true }
                return false
            }
            if !destructive.isEmpty {
                let approved = await QueryService.dangerConfirmer?.confirm(
                    .confirm(.deleteBatch(count: destructive.count)),
                    sql: destructive.prefix(5).joined(separator: "\n")
                        + (destructive.count > 5 ? "\n…" : "")
                ) ?? true
                guard approved else { return nil }
                preconfirmed = true
            }
        }
        for statement in statements {
            do {
                for try await _ in QueryService.execute(statement, on: session, dangerPreconfirmed: preconfirmed) {}
            } catch let error as DriverError {
                if case .cancelled = error { return nil }
                return error.localizedDescription
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }
}

/// Distinguishes a user-cancelled confirmation from a real success —
/// `String?` can't do this cleanly since both cases return `nil`. Only
/// `MongoShellTabState`'s `bulkWrite` loop needs this distinction, to avoid
/// miscounting a cancelled write as succeeded when tallying a batch.
public enum DataSourceWriteOutcome: Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

extension Notification.Name {
    public static let berryDBOpenSQLFile = Notification.Name("BerryDBOpenSQLFile")
}
