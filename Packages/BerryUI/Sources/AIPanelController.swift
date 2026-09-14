import BerryAI
import BerryCore
import BerryDataSourceKit
import BerryDriverKit
import BerryGraph
import BerryLicense
import BerryStore
import CryptoKit
import Foundation
import Observation

/// Drives the AI panel: owns the per-connection
/// `AISession`, the local tool executor, the inline approval flow, and the
/// switches. Rebuilt whenever the workspace's active session
/// changes. The heavy lifting (SSE, tools) lives in BerryAI; this is the glue
/// to the workspace + license + editor.
@MainActor
@Observable
public final class AIPanelController {
    /// Why the chat is or isn't usable right now — drives the panel's gate.
    public enum Availability: Equatable {
        case noConnection
        case unlicensed
 /// switched off for this connection (default on production).
        case disabledForConnection
 /// First use of this connection must accept the metadata policy.
        case needsConsent
        case ready
    }

 /// A statement the agent wants to run, awaiting the user's decision.
    public struct PendingApproval: Identifiable, Equatable {
        public let id = UUID()
        public let sql: String
        public let danger: DangerLevel
        public var isDangerous: Bool { danger != .safe }
    }

 /// An MCP tool call awaiting the user's decision.
    public struct PendingMCPApproval: Identifiable, Equatable {
        public let id = UUID()
        public let serverID: String
        public let toolName: String
        public let argumentsJSON: String
    }

 /// AI usage/access state from `GET /v1/ai/balance`. Unconditional
    /// now: every account gets both its trial-era `tokenQuota` snapshot (frozen
    /// once a trial converts to a balance — see the server's doc comment on
    /// `BalanceResponse`) *and* its pay-as-you-go `balanceMicros`/`models`, so
    /// the UI can show all three usage bars (trial, and each selectable
    /// model) together rather than branching on current plan.
    public struct Balance: Equatable, Sendable {
        public struct TokenQuota: Equatable, Sendable {
            public let used: Int
            public let limit: Int
 /// `limit == 0` means unlimited — never report that as exhausted.
            public var isExhausted: Bool { limit > 0 && used >= limit }
        }
        public struct Model: Equatable, Identifiable, Sendable {
            public let id: String
            public let name: String
            public let tokensRemaining: Int
            /// Tokens this model's lifetime topped-up credit would have
            /// bought — the "total" a usage bar fills against. 0 for an
            /// account that has never topped up.
            public let tokensTotal: Int
            /// `tokensTotal - tokensRemaining` — an approximation of tokens
            /// spent on this model so far (spend isn't tracked per model
            /// server-side; see the server's `ModelBalance` doc comment).
            public let tokensUsed: Int
        }
        public let plan: String
        public let tokenQuota: TokenQuota
        public let balanceMicros: Int
        /// Cumulative tokens spent so far across every model this account has
        /// used — informational context next to `models`' forward-looking
        /// `tokensRemaining`, which is what actually predicts "when" the
        /// balance runs out. `nil` for an account that hasn't sent an AI turn yet.
        public let totalTokensUsed: Int?
        /// True once the balance drops below the admin-configured minimum
        /// top-up — only for an account that has topped up at least once.
        public let lowBalance: Bool
        /// Combined % of lifetime top-up credit spent so far — unlike each
        /// `Model` bar above (priced at *that* model's own selling rate),
        /// this is accurate regardless of which models were mixed to get
        /// there, since every model draws down this same shared balance.
        /// `nil` for an account that has never topped up.
        public let totalBudgetUsedPercent: Double?
        public let models: [Model]
        /// Server's own `budget_override.is_some() || plan == "trial"` —
        /// whether `tokenQuota` can currently keep this account usable even
        /// at `balanceMicros <= 0` (`check_ai_allowance`, main.rs). Bug found
        /// 2026-08-11 (real account data: a "pro" plan key with an admin
        /// `token_budget` override, `balanceMicros` permanently 0 since it
        /// never did a real top-up): `isExhausted` used to key off
        /// `plan == "trial"` alone, so this exact non-trial-but-overridden
        /// shape read as exhausted forever regardless of how much token
        /// budget was left — chat kept working (the server correctly used
        /// the override), the banner just never noticed. Reading the
        /// server's own gate condition instead of re-deriving (and
        /// diverging from) it fixes every shape, not just this one.
        public let quotaFallbackActive: Bool

        /// Mirrors `check_ai_allowance`'s actual gate: when a quota fallback
        /// (trial grant or admin override) is active, the account only reads
        /// as exhausted once *both* that quota and the balance are gone, not
 /// just one (#3) — otherwise it's balance-only.
        public var isExhausted: Bool {
            quotaFallbackActive ? (tokenQuota.isExhausted && balanceMicros <= 0) : balanceMicros <= 0
        }

