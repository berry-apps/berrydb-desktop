import BerryCore
import BerryDriverKit
import BerryStore
import Foundation

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

/// User-facing approval for an AI-proposed statement.
/// Rendered inline in the AI panel: the SQL is shown with [Deny]/[Run]. Writes
/// and DDL ALWAYS prompt; a plain SELECT may auto-approve per setting.
@MainActor
public protocol AIApprovalGate {
    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool
    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool, timeoutSeconds: TimeInterval) async -> Bool
}

public extension AIApprovalGate {
    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool, timeoutSeconds: TimeInterval) async -> Bool {
        await approve(sql: sql, danger: danger, autoApprovable: autoApprovable)
    }
}

/// Snapshot of the active SQL editor tab, handed from BerryUI (which owns the
/// editor) to be serialized for `read_current_tab`.
/// Declared here because `QueryToolExecutor` serializes it; BerryUI must not leak
/// `EditorDocument`/`WorkspaceViewModel` across the one-way module boundary.
public struct ActiveTabSnapshot: Sendable {
 /// `WorkspaceTab.id` — defaulted so existing call
    /// sites that predate tab-identity exposure keep compiling unchanged.
    public let tabID: String
    public let tabTitle: String
    public let text: String
    public let cursorLocation: Int
    public let selectedRange: NSRange
    /// The pane number the UI shows for this tab (1 = top), or nil if not laid out.
    public let pane: Int?

    public init(
        tabID: String = "", tabTitle: String, text: String, cursorLocation: Int,
        selectedRange: NSRange, pane: Int? = nil
    ) {
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.text = text
        self.cursorLocation = cursorLocation
        self.selectedRange = selectedRange
        self.pane = pane
    }
}

/// The open editor/table panes for `get_open_tabs`.
/// Panes are numbered as the UI shows them (top→bottom, left→right — "1" is the
/// top pane) so the assistant can ask "which pane?" when a split is ambiguous.
public struct OpenTabsSnapshot: Sendable {
    public struct Pane: Sendable {
 /// `WorkspaceTab.id` — defaulted so existing
        /// call sites that predate tab-identity exposure keep compiling unchanged.
        public let id: String
        public let number: Int
        public let focused: Bool
        /// "editor" | "table" | "tool".
        public let kind: String
        public let title: String
        /// The editor's SQL, or nil for non-editor panes.
        public let sql: String?

        public init(id: String = "", number: Int, focused: Bool, kind: String, title: String, sql: String?) {
            self.id = id
            self.number = number
            self.focused = focused
            self.kind = kind
            self.title = title
            self.sql = sql
        }
    }

    public let panes: [Pane]
    public init(panes: [Pane]) { self.panes = panes }
}

/// Result returned by the UI-owned NoSQL execution boundary. Keeping denial
/// distinct prevents a revoked lease from being serialized as a successful
/// tool result.
public enum AIDirectStatementResult {
    case payload([String: Any])
    case denied
}

/// Runs the gateway's tool calls locally against the current `Session`, applying
/// every safety layer in: `get_schema` is metadata
/// only, `propose_sql` never runs, `run_sql` goes through `QueryService`
/// (DangerGuard + auto-LIMIT + history) behind approval and returns a ≤100-row
/// sample, and `get_sample_rows` runs only when is opted in.
@MainActor
public final class QueryToolExecutor: AIToolExecutor {
 /// Per-connection AI settings. Mutable so the panel's toggles
    /// take effect on the next tool call.
    public struct Options: Sendable {
 /// send real row data (get_sample_rows). Opt-in per connection.
        public var allowSampleRows: Bool
 /// Auto-approve plain, safe SELECTs without a prompt.
        public var autoApproveSelects: Bool

        public init(allowSampleRows: Bool = false, autoApproveSelects: Bool = true) {
            self.allowSampleRows = allowSampleRows
            self.autoApproveSelects = autoApproveSelects
        }
    }

 /// Sample of a run_sql result returned to the backend.
    private static let sampleLimit = 100
 /// Fixed cap for get_sample_rows.
    private static let sampleRowsLimit = 20
    /// Bounded list size for get_schema mode="overview" (Task 6.1/6.2): large
    /// enough for any realistic schema, small enough to keep the response —
    /// and its cache — bounded.
    private static let overviewLimit = 300
    /// Max tables per get_schema mode="ddl" call (Task 6.1) — DDL is the
    /// expensive path (one catalog.ddl(of:) round trip per table), so a
    /// single call must stay bounded even if the model asks for "everything".
    private static let ddlTableLimit = 50

    private let session: Session?
    private let catalog: SchemaCatalog?
    private let gate: any AIApprovalGate
    /// Carries an optional tab title alongside the SQL. `propose_sql` has no
    /// `title` argument by design — it writes into whatever tab is already open,
    /// where renaming would be wrong — but when no tab exists the caller has to
    /// create one, and that tab was always landing as "Untitled". The derived
    /// name is the only one available on that path.
    private let onPropose: (String, String?) -> Void
 /// Tab-aware closures. BerryUI supplies the
    /// real ones; defaults keep the DB-only tools working without a UI.
    private let readActiveTab: () -> ActiveTabSnapshot?
    private let readOpenTabs: () -> OpenTabsSnapshot?
    private let activeTabStatements: (String) -> [String]
    private let createDebugTab: (String, String?) -> Void
 /// follow-up: opens a diagram directly in its own zoomable tab
    /// same underlying action as the inline chat block's "Open in Tab"
    /// button. Without this the model's only tab-creation tool was
    /// `create_debug_tab`, whose tab type has no Mermaid rendering; reused
    /// for a diagram it just showed the raw source as plain text.
    private let openMermaidTab: (String, String?) -> Void
    /// UI-owned NoSQL boundary. The lease is intentionally passed through
    /// instead of checked only here: connection/query/write code must validate
    /// it after approval and immediately before each irreversible operation.
    private let executeStatement: (@MainActor (String, AIExecutionLease) async -> AIDirectStatementResult)?
    private let listCollections: (() -> [String])?
    public var options: Options

 /// local artifact persistence — nil `store`/
    /// `profileID` (no store configured, or no active connection profile)
    /// makes every artifact-recording call a silent no-op, since tracking an
    /// artifact is never a reason to fail the underlying tool call.
    private let store: BerryStore?
    private let profileID: UUID?
    /// Reads/writes the artifact linked to a tab (by `WorkspaceTab.id`), so
    /// repeated tool calls against the same tab accumulate versions onto one
    /// artifact instead of creating a new one each time.
    private let resolveArtifactID: (String) -> UUID?
    private let linkArtifact: (String, UUID) -> Void
    /// Groups repeated `run_sql` calls with no open tab (e.g. the agent
    /// iterating on a fix without ever creating a debug tab) onto one
    /// traceable artifact for this executor's lifetime (one connection
    /// session), instead of each call looking like an unrelated one-off.
    private var adHocArtifactID: UUID?

    /// Task 6.2 — overview cache, keyed by a content digest of the current
    /// object list. `catalog` is `let` and AIPanelController.bind() always
    /// builds a brand-new QueryToolExecutor on a genuine connection switch
    /// (its `sameConnection` early-return leaves the existing executor, and
    /// therefore this cache, in place for schema-only refreshes on the SAME
    /// connection) — so one executor instance already scopes to exactly one
    /// connection and the digest alone is a sufficient cache key.
    private struct OverviewCache {
        let digest: String
        let entries: [[String: String]]
    }