        /// Fetches `GET /v1/ai/balance`. Shared by the AI panel footer and
        /// `LicenseView`'s per-model breakdown so both read the identical
        /// shape rather than duplicating the parsing.
        public static func fetch(token: String, backendURL: URL) async -> Balance? {
            var request = URLRequest(url: backendURL.appendingPathComponent("v1/ai/balance"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let plan = object["plan"] as? String,
                  let quotaObject = object["token_quota"] as? [String: Any],
                  let quotaUsed = quotaObject["used"] as? Int,
                  let quotaLimit = quotaObject["limit"] as? Int,
                  let balanceMicros = object["balance_micros"] as? Int
            else { return nil }

            let tokenQuota = TokenQuota(used: quotaUsed, limit: quotaLimit)
            let models = (object["models"] as? [[String: Any]] ?? []).compactMap { entry -> Model? in
                guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                      let tokensRemaining = entry["tokens_remaining"] as? Int,
                      let tokensTotal = entry["tokens_total"] as? Int,
                      let tokensUsed = entry["tokens_used"] as? Int
                else { return nil }
                return Model(id: id, name: name, tokensRemaining: tokensRemaining, tokensTotal: tokensTotal, tokensUsed: tokensUsed)
            }
            return Balance(
                plan: plan, tokenQuota: tokenQuota, balanceMicros: balanceMicros,
                totalTokensUsed: object["total_tokens_used"] as? Int,
                lowBalance: object["low_balance"] as? Bool ?? false,
                totalBudgetUsedPercent: object["total_budget_used_percent"] as? Double,
                models: models,
                // Default mirrors the old (buggy) `plan == "trial"` heuristic
                // this replaces — only reachable talking to a backend that
                // predates this field.
                quotaFallbackActive: object["quota_fallback_active"] as? Bool ?? (plan == "trial")
            )
        }
    }

    private let license: LicenseManager
    private let backendURL: URL

    /// propose_sql bridge — the workspace inserts the SQL into an editor tab.
    /// Second value is an optional tab title, used only when no query tab is open
    /// and one has to be created — that tab was always landing as "Untitled"
 ///
    public var onPropose: ((String, String?) -> Void)?

 /// SQL-tab tool bridges. The
    /// workspace supplies these reading the active `EditorDocument`; when nil the
    /// tools report no active tab. `activeTabStatements` takes the tool's raw
    /// "all"/"selection"/"cursor" so this controller never names `EditorDocument`.
    public var readActiveTab: (() -> ActiveTabSnapshot?)?
    /// All open panes, numbered, so the AI can disambiguate a split (get_open_tabs).
    public var readOpenTabs: (() -> OpenTabsSnapshot?)?
    public var activeTabStatements: ((String) -> [String])?
    /// Live tab/pane/action-log snapshot for `get_ui_state`/`query_ui_graph`
 /// unlike `readOpenTabs`, carries every tab in
    /// each pane, not just the active one.
    public var uiGraphSnapshot: (() -> UIGraphSnapshot?)?
    /// The command palette / menu bar's action registry, re-described for AI
 /// routing — see `UIActionEntry`.
    public var uiActionEntries: (() -> [UIActionEntry])?
    /// AI Schema Review for a proposed new column (`preview_migration`,
 /// — `WorkspaceViewModel.previewNewColumn`.
    public var previewNewColumn: ((String, ColumnDesign) async -> [Insight]?)?
 /// Impact Simulator (`simulate_impact`)
    /// `WorkspaceViewModel.simulateImpact`, same as Graph Explorer uses.
    public var simulateImpact: ((String) -> ImpactSimulator.Report?)?
 /// Daily Review digest (`get_daily_review`)
    /// `WorkspaceViewModel.maybeGenerateDailyReview`/`latestDailyReview`, same
    /// as the Insight Panel's "Today's Summary" uses.
    public var maybeGenerateDailyReview: (() async -> Void)?
    public var latestDailyReview: (() -> DailyReviewSummary?)?
 /// Slow-query ranking (`get_slow_queries`)
    /// `WorkspaceViewModel.slowestQueries`, base "ai" tier like History
    /// itself (not Intelligence-gated).
    public var slowestQueries: ((Int) -> [QueryHistoryEntry])?
    public var createDebugTab: ((String, String?) -> Void)?
 /// `open_mermaid_tab` (follow-up) — same action as `MermaidBlock`'s
    /// "Open in Tab" button (`openMermaidInTab` below), but reachable from a
    /// tool call instead of only a chat-bubble click.
    public var openMermaidTab: ((String, String?) -> Void)?
    public var onRefreshSchema: (() -> Void)?
    /// Forwards `AISession.onTurnAdmitted` (see its doc comment) — set once
    /// per `aiSession` construction in `bind()`, since `aiSession` itself is
    /// rebuilt on a genuine connection switch.
    public var onTurnAdmitted: (() -> Void)?
 /// read/write the artifact linked to a tab, so
    /// `QueryToolExecutor` can accumulate versions onto the same artifact
    /// across repeated tool calls instead of creating a new one each time —
    /// `WorkspaceViewModel.artifactID(forTab:)`/`setArtifactID(_:forTab:)`.
    public var resolveArtifactID: ((String) -> UUID?)?
    public var linkArtifact: ((String, UUID) -> Void)?
 /// opens the artifact a chip in the transcript links to
    /// `WorkspaceViewModel.openArtifact(id:)`.
    public var openArtifact: ((UUID) -> Void)?
 /// opens the table/view a linkified `@{Name}` mention in a user's
    /// own bubble resolves to — `WorkspaceViewModel.selectObject(id:)`.
    public var openObject: ((String) -> Void)?
 /// Cmd-clicking a working-block action's payload opens it as
    /// a new editor tab — `WorkspaceViewModel.newEditorTab(text:)`. Unlike
    /// `openArtifact`, this text may never have been an artifact at all (a
    /// `get_schema` object list, a statement the model proposed but never ran).
    public var openTextInTab: ((String) -> Void)?
 /// opens a chat-rendered Mermaid diagram as its own tab, zoomable
    /// `WorkspaceViewModel.openMermaidDiagram(source:)`.
    public var openMermaidInTab: ((String) -> Void)?

    /// Bumped whenever a working block expands or collapses, so the transcript
    /// can re-run its scroll-to-bottom.
    ///
    /// The disclosure's own `isExpanded` is `@State` private to
    /// `TurnWorkSummary`, and a toggle changes the content height without
    /// changing any text — so nothing the panel already observes moves, and it
    /// kept the old scroll offset with the newest content off screen. A counter
    /// rather than a Bool: two collapses in a row must each register.
    public private(set) var workingBlockLayoutGeneration = 0

    public func noteWorkingBlockLayoutChange() {
        workingBlockLayoutGeneration += 1
    }
 /// candidates for the `@` mention autocomplete
    /// `WorkspaceViewModel.matchingArtifactMentions(query:)`.
    public var mentionCandidates: ((String) -> [ArtifactMentionItem])?

    private var session: Session?
    public private(set) var dataSourceSession: DataSourceSession?
    public private(set) var aiSession: AISession?
    private var executor: QueryToolExecutor?

 /// Local chat history + sqlite-vec RAG (Q17,
 /// Independent connection from `WorkspaceViewModel`'s own `BerryStore`
    /// (same pattern that already uses — GRDB/SQLite is fine with multiple
    /// connections to the same store.sqlite). Falls back to an in-memory store
    /// if `store.sqlite` can't be opened, so a rare disk error degrades to
    /// "chat doesn't persist" instead of the whole AI panel breaking.
    private let store: BerryStore = (try? BerryStore.open()) ?? (try! BerryStore(path: ":memory:"))

 /// Saved conversations for the panel's history menu.
    public private(set) var threads: [AIThreadSummary] = []

    public private(set) var hasMoreThreads = true
    /// True while a `loadMoreThreads` page is in flight — guards the infinite
    /// scroll from firing overlapping loads as rows re-appear.
    public private(set) var isLoadingMore = false
    private let threadPageSize = 20

    /// Refresh the saved-conversation list from the backend for the current database/dialect.
    /// If `autoLoadLatest` is true and no conversation is currently active, loads the most recent thread.
    public func refreshThreads(autoLoadLatest: Bool = false) async {
        let fetched = await aiSession?.availableThreads(limit: threadPageSize) ?? []
        threads = fetched
        hasMoreThreads = fetched.count >= threadPageSize

        if autoLoadLatest, aiSession?.currentThreadID == nil, (aiSession?.transcript.isEmpty ?? true), let latest = threads.first {
            await openThread(latest.id)
        }
    }

    /// Load the next page of past conversations for the current database/dialect.
    /// Keyset cursor from the last row we hold — stable even if a thread is
 /// touched between page loads.
    public func loadMoreThreads() async {
        guard hasMoreThreads, !isLoadingMore, let cursor = threads.last else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let fetched = await aiSession?.availableThreads(
            limit: threadPageSize,
            beforeUpdatedAt: Int(cursor.updatedAt),
            beforeID: cursor.id
        ) ?? []
        if fetched.isEmpty {
            hasMoreThreads = false
        } else {
            threads.append(contentsOf: fetched)
            hasMoreThreads = fetched.count >= threadPageSize
        }
    }

    /// New chat: clear the panel and start a fresh thread.
    public func newChat() {
        guard aiSession?.canChangeThread ?? true else { return }
        aiSession?.startNewThread()
        Task { await refreshThreads() }
    }

    /// Open a saved conversation by id.
    public func openThread(_ id: String) async {
        guard aiSession?.canChangeThread ?? true else { return }
        await aiSession?.openThread(id)
    }

    /// Delete a saved conversation, then refresh the list.
    public func deleteThread(_ id: String) async {
        guard aiSession?.canChangeThread ?? true else { return }
        await aiSession?.deleteThread(id)
        await refreshThreads()
    }

 /// Persisted per-connection AI preferences (+ consent).
    public struct AIConnectionSettings: Equatable, Sendable {
        public var enabled: Bool
        public var allowSampleRows: Bool
        public var autoApproveSelects: Bool
        public var consentGiven: Bool
        public var enabledMCPServers: Set<String>
        public var trustedMCPServers: Set<String>

        public init(
            enabled: Bool,
            allowSampleRows: Bool,
            autoApproveSelects: Bool,
            consentGiven: Bool,
            enabledMCPServers: Set<String> = [],
            trustedMCPServers: Set<String> = []
        ) {
            self.enabled = enabled
            self.allowSampleRows = allowSampleRows
            self.autoApproveSelects = autoApproveSelects
            self.consentGiven = consentGiven
            self.enabledMCPServers = enabledMCPServers
            self.trustedMCPServers = trustedMCPServers
        }
    }

    /// Store bridge (wired by the workspace). Keyed by profile — profileless
    /// quick-open connections stay in memory only.
    public var loadSettings: ((UUID) -> AIConnectionSettings?)?
    public var saveSettings: ((UUID, AIConnectionSettings) -> Void)?
 /// Builds the local `graph_query` executor for a profile
 /// nil disables the tool (quick-open / no store). Wired by the
    /// workspace so this controller stays free of the graph module.
    public var makeGraphExecutor: ((UUID) -> (any AIToolExecutor)?)?

 // Per-connection settings. Changes persist unless restoring.
    public var enabledForConnection = false {
        didSet { persistSettings() }
    }
    public var allowSampleRows = false {
        didSet {
            executor?.options.allowSampleRows = allowSampleRows
            persistSettings()
        }
    }
    public var autoApproveSelects = true {
        didSet {
            executor?.options.autoApproveSelects = autoApproveSelects
            persistSettings()
        }
    }
    private var consentGiven = false {
        didSet { persistSettings() }
    }

    /// Profile for persistence — nil for quick-open (memory only).
    private var currentProfileID: UUID?
    /// Suppresses persistence while `bind` restores settings.
    private var isRestoring = false

    public private(set) var pendingApproval: PendingApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
 /// Set by an approval card's "Run All Safe" button — subsequent
    /// safe statements this turn skip the prompt entirely instead of
    /// re-asking one by one (e.g. running many SELECTs from a tab). Reset
    /// at the start of every new user message so the trust never silently
    /// carries into a later, unrelated request. Writes/DDL are never
    /// covered by this — DangerGuard's "always ask" rule for those is
    /// untouched; the button only ever appears on a statement that's
    /// already classified safe.
    private var autoApproveSafeThisTurn = false

 // MCP: servers the user has enabled/trusted this session (in-memory
 // persistence is a follow-up) and the pending per-call approval.
    public var enabledMCPServers: Set<String> = []
    private var trustedMCPServers: Set<String> = []
    public private(set) var pendingMCPApproval: PendingMCPApproval?
    private var mcpApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var mcpExecutor: MCPToolExecutor?
    private var capabilityHost: LocalCapabilityHost?
 /// The curated MCP allowlist, for the settings UI.
    public let mcpAllowlist: [MCPServerManifest] = MCPAllowlist.bundled()

    public var draft = ""
 /// Set while the composer is editing a previously-sent message
    /// instead of drafting a new one — `prepareSend()` routes to
    /// `AISession.prepareEdit` and clears this the moment it's consumed.
    public var editingMessageID: UUID?
    public private(set) var balance: Balance?
    /// Throttle window for `refreshBalance` (below) — the number moves slowly
    /// enough (whole-turn token counts / dollars) that fetching it after
    /// every single send is wasted backend traffic for no visible benefit.
    private static let quotaRefreshInterval: TimeInterval = 30
    private var lastQuotaRefreshAttempt: Date?

    /// The text after "/" while the composer is in command-palette mode, or
    /// nil when it isn't (draft doesn't start with "/", or a space has been
    /// typed — meaning the user is now typing the command's argument, not
    /// searching). Drives the dropdown in AIPanelView.
    public var commandQuery: String? {
        guard draft.hasPrefix("/"), !draft.dropFirst().contains(" ") else { return nil }
        return String(draft.dropFirst())
    }

    /// Commands to show in the dropdown for the current `commandQuery`.
    public var matchingCommands: [ChatCommand] { ChatCommands.matching(commandQuery ?? "") }

    /// The text after the last word-starting "@" in the draft, or nil if
 /// there isn't an open one — e.g. "show me
    /// @use" → "use". Triggers on a bare "@" (matching the common
    /// Slack/Notion convention the user expected, not the original "@{"
    /// design) but only when it starts a "word" — preceded by whitespace or
    /// the start of the draft — so an "@" embedded mid-word (an email
    /// address, "foo@bar") doesn't false-trigger. Closes once whitespace
    /// follows the "@" (the mention was either accepted already — the
    /// inserted `@{Name} ` always has a space after it — or abandoned).
    /// Unlike `commandQuery` (anchored at column 0), a mention can start
    /// anywhere, so this scans from the *end* of the draft backward for the
    /// closest "@". Not truly caret-aware — `TextField` doesn't expose
    /// cursor position to SwiftUI — so this assumes the trigger being typed
    /// is always the one nearest the end, same simplifying assumption
    /// `commandQuery` already makes for "/".
    public var artifactMentionQuery: String? {
        guard let atIndex = draft.range(of: "@", options: .backwards)?.lowerBound else { return nil }
        let beforeAt = draft[..<atIndex]
        if let precedingChar = beforeAt.last, !precedingChar.isWhitespace { return nil }
        let afterAt = draft[draft.index(after: atIndex)...]
        guard !afterAt.contains(where: \.isWhitespace) else { return nil }
        return String(afterAt)
    }

    /// Mention candidates for the current `artifactMentionQuery` — supplied
    /// by `WorkspaceViewModel.matchingArtifactMentions(query:)`, since this
    /// controller doesn't hold the workspace's artifacts/schema objects itself.
    public var matchingMentions: [ArtifactMentionItem] {
        guard let query = artifactMentionQuery else { return [] }
        return mentionCandidates?(query) ?? []
    }

    public init(license: LicenseManager, backendURL: URL) {
        self.license = license
        self.backendURL = backendURL
        // Nothing else purges `ai_pending_interaction` rows past their
        // expiry — an interaction the user starts but never resumes (closes
        // the app, abandons the chat) would otherwise sit in store.sqlite
        // forever. Once per launch is enough: these are short-lived
        // (control receipts/pending confirmations), not something a
        // long-running session accumulates many of between restarts.
        _ = try? store.deleteExpiredPendingAIInteractions(nowUnix: Int64(Date().timeIntervalSince1970))
    }

    public var isProduction: Bool { session?.isProduction ?? false }

    /// Pass-throughs for the view.
    public var isStreaming: Bool { aiSession?.isStreaming ?? false }
    public var transcript: [AITurn] { aiSession?.transcript ?? [] }
    public var lastError: String? { aiSession?.lastError }
    public var requiresClientUpdate: Bool { aiSession?.requiresClientUpdate ?? false }
    public var capabilityErrorLocalizationKey: String? {
        aiSession?.capabilityErrorLocalizationKey
    }
    public var controlDeliveryErrorLocalizationKey: String? {
        aiSession?.controlDeliveryErrorLocalizationKey
    }
    public var runningTool: String? { aiSession?.runningTool }
    public var pendingReport: AISession.PendingReport? { aiSession?.pendingReport }
    public var pendingReportDraft: AISession.PendingReportDraft? {
        aiSession?.pendingReportDraft
    }
    /// The confirmed report and its (possibly since-invalidated)
    /// `report_ready_token` (Task 11) — survives past `pendingReport`'s own
    /// resolution so the user can keep reviewing it.
    public var confirmedReportDraft: AISession.ConfirmedReportDraft? {
        aiSession?.confirmedReportDraft
    }
    /// The confirmed draft's live, digest-matching `report_ready_token`, or
    /// nil — the only "is it ready" signal (Task 11); never a separate flag.
    public var reportReadyToken: String? { aiSession?.reportReadyToken }
    /// The conversation summary the user reviews *before* consenting to
    /// attach it (Task 12) — the same bytes the confirmation binds and the
    /// submission sends.
    public var reportContextSummary: String? { aiSession?.reportContextSummary }
    public var isPreparingReportContextSummary: Bool {
        aiSession?.isPreparingReportContextSummary ?? false
    }
    public var reportContextSummaryUnavailable: Bool {
        aiSession?.reportContextSummaryUnavailable ?? false
    }
    /// Set synchronously (before the `Task` in `submitConfirmedReport()`) so
    /// this reports `.submitting` instantly — `AISession`'s own
    /// `reportSubmissionState` only flips once that Task gets its MainActor
    /// turn, which otherwise reads as "Send Report needs multiple clicks."
    /// Cleared once the Task's `await` returns, letting the real state
    /// (`.submitted`/`.failed`) show through.
    private var isSubmittingReportLocally = false
    /// Same idea as `isSubmittingReportLocally`, for the four resolve
    /// actions below (`resolveReport`/`resolveReportDraft`/
    /// `resolveClarification`) — `AISession.isInteractionResolving` is
    /// correct but, like `reportSubmissionState`, only updates once its
    /// Task is scheduled.
    private var isResolvingLocally = false

    public var reportSubmissionState: AISession.ReportSubmissionState {
        isSubmittingReportLocally ? .submitting : (aiSession?.reportSubmissionState ?? .idle)
    }
    public var pendingClarification: AISession.PendingClarification? {
        aiSession?.pendingClarification
    }
    public var isInteractionPending: Bool {
        aiSession?.isInteractionPending ?? false
    }
    public var isInteractionResolving: Bool {
        isResolvingLocally || (aiSession?.isInteractionResolving ?? false)
    }
    public var canChangeThread: Bool {
        aiSession?.canChangeThread ?? true
    }
    /// Messages typed while a turn/interaction was still in flight — queued,
    /// not lost, and run automatically as each earlier one finishes.
    public var queuedMessages: [String] {
        aiSession?.queuedMessages ?? []
    }

    /// Cancels one queued message before it drains — see
    /// `AISession.removeQueuedMessage(at:)`.
    public func removeQueuedMessage(at index: Int) {
        aiSession?.removeQueuedMessage(at: index)
    }

    public func resolveReport(confirmed: Bool, attachContext: Bool) {
        guard !isResolvingLocally else { return }
        isResolvingLocally = true
        Task { [weak self] in
            await self?.aiSession?.resolveReport(
                confirmed: confirmed, attachContext: attachContext
            )
            self?.isResolvingLocally = false
        }
    }

    public func updateReportAttachContext(_ value: Bool) {
        aiSession?.updateReportAttachContext(value)
    }

    /// Fetches the conversation summary the attach-context choice would send,
    /// so the user reviews the real scope before confirming (Task 12).
    public func prepareReportContextSummary() {
        Task { [weak self] in
            await self?.aiSession?.prepareReportContextSummary()
        }
    }

    /// The explicit submit action (Task 12) — the only path from this client
    /// to `POST /v1/agent/report`, never triggered by readiness alone.
    public func submitConfirmedReport() {
        guard !isSubmittingReportLocally else { return }
        isSubmittingReportLocally = true
        Task { [weak self] in
            await self?.aiSession?.submitConfirmedReport()
            self?.isSubmittingReportLocally = false
        }
    }

    /// Lets the user revise the agent's canonical draft before confirming (Task 11).
    public func updateReportDescription(_ text: String) {
        aiSession?.updateReportDescription(text)
    }

    /// Edits the already-confirmed draft (Task 11) — invalidates
    /// `reportReadyToken` until the text matches what it was minted for again.
    public func updateConfirmedReportDraftText(_ text: String) {
        aiSession?.updateConfirmedReportDraftText(text)
    }

    /// Flips the attach-context choice on an already-confirmed draft (Task
    /// 11) — also invalidates `reportReadyToken` until reverted.
    public func updateConfirmedReportDraftAttachContext(_ value: Bool) {
        aiSession?.updateConfirmedReportDraftAttachContext(value)
    }

    /// Discards the confirmed draft (Task 11) — no submission step to
    /// cancel here (Task 12 owns that), just the local bookkeeping.
    public func dismissConfirmedReportDraft() {
        aiSession?.dismissConfirmedReportDraft()
    }

    public func resolveReportDraft(confirmed: Bool, attachContext: Bool) {
        guard !isResolvingLocally else { return }
        isResolvingLocally = true
        Task { [weak self] in
            await self?.aiSession?.resolveReportDraft(
                confirmed: confirmed, attachContext: attachContext
            )
            self?.isResolvingLocally = false
        }
    }

    public func updateReportDraftAttachContext(_ value: Bool) {
        aiSession?.updateReportDraftAttachContext(value)
    }

    public func resolveClarification(_ resolution: AISession.ClarificationResolution) {
        guard !isResolvingLocally else { return }
        isResolvingLocally = true
        Task { [weak self] in
            await self?.aiSession?.resolveClarification(resolution)
            self?.isResolvingLocally = false
        }
    }

    /// True once an AI session exists — false when there is no connection or no
    /// token yet. Used to rebuild after a license activation without disrupting
    /// an already-running conversation.
    public var isBuilt: Bool { aiSession != nil }

 /// the real gate is the credit balance now, not the license
    /// status — a `.trialExpired` device (trial fully lapsed, never topped
    /// up) still reaches `.ready` so it can see the "insufficient_credit"
    /// error bar and its "Add Credit" CTA, instead of being blocked outright
    /// with no path forward except this same sheet. Only `.none` (nothing
    /// ever activated at all) blocks the panel.
    public var availability: Availability {
        guard session != nil || dataSourceSession != nil else { return .noConnection }
        if case .none = license.status, !appleIntelligenceGranted { return .unlicensed }
        guard enabledForConnection else { return .disabledForConnection }
        guard consentGiven else { return .needsConsent }
        return .ready
    }

 /// True when Apple Intelligence access — not a real
    /// license/trial — has been granted and is currently usable. Re-evaluated
    /// live, not cached, off `license.status` and
    /// `AppleFoundationProvider.isAvailable()`.
    ///
    /// Deliberately independent of the on-device toggle: the toggle lives
    /// inside the panel this property gates, so coupling them would lock a
    /// user out with no way back to the toggle once it's off.
    public var appleIntelligenceGranted: Bool {
        guard case .none = license.status else { return false }
        return AppleIntelligenceAccess.isGranted && AppleFoundationProvider.isAvailable()
    }

    // MARK: - Bind to the active session

    /// Rebuilds the AI session for a (possibly nil) workspace connection.
 /// Restores this connection's saved AI settings (+ consent), or
 /// applies defaults — AI off by default on production.
    public func bind(
        session: Session?,
        dataSourceSession: DataSourceSession? = nil,
        collections: [CollectionRef] = [],
        catalog: SchemaCatalog?,
        objects: [SchemaObject],
        profileID: UUID?
    ) {
        // WorkspaceView calls bind() on every schema change too (objects/
        // collections), not just connection switches — including ones the
        // AI's own write tool calls trigger via onRefreshSchema. A schema-only
        // refresh on the SAME connection must not tear down an in-flight turn
        // or silently deny a pending approval the user is currently looking
        // at: the executor already reads live from the same SchemaCatalog
        // actor, so there's nothing here that actually needs rebuilding.
        // Only a genuine connection switch should reach the teardown below.
        let sameConnection = self.session?.id == session?.id
            && self.dataSourceSession?.id == dataSourceSession?.id
            && aiSession != nil
        if sameConnection {
            currentProfileID = profileID
            return
        }

        // Abandon any approval left pending on the previous connection.
        approvalContinuation?.resume(returning: false)
        approvalContinuation = nil
        pendingApproval = nil
        mcpApprovalContinuation?.resume(returning: false)
        mcpApprovalContinuation = nil
        pendingMCPApproval = nil

        self.session = session
        self.dataSourceSession = dataSourceSession
        currentProfileID = profileID
        balance = nil

        // Restore saved settings without persisting them back.
        isRestoring = true
        let saved = profileID.flatMap { loadSettings?($0) }
        consentGiven = saved?.consentGiven ?? false
        allowSampleRows = saved?.allowSampleRows ?? false
        autoApproveSelects = saved?.autoApproveSelects ?? true
        enabledMCPServers = saved?.enabledMCPServers ?? []
        trustedMCPServers = saved?.trustedMCPServers ?? []
 // default OFF on production when there's no saved choice.
        enabledForConnection = saved?.enabled ?? (session.map { !$0.isProduction } ?? (dataSourceSession != nil))
        isRestoring = false

        guard session != nil || dataSourceSession != nil, LicenseManager.apiToken() != nil else {
            aiSession = nil
            executor = nil
            return
        }

        let isNoSQL = dataSourceSession != nil
        let dialect: String
        let digest: String
        if let dataSourceSession {
            dialect = Self.dialectString(for: dataSourceSession.kind)
            digest = Self.digestCollections(collections)
        } else if let session {
            dialect = session.config.driver.rawValue
            digest = Self.digest(objects)
        } else {
            aiSession = nil
            executor = nil
            return
        }
        let collectionNames = collections.map(\.name)

        let skillExecutor = SkillToolExecutor(directory: Self.skillsDirectory)
        let uiGraphExecutor = UIGraphToolExecutor(
            store: store, profileID: currentProfileID,
            snapshot: { [weak self] in self?.uiGraphSnapshot?() }
        )
        var routes: [String: any AIToolExecutor] = [
            "list_skills": skillExecutor,
            "load_skill": skillExecutor,
 // Tab/pane awareness — deliberately
            // registered unconditionally, unlike graph_query/get_stats below:
 // this is base "ai" capability, not Intelligence-tier.
            "get_ui_state": uiGraphExecutor,
            "query_ui_graph": uiGraphExecutor,
        ]

        if session != nil || dataSourceSession != nil {
            let gate = ApprovalGateAdapter(controller: self)
            let executor = QueryToolExecutor(
                session: isNoSQL ? nil : session,
                catalog: isNoSQL ? nil : catalog,
                gate: gate,
                options: .init(allowSampleRows: allowSampleRows, autoApproveSelects: autoApproveSelects),
                onPropose: { [weak self] sql, title in self?.onPropose?(sql, title) },
                readActiveTab: { [weak self] in
                    guard let closure = self?.readActiveTab else { return nil }
                    return closure()
                },
                readOpenTabs: { [weak self] in self?.readOpenTabs?() },
                activeTabStatements: { [weak self] which in self?.activeTabStatements?(which) ?? [] },
                createDebugTab: { [weak self] sql, title in self?.createDebugTab?(sql, title) },
                openMermaidTab: { [weak self] diagram, title in self?.openMermaidTab?(diagram, title) },
                executeStatement: { [weak self] sql, lease in
                    guard lease.isValid else { return .denied }
                    guard let dataSourceSession = self?.dataSourceSession else {
                        return .payload(["error": "Direct query execution unavailable for this connection"])
                    }
                    do {
                        switch dataSourceSession.kind {
                        case .vector:
                            // Qdrant has no shell syntax — MongoShellParser
                            // cannot parse its raw-JSON query script, so
                            // run_tab_statements/explain_query silently failed
                            // for Qdrant connections before this branch existed.
                            let query = try QdrantQueryScript.parse(sql)
                            return try await Self.runDataSourceStatement(
                                readQuery: query.readQuery, changeSets: query.changeSets, collection: query.collection,
                                dataSourceSession: dataSourceSession, lease: lease,
                                onRefreshSchema: { Task { @MainActor [weak self] in self?.onRefreshSchema?() } }
                            )
                        case .search:
                            // Same reasoning as Qdrant above — Elasticsearch's
                            // Query DSL script isn't Mongo shell syntax either
 //
                            let query = try ElasticsearchQueryScript.parse(sql)
                            return try await Self.runDataSourceStatement(
                                readQuery: query.readQuery, changeSets: query.changeSets, collection: query.index,
                                dataSourceSession: dataSourceSession, lease: lease,
                                onRefreshSchema: { Task { @MainActor [weak self] in self?.onRefreshSchema?() } }
                            )
                        case .document:
                            let statements = try MongoShellParser.parse(sql)
                            guard let first = statements.first else {
                                return .payload(["error": "No statement found in script"])
                            }
                            let action = try MongoShellResolver.resolve(first)
                            switch action {
                            case .query(let query):
                                guard lease.isValid else { return .denied }
                                var count = 0
                                var docs: [[String: String]] = []
                                for try await doc in dataSourceSession.connection.query(query) {
                                    guard lease.isValid else { return .denied }
                                    if count < 10 { docs.append(["document": "\(doc)"]) }
                                    count += 1
                                }
                                guard lease.isValid else { return .denied }
                                return .payload(["executed": true, "result_count": count, "sample": docs])
                            case .write(let change):
                                guard lease.isValid else { return .denied }
                                let writeResult = try await dataSourceSession.connection.write(change)
                                guard lease.isValid else { return .denied }
                                Task { @MainActor [weak self] in self?.onRefreshSchema?() }
                                return .payload(["executed": true, "type": "write", "collection": change.collection, "result": "\(writeResult)"])
                            case .writeMany(let changes):
                                var count = 0
                                for change in changes {
                                    guard lease.isValid else { return .denied }
                                    _ = try await dataSourceSession.connection.write(change)
                                    count += 1
                                }
                                guard lease.isValid else { return .denied }
                                Task { @MainActor [weak self] in self?.onRefreshSchema?() }
                                return .payload(["executed": true, "type": "writeMany", "count": count])
                            }
                        }
                    } catch {
                        return .payload(["error": error.localizedDescription])
                    }
                },
                listCollections: { collectionNames },
                store: store,
                profileID: currentProfileID,
                resolveArtifactID: { [weak self] tabID in self?.resolveArtifactID?(tabID) },
                linkArtifact: { [weak self] tabID, artifactID in self?.linkArtifact?(tabID, artifactID) }
            )
            self.executor = executor
        } else {
            self.executor = nil
        }

 // Register graph_query alongside the SQL tools in one AISession
 // when a DSG is available for this profile; otherwise the SQL
        // executor stands alone. DSG is SQL-only (!isNoSQL).
 // Skills are always available; graph_query only with a DSG.
        if !isNoSQL, let profileID = currentProfileID, let graphExecutor = makeGraphExecutor?(profileID) {
            routes["graph_query"] = graphExecutor
            routes["get_stats"] = graphExecutor
 // preview_migration — same
            // Intelligence-tier availability as graph_query/get_stats, since
            // it compares against the same harvested DSG.
            routes["preview_migration"] = PreviewMigrationToolExecutor(previewNewColumn: { [weak self] table, column in
                await self?.previewNewColumn?(table, column) ?? nil
            })
 // simulate_impact — same
            // Intelligence-tier availability, since it also reads the
            // harvested DSG (plus query history).
            routes["simulate_impact"] = SimulateImpactToolExecutor(simulateImpact: { [weak self] table in
                self?.simulateImpact?(table) ?? nil
            })
 // get_daily_review — same
            // Intelligence-tier availability as the other bridges here.
            routes["get_daily_review"] = GetDailyReviewToolExecutor(
                maybeGenerateDailyReview: { [weak self] in await self?.maybeGenerateDailyReview?() },
                latestDailyReview: { [weak self] in self?.latestDailyReview?() }
            )
        }
        // Read fresh on every request, and re-synced against the backend once
        // on a 401 (AIClient's own retry-once), so a token lost to a Keychain
        // reset or an in-memory backend restart is silently repaired instead
        // of surfacing "Your session has expired" while the license itself is
        // still perfectly valid.
        let transport = AIClient(
            baseURL: backendURL,
            token: { LicenseManager.apiToken() ?? "dev-token" },
            reauthenticate: { [license] in await license.syncFromBackend() },
 // AI Database Coach — a global preference,
            // not per-connection (how the user likes things explained
            // doesn't change with which database they're looking at), same
            // @AppStorage key AIPanelView's picker writes.
            detailLevel: { UserDefaults.standard.string(forKey: "berry.ai.detailLevel") },
 // the user's chosen AI model, same @AppStorage key
            // AIPanelView's model picker writes. Empty string (the default)
            // is read back here too, so guard against sending a blank field.
            model: {
                let value = UserDefaults.standard.string(forKey: "berry.ai.model")
                return value?.isEmpty == false ? value : nil
            }
        )
 // search_conversation (Q17) runs entirely local now — no gateway
        // interception needed, just another client-executed tool like graph_query.
        routes["search_conversation"] = SearchConversationToolExecutor(
            store: store, transport: transport, currentThreadID: { [weak self] in self?.aiSession?.currentThreadID }
        )
 // search_schema — deliberately reads the
        // ungated `objects`/`collections` snapshot (base sidebar data, always
        // populated), NOT the Intelligence-gated harvested DSG, so this stays
        // base "ai" capability like search_conversation rather than inheriting
        // graph_query's tier gate.
        routes["search_schema"] = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { [weak self] in self?.currentProfileID },
            candidateNames: {
                isNoSQL ? collectionNames : objects.filter(\.kind.isRelational).map(\.name)
            }
        )
 // get_slow_queries — reads query_history, base
        // "ai" tier like History itself, available for SQL and NoSQL alike.
        routes["get_slow_queries"] = GetSlowQueriesToolExecutor(slowestQueries: { [weak self] limit in
            self?.slowestQueries?(limit) ?? []
        })
 // skill:<name> and mcp:<server>:<tool> route by prefix.
        capabilityHost?.invalidate()
        if let old = mcpExecutor { Task { await old.disconnectAll() } }
        let mcpExecutor = MCPToolExecutor(gate: MCPApprovalAdapter(controller: self))
        self.mcpExecutor = mcpExecutor
        let toolRouter: any AIToolExecutor = ToolRouter(
            routes: routes,
            prefixRoutes: [("skill:", skillExecutor), ("mcp:", mcpExecutor)],
            fallback: executor
        )
        let capabilityHost = LocalCapabilityHost(executor: toolRouter)
        self.capabilityHost = capabilityHost
        let toolExecutor: any AIToolExecutor = capabilityHost
        let connectionKey = currentProfileID?.uuidString
        let existingThreadID = aiSession?.currentThreadID
        let existingDialect = aiSession?.currentDialect
        let existingConnectionKey = aiSession?.currentConnectionKey
        let existingTranscript = aiSession?.transcript ?? []
        aiSession = AISession(
            transport: transport,
            executor: toolExecutor,
            dialect: dialect,
            connectionKey: connectionKey,
            schemaDigest: digest,
            store: store,
            skills: skillExecutor
        )
        // Only graft the previous AISession's in-memory transcript across a
        // rebuild when it's provably the SAME connection (e.g. a reconnect
        // that minted a fresh Session.id — ConnectionManager.open always
        // does) reconnecting mid-session, not a genuine switch to a
        // different connection. Matching on `dialect` alone let two
        // different connections of the same dialect (e.g. two Postgres
        // servers) bleed one's chat into the other's the instant the user
        // switched. `existingConnectionKey` is nil for profileless
        // quick-open connections, so those never graft across a switch
        // either — consistent with quick-open getting no persistent AI
        // identity anywhere else in this controller.
        if let existingConnectionKey, existingConnectionKey == connectionKey,
            existingDialect == dialect, let existingThreadID {
            aiSession?.loadThread(id: existingThreadID, turns: existingTranscript)
        }
        aiSession?.onTurnAdmitted = { [weak self] in self?.onTurnAdmitted?() }

 // Spawn enabled MCP servers in the background; their tools appear
        // on the next turn once tools/list returns.
        let enabled = enabledMCPServers
        Task { await mcpExecutor.connect(mcpAllowlist, enabled: enabled) }
        // Populate history immediately after session is built so the
 // history menu is non-empty even before the user opens it.
        Task { await refreshThreads(autoLoadLatest: true) }
 // Same for the balance footer: otherwise it showed nothing
        // at all until the user's first send completed — it must be visible
        // as soon as the panel is usable, not just after a message round trip.
        Task { await refreshBalance(force: true) }
    }

 /// AI Command Palette NL routing: a
    /// dedicated AI turn whose executor is deliberately narrow — UI
    /// navigation (`perform_ui_action`) plus the read-only analysis bridges
    /// already built for chat (`get_slow_queries`/`graph_query`/`get_stats`/
    /// `simulate_impact`/`preview_migration`), never `run_sql`/`propose_sql`/
    /// write tools — regardless of the model's system prompt, it has no
    /// mutating capability to misuse, so this needs no separate
    /// narrow-system-prompt backend mode ("cheapest implementation" per the
    /// doc). This is what lets "impact of dropping X"/"optimize this
 /// table"/"show slow queries" actually investigate
    /// instead of only opening a blank panel.
    /// Runs as its own `AISession`/thread rather than the panel's main one,
    /// so it costs the same as one ordinary chat turn (per the doc) without
    /// splicing routing exchanges into the user's actual conversation
    /// history. Returns whether a UI action actually fired (so the palette
    /// can dismiss deterministically without parsing the model's reply) and
    /// the model's final text for display otherwise.
    public func routeCommandPaletteQuery(_ text: String) async -> (performed: Bool, reply: String?) {
        guard LicenseManager.apiToken() != nil else { return (false, nil) }
        let entryExecutor = PerformUIActionToolExecutor(currentEntries: { [weak self] in
            self?.uiActionEntries?() ?? []
        })
        var routes: [String: any AIToolExecutor] = [
            "perform_ui_action": entryExecutor,
            "get_slow_queries": GetSlowQueriesToolExecutor(slowestQueries: { [weak self] limit in
                self?.slowestQueries?(limit) ?? []
            }),
        ]
 // Read-only analysis bridges — SQL-only, same as the
        // main chat session's own gating for these tools.
        if dataSourceSession == nil, let profileID = currentProfileID, let graphExecutor = makeGraphExecutor?(profileID) {
            routes["graph_query"] = graphExecutor
            routes["get_stats"] = graphExecutor
            routes["simulate_impact"] = SimulateImpactToolExecutor(simulateImpact: { [weak self] table in
                self?.simulateImpact?(table) ?? nil
            })
            routes["preview_migration"] = PreviewMigrationToolExecutor(previewNewColumn: { [weak self] table, column in
                await self?.previewNewColumn?(table, column) ?? nil
            })
        }
        let router = ToolRouter(routes: routes)
        let transport = AIClient(
            baseURL: backendURL,
            token: { LicenseManager.apiToken() ?? "dev-token" },
            reauthenticate: { [license] in await license.syncFromBackend() }
        )
        let dialect: String
        if let dataSourceSession {
            dialect = Self.dialectString(for: dataSourceSession.kind)
        } else if let session {
            dialect = session.config.driver.rawValue
        } else {
            dialect = "postgres"
        }
        let routingSession = AISession(
            transport: transport, executor: router,
            dialect: dialect, schemaDigest: "command-palette", store: store
        )
        await routingSession.send(text)
        let reply = routingSession.transcript.last(where: { $0.role == .assistant })?.text
        return (entryExecutor.didPerform, reply)
    }