    /// Sendable result of one overview fetch — crosses the `overviewInFlight`
    /// Task boundary, so it's a plain `[String: String]` payload rather than
    /// `[String: Any]` (which Swift can't statically prove Sendable).
    private struct OverviewFetch: Sendable {
        let digest: String
        let entries: [[String: String]]
    }

    private var overviewCache: OverviewCache?
    /// De-dupes concurrent get_schema(overview) callers onto a single
    /// `catalog.objects()` fetch + transform instead of one each.
    private var overviewInFlight: Task<OverviewFetch, Error>?
    /// Test-only visibility into cache rebuilds — proves cache-hit and
    /// invalidation behavior in QueryToolExecutorTests. Not part of the
    /// public tool-execution API.
    private(set) var overviewBuildCount = 0
    /// Test-only visibility into how many *new* fetch Tasks were started
    /// (as opposed to joining `overviewInFlight`) — proves concurrent-dedup
    /// specifically, independent of `overviewBuildCount` (which the digest
    /// cache alone could also hold at 1 even without dedup, since redundant
    /// fetches of an unchanged schema all produce the same digest).
    private(set) var overviewFetchCount = 0

    private let executionDeadlineSeconds: TimeInterval?

    public init(
        session: Session? = nil,
        catalog: SchemaCatalog? = nil,
        gate: any AIApprovalGate,
        options: Options = Options(),
        onPropose: @escaping (String, String?) -> Void,
        readActiveTab: @escaping () -> ActiveTabSnapshot? = { nil },
        readOpenTabs: @escaping () -> OpenTabsSnapshot? = { nil },
        activeTabStatements: @escaping (String) -> [String] = { _ in [] },
        createDebugTab: @escaping (String, String?) -> Void = { _, _ in },
        openMermaidTab: @escaping (String, String?) -> Void = { _, _ in },
        executeStatement: (@MainActor (String, AIExecutionLease) async -> AIDirectStatementResult)? = nil,
        listCollections: (() -> [String])? = nil,
        store: BerryStore? = nil,
        profileID: UUID? = nil,
        resolveArtifactID: @escaping (String) -> UUID? = { _ in nil },
        linkArtifact: @escaping (String, UUID) -> Void = { _, _ in },
        /// Test-only override for `aiQueryTimeoutSeconds`'s default — a real
        /// 90s wait isn't practical in a test.
        queryTimeoutSeconds: TimeInterval = 90,
        executionDeadlineSeconds: TimeInterval? = 110
    ) {
        self.session = session
        self.catalog = catalog
        self.gate = gate
        self.options = options
        self.onPropose = onPropose
        self.readActiveTab = readActiveTab
        self.readOpenTabs = readOpenTabs
        self.activeTabStatements = activeTabStatements
        self.createDebugTab = createDebugTab
        self.openMermaidTab = openMermaidTab
        self.store = store
        self.profileID = profileID
        self.resolveArtifactID = resolveArtifactID
        self.linkArtifact = linkArtifact
        self.executeStatement = executeStatement
        self.listCollections = listCollections
        self.aiQueryTimeoutSeconds = queryTimeoutSeconds
        self.executionDeadlineSeconds = executionDeadlineSeconds
    }