 /// Enable/disable an allowlisted MCP server and reconnect so its tools
    /// (dis)appear. In-memory this session.
    public func setMCPServer(_ id: String, enabled: Bool) {
        if enabled { enabledMCPServers.insert(id) } else { enabledMCPServers.remove(id) }
        persistSettings()
        guard let mcpExecutor else { return }
        let servers = enabledMCPServers
        Task {
            await mcpExecutor.disconnectAll()
            await mcpExecutor.connect(mcpAllowlist, enabled: servers)
        }
    }

    // MARK: - Consent + send

 /// Accept the metadata policy and turn AI on for this connection.
    public func giveConsentAndEnable() {
        enabledForConnection = true
        consentGiven = true
    }

    /// Persists the current settings for the active profile (no-op while
    /// restoring or for a profileless quick-open connection).
    private func persistSettings() {
        guard !isRestoring, let profileID = currentProfileID else { return }
        saveSettings?(profileID, AIConnectionSettings(
            enabled: enabledForConnection,
            allowSampleRows: allowSampleRows,
            autoApproveSelects: autoApproveSelects,
            consentGiven: consentGiven,
            enabledMCPServers: enabledMCPServers,
            trustedMCPServers: trustedMCPServers
        ))
    }

    /// What `prepareSend` decided, for `send(_:)` below to carry out.
    public enum PreparedSend {
        case local(AISession.SendLocalAdmission)
        case backend(AISession.SendAdmission)
        /// The message was already appended (both bubbles) because there
        /// was nowhere to route it. `send(_:)` has nothing further to do —
        /// this just lets callers still reach their post-send logic (e.g.
        /// scrolling to the new bubble) the same as any other case.
        case handled
        /// Apple-Intelligence-only access (no real license), but this
        /// device has an email captured via the grant — try a real trial
        /// for it before giving up. Balance is shared per email across
        /// devices (not per device), so an email that already topped up
        /// elsewhere picks its balance back up automatically the moment
        /// its own fresh trial-token quota runs out — no account-linking
        /// needed, the backend already does this.
        case backendAfterTrial(AISession.SendAdmission, email: String)
    }