 /// The tools this executor advertises to the gateway.
    public var toolSpecs: [AIToolSpec] {
        if session == nil {
            return [
                AIToolSpec(
                    name: "get_schema",
                    description: "Return the list of collection names in the active database.",
                    parametersJSON: #"{"type":"object","properties":{}}"#
                ),
                AIToolSpec(
                    name: "propose_query",
                    description: "Put MongoDB shell / NoSQL query script into the user's active query editor tab without executing it (automatically creates a new query tab if none is open). ALWAYS call this tool whenever writing, generating, or updating a query for the user.",
                    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"The MongoDB shell query script (e.g. db.users.insertMany(...))."}},"required":["query"]}"#
                ),
                AIToolSpec(
                    name: "read_current_tab",
                    description: "Return the FOCUSED query tab's title, script text, cursor position and selection.",
                    parametersJSON: #"{"type":"object","properties":{}}"#
                ),
                AIToolSpec(
                    name: "get_open_tabs",
                    description: "List the user's open panes, numbered as shown in the UI (1 = top pane), each with its kind, title, focus, and query script. Call this when the user says \"this query/tab\" and more than one editor pane is open.",
                    parametersJSON: #"{"type":"object","properties":{}}"#
                ),
                AIToolSpec(
                    name: "run_tab_statements",
                    description: "Run the statements in the open Mongo shell query tab (all, the selection, or the one under the cursor).",
                    parametersJSON: #"{"type":"object","properties":{"which":{"type":"string","enum":["all","selection","cursor"],"description":"Which statements to run."}},"required":["which"]}"#
                ),
                AIToolSpec(
                    name: "create_debug_tab",
                    description: "Open a new query tab containing the given MongoDB shell query script.",
                    parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string","description":"The query script."},"query":{"type":"string","description":"The query script."},"title":{"type":"string"}}}"#
                ),
                AIToolSpec(
                    name: "open_mermaid_tab",
                    description: "Open a Mermaid diagram in its own dedicated tab with zoom/pan controls — use for a diagram too large or dense to read well inline, or when the user asks to view a diagram in its own tab. This only opens the tab; it does not also render the diagram inline in your reply, so still include it as a ```mermaid fenced block in your reply if you want that too.",
                    parametersJSON: #"{"type":"object","properties":{"diagram":{"type":"string","description":"Valid Mermaid diagram source."},"title":{"type":"string"}},"required":["diagram"]}"#
                ),
                AIToolSpec(
                    name: "get_artifact",
                    description: "Look up a durable artifact (a query/tab this agent previously created or ran) by id — its title, kind, and the payload/result of its latest run, or a specific version if requested.",
                    parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"}},"required":["artifact_id"]}"#
                ),
                AIToolSpec(
                    name: "get_artifact_overview",
                    description: "Cheap first look at a large artifact before reading it: payload size and how many chunks read_artifact_chunk needs to cover it, without the content itself. Call this first if get_artifact might return too much (e.g. a run_tab_statements artifact with many statements).",
                    parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"}},"required":["artifact_id"]}"#
                ),
                AIToolSpec(
                    name: "read_artifact_chunk",
                    description: "Read one bounded chunk of a large artifact's result (one chunk per statement for a multi-statement run) — loop chunk_index from 0 to total_chunks-1 to read all of it without truncation.",
                    parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"},"chunk_index":{"type":"integer"}},"required":["artifact_id","chunk_index"]}"#
                ),
            ]
        }
        return [
            AIToolSpec(name: "get_schema", description: "Return schema metadata. Call with no arguments (or mode=\"overview\") first — it returns every known table/view's name and kind, no DDL, cheap. Only call mode=\"ddl\" for the specific tables you actually need (pass 'tables'); it returns their full CREATE statements.", parametersJSON: #"{"type":"object","properties":{"mode":{"type":"string","enum":["overview","ddl"],"description":"\"overview\" (default): names and kinds only, no DDL. \"ddl\": full CREATE statements for 'tables'."},"tables":{"type":"array","items":{"type":"string"},"description":"Table/view names to fetch DDL for. Required when mode is \"ddl\" (max 50 per call); ignored otherwise."}}}"#),
            AIToolSpec(name: "propose_sql", description: "Put SQL or NoSQL query into the user's active query editor tab without executing it (automatically creates a new query tab if none is open). Use this tool whenever writing, generating, or updating a query for the user.", parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}"#),
            AIToolSpec(name: "run_sql", description: "Run one SQL statement through the approval gate and return up to 100 sampled rows.", parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"}},"required":["sql"]}"#),
            AIToolSpec(name: "get_sample_rows", description: "Return a few example rows from a table (only when the user has opted in).", parametersJSON: #"{"type":"object","properties":{"table":{"type":"string"}},"required":["table"]}"#),
            AIToolSpec(name: "read_current_tab", description: "Return the FOCUSED SQL editor tab's title, text, cursor position and selection.", parametersJSON: #"{"type":"object","properties":{}}"#),
            AIToolSpec(name: "get_open_tabs", description: "List the user's open panes, numbered as shown in the UI (1 = top pane), each with its kind (editor/table/tool), title, focus, and the editor's SQL. Call this when the user says \"this query/tab\" and more than one editor pane is open, then ask which pane number they mean.", parametersJSON: #"{"type":"object","properties":{}}"#),
            AIToolSpec(name: "run_tab_statements", description: "Run the statements in the open SQL tab (all, the selection, or the one under the cursor), each through the approval gate.", parametersJSON: #"{"type":"object","properties":{"which":{"type":"string","enum":["all","selection","cursor"],"description":"Which statements to run."}},"required":["which"]}"#),
            AIToolSpec(name: "explain_query", description: "EXPLAIN the statement under the cursor and return the query plan tree.", parametersJSON: #"{"type":"object","properties":{"analyze":{"type":"boolean","description":"Use EXPLAIN ANALYZE (actually runs the statement)."}}}"#),
            AIToolSpec(name: "create_debug_tab", description: "Open a new SQL editor tab containing the given SQL.", parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"},"title":{"type":"string"}},"required":["sql"]}"#),
            AIToolSpec(name: "open_mermaid_tab", description: "Open a Mermaid diagram in its own dedicated tab with zoom/pan controls — use for a diagram too large or dense to read well inline, or when the user asks to view a diagram in its own tab. This only opens the tab; it does not also render the diagram inline in your reply, so still include it as a ```mermaid fenced block in your reply if you want that too.", parametersJSON: #"{"type":"object","properties":{"diagram":{"type":"string","description":"Valid Mermaid diagram source."},"title":{"type":"string"}},"required":["diagram"]}"#),
            AIToolSpec(name: "get_artifact", description: "Look up a durable artifact (a query/tab this agent previously created or ran) by id — its title, kind, and the payload/result of its latest run, or a specific version if requested.", parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"}},"required":["artifact_id"]}"#),
            AIToolSpec(name: "get_artifact_overview", description: "Cheap first look at a large artifact before reading it: payload size and how many chunks read_artifact_chunk needs to cover it, without the content itself. Call this first if get_artifact might return too much (e.g. a run_tab_statements artifact with many statements).", parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"}},"required":["artifact_id"]}"#),
            AIToolSpec(name: "read_artifact_chunk", description: "Read one bounded chunk of a large artifact's result (one chunk per statement for a multi-statement run) — loop chunk_index from 0 to total_chunks-1 to read all of it without truncation.", parametersJSON: #"{"type":"object","properties":{"artifact_id":{"type":"string"},"version_number":{"type":"integer"},"chunk_index":{"type":"integer"}},"required":["artifact_id","chunk_index"]}"#),
        ]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await execute(call, lease: .alwaysValid())
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return switch call.name {
        case "get_schema": await getSchema(tables: call.args["tables"], mode: call.args["mode"], lease: lease)
        case "propose_sql", "propose_query": propose(call.args["query"] ?? call.args["sql"], lease: lease)
        case "run_sql": await runSQL(call.args["sql"], lease: lease)
        case "get_sample_rows": await sampleRows(table: call.args["table"], lease: lease)
        case "read_current_tab": readCurrentTab()
        case "get_open_tabs": openTabsList()
        case "run_tab_statements": await runTabStatements(which: call.args["which"], lease: lease)
        case "explain_query": await explainQuery(analyze: call.args["analyze"] == "true", lease: lease)
        case "create_debug_tab": createDebugTabTool(sql: call.args["sql"], title: call.args["title"], lease: lease)
        case "open_mermaid_tab": openMermaidTabTool(diagram: call.args["diagram"], title: call.args["title"], lease: lease)
        case "get_artifact": getArtifact(artifactID: call.args["artifact_id"], versionNumber: call.args["version_number"])
        case "get_artifact_overview": getArtifactOverview(artifactID: call.args["artifact_id"], versionNumber: call.args["version_number"])
        case "read_artifact_chunk": readArtifactChunk(
            artifactID: call.args["artifact_id"], versionNumber: call.args["version_number"], chunkIndex: call.args["chunk_index"]
        )
        default: .failed("Unknown tool '\(call.name)'")
        }
    }

    // MARK: - get_schema (metadata only, no DB read of rows)

    /// mode="overview" (default, and any unrecognized mode — backward
    /// compatible with callers still sending the pre-Task-6.1 shape with no
    /// mode at all): bounded {name, kind} list, no DDL. mode="ddl": full
    /// CREATE statements, but only for the explicit, bounded `tables` list.
    private func getSchema(tables filter: String?, mode: String?, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        if let catalog {
            let normalizedMode = (mode ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            do {
                if normalizedMode == "ddl" {
                    return try await getSchemaDDL(tables: filter, catalog: catalog, lease: lease)
                }
                return try await getSchemaOverview(catalog: catalog, lease: lease)
            } catch {
                guard lease.isValid else { return .denied }
                return .failed(error.localizedDescription)
            }
        } else if let listCollections {
            guard lease.isValid else { return .denied }
            let cols = listCollections()
            guard lease.isValid else { return .denied }
            return .ok(Self.json(["collections": cols]))
        }
        return .failed("Schema catalog unavailable for this connection")
    }

    /// Task 6.2: cached by a digest of the current object list, so repeated
    /// overview calls on an unchanged schema skip rebuilding the payload. A
    /// changed digest (new/dropped table, or an explicit `catalog.invalidate()`
    /// schema refresh) always wins over the cache since the digest itself is
    /// recomputed from a fresh `catalog.objects()` fetch every call.
    private func getSchemaOverview(catalog: SchemaCatalog, lease: AIExecutionLease) async throws -> ToolOutcome {
        let fetch = try await overviewEntries(catalog: catalog)
        guard lease.isValid else { return .denied }
        let entries: [[String: String]]
        if let cache = overviewCache, cache.digest == fetch.digest {
            entries = cache.entries
        } else {
            entries = fetch.entries
            overviewCache = OverviewCache(digest: fetch.digest, entries: fetch.entries)
            overviewBuildCount += 1
        }
        return .ok(Self.json(["objects": entries]))
    }

    /// Fetches the current object list once and builds the bounded overview
    /// payload, shared across concurrent callers via `overviewInFlight` so N
    /// simultaneous get_schema(overview) calls cause exactly one
    /// `catalog.objects()` round trip instead of N (Task 6.2). The task body
    /// captures no MainActor-isolated state (only the Sendable `catalog`
    /// actor and a local `Int`), so it needs no isolation of its own.
    private func overviewEntries(catalog: SchemaCatalog) async throws -> OverviewFetch {
        if let inFlight = overviewInFlight {
            return try await inFlight.value
        }
        overviewFetchCount += 1
        let limit = Self.overviewLimit
        let task = Task { () async throws -> OverviewFetch in
            let objects = try await catalog.objects()
            let relational = objects
                .filter { $0.kind == .table || $0.kind == .view }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let digest = relational.map { "\($0.kind.rawValue):\($0.database ?? "").\($0.name)" }.joined(separator: "\n")
            let bounded = relational.prefix(limit)
            let entries = bounded.map { ["name": $0.name, "kind": $0.kind.rawValue, "schema": $0.database ?? ""] }
            return OverviewFetch(digest: digest, entries: entries)
        }
        overviewInFlight = task
        defer { overviewInFlight = nil }
        return try await task.value
    }

    /// mode="ddl": full DDL, but only for the explicit `tables` list (bounded
    /// by `ddlTableLimit`) — never the whole catalog in one call. A name that
    /// matches no known table/view is skipped silently (same "no entry, no
    /// error" convention the old unfiltered path already used).
    private func getSchemaDDL(tables filter: String?, catalog: SchemaCatalog, lease: AIExecutionLease) async throws -> ToolOutcome {
        let wanted = Self.parseTableFilter(filter)
        guard !wanted.isEmpty else {
            return .failed("get_schema mode \"ddl\" requires a non-empty 'tables' list")
        }
        guard wanted.count <= Self.ddlTableLimit else {
            return .failed("get_schema mode \"ddl\" supports at most \(Self.ddlTableLimit) tables per call")
        }
        let objects = try await catalog.objects()
        guard lease.isValid else { return .denied }
        let matches = objects
            .filter {
                ($0.kind == .table || $0.kind == .view)
                    && (wanted.contains($0.name.lowercased())
                        || wanted.contains("\($0.database ?? "").\($0.name)".lowercased()))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var entries: [[String: Any]] = []
        for object in matches {
            guard lease.isValid else { return .denied }
            let ddl = (try? await catalog.ddl(of: object)) ?? ""
            guard lease.isValid else { return .denied }
            entries.append(["name": object.name, "kind": object.kind.rawValue, "ddl": ddl])
        }
        guard lease.isValid else { return .denied }
        return .ok(Self.json(["objects": entries]))
    }

    /// Array-shaped tool args arrive as a comma-joined string in this file's
    /// convention (see `execute`'s dispatch) — matches the pre-Task-6.1
    /// `tables` parsing exactly.
    private static func parseTableFilter(_ filter: String?) -> Set<String> {
        Set((filter ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    public static func parseTableRef(_ input: String, in objects: [SchemaObject]) -> Result<TableRef, String> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(".") {
            let parts = trimmed.split(separator: ".", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,() "))
            }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                return .success(TableRef(database: parts[0], name: parts[1]))
            }
        }
        let cleanName = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,() "))
        let matching = objects.filter {
            ($0.kind == .table || $0.kind == .view)
                && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }
        if matching.count == 1 {
            return .success(TableRef(database: matching[0].database, name: matching[0].name))
        } else if matching.count > 1 {
            let schemas = matching.compactMap(\.database).sorted().joined(separator: ", ")
            return .failure("Table '\(cleanName)' is ambiguous across schemas (\(schemas)). Please specify schema qualification (e.g. '\(matching[0].database ?? "schema").\(cleanName)').")
        }
        return .success(TableRef(name: cleanName))
    }

    // MARK: - propose_sql (harmless — inserts into the editor, never runs)

    private func propose(_ sql: String?, lease: AIExecutionLease) -> ToolOutcome {
        guard let sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("propose_sql requires 'sql'")
        }
        guard lease.isValid else { return .denied }
        onPropose(sql, Self.tabTitle(explicit: nil, sql: sql))
        return .ok(Self.json(tabResultPayload(["proposed": true])))
    }

 /// Folds the tab identity `readActiveTab()` now reports
 /// into a propose_sql/create_debug_tab JSON result, so the
    /// assistant can say "created query in tab {xxx}" and reference it
    /// correctly on a later turn. Best-effort: a nil snapshot (e.g. the
    /// mutation landed in a tab kind `readActiveTab()` doesn't cover, such as
    /// Qdrant) just omits these fields rather than failing the tool call.
    private func tabResultPayload(_ base: [String: Any]) -> [String: Any] {
        guard let snapshot = readActiveTab() else { return base }
        var payload = base
        payload["tab_id"] = snapshot.tabID
        payload["tab_title"] = snapshot.tabTitle
        if let pane = snapshot.pane { payload["pane"] = pane }
 // the tab now holds whatever propose_sql/create_debug_tab just
        // wrote — record that as the artifact's next version so the bubble
        // can link to it and it survives a history reload.
        if let kind = Self.artifactKind(forTabID: snapshot.tabID),
           let recorded = recordArtifactVersion(
               kind: kind, title: snapshot.tabTitle, tabID: snapshot.tabID, payload: snapshot.text
           ) {
            payload["artifact_id"] = recorded.artifactID.uuidString
            payload["artifact_version"] = recorded.versionNumber
        }
        return payload
    }

    /// Called with partial SQL fragments as the LLM streams the `propose_sql`
    /// argument in real-time, so the editor tab updates character-by-character.
    public func streamPropose(_ partialSQL: String) {
        guard !partialSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Streaming fragments carry no title: the tab already exists by the time
        // the first fragment lands, and a half-written statement would derive a
        // misleading name from an incomplete FROM clause.
        onPropose(partialSQL, nil)
    }

    // MARK: - run_sql (approval → QueryService → ≤100-row sample)

    private func runSQL(_ sql: String?, lease: AIExecutionLease) async -> ToolOutcome {
        guard let sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("run_sql requires 'sql'")
        }
        let startTime = Date()
        let maxDuration = executionDeadlineSeconds
        let durationLabel = (maxDuration ?? 110) > 0 ? "\(Int(maxDuration ?? 110))s" : "110s"
        if let maxDuration, Date().timeIntervalSince(startTime) >= maxDuration {
            return .failed("Execution stopped: tool deadline (\(durationLabel)) exceeded")
        }
        let remainingForApproval = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
        guard await approve(sql, timeoutSeconds: remainingForApproval) else { return .denied }
        guard lease.isValid else { return .denied }

        let remainingForQuery = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
        if let remaining = remainingForQuery, remaining <= 0 {
            return .failed("Execution stopped: tool deadline (\(durationLabel)) exceeded")
        }

        do {
            var payload = try await drainSample(sql, lease: lease, timeoutOverrideSeconds: remainingForQuery)
            recordRunSQLArtifact(sql: sql, into: &payload)
            return .ok(Self.json(payload))
        }
        catch is CancellationError { return .denied }
        catch {
            guard lease.isValid else { return .denied }
            return .failed(error.localizedDescription)
        }
    }

 // MARK: - get_sample_rows (opt-in; the opt-in is the consent)

    private func sampleRows(table name: String?, lease: AIExecutionLease) async -> ToolOutcome {
        guard options.allowSampleRows else { return .denied }
        guard let session else { return .failed("Sample rows unavailable for this connection") }
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("get_sample_rows requires 'table'")
        }
        let objects = (try? await catalog?.objects()) ?? []
        guard lease.isValid else { return .denied }
        let tableRef: TableRef
        switch Self.parseTableRef(name, in: objects) {
        case .success(let ref):
            tableRef = ref
        case .failure(let error):
            return .failed(error)
        }
        let sql = session.dialect.select(
            from: tableRef, whereClause: nil, orderBy: nil, limit: Self.sampleRowsLimit
        )
        guard lease.isValid else { return .denied }
        do { return .ok(Self.json(try await drainSample(sql, lease: lease, timeoutOverrideSeconds: executionDeadlineSeconds))) }
        catch is CancellationError { return .denied }
        catch {
            guard lease.isValid else { return .denied }
            return .failed(error.localizedDescription)
        }
    }

 // MARK: - SQL-tab tools

 /// snapshot of the open editor tab. Metadata only, no DB access.
    private func readCurrentTab() -> ToolOutcome {
        guard let snapshot = readActiveTab() else {
            return .failed("No SQL editor tab is currently active")
        }
        var object: [String: Any] = [
            "tab_id": snapshot.tabID,
            "tab_title": snapshot.tabTitle,
            "text": snapshot.text,
            "cursor_location": snapshot.cursorLocation,
            "selected_range": ["location": snapshot.selectedRange.location, "length": snapshot.selectedRange.length],
        ]
        if let pane = snapshot.pane { object["pane"] = pane }
        return .ok(Self.json(object))
    }

    /// List every open pane, numbered as the UI shows them, so the assistant can
 /// disambiguate a split before acting.
    private func openTabsList() -> ToolOutcome {
        let panes = readOpenTabs()?.panes ?? []
        let serialized = panes.map { pane -> [String: Any] in
            var object: [String: Any] = [
                "tab_id": pane.id,
                "pane": pane.number,
                "focused": pane.focused,
                "kind": pane.kind,
                "title": pane.title,
            ]
            if let sql = pane.sql { object["sql"] = sql }
            return object
        }
        return .ok(Self.json([
            "pane_count": panes.count,
            "focused_pane": panes.first(where: { $0.focused })?.number ?? 0,
            "panes": serialized,
        ]))
    }

 /// run the tab's statements for `which` ("all"|"selection"|"cursor"),
    /// each through the same DangerGuard→approval→QueryService chain as run_sql —
    /// no shortcut past approval, and stop at the first denial or error.
    private func runTabStatements(which: String?, lease: AIExecutionLease) async -> ToolOutcome {
        let mode = which ?? "all"
        let statements = activeTabStatements(mode)
        guard !statements.isEmpty else {
            return .failed("No statements found for run mode '\(mode)'")
        }
        var results: [[String: Any]] = []
        var stoppedEarly = false
        let startTime = Date()
        let maxDuration = executionDeadlineSeconds
        let durationLabel = (maxDuration ?? 110) > 0 ? "\(Int(maxDuration ?? 110))s" : "110s"
        for sql in statements {
            if let maxDuration, Date().timeIntervalSince(startTime) >= maxDuration {
                stoppedEarly = true
                results.append(["sql": sql, "error": "Execution stopped: tool deadline (\(durationLabel)) exceeded"])
                break
            }
            let remainingForApproval = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
            guard await approve(sql, timeoutSeconds: remainingForApproval) else { stoppedEarly = true; break }
            if let maxDuration, Date().timeIntervalSince(startTime) >= maxDuration {
                stoppedEarly = true
                results.append(["sql": sql, "error": "Execution stopped: tool deadline (\(durationLabel)) exceeded"])
                break
            }
            guard lease.isValid else { return .denied }

            let remainingForQuery = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
            if let remaining = remainingForQuery, remaining <= 0 {
                stoppedEarly = true
                results.append(["sql": sql, "error": "Execution stopped: tool deadline (\(durationLabel)) exceeded"])
                break
            }

            do {
                var payload = try await drainSample(sql, lease: lease, timeoutOverrideSeconds: remainingForQuery)
                payload["sql"] = sql
                results.append(payload)
            } catch is CancellationError {
                return .denied
            } catch {
                guard lease.isValid else { return .denied }
                stoppedEarly = true
                results.append(["sql": sql, "error": error.localizedDescription])
                break
            }
        }
        var outcome: [String: Any] = ["statements": results, "stopped_early": stoppedEarly]
        recordRunTabStatementsArtifact(statements: statements, results: results, into: &outcome)
        return .ok(Self.json(outcome))
    }

 /// EXPLAIN the statement under the cursor as a PlanNode tree. Always
    /// asks (EXPLAIN ANALYZE actually runs the statement); classifies the original
    /// SQL so the danger level is real. Keeps raw columns/rows for the tree parser.
    private func explainQuery(analyze: Bool, lease: AIExecutionLease) async -> ToolOutcome {
        guard let session else { return .failed("EXPLAIN unavailable for this connection") }
        let statements = activeTabStatements("cursor")
        guard let sql = statements.first, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("No statement under the cursor to explain")
        }
        let danger = DangerGuard.classify(sql, isProduction: session.isProduction)
        // Same reasoning as `approve(_:)` above: a `.typedConfirm`
        // can't be satisfied by the chat's Deny/Run-only card, and letting
        // it through to QueryService's `dangerPreconfirmed: true` call below
        // would surface a second, invisible, blocking NSAlert instead.
        if case .typedConfirm = danger { return .denied }

        let startTime = Date()
        let maxDuration = executionDeadlineSeconds
        let durationLabel = (maxDuration ?? 110) > 0 ? "\(Int(maxDuration ?? 110))s" : "110s"
        if let maxDuration, Date().timeIntervalSince(startTime) >= maxDuration {
            return .failed("Execution stopped: tool deadline (\(durationLabel)) exceeded")
        }

        let remainingForApproval = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
        guard await gate.approve(sql: sql, danger: danger, autoApprovable: false, timeoutSeconds: remainingForApproval ?? 110) else { return .denied }
        guard lease.isValid else { return .denied }

        let remainingForQuery = maxDuration.map { max(0, $0 - Date().timeIntervalSince(startTime)) }
        if let remaining = remainingForQuery, remaining <= 0 {
            return .failed("Execution stopped: tool deadline (\(durationLabel)) exceeded")
        }

        let explainSQL = "\(session.dialect.explainPrefix(analyze: analyze)) \(sql)"
        do {
            let result = try await drainExplain(explainSQL, session: session, lease: lease, timeoutOverrideSeconds: remainingForQuery)
            return .ok(Self.json(result))
        } catch is CancellationError {
            return .denied
        } catch {
            guard lease.isValid else { return .denied }
            return .failed(error.localizedDescription)
        }
    }

    final class ResultBox: @unchecked Sendable {
        let payload: [String: Any]
        init(_ payload: [String: Any] = [:]) { self.payload = payload }
    }

    /// Races an async operation against a timeout without blocking the caller on
    /// cancellation when child tasks are stuck on wedged sockets or non-cooperative loops.
    final class UnstoppableTimeoutRace: @unchecked Sendable {
        private let lock = NSLock()
        private var isResolved = false
        private var continuation: CheckedContinuation<ResultBox, any Error>?
        private var workTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?

        static func run(
            timeoutSeconds: TimeInterval,
            timeoutError: any Error,
            work: @escaping @MainActor () async throws -> ResultBox
        ) async throws -> ResultBox {
            try Task.checkCancellation()

            let raceBox = RaceHolder()
            let box = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResultBox, any Error>) in
                    let race = UnstoppableTimeoutRace(continuation: continuation)
                    let shouldStart = raceBox.setRace(race)
                    guard shouldStart else {
                        race.cancel()
                        return
                    }
                    race.start(timeoutSeconds: timeoutSeconds, timeoutError: timeoutError, work: work)
                }
            } onCancel: {
                raceBox.cancel()
            }
            return box
        }

        init(continuation: CheckedContinuation<ResultBox, any Error>) {
            self.continuation = continuation
        }

        func cancel() {
            resolve(with: .failure(CancellationError()))
        }

        func start(
            timeoutSeconds: TimeInterval,
            timeoutError: any Error,
            work: @escaping @MainActor () async throws -> ResultBox
        ) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            let workTask = Task { @MainActor in
                do {
                    let result = try await work()
                    self.resolve(with: .success(result))
                } catch {
                    self.resolve(with: .failure(error))
                }
            }
            self.workTask = workTask

            let timeoutTask = Task {
                let nanos = UInt64(max(0, timeoutSeconds) * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanos)
                } catch {
                    return
                }
                workTask.cancel()
                self.resolve(with: .failure(timeoutError))
            }
            self.timeoutTask = timeoutTask
            lock.unlock()
        }

        private func resolve(with result: Result<ResultBox, any Error>) {
            lock.lock()
            guard !isResolved else {
                lock.unlock()
                return
            }
            isResolved = true
            let cont = continuation
            continuation = nil
            let tTask = timeoutTask
            let wTask = workTask
            lock.unlock()

            tTask?.cancel()
            if case .failure = result {
                wTask?.cancel()
            }
            cont?.resume(with: result)
        }
    }

    final class RaceHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _race: UnstoppableTimeoutRace?
        private var _isCancelled = false

        func setRace(_ race: UnstoppableTimeoutRace) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if _isCancelled {
                return false
            }
            _race = race
            return true
        }

        func cancel() {
            lock.lock()
            _isCancelled = true
            let r = _race
            lock.unlock()
            r?.cancel()
        }
    }

    private func drainExplain(
        _ explainSQL: String,
        session: Session,
        lease: AIExecutionLease,
        timeoutOverrideSeconds: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard lease.isValid else { throw CancellationError() }
        let effectiveTimeout: TimeInterval
        if let timeoutOverrideSeconds {
            effectiveTimeout = min(aiQueryTimeoutSeconds, max(0, timeoutOverrideSeconds))
        } else {
            effectiveTimeout = aiQueryTimeoutSeconds
        }

        let timeoutLabel = effectiveTimeout < 1 && effectiveTimeout > 0 ? String(format: "%.1f", effectiveTimeout) : "\(Int(ceil(effectiveTimeout)))"
        let timeoutError = DriverError.queryFailed(
            message: "Query timed out after \(timeoutLabel)s — the connection may be stuck; try reconnecting.",
            code: nil
        )

        let box = try await UnstoppableTimeoutRace.run(timeoutSeconds: effectiveTimeout, timeoutError: timeoutError) {
            guard lease.isValid else { throw CancellationError() }
            var columnMetas: [ColumnMeta] = []
            var rawRows: [[BerryValue]] = []
            // Same double-gate as drainSample below: `gate.approve` above
            // already classified and confirmed the raw `sql` via the chat
            // card, so QueryService must not re-confirm the wrapped
            // EXPLAIN statement through its own blocking native alert.
            for try await event in QueryService.execute(explainSQL, on: session, autoLimit: nil, dangerPreconfirmed: true) {
                try Task.checkCancellation()
                guard lease.isValid else { throw CancellationError() }
                switch event {
                case let .columns(metas): columnMetas = metas
                case let .rows(batch): rawRows.append(contentsOf: batch)
                case .complete: break
                }
            }
            try Task.checkCancellation()
            guard lease.isValid else { throw CancellationError() }
            if let plan = ExplainTreeParser.parse(columns: columnMetas, rows: rawRows) {
                return ResultBox(["plan": Self.planJSON(plan)])
            }
            // Unrecognized EXPLAIN shape → raw grid, same shape as run_sql.
            return ResultBox([
                "columns": columnMetas.map(\.name),
                "rows": rawRows.map { $0.map(Self.jsonValue) },
            ])
        }
        return box.payload
    }

 /// create a fresh debug tab with the given SQL (never reuses a tab).
    private func createDebugTabTool(sql: String?, title: String?, lease: AIExecutionLease) -> ToolOutcome {
        guard let sql, !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("create_debug_tab requires 'sql'")
        }
        guard lease.isValid else { return .denied }
        createDebugTab(sql, Self.tabTitle(explicit: title, sql: sql))
        return .ok(Self.json(tabResultPayload(["created": true])))
    }

 /// follow-up. No `tabResultPayload`/artifact-linking here (unlike
    /// `createDebugTabTool` above) — `readActiveTab()`/`artifactKind(forTabID:)`
    /// only understand the SQL/Mongo/Qdrant editor tab kinds, and a Mermaid
    /// tab has no query text or run result to track as an artifact version.
    private func openMermaidTabTool(diagram: String?, title: String?, lease: AIExecutionLease) -> ToolOutcome {
        guard let diagram, !diagram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("open_mermaid_tab requires 'diagram'")
        }
        guard lease.isValid else { return .denied }
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        openMermaidTab(diagram, resolvedTitle?.isEmpty == false ? resolvedTitle : nil)
        return .ok(Self.json(["created": true]))
    }

    /// The model's own title if it sent one, otherwise a name derived from the
    /// statement.
    ///
    /// Every agent-created tab was landing as "Untitled", so a turn opening
    /// several left them indistinguishable. `title` is required by the backend
    /// schema now, but a model can still omit it, and the SQL itself names its
    /// own subject — the primary table is a far better label than a generic one.
    static func tabTitle(explicit: String?, sql: String) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }
        // First identifier after FROM/INTO/UPDATE/TABLE — the statement's subject
        // in every shape that reaches this tool. Nil rather than a guess when
        // nothing matches, so the caller's own default still applies.
        let pattern = #"(?i)\b(?:from|into|update|table)\s+([a-z_][\w."]*)"#
        guard let match = sql.range(of: pattern, options: .regularExpression) else { return nil }
        let clause = sql[match]
        guard let name = clause.split(whereSeparator: \.isWhitespace).last else { return nil }
        return String(name)
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ";,()"))
    }

 // MARK: - Artifacts

 /// `WorkspaceTab.id` is `"<prefix>:<uuid>"` — the prefix
    /// alone says which query/tab kind a tab is, without this package needing
    /// to see `WorkspaceTab` itself (BerryAI must not import BerryUI). Nil
    /// for every other tab kind (table/collection/tool/alterTable), which
    /// these tools never create or run into.
    private static func artifactKind(forTabID tabID: String) -> Artifact.Kind? {
        if tabID.hasPrefix("editor:") { return .editorTab }
        if tabID.hasPrefix("mongoShell:") { return .mongoShell }
        if tabID.hasPrefix("qdrantQuery:") { return .qdrantQuery }
        return nil
    }

    /// Resolves the artifact linked to `tabID` (creating and linking a new
    /// one if it isn't linked yet) and appends `payload`/`resultSnapshotJSON`
    /// as its next version. A no-op (nil) whenever `store`/`profileID` aren't
    /// configured — artifact tracking is best-effort, never a reason to fail
    /// the underlying tool call.
    private func recordArtifactVersion(
        kind: Artifact.Kind, title: String, tabID: String, payload: String, resultSnapshotJSON: String? = nil
    ) -> (artifactID: UUID, versionNumber: Int)? {
        guard let store, let profileID else { return nil }
        let artifactID: UUID
        if let existing = resolveArtifactID(tabID) {
            artifactID = existing
        } else {
            let artifact = Artifact(profileID: profileID, kind: kind, title: title)
            guard (try? store.saveArtifact(artifact)) != nil else { return nil }
            artifactID = artifact.id
            linkArtifact(tabID, artifactID)
        }
        guard let version = try? store.appendArtifactVersion(
            artifactID: artifactID, payload: payload, resultSnapshotJSON: resultSnapshotJSON
        ) else { return nil }
        return (artifactID, version.versionNumber)
    }

    /// Same as `recordArtifactVersion`, but for a run with no open tab to
    /// link to (e.g. the agent iterating on a fix without ever creating a
    /// debug tab) — groups repeated untabbed runs onto one artifact for this
    /// executor's lifetime (one connection session) instead of each looking
    /// like an unrelated one-off.
    private func recordAdHocArtifactVersion(
        sql: String, resultSnapshotJSON: String
    ) -> (artifactID: UUID, versionNumber: Int)? {
        guard let store, let profileID else { return nil }
        let artifactID: UUID
        if let existing = adHocArtifactID {
            artifactID = existing
        } else {
            let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Ad-hoc run")
            guard (try? store.saveArtifact(artifact)) != nil else { return nil }
            artifactID = artifact.id
            adHocArtifactID = artifactID
        }
        guard let version = try? store.appendArtifactVersion(
            artifactID: artifactID, payload: sql, resultSnapshotJSON: resultSnapshotJSON
        ) else { return nil }
        return (artifactID, version.versionNumber)
    }

 /// records this run_sql call as a new artifact version — onto the
    /// active tab's artifact if one is open and is a query/tab kind, else a
    /// per-session ad-hoc artifact.
    private func recordRunSQLArtifact(sql: String, into payload: inout [String: Any]) {
        let resultJSON = Self.json(payload)
        let recorded: (artifactID: UUID, versionNumber: Int)?
        if let snapshot = readActiveTab(), let kind = Self.artifactKind(forTabID: snapshot.tabID) {
            recorded = recordArtifactVersion(
                kind: kind, title: snapshot.tabTitle, tabID: snapshot.tabID,
                payload: sql, resultSnapshotJSON: resultJSON
            )
        } else {
            recorded = recordAdHocArtifactVersion(sql: sql, resultSnapshotJSON: resultJSON)
        }
        guard let recorded else { return }
        payload["artifact_id"] = recorded.artifactID.uuidString
        payload["artifact_version"] = recorded.versionNumber
    }

 /// one artifact version per `run_tab_statements` call (not per
    /// individual statement) — payload is every statement joined, so a
    /// version mirrors exactly what "run all"/"run selection" actually ran.
    /// No ad-hoc fallback: this tool inherently runs an open tab's
    /// statements, so `readActiveTab()` is expected to resolve here.
    private func recordRunTabStatementsArtifact(
        statements: [String], results: [[String: Any]], into outcome: inout [String: Any]
    ) {
        guard let snapshot = readActiveTab(), let kind = Self.artifactKind(forTabID: snapshot.tabID) else { return }
        guard let recorded = recordArtifactVersion(
            kind: kind, title: snapshot.tabTitle, tabID: snapshot.tabID,
            payload: statements.joined(separator: "\n"),
            resultSnapshotJSON: Self.json(["statements": results])
        ) else { return }
        outcome["artifact_id"] = recorded.artifactID.uuidString
        outcome["artifact_version"] = recorded.versionNumber
    }

    /// Looks up an artifact by id — its metadata plus the latest version, or
    /// a specific `versionNumber` if requested (the "agent can recall what it
 /// wrote" half). Read-only, local metadata only.
    private func getArtifact(artifactID: String?, versionNumber: String?) -> ToolOutcome {
        guard let artifactID, let uuid = UUID(uuidString: artifactID) else {
            return .failed("get_artifact requires a valid 'artifact_id'")
        }
        guard let store else { return .failed("Artifact storage unavailable") }
        guard let artifact = try? store.artifact(id: uuid) else {
            return .failed("No artifact found for id \(artifactID)")
        }
        var object: [String: Any] = [
            "artifact_id": artifact.id.uuidString,
            "kind": artifact.kind.rawValue,
            "title": artifact.title,
        ]
        if let objectRef = artifact.objectRef { object["object_ref"] = objectRef }
        if let version = Self.resolveVersion(store: store, artifactID: uuid, versionNumber: versionNumber) {
            object["version_number"] = version.versionNumber
            object["payload"] = version.payload
            if let resultSnapshotJSON = version.resultSnapshotJSON {
                if let data = resultSnapshotJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    object["result"] = parsed
                } else {
                    object["result"] = resultSnapshotJSON
                }
            }
        }
        return .ok(Self.json(object))
    }

 /// a cheap first look at a large artifact
    /// before reading it — size/chunk-count only, no content. Mirrors
    /// `get_schema`'s overview/ddl split: this is the "overview" half,
    /// `read_artifact_chunk` is the "ddl" (detail-on-demand) half.
    private func getArtifactOverview(artifactID: String?, versionNumber: String?) -> ToolOutcome {
        guard let artifactID, let uuid = UUID(uuidString: artifactID) else {
            return .failed("get_artifact_overview requires a valid 'artifact_id'")
        }
        guard let store else { return .failed("Artifact storage unavailable") }
        guard let artifact = try? store.artifact(id: uuid) else {
            return .failed("No artifact found for id \(artifactID)")
        }
        var object: [String: Any] = [
            "artifact_id": artifact.id.uuidString,
            "kind": artifact.kind.rawValue,
            "title": artifact.title,
        ]
        if let version = Self.resolveVersion(store: store, artifactID: uuid, versionNumber: versionNumber) {
            object["version_number"] = version.versionNumber
            object["payload_length"] = version.payload.count
            object["chunk_count"] = Self.resultChunks(version.resultSnapshotJSON).count
        }
        return .ok(Self.json(object))
    }

 /// one bounded chunk of a version's result — one chunk per
    /// statement for `run_tab_statements`'s aggregated `{"statements":[...]}`
    /// shape (the only place a single version's result can genuinely outgrow
    /// one tool-result call: each statement is already capped by
    /// `drainSample`'s 100-row limit, but that cap doesn't bound the total
    /// across many statements). Every other shape is already bounded on its
    /// own, so it's just one chunk — this never special-cases "small" vs
    /// "large" artifacts, it just reports how many chunks there are. Always
    /// reports `chunk_index`/`total_chunks` so the model never has to guess
    /// whether it's read everything.
    private func readArtifactChunk(artifactID: String?, versionNumber: String?, chunkIndex: String?) -> ToolOutcome {
        guard let artifactID, let uuid = UUID(uuidString: artifactID) else {
            return .failed("read_artifact_chunk requires a valid 'artifact_id'")
        }
        guard let index = chunkIndex.flatMap(Int.init), index >= 0 else {
            return .failed("read_artifact_chunk requires a valid non-negative 'chunk_index'")
        }
        guard let store else { return .failed("Artifact storage unavailable") }
        guard let version = Self.resolveVersion(store: store, artifactID: uuid, versionNumber: versionNumber) else {
            return .failed("No artifact version found for id \(artifactID)")
        }
        let chunks = Self.resultChunks(version.resultSnapshotJSON)
        guard !chunks.isEmpty else {
            return .failed("Artifact version has no result to read")
        }
        guard index < chunks.count else {
            return .failed("chunk_index \(index) out of range — total_chunks is \(chunks.count)")
        }
        return .ok(Self.json([
            "chunk_index": index,
            "total_chunks": chunks.count,
            "chunk": chunks[index],
        ]))
    }

    /// Shared by `getArtifact`/`getArtifactOverview`/`readArtifactChunk`: the
    /// requested `versionNumber`, or the latest version if nil/unparseable.
    private static func resolveVersion(
        store: BerryStore, artifactID: UUID, versionNumber: String?
    ) -> ArtifactVersion? {
        if let versionNumber, let requested = Int(versionNumber) {
            return try? store.artifactVersion(artifactID: artifactID, versionNumber: requested)
        }
        return try? store.latestArtifactVersion(artifactID: artifactID)
    }

    /// Splits a version's stored result into addressable chunks: one entry
    /// per statement for `run_tab_statements`'s `{"statements":[...]}` shape,
    /// or the whole (already-bounded) object as a single chunk otherwise.
    /// Empty for a version with no result at all.
    private static func resultChunks(_ resultSnapshotJSON: String?) -> [[String: Any]] {
        guard let resultSnapshotJSON,
              let data = resultSnapshotJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let statements = object["statements"] as? [[String: Any]] {
            return statements
        }
        return [object]
    }

    // MARK: - Safety chain (shared by run_sql and run_tab_statements)

    /// DangerGuard classification + approval for one statement. Writes/DDL always
 /// prompt; a plain safe SELECT may auto-approve.
    ///
 /// `.typedConfirm` (DROP/TRUNCATE on production) is denied
    /// outright rather than routed through the chat's approval card: that
    /// card only has Deny/Run buttons, no field to type the object name, so
 /// it cannot actually satisfy. If "Run anyway" were wired through
    /// to `QueryService.execute(dangerPreconfirmed: true)` regardless, the
    /// production-rules-never-downgrade rule there (correctly) leaves the
    /// statement classified `.typedConfirm`, so `QueryService` falls through
    /// to `dangerConfirmer.confirm()` a SECOND time — surfacing a blocking
    /// native `NSAlert` invisible to the chat UI. Nothing in the chat ever
    /// tells the user an alert is waiting, so it sits until the user
    /// stumbles onto it (or never does), pinning the MainActor and every
    /// other queued tool call behind it until the gateway's 120s
    /// `pending_tool_ttl` gives up — this is the "AI chat hangs on
    /// thinking forever" failure mode. Denying here means the agent reports
    /// back that this statement needs to be run manually, which is also the
 /// correct outcome for: typing the object name to confirm a
    /// destructive production DDL is deliberately a manual-only action.
    private func approve(_ sql: String, timeoutSeconds: TimeInterval? = nil) async -> Bool {
        let isProduction = session?.isProduction ?? false
        let danger = DangerGuard.classify(sql, isProduction: isProduction)
        if case .typedConfirm = danger { return false }
        let autoApprovable = Self.isReadOnly(sql) && danger == .safe && options.autoApproveSelects
        if autoApprovable { return true }
        if let timeoutSeconds {
            return await gate.approve(sql: sql, danger: danger, autoApprovable: autoApprovable, timeoutSeconds: timeoutSeconds)
        } else if let deadline = executionDeadlineSeconds {
            return await gate.approve(sql: sql, danger: danger, autoApprovable: autoApprovable, timeoutSeconds: deadline)
        } else {
            return await gate.approve(sql: sql, danger: danger, autoApprovable: autoApprovable)
        }
    }

    /// Bounds a real database round-trip from an AI tool call — comfortably
    /// under the gateway's `pending_tool_ttl` (2 minutes), leaving headroom
    /// for the rest of the client<->backend round-trip. PostgresNIO (and the
    /// other drivers) set no query timeout of their own, so a connection
    /// that goes quietly dead mid-query (e.g. a TCP socket wedged by a
    /// network blip, server already gone) otherwise hangs indefinitely —
    /// `pg_stat_activity` on the actual server shows nothing running when
    /// this happens, confirming the stall is client-side, not a real slow
    /// query. Every later `run_sql` queues behind the same stuck connection,
    /// so the model just keeps retrying and re-hanging. Same shape of bug as
    /// the embeddings HTTP client having no timeout, fixed here
    /// via the driver's *existing* cancellation path: `execute(_:)`'s stream
    /// already calls `cancelCurrentQuery()` on cancellation
    /// (`PostgresDriverConnection.swift`), so cancelling the losing side of
    /// this race tears the stuck query down properly instead of just
    /// abandoning it.
    private let aiQueryTimeoutSeconds: TimeInterval

    /// Drains a statement through the single SQL path (N1) into a bounded result
    /// payload. Keeps reading past the cap so history records a clean success;
    /// auto-LIMIT already bounds the total.
    private func drainSample(
        _ sql: String,
        lease: AIExecutionLease,
        timeoutOverrideSeconds: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard lease.isValid else { throw CancellationError() }
        let effectiveTimeout: TimeInterval
        if let timeoutOverrideSeconds {
            effectiveTimeout = min(aiQueryTimeoutSeconds, max(0, timeoutOverrideSeconds))
        } else {
            effectiveTimeout = aiQueryTimeoutSeconds
        }

        let timeoutLabel = effectiveTimeout < 1 && effectiveTimeout > 0 ? String(format: "%.1f", effectiveTimeout) : "\(Int(ceil(effectiveTimeout)))"
        let timeoutError = DriverError.queryFailed(
            message: "Query timed out after \(timeoutLabel)s — the connection may be stuck; try reconnecting.",
            code: nil
        )

        let box = try await UnstoppableTimeoutRace.run(timeoutSeconds: effectiveTimeout, timeoutError: timeoutError) {
            guard let session = self.session else {
                if let executeStatement = self.executeStatement {
                    guard lease.isValid else { throw CancellationError() }
                    switch await executeStatement(sql, lease) {
                    case .payload(let payload):
                        guard lease.isValid else { throw CancellationError() }
                        return ResultBox(payload)
                    case .denied:
                        throw CancellationError()
                    }
                }
                return ResultBox(["error": "Direct query execution unavailable for this connection"])
            }
            let result = try await self.runDatabaseQuery(sql, session: session, lease: lease)
            return ResultBox(result)
        }
        return box.payload
    }

    /// `approve(_:)` already gated this exact statement through the chat's
    /// own card using the same `DangerGuard.classify` QueryService
    /// recomputes internally — without `dangerPreconfirmed`, a soft
    /// data-destroying statement (DELETE/DROP/TRUNCATE, non-production)
    /// hit a SECOND, separate confirmation: QueryService's own
    /// `dangerConfirmer`, a blocking native NSAlert invisible to the chat
    /// UI. If the user never noticed it, the whole tool call (and every
    /// later one queued behind the same MainActor) stalled until the
    /// gateway's pending-tool timeout gave up. Production/no-WHERE
    /// guardrails are untouched — `dangerPreconfirmed` only downgrades the
    /// soft-delete reasons ("production rules
    /// never downgrade").
    @MainActor
    private func runDatabaseQuery(_ sql: String, session: Session, lease: AIExecutionLease) async throws -> [String: Any] {
        var columns: [String] = []
        var rows: [[Any]] = []
        var truncated = false
        var rowsAffected: Int64?
        for try await event in QueryService.execute(sql, on: session, dangerPreconfirmed: true) {
            try Task.checkCancellation()
            guard lease.isValid else { throw CancellationError() }
            switch event {
            case let .columns(metas):
                columns = metas.map(\.name)
            case let .rows(batch):
                for row in batch {
                    if rows.count < Self.sampleLimit {
                        rows.append(row.map(Self.jsonValue))
                    } else {
                        truncated = true
                    }
                }
            case let .complete(stats):
                rowsAffected = stats.rowsAffected
            }
        }
        try Task.checkCancellation()
        guard lease.isValid else { throw CancellationError() }
        var payload: [String: Any] = ["columns": columns, "rows": rows, "truncated": truncated]
        if let rowsAffected { payload["rows_affected"] = rowsAffected }
        return payload
    }

    // MARK: - Helpers

    private static func isReadOnly(_ sql: String) -> Bool {
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("select") || head.hasPrefix("with")
            || head.hasPrefix("explain") || head.hasPrefix("show")
            || head.contains(".find(") || head.contains(".aggregate(")
            || head.contains(".count(") || head.contains(".distinct(")
    }

    private static func jsonValue(_ value: BerryValue) -> Any {
        value.displayString ?? NSNull()
    }

 /// PlanNode is not Codable, so build the tree JSON by hand.
    private static func planJSON(_ nodes: [PlanNode]) -> [[String: Any]] {
        nodes.map { ["id": $0.id, "text": $0.text, "children": planJSON($0.children)] }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