    /// Synchronous half of send(): validates, clears `draft`, and admits the
    /// prompt into `AISession` (`admitSend` for the backend path,
    /// `admitSendLocal` for on-device) — which appends the user's transcript
    /// bubble, and the empty "preparing" assistant bubble, immediately.
    /// Callers must run this directly on the call stack of the user action
    /// (not inside a `Task {}`) so both the composer clearing and the
    /// bubbles show up the instant Enter/Send fires, instead of waiting for
    /// a new Task's turn behind whatever is already queued on the MainActor
    /// (e.g. an in-flight turn's per-token transcript updates) — that
    /// queuing delay is what previously read as "takes forever to send, and
    /// the bubble lags even further behind that". The on-device path used to
    /// skip this (`sendLocal` was a single `async func`), so it alone kept
    /// lagging behind Send whenever the MainActor was busy.
    public func prepareSend() -> PreparedSend? {
        guard availability == .ready, let aiSession else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        draft = ""
        // A fresh message starts a fresh trust window — "Run All Safe" from
        // an earlier turn must not silently cover statements a later,
 // unrelated request proposes.
        autoApproveSafeThisTurn = false
        // A device with no real license/trial must never reach the metered
        // backend through any branch below — editing included.
        let hasRealLicense: Bool = {
            if case .none = license.status { return false }
            return true
        }()
 // Editing a past message always goes through the backend
        // versioning/tree state lives in AISession.prepareEdit, which
        // sendLocal's on-device loop doesn't participate in.
        if let messageID = editingMessageID {
            editingMessageID = nil
            guard hasRealLicense else {
                aiSession.admitBlocked(text, reason: L(
                    "Editing needs cloud AI — on-device doesn't support it yet. Add a trial, license, or credit in License settings to edit this message."
                ))
                return .handled
            }
            guard let admission = aiSession.prepareEdit(messageID: messageID, newText: text) else { return nil }
            return .backend(admission)
        }
 // On-device: checked here, at the point of sending, not in
        // `availability` — that's what keeps the toggle from also gating
        // whether the panel itself is reachable.
        if UserDefaults.standard.bool(forKey: "berry.ai.onDevice"), AppleFoundationProvider.isAvailable() {
            return .local(aiSession.admitSendLocal(text, provider: AppleFoundationProvider()))
        }
        guard hasRealLicense else {
 // no real license, but this device already has an email
            // (captured when Apple Intelligence access was granted) — try
            // a real trial for it before giving up, instead of just
            // telling the user to go do it themselves. Requires
            // `canRunImmediately` (checked and consumed on this same
            // synchronous call stack, so it can't go stale before
            // `admitSend` runs) — a message that would otherwise queue
            // must not get entangled with an auto-trial attempt that might
            // then fail, which would leave it orphaned.
            if let email = AppleIntelligenceAccess.grantedEmail, aiSession.canRunImmediately {
                return .backendAfterTrial(aiSession.admitSend(text), email: email)
            }
            aiSession.admitBlocked(text, reason: L(
                "On-device AI is off, and there's no trial or license for cloud AI. Turn on-device back on above, or add a trial, license, or credit in License settings to use cloud AI instead."
            ))
            return .handled
        }
        return .backend(aiSession.admitSend(text))
    }

    public func send(_ prepared: PreparedSend) async {
        guard let aiSession else { return }
        switch prepared {
        case .local(let admission):
            await aiSession.runLocal(admission)
        case .backend(let admission):
            await runOnBackendAndRefresh(admission)
        case .handled:
            break
        case let .backendAfterTrial(admission, email):
            await license.startTrial(email: email)
            if case .none = license.status {
                // Trial start failed (network, or the server rejected it) —
                // the assistant bubble already exists from admitSend's
                // beginTurn; fail it in place with an explanation rather
                // than leaving a permanent spinner or attempting the
                // backend call anyway with no valid token. Reuse the same
                // code→message mapping LicenseView uses (e.g. this device
 // already used its trial under a different email)
                // instead of a generic message that would bury the actual,
                // actionable reason.
                if case let .run(_, assistantIndex, assistantTurnID) = admission {
                    let reason = license.lastError.map(licenseErrorMessage) ?? L(
                        "Couldn't start a trial for cloud AI — check your connection, or add a trial, license, or credit in License settings."
                    )
                    aiSession.failActiveTurn(assistantIndex: assistantIndex, assistantTurnID: assistantTurnID, reason: reason)
                }
            } else {
                await runOnBackendAndRefresh(admission)
            }
        }
    }

    private func runOnBackendAndRefresh(_ admission: AISession.SendAdmission) async {
        guard let aiSession else { return }
        await aiSession.run(admission)
        // Reported: an admin's mid-session budget top-up left the quota-
        // exhausted banner (AIPanelView's `balance?.isExhausted` fallback)
        // stuck showing even after a retry succeeded — the 30s throttle
        // below is right for the common case, but must not win when the
        // cache is the one thing actively lying: a turn that just
        // completed without error is direct proof the cached "exhausted"
        // reading is stale, so force the refresh in exactly that case.
        let staleExhausted = balance?.isExhausted == true && aiSession.lastError == nil
        await refreshBalance(force: staleExhausted)
 // A fresh chat now exists / got its title on the backend — reflect it.
        await refreshThreads()
    }

 // MARK: - Approval gate backing

    func requestApproval(sql: String, danger: DangerLevel) async -> Bool {
        if danger == .safe, autoApproveSafeThisTurn { return true }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = PendingApproval(sql: sql, danger: danger)
        }
    }

    /// `trustRemainingSafeThisTurn`: from the approval card's "Run All Safe"
    /// button, only ever offered on a statement already classified safe —
    /// this still approves that current statement too, not just future ones.
    public func resolveApproval(_ approved: Bool, trustRemainingSafeThisTurn: Bool = false) {
        if trustRemainingSafeThisTurn { autoApproveSafeThisTurn = true }
        pendingApproval = nil
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
    }

 /// MCP tool approval. A trusted server
    /// auto-approves; otherwise the panel prompts with server/tool/args.
    func requestMCPApproval(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool = false) async -> Bool {
        if trustedMCPServers.contains(serverID), !forcePrompt { return true }
        return await withCheckedContinuation { continuation in
            mcpApprovalContinuation = continuation
            pendingMCPApproval = PendingMCPApproval(serverID: serverID, toolName: toolName, argumentsJSON: argumentsJSON)
        }
    }

    public func resolveMCPApproval(_ approved: Bool, trustServer: Bool = false) {
        if approved, trustServer, let serverID = pendingMCPApproval?.serverID {
            trustedMCPServers.insert(serverID)
            persistSettings()
        }
        pendingMCPApproval = nil
        mcpApprovalContinuation?.resume(returning: approved)
        mcpApprovalContinuation = nil
    }

 // MARK: - Balance

    /// `force` bypasses the throttle for an explicit user-facing refresh (none
    /// today, but kept for a future "refresh" action) — the implicit call
    /// after every send always respects it.
    ///
    /// The throttle timestamp is only stamped on a *successful* fetch —
    /// stamping it up front (as this used to) meant a single failed/slow
    /// attempt (e.g. `bind()`'s eager call racing the network right at app
    /// launch) consumed the whole window, silently blocking every refresh
    /// for the next 30s including the one right after the user's first
    /// send — exactly when the balance footer should finally populate.
    public func refreshBalance(force: Bool = false) async {
        if !force, let lastQuotaRefreshAttempt,
           Date().timeIntervalSince(lastQuotaRefreshAttempt) < Self.quotaRefreshInterval {
            return
        }
        guard let token = LicenseManager.apiToken() else { return }
        guard let fetched = await Balance.fetch(token: token, backendURL: backendURL) else { return }
        balance = fetched
        lastQuotaRefreshAttempt = Date()
    }

 /// Global skills directory.
    private static var skillsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BerryDB/skills", isDirectory: true)
    }

 /// Stable per-connection schema hash for the gateway's DDL cache.
    private static func digest(_ objects: [SchemaObject]) -> String {
        let joined = objects
            .map { "\($0.kind.rawValue).\($0.name)" }
            .sorted()
            .joined(separator: ",")
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func digestCollections(_ collections: [CollectionRef]) -> String {
        let names = collections.map(\.name).sorted().joined(separator: ",")
        let hash = SHA256.hash(data: Data(names.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Shared read/write execution for `run_tab_statements`/`explain_query`
 /// against a Qdrant/Elasticsearch query
    /// mirrors the Mongo branch's inline shape (stream + sample up to 10 for
    /// a read, apply each change for a write) so both connection families get
    /// the same tool contract. `changeSets.count == 1` reports `"write"`,
    /// otherwise `"writeMany"` — Qdrant/Elasticsearch query scripts have no
    /// separate single/many op the way Mongo's parser distinguishes `.write`
    /// from `.writeMany`, so the change count is the only real signal.
    private static func runDataSourceStatement(
        readQuery: DataSourceQuery?, changeSets: [DataSourceChangeSet]?, collection: String,
        dataSourceSession: DataSourceSession, lease: AIExecutionLease, onRefreshSchema: @escaping () -> Void
    ) async throws -> AIDirectStatementResult {
        if let readQuery {
            guard lease.isValid else { return .denied }
            var count = 0
            var docs: [[String: String]] = []
            for try await doc in dataSourceSession.connection.query(readQuery) {
                guard lease.isValid else { return .denied }
                if count < 10 { docs.append(["document": "\(doc)"]) }
                count += 1
            }
            guard lease.isValid else { return .denied }
            return .payload(["executed": true, "result_count": count, "sample": docs])
        }
        guard let changeSets, !changeSets.isEmpty else {
            return .payload(["error": "No statement found in script"])
        }
        var count = 0
        var lastResult: DataSourceWriteResult?
        for change in changeSets {
            guard lease.isValid else { return .denied }
            lastResult = try await dataSourceSession.connection.write(change)
            count += 1
        }
        guard lease.isValid else { return .denied }
        onRefreshSchema()
        if changeSets.count == 1, let lastResult {
            return .payload(["executed": true, "type": "write", "collection": collection, "result": "\(lastResult)"])
        }
        return .payload(["executed": true, "type": "writeMany", "count": count])
    }

    /// The `dialect` string sent to `AISession`/the backend system prompt
 /// `.document` reports "mongodb" (the
    /// backend's `system_prompt()` match arm) rather than the generic kind
    /// name; every other kind's `rawValue` already IS its own dialect token
    /// (`"vector"`, `"search"`), so no other special-casing is needed here.
    private static func dialectString(for kind: DataSourceKind) -> String {
        kind == .document ? "mongodb" : kind.rawValue
    }
}

/// Bridges the executor's approval requests to the panel controller without a
/// retain cycle (executor → gate → controller is weak; controller owns both).
@MainActor
private final class ApprovalGateAdapter: AIApprovalGate {
    weak var controller: AIPanelController?

    init(controller: AIPanelController) {
        self.controller = controller
    }

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        await controller?.requestApproval(sql: sql, danger: danger) ?? false
    }
}

/// Bridges the MCP executor's approval requests to the panel controller.
@MainActor
private final class MCPApprovalAdapter: MCPApprovalGate {
    weak var controller: AIPanelController?

    init(controller: AIPanelController) {
        self.controller = controller
    }

    func approveMCP(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool) async -> Bool {
        await controller?.requestMCPApproval(
            serverID: serverID, toolName: toolName,
            argumentsJSON: argumentsJSON, forcePrompt: forcePrompt
        ) ?? false
    }
}
