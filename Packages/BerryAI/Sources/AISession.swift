import BerryCore
import BerryStore
import Foundation
import Network

/// `Task.sleep(for:)` (generic over `Clock`) crashes in release builds when
/// multiple modules in the same binary generate different specializations of
/// it — confirmed upstream Swift runtime bug (swiftlang/swift#86204, #84793,
/// `swift_task_dealloc`/"freed pointer was not the last allocation"), not
/// application logic; see docs/tests/crash.md for this app's own hit.
/// `Task.sleep(nanoseconds:)` isn't generic over `Clock`, so it can't collide
/// — this converts a `Duration` to feed that call instead.
extension Duration {
    var berryNanoseconds: UInt64 {
        let c = components
        return UInt64(max(0, c.seconds)) * 1_000_000_000 + UInt64(max(0, c.attoseconds)) / 1_000_000_000
    }
}

/// A reference to an artifact (AI-29/30/31, docs/draft/09.md) a tool call
/// produced during a turn — rendered as a clickable chip below the bubble so
/// the user (or a later turn re-reading the transcript) can open exactly
/// what the agent wrote/ran.
public struct ArtifactRef: Sendable, Equatable, Codable {
    public let artifactID: UUID
    public let versionNumber: Int
    public let title: String
    public let kind: Artifact.Kind

    public init(artifactID: UUID, versionNumber: Int, title: String, kind: Artifact.Kind) {
        self.artifactID = artifactID
        self.versionNumber = versionNumber
        self.title = title
        self.kind = kind
    }
}

/// One tool invocation inside a working sub-block, with the detail
/// docs/feature/09's example expands under each action: the inputs it ran with,
/// a short summary of what came back, and its status.
///
/// Needed because most tools produce no artifact — "Reading schema", "Analyzing
/// queries" — so `artifactRefs` alone leaves their badge with nothing behind it.
/// Inputs/outputs are deliberately short, pre-rendered strings rather than raw
/// JSON: this is display detail, and a large `run_sql` result must not be copied
/// into the transcript (and so into memory for the whole session) just to show
/// a line about it.
public struct AIToolAction: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case running, completed, denied, failed
    }

    public var name: String
    public var status: Status
    /// Argument summaries, one per line — `docs/feature/09`'s `• export`.
    public var inputs: [String]
    /// Result summaries — the example's `Found • …`.
    public var outputs: [String]
    /// The action's primary argument, untruncated: the SQL a run executed, the
    /// contents a tab was written with, the objects a schema read inspected.
    ///
    /// Separate from `inputs` because those are capped for the row and so cannot
    /// answer "what did it actually run" — which is the question a click needs to
    /// answer. Only the ARGUMENT is kept whole, never the result: an argument is
    /// bounded by what the model can emit (a few KB), while a `run_sql` result
    /// can be megabytes, and this lives in the transcript for the whole session.
    /// Full results are reached by opening the artifact instead, where the data
    /// already lives.
    public var payload: String?

    public init(
        name: String, status: Status, inputs: [String] = [], outputs: [String] = [],
        payload: String? = nil
    ) {
        self.name = name
        self.status = status
        self.inputs = inputs
        self.outputs = outputs
        self.payload = payload
    }

    /// Whether a click has something to show. Same no-dead-affordance rule as
    /// `hasDetail`.
    public var isInspectable: Bool {
        !(payload ?? "").isEmpty
    }

    /// Whether there is anything to expand into. A badge must not offer a
    /// disclosure that opens onto nothing — that reads as a broken click, which
    /// is exactly what was reported for the artifact-less tools.
    public var hasDetail: Bool {
        !inputs.isEmpty || !outputs.isEmpty
    }

    public var statusLabel: String {
        switch status {
        case .running: return "Running"
        case .completed: return "Completed"
        case .denied: return "Denied"
        case .failed: return "Failed"
        }
    }
}

/// One conversational turn shown in the AI panel (docs/architecture/09 §5).
public struct AITurn: Identifiable, Sendable, Equatable {
    public enum Role: Sendable { case user, assistant }
    public let id: UUID
    public let role: Role
    /// The persisted `ai_message` row this turn corresponds to (AI-35) — nil
    /// until `persistTurn` writes it back, or for a turn that never made it
    /// to disk (e.g. still streaming). Distinct from `id` above, which stays
    /// a fresh random UUID minted for SwiftUI identity / `subThreads(for:)`
    /// keying and is re-minted on every reload; `messageID` is the stable
    /// link editing/version-navigation need to find "which DB row is this."
    public var messageID: UUID?
    public var text: String
    /// Optional planner output shown as a collapsible "Plan" block above the
    /// answer (docs/agents/architecture/02 §A). Empty when no planner ran.
    public var plan: String
    /// This turn's "working" state machine (docs/feature/09) — narration
    /// steps, tool-call actions/artifacts, and the live/settled timer. See
    /// `AIWorkBlock`. The properties below forward into it so existing call
    /// sites keep reading e.g. `turn.workSteps` rather than `turn.work.steps`;
    /// nothing outside `AIWorkBlock`'s own mutators writes to it directly.
    public var work: AIWorkBlock
    /// Artifacts a tool call produced during this turn (AI-31) — empty for
    /// user turns and for any assistant turn that didn't touch one.
    public var artifactRefs: [ArtifactRef]

    /// Completed prior rounds of this turn's own narration plus which
    /// tool(s) ran during that round (Task 13 round boundaries, docs/feature
    /// /09) — each earlier round's work, preserved as collapsible history
    /// instead of being overwritten by the next round the way `text` used
    /// to (docs/agents/architecture/06 §5): a multi-round tool-calling turn
    /// narrates "step 1", "step 2", … before its final answer, and all but
    /// the last round used to vanish the moment the next one started. The
    /// still-streaming/most-recent round stays in `text` above; only
    /// in-memory for the live session, not yet persisted, so a reloaded
    /// thread only shows the final round.
    public var workSteps: [AIWorkStep] { work.steps }
    /// Set the instant this turn's first `tool.call` arrives — independent
    /// of `workSteps`, whose entries can stay `.open` (see `AIWorkBlock`)
    /// well past this flag flipping true. Many multi-tool-call sequences
    /// (e.g. running several SQL statements back to back) narrate nothing
    /// between calls at all, so
    /// gating the "Working…"/"Worked for Xs" summary on `!workSteps.isEmpty`
    /// left the UI showing nothing for the whole stretch, only jumping to
    /// the final answer at the end — this flag alone is enough to show the
    /// summary continuously through that gap even with no text to expand.
    public var hadToolCall: Bool { work.hadToolCall }
    /// How many `tool.call` events this turn has seen so far — counted
    /// client-side rather than read off the backend's own executor round
    /// number, because a silent round (no narration) never sends a delta at
    /// all, so `payload.round` is simply unavailable for it.
    public var toolCallCount: Int { work.toolCallCount }
    /// Wall-clock time this turn's multi-round tool-calling phase took,
    /// start to finish. `nil` until the turn's `message.complete` lands —
    /// the UI reads that as "still working," matching a collapsed "Worked
    /// for Xs" summary line (Codex-style) instead of a per-step disclosure
    /// list once it's known.
    public var workDuration: TimeInterval? { work.duration }
    /// The instant this turn's first `tool.call` arrived — same `Date`
    /// `workDuration` is later computed from, so the view's live-ticking
    /// counter (docs/feature/09) and the eventual settled "Worked for Xs"
    /// never disagree at the collapse moment. `nil` until the first tool
    /// call (mirrors `hadToolCall`).
    public var workStartedAt: Date? { work.startedAt }
    /// Whether this turn's provider emitted any reasoning-mode trace
    /// (`reasoning.delta`, docs/architecture/09 §3) — a flag, NOT the text.
    ///
    /// The trace used to be accumulated into two properties here. It stopped
    /// being rendered when the working block moved to narration-based
    /// sub-blocks, but the append kept running on every token, and `transcript`
    /// is `@Observable` — so each write invalidated the whole view tree for a
    /// string nothing displays. One live round carried 5684 reasoning events
    /// (docs/tests/crash.md): 5684 invalidations plus O(n) string growth, for
    /// nothing. Nothing else needed the text either — it is never sent back to
    /// the backend and never persisted.
    ///
    /// The flag remains because the working block must still appear for a round
    /// that only thinks and narrates nothing.
    public var hadReasoning: Bool { work.hadReasoning }

    public init(
        id: UUID = UUID(), role: Role, text: String, plan: String = "",
        workSteps: [AIWorkStep] = [], hadToolCall: Bool = false, workDuration: TimeInterval? = nil,
        workStartedAt: Date? = nil, artifactRefs: [ArtifactRef] = [], messageID: UUID? = nil
    ) {
        self.id = id
        self.role = role
        self.messageID = messageID
        self.text = text
        self.plan = plan
        self.work = AIWorkBlock(
            steps: workSteps, startedAt: workStartedAt, duration: workDuration,
            hadToolCall: hadToolCall
        )
        self.artifactRefs = artifactRefs
    }
}

/// A sub-agent's activity, rendered as a nested card (docs/agents/architecture/06 §6).
/// Keyed by the child thread id; text is the sub-agent's streamed answer.
public struct SubAgentTranscript: Identifiable, Sendable, Equatable {
    public let id: String
    /// The assistant turn that spawned this sub-agent, so the UI can nest it there.
    public let parentTurnID: UUID
    public var text: String = ""
    public var tools: [String] = []

    public init(id: String, parentTurnID: UUID, text: String = "", tools: [String] = []) {
        self.id = id
        self.parentTurnID = parentTurnID
        self.text = text
        self.tools = tools
    }
}

/// Rebuild the display transcript from a thread's stored messages (AI-21). Keeps
/// user turns and assistant turns that actually said something; drops tool
/// results and the empty assistant messages that only carried a tool call.
public func conversationTurns(from messages: [[String: Any]]) -> [AITurn] {
    messages.compactMap { message in
        let role = message["role"] as? String ?? ""
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = (message["plan"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !plan.isEmpty else { return nil }
        switch role {
        case "user": return AITurn(role: .user, text: text)
        case "assistant": return AITurn(role: .assistant, text: text, plan: plan)
        default: return nil
        }
    }
}

/// Tunables for the client-side skill-ranking wait (Task 7.2). Kept in one
/// place, same as `AIConversationPolicy` (`ConversationEmbeddingIndexer.swift`),
/// so the bound isn't a magic number scattered inline.
public enum AISkillRankPolicy {
    /// How long `resolveTools` waits for `transport.rankSkills` before
    /// falling back to the static tool set alone for that turn. A rank call
    /// is a small JSON round trip that should normally finish in well under
    /// a second; this leaves headroom for a slow network without letting a
    /// hung backend delay `streamTurn` indefinitely.
    public static let rankTimeout: Duration = .seconds(1.5)
}

/// Drives one AI conversation against the gateway (docs/architecture/09 §3/§6).
///
/// The gateway pauses its SSE stream on a `tool.call` until we post the tool
/// result, so a tool call is handled inline in the receive loop: run the tool
/// (which prompts for approval on writes), post its outcome, then keep reading
/// the same stream as the model resumes. No detached task is needed — nothing
/// else streams while the gateway waits for us.
@MainActor
@Observable
public final class AISession {
    public private(set) var transcript: [AITurn] = []
    public private(set) var isStreaming = false
    public private(set) var lastError: String?
    public private(set) var requiresClientUpdate = false
    /// Localization key for a bounded capability-protocol error. Raw backend
    /// prose and unknown codes are never surfaced to the user.
    public private(set) var capabilityErrorLocalizationKey: String?
    /// Localization key for an ambiguous one-shot delivery. The corresponding
    /// control action is abandoned so the UI cannot replay it blindly.
    public private(set) var controlDeliveryErrorLocalizationKey: String?
    /// Name of the tool currently running, for a "Running get_schema…" hint.
    public private(set) var runningTool: String?
    /// Cumulative tokens reported by the gateway this session (AI-08 quota UI).
    public private(set) var totalTokens = 0
    /// Sub-agent transcripts by child thread id (docs/agents/architecture/06 §6).
    public private(set) var subThreads: [String: SubAgentTranscript] = [:]
    /// Child thread ids grouped by `parentTurnID`, maintained alongside
    /// `subThreads` — see `subThreads(for:)`.
    private var subThreadIDsByParentTurn: [UUID: [String]] = [:]
    /// Messages sent while a turn was already streaming, waiting to run next
    /// (AI-08): the composer stays usable during a response instead of
    /// dropping what you typed. Runs in order, one at a time.
    public private(set) var queuedMessages: [String] = []
    private var queuedMessageWasDisplayed: [Bool] = []
    /// Which path each queued message drains through — the backend queue
    /// (AI-08) only ever knew how to redrive via `runTurn`, so on-device had
    /// no queue of its own. Kept parallel to `queuedMessages`/
    /// `queuedMessageWasDisplayed` rather than folding all three into one
    /// array, matching how those two already track state.
    private var queuedMessageRunsLocally: [Bool] = []
    /// The provider from the most recent `sendLocal` call, reused by
    /// `drainQueuedMessageIfReady` to redrive a locally-queued message —
    /// `AppleFoundationProvider` is stateless in production; tests inject a
    /// scripted fake per call.
    private var lastLocalProvider: (any LocalCompletionProvider)?
    /// Fired synchronously from `beginTurn()`, the instant a new turn's
    /// (empty) assistant bubble is appended — for both a fresh `send()` and
    /// a queued message being drained once the previous turn finishes.
    /// `AIPanelView` uses this to scroll to the new bubble directly and
    /// synchronously, the same way it already does for `send()` — reported
    /// live that a message dequeued from AI-08's queue didn't get the same
    /// treatment, only ever catching up later via the slower reactive
    /// `onChange` path.
    public var onTurnAdmitted: (() -> Void)?

    /// Throttles `streamPropose` dispatch during `.toolArgDelta` — see
    /// `streamTurn`. Instance properties (not locals inside `streamTurn`)
    /// because a `Task` spawned there needs stable, actor-isolated storage to
    /// mutate; a captured local `var` triggers a Swift Concurrency "mutated
    /// after capture" warning since the compiler cannot see the capture is
    /// safe the way it can for actor-isolated storage.
    private var pendingProposeTask: Task<Void, Never>?
    private var latestPartialProposal: (name: String, sql: String)?

    /// True while a turn failed because the network was down and BerryDB is
    /// watching for it to come back to retry automatically — otherwise a
    /// turn that fails offline just sits as a dead error until the user
    /// notices and retypes it by hand.
    public private(set) var isWaitingForNetwork = false
    private var pendingNetworkRetryText: String?
    // @ObservationIgnored: never read by a View, so it shouldn't be part of
    // @Observable's tracking in the first place — also required to make
    // nonisolated(unsafe) below actually take effect (the macro's tracked
    // accessors otherwise still route through MainActor-isolated storage).
    // nonisolated(unsafe): only ever mutated on MainActor during normal
    // operation (set in startNetworkMonitor(), called from init); the one
    // nonisolated access is `deinit` cancelling it, which by definition has
    // exclusive access to `self` — no concurrent MainActor access can be
    // interleaved with an instance's own deinit. NWPathMonitor isn't provably
    // Sendable, so plain `nonisolated` (which requires that) doesn't compile.
    @ObservationIgnored
    private nonisolated(unsafe) var networkMonitor: NWPathMonitor?

    public struct PendingReport: Identifiable, Equatable {
        public let id: String
        /// Editable (Task 11): the user can revise the agent's canonical
        /// draft before confirming — see `AISession.updateReportDescription`.
        public var description: String
        public let category: String?
        public let severity: String?
        public var attachContext: Bool = true

        public init(
            id: String = UUID().uuidString,
            description: String,
            category: String? = nil,
            severity: String? = nil,
            attachContext: Bool = true
        ) {
            self.id = id
            self.description = description
            self.category = category
            self.severity = severity
            self.attachContext = attachContext
        }
    }

    /// The confirmed report draft and its `report_ready_token` (Task 11).
    /// `resolveReport(confirmed: true)` always resolves the one-shot backend
    /// interaction once resumed — accepting consumes it server-side the same
    /// as declining/cancelling does — so this survives independently of
    /// `pendingReport`/`activeInteraction`, which are cleared right after.
    /// The user can keep editing `text`/`includeContext` here; either change
    /// invalidates `readyToken` the same way editing the still-open review
    /// draft would, per `AISession.reportReadyToken` below.
    public struct ConfirmedReportDraft: Equatable {
        public var text: String
        public let category: String?
        public let severity: String?
        public var includeContext: Bool
        /// The exact summary bytes the user was shown before confirming
        /// (Task 12) — `nil` when nothing was attached. Frozen at confirm:
        /// this *is* what was consented to, so it is also exactly what
        /// submission sends and what the bound context digest hashes.
        public let conversationSummary: String?
        /// The thread and review this credential is bound to, captured at
        /// confirm rather than read live, so a submission can only ever be
        /// addressed to the conversation the user actually confirmed in.
        fileprivate let threadID: String
        fileprivate let callID: String
        /// The backend's idempotency key for this confirmation, minted once
        /// here so every retry of these bytes reuses it (Task 12). A new
        /// confirmation mints a new one, which is correct: it is a different
        /// submission.
        fileprivate let clientRequestID: String
        fileprivate let readyToken: String
        fileprivate let readyDraftDigest: String
        fileprivate let readyIncludeContext: Bool
        /// The context digest the token is actually bound to — `nil` when
        /// `readyIncludeContext` is false. The backend re-derives this at
        /// submission as `sha256(conversation_summary)` and compares it to
        /// what the credential sealed, so the client must bind the digest of
        /// the *summary the user saw*, not of the live message scope.
        fileprivate let readyContextDigest: String?
        fileprivate let readyExpiresAtUnix: Int64
    }

    /// The rough `/report` text before the user has consented to send it for
    /// backend refinement (Task 4.1 pre-refinement consent gate). Distinct
    /// from `PendingReport`, which is backend-driven and only exists once
    /// `report_draft_ready` fires — this state exists entirely beforehand,
    /// with no backend call made yet.
    public struct PendingReportDraft: Identifiable, Equatable {
        /// The owning thread's id — one undecided draft per thread.
        public let id: String
        public var text: String
        public var attachContext: Bool = true

        public init(id: String, text: String, attachContext: Bool = true) {
            self.id = id
            self.text = text
            self.attachContext = attachContext
        }
    }

    public struct PendingClarification: Identifiable, Equatable {
        public let id: String
        public let question: String
        public let reason: String?
        public let choices: [String]
        public let allowFreeText: Bool
        public let origin: AIInteraction.Origin
        public let originThreadID: String
        public let originPath: String

        public init(
            id: String = UUID().uuidString,
            question: String,
            reason: String? = nil,
            choices: [String] = [],
            allowFreeText: Bool = true,
            origin: AIInteraction.Origin = .root,
            originThreadID: String = "",
            originPath: String = "root"
        ) {
            self.id = id
            self.question = question
            self.reason = reason
            self.choices = choices
            self.allowFreeText = allowFreeText
            self.origin = origin
            self.originThreadID = originThreadID
            self.originPath = originPath
        }
    }

    public enum ClarificationResolution: Equatable {
        case answer(String)
        case decline(displayText: String)
        case cancel(displayText: String)
    }

    private enum InteractionPayload {
        case clarification(PendingClarification)
        case report(PendingReport)
    }

    private enum InteractionOrigin {
        case backend(AIInteraction)
        case local(provider: any LocalCompletionProvider)
    }

    private struct ActiveInteraction {
        let threadID: String
        var payload: InteractionPayload
        let origin: InteractionOrigin
        var isResolving: Bool
    }

    private enum SessionInteractionError: Error {
        case invalidPayload
        case conflictingInteraction
        case threadChanged
        case interactionExpired
    }

    /// Exactly one continuation may exist at a time. Keeping payload, thread,
    /// origin/token and resolution status in one value prevents mismatched
    /// ad-hoc pending fields and makes retry behavior atomic.
    private var activeInteraction: ActiveInteraction?

    /// Whether `admitSend` would run a message immediately (true) or queue
    /// it (false) — the same condition its own guards check, exposed so a
    /// caller can decide whether a precondition (AI-20: starting a real
    /// trial before running the turn) is safe to attempt without leaving a
    /// queued message orphaned if that precondition then fails.
    public var canRunImmediately: Bool {
        activeInteraction == nil && pendingReportDraft == nil && !isStreaming
    }

    public var pendingReport: PendingReport? {
        guard case let .report(report) = activeInteraction?.payload else {
            return nil
        }
        return report
    }

    public var pendingClarification: PendingClarification? {
        guard case let .clarification(clarification) = activeInteraction?.payload else {
            return nil
        }
        return clarification
    }

    /// Set by `/report` (Task 4.1) before any backend call — cleared once the
    /// user consents (moving into a real backend-driven turn) or declines.
    public private(set) var pendingReportDraft: PendingReportDraft?

    /// Set once `resolveReport(confirmed: true)` resumes the interaction
    /// (Task 11) — outlives the interaction itself, unlike `pendingReport`,
    /// so a later submission step has something to read. Intentionally
    /// doesn't gate `isInteractionPending`/`canChangeThread`: the backend
    /// interaction really is over once resumed, so the chat continues
    /// normally, exactly as it does after any other resumed interaction.
    public private(set) var confirmedReportDraft: ConfirmedReportDraft?

    /// The bounded conversation summary the user is shown *before* deciding
    /// whether to attach it (Task 12). Fetched from `/v1/ai/summarize`, never
    /// generated by the backend after the fact: the bytes reviewed here are
    /// the bytes the confirmation binds and the bytes submission sends, so
    /// what was consented to and what is stored can never diverge. `nil`
    /// means "not fetched for the open review yet".
    public private(set) var reportContextSummary: String?
    public private(set) var isPreparingReportContextSummary = false
    /// True once a summarize attempt came back unusable (empty, or beyond
    /// `AIReportPolicy.maxContextBytes`). Confirming with context attached
    /// stays blocked until a later attempt succeeds — there is nothing the
    /// user could have consented to.
    public private(set) var reportContextSummaryUnavailable = false

    /// Where the confirmed report's one submission stands (Task 12). Never
    /// advances on its own: `.submitting` is only ever reached through the
    /// explicit `submitConfirmedReport()` action.
    public enum ReportSubmissionState: Equatable, Sendable {
        case idle
        case submitting
        /// `duplicate` is the backend's idempotent-retry acknowledgement:
        /// this exact submission was already stored. Still success.
        case submitted(duplicate: Bool)
        case failed(ReportSubmissionFailure)
    }

    /// What the user can be told, and what they can do about it. Deliberately
    /// a closed set of local cases rather than backend prose — no refusal
    /// body from `/v1/agent/report` is safe or useful to render verbatim.
    public enum ReportSubmissionFailure: String, Equatable, Sendable {
        /// `403 control_token_expired` — the review itself timed out.
        case reviewExpired
        /// `403` otherwise — the credential no longer matches; reconfirm.
        case notReady
        /// `409` — something changed between confirming and submitting.
        case alreadySubmitted
        /// `413`, or a locally pre-checked oversize draft/summary.
        case tooLarge
        /// `503` or a dropped response, after the automatic retry. Retrying
        /// again is safe and reuses the same idempotency key.
        case unavailable
        case notAuthorized
        /// `426`/`400`/a malformed receipt — this client built the request
        /// wrong. Not retryable; retrying identical bytes fails identically.
        case clientError
    }

    public private(set) var reportSubmissionState: ReportSubmissionState = .idle

    /// Captured from a `report.ready` SSE event mid-turn (Task 11) so
    /// `resumeInteraction`'s caller can read it once the turn settles —
    /// reset at the start of every `resumeInteraction` call so a stale grant
    /// from an earlier interaction can never leak into a later one.
    private var lastReportReadyGrant: AIReportReadyGrant?

    /// The confirmed draft's live `report_ready_token` (Task 11), or `nil`
    /// if none has been minted yet, it expired, or the text/attach-context
    /// choice has changed since the exact digest/flag it was minted for.
    /// Recomputed from the current draft on every read — this is the only
    /// "is the report ready" signal; there is no separate boolean that could
    /// drift from it (a stale token can never masquerade as valid here).
    public var reportReadyToken: String? {
        guard let draft = confirmedReportDraft,
              draft.readyDraftDigest == AIRequestIntegrity.contentDigest(draft.text),
              draft.readyIncludeContext == draft.includeContext,
              draft.readyContextDigest == currentReportContextDigest(for: draft),
              draft.readyExpiresAtUnix > Int64(now().timeIntervalSince1970)
        else { return nil }
        return draft.readyToken
    }

    /// The attached-context digest for what would be submitted right now —
    /// `nil` when `includeContext` is off, matching the invariant
    /// `AIEvent.decode` already enforces on `report.ready`
    /// (`readyContextDigest` is nil exactly when `readyIncludeContext` is
    /// false).
    ///
    /// This hashes the *consented summary bytes*, not the live message
    /// scope (Task 12): the backend recomputes `sha256(conversation_summary)`
    /// at submission and compares it to what the credential sealed, so
    /// binding anything else here would make every context-attached
    /// submission fail with a binding mismatch. Ambient conversation
    /// activity after confirm therefore no longer invalidates the token —
    /// correctly, since the user consented to these exact bytes and these
    /// exact bytes are what gets sent.
    ///
    /// Fails closed if the summary is somehow missing while
    /// `includeContext` is on: `nil` here can never equal a non-nil
    /// `readyContextDigest`, so the token reads as invalid.
    private func currentReportContextDigest(for draft: ConfirmedReportDraft) -> String? {
        guard draft.includeContext, let summary = draft.conversationSummary else {
            return nil
        }
        return AIRequestIntegrity.contentDigest(summary)
    }

    public var isInteractionPending: Bool { activeInteraction != nil || pendingReportDraft != nil }
    public var isInteractionResolving: Bool {
        activeInteraction?.isResolving ?? false
    }
    public var canChangeThread: Bool {
        !isStreaming && activeInteraction == nil && pendingReportDraft == nil
    }
    /// Sub-agents spawned by a given assistant turn, in a stable order.
    ///
    /// The panel calls this inside a `ForEach` over every turn, and `body`
    /// re-evaluates on every streamed token — so this has to stay independent
    /// of how many turns or sub-agents the session has accumulated overall.
    /// It used to guard only on the WHOLE `subThreads` dictionary being empty
    /// (`!subThreads.isEmpty`) before filtering-and-sorting every entry
    /// against `turnID` — the intent was an early exit for "no sub-agents at
    /// all", the overwhelmingly common case, but as soon as the session had
    /// ANY sub-agent activity anywhere, every OTHER turn's call — including
    /// the turns with none of their own — paid a full filter+sort over the
    /// whole dictionary, every token. `subThreadIDsByParentTurn` is
    /// maintained incrementally by `appendSub`/`noteSubTool` specifically so
    /// this can look up just this turn's own (typically empty, sometimes
    /// small) slice directly instead.
    public func subThreads(for turnID: UUID) -> [SubAgentTranscript] {
        guard let ids = subThreadIDsByParentTurn[turnID] else { return [] }
        return ids.sorted().compactMap { subThreads[$0] }
    }

    private let transport: AITransport
    private let executor: any AIToolExecutor
    private let skills: (any SkillRanking)?
    private let dialect: String
    /// Scopes saved threads to the connection this session was bound to
    /// (§7.3 v28) — the saved profile's `UUID.uuidString`, or nil for a
    /// profileless quick-open connection. Never used for anything but
    /// thread scoping; tool execution reads the live connection directly.
    private let connectionKey: String?
    private let schemaDigest: String
    private let store: BerryStore
    private let embeddingIndexer: ConversationEmbeddingIndexer
    private let now: () -> Date
    private var threadID: String?
    private let skillRankTimeout: Duration
    /// Successful `rankSkills` results, keyed by skill content/version plus
    /// the normalized query (Task 7.2) — see `resolveTools`. Never holds a
    /// timed-out/failed attempt, so a transient hang doesn't poison later
    /// turns.
    private var skillRankCache: [String: [String]] = [:]

    public init(
        transport: AITransport,
        executor: any AIToolExecutor,
        dialect: String,
        connectionKey: String? = nil,
        schemaDigest: String,
        store: BerryStore,
        skills: (any SkillRanking)? = nil,
        skillRankTimeout: Duration = AISkillRankPolicy.rankTimeout,
        now: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.executor = executor
        self.skills = skills
        self.dialect = dialect
        self.connectionKey = connectionKey
        self.schemaDigest = schemaDigest
        self.store = store
        self.embeddingIndexer = ConversationEmbeddingIndexer(store: store, transport: transport)
        self.now = now
        self.skillRankTimeout = skillRankTimeout
        startNetworkMonitor()
    }

    /// A started `NWPathMonitor` runs until explicitly cancelled — dropping
    /// the last reference to `self` does not stop it. Without this, every
    /// discarded `AISession` (every genuine connection switch, `bind()`)
    /// leaked its monitor and its dedicated `DispatchQueue` running forever
    /// in the background.
    deinit {
        networkMonitor?.cancel()
    }

    /// Watches for connectivity returning after a turn failed offline
    /// (`runTurn`'s catch block below). One monitor per session instance —
    /// `bind()` tears down the whole session on a real connection switch,
    /// discarding this instance; `deinit` below cancels the monitor then
    /// (a *started* `NWPathMonitor` keeps running until `.cancel()` is
    /// called explicitly — dropping the last reference does not stop it,
    /// despite what this comment used to claim). The `[weak self]` handler
    /// still matters independently: it's what makes a stray callback safe
    /// if one fires in the narrow window before cancellation takes effect.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                await self?.retryAfterNetworkRestored()
            }
        }
        monitor.start(queue: DispatchQueue(label: "AISession.NWPathMonitor"))
    }

    /// Fires once per reconnect, only if a turn is actually waiting — a
    /// `.satisfied` update with nothing pending (the common case: most path
    /// updates aren't a recovery from an outage) is a no-op.
    private func retryAfterNetworkRestored() async {
        guard let text = pendingNetworkRetryText, !isStreaming else { return }
        pendingNetworkRetryText = nil
        isWaitingForNetwork = false
        await send(text)
    }

    /// Connectivity-loss errors specifically — as opposed to a server error,
    /// auth failure, or bad request, none of which will resolve themselves
    /// just because the network comes back, so none of those should queue a
    /// silent auto-retry.
    private static func isConnectivityError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotConnectToHost, .cannotFindHost, .timedOut, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Outcome of admitting a newly submitted prompt (`admitSend`).
    public enum SendAdmission: Sendable {
        case ignored
        case queued
        case reportDraft(String)
        case run(text: String, assistantIndex: Int, assistantTurnID: UUID)
    }

    /// Synchronous half of `send`: decides how `text` should be handled and,
    /// for the immediate-run case, appends the user's bubble *and* the empty
    /// assistant bubble (via `beginTurn`, which also flips `isStreaming`) to
    /// `transcript` right away. `AIPanelController.prepareSend` calls this
    /// directly on the MainActor call stack of the Enter/Send action —
    /// before any `Task` is scheduled — so neither the user's own message nor
    /// the "AI is working on it" typing indicator wait behind whatever a
    /// previous turn still streaming (or anything else) has queued on the
    /// MainActor. `send` below is the all-in-one convenience for every other
    /// caller (tests included).
    public func admitSend(_ text: String) -> SendAdmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }

        // Discovery entry lives in ChatCommands.all (BerryAI/ChatCommand.swift).
        // `/report <message>` (Task 4.1) stays local — no network call, no
        // ai_message write — until `resolveReportDraft` sees explicit consent.
        if trimmed.lowercased().hasPrefix("/report ") {
            return .reportDraft(String(trimmed.dropFirst("/report ".count)))
        }

        // Queues, same as an active backend interaction — the UI already
        // blocks this today (composer disables on isInteractionPending), but
        // the session shouldn't rely solely on that.
        guard activeInteraction == nil, pendingReportDraft == nil else {
            queuedMessages.append(trimmed)
            queuedMessageWasDisplayed.append(false)
            queuedMessageRunsLocally.append(false)
            return .queued
        }
        // A turn already streaming just queues this one instead of dropping
        // it (AI-08) — same "not a transcript bubble yet" treatment as the
        // activeInteraction branch above, so a queued send only shows up in
        // the composer's queued-messages strip until it actually dequeues
        // and runs (drainQueuedMessageIfReady appends the bubble then).
        guard !isStreaming else {
            queuedMessages.append(trimmed)
            queuedMessageWasDisplayed.append(false)
            queuedMessageRunsLocally.append(false)
            return .queued
        }
        // Nothing queued ahead of it — show both bubbles right away, it's
        // about to run.
        transcript.append(AITurn(role: .user, text: trimmed))
        let (assistant, assistantTurnID) = beginTurn()
        return .run(text: trimmed, assistantIndex: assistant, assistantTurnID: assistantTurnID)
    }

    /// For when `AIPanelController.prepareSend()` finds nowhere to actually
    /// route a turn (no real license and on-device isn't usable, or an edit
    /// attempted without cloud AI). Shows the user's own message like any
    /// other send, with `reason` filled in directly as the reply — no
    /// network/local-model call is attempted, there's nothing to run.
    public func admitBlocked(_ text: String, reason: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        transcript.append(AITurn(role: .user, text: trimmed))
        transcript.append(AITurn(role: .assistant, text: reason))
    }

    /// Fails a turn `admitSend` already began (assistant bubble already on
    /// the transcript, `isStreaming` already true) before any network call
    /// happened — for a precondition that turned out not to hold (AI-20:
    /// an auto-trial-start attempt that failed before `runTurn` ever ran).
    /// `assistantTurnID` guards against a stale call landing on a
    /// different turn that has since taken the same index.
    public func failActiveTurn(assistantIndex: Int, assistantTurnID: UUID, reason: String) {
        isStreaming = false
        defer { drainQueuedMessageIfReady() }
        guard transcript.indices.contains(assistantIndex),
              transcript[assistantIndex].id == assistantTurnID else { return }
        transcript[assistantIndex].text = reason
    }

    /// Runs the async continuation for an admission already decided by
    /// `admitSend` — the other half of the split described there.
    public func run(_ admission: SendAdmission) async {
        switch admission {
        case .ignored, .queued:
            return
        case .reportDraft(let message):
            await beginReportDraft(message)
        case .run(let text, let assistantIndex, let assistantTurnID):
            await runTurn(text, assistant: assistantIndex, assistantTurnID: assistantTurnID)
        }
    }

    public func send(_ text: String) async {
        await run(admitSend(text))
    }

    /// Sync half of editing an already-sent message (AI-35) — mirrors
    /// `admitSend`'s split and must run on the same MainActor call stack as
    /// the Edit/Send action, for the same reason documented there. Truncates
    /// `transcript` back to before the edited turn, retargets the thread's
    /// active tip to the message's ORIGINAL parent (not wherever the current
    /// leaf happens to be), then hands off to `admitSend` — which reuses the
    /// entire normal send path unchanged, since `persistTurn` reads
    /// `activeLeafMessageID` fresh at persist time. No new parameters needed
    /// on `persistTurn`/`runTurn`/`SendAdmission`. Scoped to plain user
    /// turns only — `local:interaction` rows (clarify answers, report
    /// drafts) carry resume-token/capability-host state editing would need
    /// to reconcile separately, not part of this feature.
    public func prepareEdit(messageID: UUID, newText: String) -> SendAdmission? {
        guard !isStreaming, activeInteraction == nil, pendingReportDraft == nil else { return nil }
        guard let target = try? store.aiMessage(id: messageID), target.role == "user",
              target.toolCalls != "local:interaction",
              let turnIndex = transcript.firstIndex(where: { $0.messageID == messageID })
        else { return nil }
        for removed in transcript[turnIndex...] {
            if let childIDs = subThreadIDsByParentTurn.removeValue(forKey: removed.id) {
                for childID in childIDs { subThreads.removeValue(forKey: childID) }
            }
        }
        transcript.removeSubrange(turnIndex...)
        guard var thread = try? store.aiThread(id: target.threadID) else { return nil }
        // The stored rolling summary can describe content no longer on the
        // active path after this edit — no way to "un-fold" it, so reset
        // rather than risk contaminated context; buildContext already has a
        // cursor-is-nil "rebuild from scratch" fallback to land on.
        thread.summary = ""
        thread.summaryThroughSeq = nil
        thread.activeLeafMessageID = target.parentID
        try? store.saveAIThread(thread)
        return admitSend(newText)
    }

    /// Switches to a different version at a fork point (AI-35's `‹ i/N ›`
    /// nav) — `messageID` names ONE sibling; this resolves that sibling's
    /// own current tip (it may itself have been edited further since) and
    /// reloads the transcript for that path.
    public func selectSibling(messageID: UUID) async {
        guard !isStreaming, activeInteraction == nil, pendingReportDraft == nil,
              let id = threadID, let uuid = UUID(uuidString: id)
        else { return }
        guard let tip = try? store.resolveTip(threadID: uuid, from: messageID),
              var thread = try? store.aiThread(id: uuid)
        else { return }
        thread.summary = ""
        thread.summaryThroughSeq = nil
        thread.activeLeafMessageID = tip
        try? store.saveAIThread(thread)
        guard let turns = try? activeTurns(threadID: uuid) else { return }
        loadThread(id: id, turns: turns)
    }

    /// Every version of `messageID`'s message (siblings sharing its parent),
    /// oldest first — a single-element (or empty) result means nothing to
    /// navigate. The UI shows `‹ i/N ›` only when this has more than one.
    public func siblings(of messageID: UUID) -> [UUID] {
        guard let id = threadID, let uuid = UUID(uuidString: id),
              let message = try? store.aiMessage(id: messageID)
        else { return [] }
        let groups = (try? store.siblingGroups(threadID: uuid)) ?? [:]
        return groups[message.parentID] ?? []
    }

    /// Synchronous: resets per-turn error state, appends the empty assistant
    /// bubble, and flips `isStreaming` — the "AI is now working on it" cue
    /// (typing indicator). Split out of `runTurn` so eager callers
    /// (`admitSend`, and the two call sites below that already run
    /// synchronously up to their own `Task`/`await runTurn`) can show that
    /// cue immediately instead of waiting for `runTurn` itself to start.
    private func beginTurn() -> (index: Int, id: UUID) {
        lastError = nil
        requiresClientUpdate = false
        capabilityErrorLocalizationKey = nil
        controlDeliveryErrorLocalizationKey = nil
        transcript.append(AITurn(role: .assistant, text: ""))
        let assistant = transcript.count - 1
        isStreaming = true
        onTurnAdmitted?()
        return (assistant, transcript[assistant].id)
    }

    /// Runs one turn against the gateway. Only ever called when `isStreaming`
    /// is false — either directly from `send`, or from the queue drain below.
    /// `assistant`/`assistantTurnID` must come from a `beginTurn()` the
    /// caller already ran (see call sites) — `runTurn` itself no longer
    /// appends the placeholder, so that cue can show up before this
    /// `async` function gets its turn on the MainActor.
    ///
    /// `persist`/`contextOverride` back the Task 4.1 report-refinement turn
    /// (`resolveReportDraft`): the rough text and this turn's exchange must
    /// never reach `ai_message`/the embedding indexer, and an "attach recent
    /// conversation" toggle turned off must send no local context at all —
    /// neither is true for any other caller, which is why both default to
    /// the normal, unsuppressed behavior.
    private func runTurn(
        _ trimmed: String, assistant: Int, assistantTurnID: UUID,
        persist: Bool = true, contextOverride: AITurnContext? = nil
    ) async {
        defer {
            isStreaming = false
            runningTool = nil
            if lastError != nil || capabilityErrorLocalizationKey != nil
                || controlDeliveryErrorLocalizationKey != nil || isWaitingForNetwork,
               transcript.indices.contains(assistant),
               transcript[assistant].id == assistantTurnID,
               transcript[assistant].text.isEmpty,
               transcript[assistant].plan.isEmpty,
               // A turn that did real work (narrated, called a tool, or
               // reasoned) must survive even with empty `text` — a provider
               // error before any committed answer arrived is exactly the
               // case `streamTurn`'s turn-end `defer` (`settleWork`) exists
               // to settle, not silently discard. Only a turn that never did
               // anything at all is dead weight worth removing.
               !transcript[assistant].hadToolCall,
               !transcript[assistant].hadReasoning,
               transcript[assistant].workSteps.isEmpty,
               !subThreads.values.contains(where: { $0.parentTurnID == assistantTurnID }) {
                transcript.remove(at: assistant)
            }
            drainQueuedMessageIfReady()
        }

        do {
            // Independent of each other (resolveTools doesn't need the
            // thread, ensureThread doesn't need the tool list) — run them
            // concurrently rather than paying both round trips back to back
            // before the actual message can go out.
            //
            // Diagnostic-only timing around this block, chasing a live
            // report of a long stall between send() and the SSE stream
            // actually opening (~49s observed, with the MainActor
            // apparently starved enough in that window to delay even an
            // unrelated `DispatchQueue.main.asyncAfter(0.05)` scroll
            // callback by 32s) — no behavior change.
            let preStreamStart = Date()
            async let threadTask = ensureThread()
            async let toolsTask = resolveTools(for: trimmed)
            var thread = try await threadTask
            DiagnosticLog.default.event(
                "runTurn: ensureThread done", detail: "elapsed=\(Int(-preStreamStart.timeIntervalSinceNow * 1000))ms"
            )
            // buildContext only needs the thread id resolved above, not the
            // tool list — start it now so its SQLite read overlaps with the
            // still-running skill-rank round trip instead of waiting for it.
            // (Captured into a `let` first: `thread` itself is a `var`
            // reassigned on the 404-retry path below, and passing a `var`
            // directly into an `async let` trips strict-concurrency's
            // sending-risk check even though the reassignment happens only
            // after this task is already awaited.)
            let threadForContext = thread
            async let contextTask = contextForTurn(threadID: threadForContext, override: contextOverride)
            let tools = await toolsTask
            DiagnosticLog.default.event(
                "runTurn: resolveTools done", detail: "elapsed=\(Int(-preStreamStart.timeIntervalSinceNow * 1000))ms"
            )
            let capabilities = try (executor as? LocalCapabilityHost)?.beginTurn(with: tools)
            let (context, pendingSummaryFold) = await contextTask
            DiagnosticLog.default.event(
                "runTurn: contextForTurn done, about to call streamTurn",
                detail: "elapsed=\(Int(-preStreamStart.timeIntervalSinceNow * 1000))ms"
            )
            do {
                try await streamTurn(threadID: thread, text: trimmed, tools: tools, capabilities: capabilities, context: context, resume: nil, assistantIndex: assistant, assistantTurnID: assistantTurnID)
            } catch AITransportError.badResponse(let code, _) where code == 404 {
                threadID = nil
                thread = try await ensureThread()
                let retryCapabilities = try (executor as? LocalCapabilityHost)?
                    .beginTurn(with: tools)
                try await streamTurn(threadID: thread, text: trimmed, tools: tools, capabilities: retryCapabilities, context: context, resume: nil, assistantIndex: assistant, assistantTurnID: assistantTurnID)
            }
            if persist {
                let interactionMarker = pendingClarification != nil || pendingReport != nil
                    ? "local:interaction" : nil
                let persisted = await persistTurn(
                    threadID: thread, userText: trimmed,
                    assistantText: transcript[assistant].text,
                    assistantMetadata: interactionMarker,
                    assistantArtifactRefs: transcript[assistant].artifactRefs
                )
                applyPersistedMessageIDs(persisted, assistant: assistant)
                if !persisted.isEmpty {
                    let indexer = embeddingIndexer
                    Task { await indexer.index(persisted) }
                }
                // Only after this turn is safely persisted (Task 7.1) — never
                // delays the postMessage that just completed above, and never
                // runs at all for a turn that failed to persist.
                if let pendingSummaryFold {
                    let sessionStore = store
                    let sessionTransport = transport
                    Task { await Self.applySummaryFold(pendingSummaryFold, store: sessionStore, transport: sessionTransport) }
                }
            }
        } catch {
            if case AITransportError.clientUpdateRequired = error {
                requiresClientUpdate = true
            } else if case AITransportError.capabilityNegotiationFailed = error {
                requiresClientUpdate = true
            } else if error is LocalCapabilityError {
                requiresClientUpdate = true
            }
            if case let AITransportError.capabilityRejected(code) = error {
                capabilityErrorLocalizationKey = Self.capabilityErrorLocalizationKey(for: code)
            }
            if case let AITransportError.badResponse(code, _) = error, code == 404 {
                threadID = nil
            }
            if case let AITransportError.protocolViolation(code) = error {
                lastError = code
            } else if case SessionInteractionError.interactionExpired = error {
                lastError = nil
                controlDeliveryErrorLocalizationKey =
                    "This AI request expired. Ask the agent to try again."
            } else if case AITransportError.toolResultDeliveryAmbiguous = error {
                controlDeliveryErrorLocalizationKey =
                    "The result may have been received, so BerryDB stopped safely instead of sending it twice."
            } else if Self.isConnectivityError(error) {
                // No point surfacing a dead-end error for something that
                // will very likely resolve itself — queue this exact text
                // for a silent one-shot retry once the network monitor
                // reports the connection is back.
                pendingNetworkRetryText = trimmed
                isWaitingForNetwork = true
                lastError = nil
            } else if capabilityErrorLocalizationKey == nil {
                lastError = Self.describe(error)
            }
        }
    }

    /// `/report` interception (Task 4.1): the rough-local state. Ensuring the
    /// thread only writes the local `ai_thread` row (`ensureThread` — no
    /// network call), and the draft is persisted to `BerryStore` before it's
    /// published so app-restart recovery and explicit deletion both have
    /// something to read/remove. A second `/report` while one is already
    /// undecided, or while a backend interaction is active, is ignored.
    private func beginReportDraft(_ message: String) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, activeInteraction == nil, pendingReportDraft == nil else { return }
        guard let thread = try? await ensureThread(), let id = UUID(uuidString: thread) else { return }
        try? store.savePendingReportDraft(AIPendingReportDraftRecord(
            threadID: id, text: text, attachContext: true, createdAt: now()
        ))
        pendingReportDraft = PendingReportDraft(id: thread, text: text)
    }

    /// Cancels one not-yet-sent queued message — the composer's queue strip
    /// calls this from its per-row remove button. `index` is a position into
    /// `queuedMessages` (what the strip already enumerates over), removed
    /// from all three parallel arrays together so a later drain never reads
    /// a stale `wasDisplayed`/`runsLocally` for a since-shifted message.
    /// Out-of-bounds is a silent no-op — the row it belonged to is simply
    /// gone from the UI by the time this would matter.
    public func removeQueuedMessage(at index: Int) {
        guard queuedMessages.indices.contains(index) else { return }
        queuedMessages.remove(at: index)
        if queuedMessageWasDisplayed.indices.contains(index) {
            queuedMessageWasDisplayed.remove(at: index)
        }
        if queuedMessageRunsLocally.indices.contains(index) {
            queuedMessageRunsLocally.remove(at: index)
        }
    }

    /// Pops the leading run of `queuedMessages` that can merge into one
    /// turn: consecutive entries sharing the same `runsLocally`
    /// destination, none of them already displayed on their own
    /// (`queuedMessageWasDisplayed == false` — true for every entry any
    /// call site pushes today; see the doc comment on
    /// `drainQueuedMessageIfReady` for why an already-displayed entry never
    /// extends a run). Always pops at least 1 entry. Removes the popped
    /// prefix from all three parallel arrays.
    private func drainMergeableRun() -> (texts: [String], runsLocally: Bool, firstWasDisplayed: Bool) {
        let runsLocally = queuedMessageRunsLocally.first ?? false
        let firstWasDisplayed = queuedMessageWasDisplayed.first ?? true
        var count = 1
        if !firstWasDisplayed {
            while count < queuedMessages.count,
                  queuedMessageWasDisplayed[count] == false,
                  queuedMessageRunsLocally[count] == runsLocally {
                count += 1
            }
        }
        let texts = Array(queuedMessages.prefix(count))
        queuedMessages.removeFirst(count)
        queuedMessageWasDisplayed.removeFirst(min(count, queuedMessageWasDisplayed.count))
        queuedMessageRunsLocally.removeFirst(min(count, queuedMessageRunsLocally.count))
        return (texts, runsLocally, firstWasDisplayed)
    }

    /// Drains the front of the queue into one turn. A run of 2+ mergeable
    /// entries (see `drainMergeableRun`) becomes one numbered bubble and one
    /// combined turn instead of one turn per message — the wait for the
    /// Nth queued message used to be the sum of every turn ahead of it.
    /// `wasDisplayed` (see `drainMergeableRun`) is only meaningful for a
    /// lone popped entry (an interaction/report completion site that
    /// already showed this text's bubble itself); a merged run is never
    /// already displayed, by construction.
    private func drainQueuedMessageIfReady() {
        guard !isStreaming, activeInteraction == nil,
              !queuedMessages.isEmpty else { return }
        let run = drainMergeableRun()
        let text: String
        if run.texts.count > 1 {
            text = run.texts.enumerated()
                .map { "\($0.offset + 1)) \($0.element)" }
                .joined(separator: "\n")
            transcript.append(AITurn(role: .user, text: text))
        } else {
            text = run.texts[0]
            if !run.firstWasDisplayed {
                transcript.append(AITurn(role: .user, text: text))
            }
        }
        let (assistant, assistantTurnID) = beginTurn()
        if run.runsLocally, let provider = lastLocalProvider {
            Task { [weak self] in
                await self?.runLocalTurn(text, provider: provider, assistant: assistant)
            }
        } else {
            Task { [weak self] in
                await self?.runTurn(text, assistant: assistant, assistantTurnID: assistantTurnID)
            }
        }
    }

    /// One pending rolling-summary fold: the previous summary text and the
    /// not-yet-folded delta computed at `buildContext` time, deferred so the
    /// `/v1/ai/summarize` round trip never blocks the turn that discovered it
    /// (Task 7.1 — see `runTurn`'s persist step, which fires it the same way
    /// `embeddingIndexer.index` is fired).
    private struct PendingSummaryFold {
        let threadID: String
        let previous: String
        let delta: [AIContextMessage]
        let newCursor: Int?
    }

    /// Client-built turn context (Q17 §7.4): the last `recentWindow` local
    /// messages, plus the last *successfully persisted* rolling summary and
    /// whatever hasn't been folded into it yet, sent as raw messages instead
    /// of waiting on a fresh fold (Task 7.1) — no network call happens here.
    /// The actual fold (`applySummaryFold`) runs in the background after this
    /// turn persists; `summaryThroughSeq` only ever advances there, and only
    /// after a successful response, so a slow/failed fold just leaves later
    /// turns sending a slightly longer unsummarized tail, never stale or
    /// duplicated content.
    ///
    /// Filters out `toolCalls == "local:interaction"` rows the same way
    /// `recentReportContext` already does — that marker means control-plane
    /// content (a clarify_request Q&A, a report draft) that must never
    /// resurface as conversational context for a later, unrelated turn, and
    /// must never be folded into `summarize()` either. Without this, an
    /// interaction row excluded from embedding could still leak back into
    /// the model verbatim via ordinary context/summary once the thread grows.
    private func buildContext(
        threadID: String
    ) async -> (context: AITurnContext, fold: PendingSummaryFold?) {
        guard let id = UUID(uuidString: threadID) else {
            return (AITurnContext(summary: "", recentMessages: []), nil)
        }
        // Bounded probe: fetch one more than the threshold, so its row count
        // alone says whether this thread needs compression — never fetching a
        // long-lived thread's full history just to learn it's long (docs/feature/08
        // perf follow-up: the DB read below used to be `aiMessagesAsync(threadID:)`
        // unbounded, re-fetching the entire thread on every single turn).
        // AI-35: active path only, throughout — an edited-away message must
        // not leak into the model's own context.
        let probeLimit = AIConversationPolicy.summaryThreshold + 1
        let probe = (try? await store.activeAIRecentMessagesAsync(threadID: id, limit: probeLimit)) ?? []
        guard probe.count > AIConversationPolicy.summaryThreshold else {
            return (
                AITurnContext(
                    summary: "",
                    recentMessages: probe.map { AIContextMessage(role: $0.role, content: $0.content) }
                ),
                nil
            )
        }
        let recentRecords = (try? await store.activeAIRecentMessagesAsync(
            threadID: id, limit: AIConversationPolicy.recentWindow
        )) ?? []
        let recent = recentRecords.map { AIContextMessage(role: $0.role, content: $0.content) }
        let recentIDs = Set(recentRecords.map(\.id))
        let storedThread = try? await store.aiThreadAsync(id: id)
        let previous = storedThread?.summary ?? ""
        let cursor = storedThread?.summaryThroughSeq
        // A pre-v18 summary has unknown coverage. Rebuild the prefix once from
        // source instead of risking duplicated information in an incremental
        // fold — the one remaining unbounded fetch, and only ever hit once per
        // thread (every fold after the first sets a cursor).
        let sinceCursor: [AIMessageRecord]
        if let cursor {
            sinceCursor = (try? await store.activeAIMessagesAsync(threadID: id, sinceSeq: cursor)) ?? []
        } else {
            sinceCursor = ((try? await store.activeAIMessagesAsync(threadID: id)) ?? [])
                .filter { $0.toolCalls != "local:interaction" }
        }
        let delta = sinceCursor.filter { !recentIDs.contains($0.id) }
        guard !delta.isEmpty else {
            return (AITurnContext(summary: previous, recentMessages: recent), nil)
        }
        let tail = delta.map { AIContextMessage(role: $0.role, content: $0.content) }
        let fold = PendingSummaryFold(
            threadID: threadID,
            previous: cursor == nil ? "" : previous,
            delta: tail,
            newCursor: delta.last?.seq
        )
        let (boundedTail, droppedCount) = Self.boundedTail(tail, recent: recent)
        guard droppedCount > 0 else {
            return (AITurnContext(summary: previous, recentMessages: boundedTail + recent), fold)
        }
        // Bound exceeded: degrade explicitly instead of silently dropping the
        // newest context (Task 7.1). The notice is visible in what's actually
        // sent, and the fold that would absorb the dropped messages is fired
        // right now rather than deferred to this turn's (possibly failing)
        // persist step, so the backlog shrinks before it can grow further.
        let notice = "[\(droppedCount) older message(s) omitted from this turn's context — a summary refresh is in progress.]"
        let sessionStore = store
        let sessionTransport = transport
        Task { await Self.applySummaryFold(fold, store: sessionStore, transport: sessionTransport) }
        return (
            AITurnContext(
                summary: previous.isEmpty ? notice : "\(previous)\n\n\(notice)",
                recentMessages: boundedTail + recent
            ),
            nil
        )
    }

    /// Wraps the contextOverride/buildContext choice so `runTurn` can start it
    /// as its own `async let` right after the thread id resolves, instead of
    /// only after also awaiting the (possibly slower) tool-resolution call.
    private func contextForTurn(
        threadID: String, override: AITurnContext?
    ) async -> (context: AITurnContext, fold: PendingSummaryFold?) {
        if let override { return (context: override, fold: nil) }
        return await buildContext(threadID: threadID)
    }

    /// Safety margin under the backend's hard context cap
    /// (`AIConversationPolicy.contextMessageHardCap`/`contextByteHardCap`) so
    /// this turn's own outgoing text and tool schemas still fit inside the
    /// request (Task 7.1).
    private static let contextMessageMargin = 8
    private static let contextByteMargin = 32 * 1024

    /// Trims `tail` (the not-yet-summarized messages older than
    /// `recentWindow`) so `tail + recent` stays under the backend's hard
    /// context cap. `recent` is always kept whole; the oldest `tail` entries
    /// are dropped first — they're still covered by the fold this triggers,
    /// so nothing is lost permanently, only deferred to the next turn.
    private static func boundedTail(
        _ tail: [AIContextMessage], recent: [AIContextMessage]
    ) -> (tail: [AIContextMessage], droppedCount: Int) {
        let recentBytes = recent.reduce(0) { $0 + $1.content.utf8.count }
        let messageBudget = AIConversationPolicy.contextMessageHardCap
            - contextMessageMargin - recent.count
        var byteBudget = AIConversationPolicy.contextByteHardCap
            - contextByteMargin - recentBytes
        guard messageBudget > 0, byteBudget > 0 else { return ([], tail.count) }
        var kept: [AIContextMessage] = []
        for message in tail.reversed() {
            let cost = message.content.utf8.count
            guard kept.count < messageBudget, cost <= byteBudget else { break }
            kept.append(message)
            byteBudget -= cost
        }
        return (kept.reversed(), tail.count - kept.count)
    }

    /// Folds `job`'s captured delta into the persisted rolling summary (Task
    /// 7.1). `store`/`transport` are passed explicitly rather than captured
    /// via `self` — the same `Task { ... }`-without-`self` shape `runTurn`
    /// already uses to kick off `embeddingIndexer.index` — so this keeps
    /// running to completion even if the session that scheduled it is gone
    /// (app close) or the caller's own task was cancelled. Re-reads the
    /// thread's cursor immediately before writing so an outdated result
    /// racing a newer fold (e.g. from an overlapping later turn) can't move
    /// `summaryThroughSeq` backward.
    private static func applySummaryFold(
        _ job: PendingSummaryFold, store: BerryStore, transport: AITransport
    ) async {
        guard let id = UUID(uuidString: job.threadID) else { return }
        let summary = await transport.summarize(previous: job.previous, messages: job.delta)
        guard !summary.isEmpty, let newCursor = job.newCursor else { return }
        guard var thread = try? store.aiThread(id: id) else { return }
        if let existingCursor = thread.summaryThroughSeq, existingCursor >= newCursor {
            return
        }
        thread.summary = summary
        thread.summaryThroughSeq = newCursor
        thread.updatedAt = Date()
        try? store.saveAIThread(thread)
    }

    /// Persists the turn locally (Q17 §7.3) — the backend no longer does this
    /// (stateless `post_message`, §7.4). Only the display-level user/assistant
    /// text is kept, not intermediate tool-call/tool-result messages (unlike
    /// the old backend's full raw history) — the next turn's context is
    /// slightly less detailed there, but display/summary continuity holds.
    private func persistTurn(
        threadID: String, userText: String?, assistantText: String,
        userMetadata: String? = nil, assistantMetadata: String? = nil,
        assistantArtifactRefs: [ArtifactRef] = []
    ) async -> [AIMessageRecord] {
        guard let id = UUID(uuidString: threadID) else { return [] }
        guard var thread = try? await store.aiThreadAsync(id: id) else { return [] }
        var seq = (try? await store.aiMessagesAsync(threadID: id).count) ?? 0
        let now = Date()
        var persisted: [AIMessageRecord] = []
        // AI-35: every write chains onto the thread's current active tip and
        // advances it, so the message tree never has a gap — this applies
        // uniformly to normal sends, interaction resolution, and report
        // turns (every `persistTurn` call site), even though only normal
        // sends are user-editable today.
        var cursor = thread.activeLeafMessageID
        if let userText, !userText.isEmpty {
            let user = AIMessageRecord(
                threadID: id, seq: seq, role: "user",
                content: userText, toolCalls: userMetadata, createdAt: now, parentID: cursor
            )
            if (try? await store.appendAIMessageAsync(user)) != nil {
                persisted.append(user)
                cursor = user.id
            }
            seq += 1
        }
        let trimmedAssistant = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedAssistant.isEmpty {
            let assistant = AIMessageRecord(
                threadID: id, seq: seq, role: "assistant",
                content: assistantText, toolCalls: assistantMetadata, createdAt: now,
                artifactsJSON: Self.encodeArtifactRefs(assistantArtifactRefs), parentID: cursor
            )
            if (try? await store.appendAIMessageAsync(assistant)) != nil {
                persisted.append(assistant)
                cursor = assistant.id
            }
        }
        if thread.title == nil {
            thread.title = userText.map { String($0.prefix(48)) }
        }
        thread.updatedAt = now
        thread.activeLeafMessageID = cursor
        try? await store.saveAIThreadAsync(thread)
        return persisted
    }

    /// Writes `persistTurn`'s returned records' ids back onto the transcript
    /// entries they came from (AI-35) — every call site appends the user
    /// turn immediately before `assistant`'s empty placeholder (`admitSend`/
    /// `beginTurn` and this file's other turn-starting call sites all follow
    /// that same shape), so matching by role against those two fixed
    /// positions is enough; `persistTurn`'s return value used to be handed
    /// only to the embedding indexer and otherwise discarded, leaving every
    /// `AITurn` with no stable link back to its DB row.
    private func applyPersistedMessageIDs(_ persisted: [AIMessageRecord], assistant: Int) {
        for record in persisted {
            switch record.role {
            case "user" where transcript.indices.contains(assistant - 1):
                transcript[assistant - 1].messageID = record.id
            case "assistant" where transcript.indices.contains(assistant):
                transcript[assistant].messageID = record.id
            default:
                break
            }
        }
    }

    /// Tracks round/segment boundaries for one stream of assistant text
    /// (the root transcript, or one sub-agent) so a new round's text starts
    /// fresh in `AITurn.text` rather than concatenating onto the previous
    /// round's narration — the previous round's text is preserved in
    /// `AITurn.workSteps` first (root only; sub-agents still just replace, see
    /// `appendSub`'s `replace` flag). Round/segmentID is authoritative
    /// when the backend sends it — a changed value marks a boundary even
    /// without a `tool.call` in between. Legacy/local providers send no
    /// metadata at all, so `startsNewRound` falls back to whatever
    /// `markToolCallBoundary` last recorded, matching the plan's "infer a
    /// boundary after tool.call" fallback for older clients.
    private struct RoundCursor {
        private var key: String?
        private var legacyBoundaryPending = false

        mutating func startsNewRound(round: Int?, segmentID: String?) -> Bool {
            if let newKey = segmentID ?? round.map(String.init) {
                let isNew = key != newKey
                key = newKey
                return isNew
            }
            defer { legacyBoundaryPending = false }
            return legacyBoundaryPending
        }

        mutating func markToolCallBoundary() {
            legacyBoundaryPending = true
        }
    }

    private func streamTurn(
        threadID: String,
        text: String,
        tools: [AIToolSpec],
        capabilities: AICapabilityAdvertisement?,
        context: AITurnContext,
        resume: AIInteractionResume?,
        assistantIndex: Int,
        assistantTurnID: UUID
    ) async throws {
        let rootID = threadID
        // Accumulate streaming sql arg fragments from propose_sql / create_debug_tab
        // so we can mirror them to the editor tab progressively.
        var streamingToolName: String? = nil
        var streamingArgBuffer: String = ""
        // Resumes `scanPartialStringValue` from where the previous delta left
        // off instead of rescanning `streamingArgBuffer` from the start every
        // time — reset together with it below.
        var partialValueScan = PartialStringScan()
        // `pendingProposeTask`/`latestPartialProposal` throttle how often a
        // partial SQL value reaches the editor tab — see the `.toolArgDelta`
        // and `.toolCall` cases below. They are instance properties, not
        // locals here; see their declaration for why.
        pendingProposeTask = nil
        latestPartialProposal = nil
        // Owned by `.delta` alone. It briefly had a sibling for
        // `reasoning.delta`, added because sharing one mutating cursor let
        // whichever event arrived first consume the round boundary — leaving
        // `.delta` to concatenate every round's narration and never flush a
        // sub-block. That sibling is gone now only because `.reasoning` no
        // longer tracks rounds at all (it discards its text); the underlying
        // hazard is unchanged, so any future per-round consumer of another
        // event kind needs its own cursor, never this one.
        var rootRoundCursor = RoundCursor()
        var subRoundCursors: [String: RoundCursor] = [:]

        let capabilityHost = executor as? LocalCapabilityHost
        var validatedResumeReceipt = resume == nil
        // Set only for a `report_draft_ready` interaction (Task 11): unlike
        // `clarify_request`, its `report.draft` digest preview is emitted
        // immediately after `interaction.required` on the very same stream,
        // so suspending/publishing must wait for the stream to actually
        // close rather than returning the instant the interaction arrives —
        // an early return here would stop pulling from the stream and the
        // preview would never be read.
        var pendingSuspendedInteraction: (prepared: ActiveInteraction, assistantIndex: Int)?
        // Settle the working block on EVERY exit from this turn, not just the
        // `message.complete` handler below. `gateway.rs` ends a turn with an
        // `error` event and no `message.complete` on several real paths (a
        // provider failure mid-round, an unauthorized tool, the step-limit
        // dead end), and this function can also return early on a suspended
        // interaction or throw on a transport failure. `workDuration` set only
        // from `message.complete` left every one of those cases ticking
        // "Working…" forever on a turn that had already stopped — the reported
        // hang. Now that `TurnView.showsResponseText` gates the response
        // bubble on this same value (docs/feature/09 §block response), an
        // unsettled block would also hide whatever partial answer did arrive.
        //
        // Guarded on the turn still being the one we started (same index and
        // id — `runTurn`'s own `defer` can remove an errored empty turn) and
        // on it actually having had a working block to settle.
        defer {
            // The safety net for every exit path OTHER than `message.complete`
            // (which already called this eagerly, above) — error, thrown
            // transport failure, cancellation, interaction suspension.
            // `settleWork` is idempotent, so this is a no-op on the happy path.
            settleWork(assistantIndex: assistantIndex, assistantTurnID: assistantTurnID)
        }
        do {
            // Section marker, not a truncate: post-turn actions (an artifact
            // click) and cross-turn slowdowns both need earlier turns to
            // survive. `startSection` trims by size only.
            //
            // `resume` tags whether this call came from `resumeInteraction`
            // (resolving a clarification/report) or the main send/404-retry
            // path (both pass `resume: nil`) — added to chase a live report
            // of ~21 distinct threads each opening and closing an empty
            // stream within about a second, one of them 10 times over, right
            // where a turn later got its tool result rejected as
            // `control_token_unknown` (the gateway's pending-tool TTL had
            // expired by the time the client got back to it). `streamTurn`
            // only has 3 call sites total, all in this file, so this is
            // enough to tell them apart on the next repro without guessing.
            DiagnosticLog.default.startSection(
                "turn start thread=\(threadID) resume=\(resume != nil) action=\(resume?.action.rawValue ?? "-")"
            )
            for try await stream in transport.postMessage(
                threadID: threadID, text: text, tools: tools,
                capabilities: capabilities, context: context, dialect: dialect,
                resume: resume
            ) {
            // Coalesced: this is the consumer side of the same per-token
            // firehose. Pairing its counts/spans against the producer's
            // ("producer: …" in the same file) is what makes the client
            // falling behind visible — a burst with the same count taking
            // longer here than there is the signal.
            DiagnosticLog.default.tick("consumer: \(stream.event.diagnosticKind)")
            let tid = stream.threadID ?? rootID
            let isRoot = tid == rootID
            if !validatedResumeReceipt {
                if case .capabilityMode = stream.event {
                    // Derived from the HTTP response header, not an SSE event.
                } else if case let .interactionReceipt(receipt) = stream.event,
                          isRoot,
                          receipt.threadID == rootID,
                          receipt.clientRequestID == resume?.clientRequestID,
                          receipt.requestDigest == resume?.requestDigest {
                    validatedResumeReceipt = true
                } else {
                    throw AITransportError.protocolViolation(
                        code: "interaction_receipt_required"
                    )
                }
            } else if resume == nil,
                      case .interactionReceipt = stream.event {
                throw AITransportError.protocolViolation(
                    code: "unexpected_interaction_receipt"
                )
            }
            switch stream.event {
            case let .capabilityMode(mode):
                guard isRoot, let host = executor as? LocalCapabilityHost else { break }
                try host.setTransportMode(mode)
            case let .capabilitiesAccepted(value):
                guard isRoot, let host = executor as? LocalCapabilityHost else { break }
                try host.accept(value)
            case let .delta(payload):
                if isRoot {
                    let isNewRound = rootRoundCursor.startsNewRound(
                        round: payload.round, segmentID: payload.segmentID
                    )
                    // Mutate `work`/`text` in place through `transcript`'s own
                    // storage — going via a `var newTranscript = transcript`
                    // copy first forces a full COW copy of every turn in the
                    // conversation on every single token (a second live
                    // reference to the same buffer defeats the uniqueness
                    // check), which gets slower the longer the thread is and
                    // reads as the reply typing out more slowly than it's
                    // actually arriving.
                    if isNewRound {
                        transcript[assistantIndex].work.roundBoundaryCrossed(now: Date())
                    }
                    if !transcript[assistantIndex].work.hadToolCall {
                        // No tool has run yet this turn: unambiguously the
                        // answer, the dominant plain-chat case. Must not
                        // detour through the working block.
                        transcript[assistantIndex].text += payload.text
                    } else if let openIndex = transcript[assistantIndex].work.openStepIndex,
                              !transcript[assistantIndex].work.steps[openIndex].narration.isEmpty {
                        // The open step already narrated (via `progress.note`),
                        // so this delta is unambiguously the answer too —
                        // streams straight into the bubble live rather than
                        // being decided retroactively at the next round
                        // boundary the way the reverted code did it.
                        transcript[assistantIndex].text += payload.text
                    } else {
                        // A tool has run and the open step (if any) has not
                        // narrated: this text could be the final answer, or
                        // narration for a round that isn't done yet (PR
                        // #114's exact ambiguity). Buffer it into the working
                        // block instead of guessing — it still streams live,
                        // just there, until the turn confirms there are no
                        // more rounds (this function's turn-end `defer`).
                        transcript[assistantIndex].work.appendProvisionalText(payload.text, now: Date())
                    }
                } else {
                    let isNewRound = subRoundCursors[tid, default: RoundCursor()]
                        .startsNewRound(round: payload.round, segmentID: payload.segmentID)
                    appendSub(tid, text: payload.text, parentTurnID: assistantTurnID, replace: isNewRound)
                }
                // TEMPORARY diagnostic (investigating reported release-build
                // stutter, docs/tests/crash.md): the existing top-of-loop
                // "consumer: message.delta" tick spans event RECEIPT +
                // PROCESSING together. This one covers processing alone, so
                // comparing the two spans for the same event count tells
                // apart "this case body is slow" from "something else is
                // starving the actor between awaits on the stream."
                DiagnosticLog.default.tick("consumer: delta.handled")
            case .reasoning:
                // Root only (matches hadToolCall/toolCallCount's scope).
                //
                // The trace text is deliberately DISCARDED — see
                // `AITurn.hadReasoning`. This case is the single hottest event
                // on the stream (5684 in one round, docs/tests/crash.md), and
                // every write here lands on an `@Observable` array, so
                // accumulating text nothing renders cost a full view-tree
                // invalidation per token. All that is needed is "reasoning
                // happened", recorded once — the guard below is what keeps
                // `work` (and so `transcript`) written exactly once for a
                // whole thinking burst, not once per token.
                guard isRoot else { break }
                if !transcript[assistantIndex].hadReasoning {
                    // Reasoning is part of the same unified "working" activity
                    // as tool calls (docs/feature/09) — `noteReasoning` starts
                    // the same live-timer clock the header reads, whichever of
                    // the two happens first (a reasoning-mode model typically
                    // thinks before its very first tool call, if it ever makes
                    // one at all).
                    transcript[assistantIndex].work.noteReasoning(now: Date())
                }
            case let .progressNote(note):
                guard isRoot else { break }
                // `AIWorkBlock.note` owns the whole rule: join two consecutive
                // notes into one step, but close-then-open a fresh step for a
                // note arriving once the current one already has an action —
                // a note always starts a new decision, unlike a bare tool
                // call, which does not close (see `.toolCall` below and PR
                // #108(a): a narration-less round used to absorb the NEXT
                // round's note because nothing closed it first).
                transcript[assistantIndex].work.note(note, now: Date())
            case let .plan(piece):
                if isRoot {
                    transcript[assistantIndex].plan += piece
                } else {
                    appendSub(tid, text: piece, parentTurnID: assistantTurnID)
                }
            case let .toolArgDelta(name, argDelta):
                guard isRoot else { break }
                // Stream propose_sql / create_debug_tab sql argument into the
                // editor tab in real-time as the LLM generates it.
                if name != streamingToolName {
                    streamingToolName = name
                    streamingArgBuffer = ""
                    partialValueScan = PartialStringScan()
                }
                if name == "propose_sql" || name == "propose_query" || name == "create_debug_tab" {
                    streamingArgBuffer += argDelta
                    // The arg arrives as raw JSON fragments (e.g. `"db.use`).
                    // Attempt to extract the query/sql string value incrementally.
                    if let partialSQL = scanPartialStringValue(
                        keys: ["query", "sql"], from: streamingArgBuffer, state: &partialValueScan
                    ) {
                        latestPartialProposal = (name, partialSQL)
                        if pendingProposeTask == nil {
                            pendingProposeTask = Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                guard let self else { return }
                                pendingProposeTask = nil
                                guard let pending = latestPartialProposal else { return }
                                latestPartialProposal = nil
                                dispatchPropose(pending.name, pending.sql)
                            }
                        }
                    }
                }
            case let .toolCall(call):
                // Reset streaming state — the final tool.call supersedes the deltas.
                // Flush whatever partial value the throttle is still holding
                // rather than losing it: same "cancel, then guarantee one
                // final application" the `.onChange(of: isStreaming)` handler
                // in `MarkdownMessageView` does for its own throttled reparse.
                pendingProposeTask?.cancel()
                pendingProposeTask = nil
                if let pending = latestPartialProposal {
                    latestPartialProposal = nil
                    dispatchPropose(pending.name, pending.sql)
                }
                streamingToolName = nil
                streamingArgBuffer = ""
                // Legacy/local providers send no round metadata on deltas at
                // all — a tool.call is the only boundary signal available,
                // so mark the next delta on this stream as a new round.
                var rootActionLocation: (stepIndex: Int, actionIndex: Int)?
                if isRoot {
                    rootRoundCursor.markToolCallBoundary()
                    // Whether this is the turn's very first tool call — the
                    // only moment prose accumulated on the `.direct` channel
                    // (see `.delta`) can exist with nowhere to go yet.
                    let isFirstToolCall = !transcript[assistantIndex].work.hadToolCall
                    // Publishes the action as `.running` immediately, before
                    // the tool executes — visible while the call is in
                    // flight, not just once it resolves. `inputs`/`payload`
                    // are already fully known from `call.args`; only
                    // `status`/`outputs` are unknown until it returns (set
                    // below via `toolCallFinished`).
                    let actionPayload = Self.actionPayload(name: call.name, args: call.args)
                    let location = transcript[assistantIndex].work.toolCallStarted(
                        name: call.name,
                        inputs: Self.actionInputs(from: call.args, excluding: actionPayload?.key),
                        payload: actionPayload?.value,
                        now: Date()
                    )
                    rootActionLocation = location
                    // A model narrating in plain prose despite the prompt,
                    // exactly as before `note_progress` existed — this can
                    // only happen before the turn's first tool call, since
                    // `.delta` only ever appends straight to `text` (the
                    // `.direct` channel) while `hadToolCall` is still false.
                    // Degrade to treating that prose as this step's
                    // narration instead of leaving it in the answer, unless
                    // an explicit `progress.note` already gave the step real
                    // narration (in which case this tool call attached to
                    // that step, not a fresh one, and stray leftover prose —
                    // an untested, unusual interleaving — is discarded
                    // rather than clobbering it).
                    // Only on the FIRST tool call: any other tool call's
                    // `text` may be already-committed real answer content
                    // from an earlier round (an answer the model split
                    // across a tool call) and must never be touched here.
                    if isFirstToolCall, !transcript[assistantIndex].text.isEmpty {
                        if transcript[assistantIndex].work.steps[location.stepIndex].narration.isEmpty {
                            transcript[assistantIndex].work.setFallbackNarration(
                                transcript[assistantIndex].text, at: location.stepIndex
                            )
                        }
                        transcript[assistantIndex].text = ""
                    }
                } else {
                    subRoundCursors[tid, default: RoundCursor()].markToolCallBoundary()
                }
                if !isRoot { noteSubTool(tid, call.name, parentTurnID: assistantTurnID) }
                guard let dispatchNonce = call.dispatchNonce,
                      let capabilitySetDigest = call.capabilitySetDigest else {
                    throw SessionInteractionError.invalidPayload
                }
                runningTool = call.name
                DiagnosticLog.default.event(
                    "tool begin",
                    detail: "name=\(call.name) round=\(transcript[assistantIndex].toolCallCount)"
                )
                let outcome = await executor.execute(call)
                DiagnosticLog.default.event(
                    "tool end", detail: "name=\(call.name) status=\(outcome.status)"
                )
                runningTool = nil
                if isRoot, let location = rootActionLocation {
                    transcript[assistantIndex].work.toolCallFinished(
                        stepIndex: location.stepIndex, actionIndex: location.actionIndex,
                        status: Self.actionStatus(for: outcome.status),
                        outputs: Self.actionOutputs(from: outcome.resultJSON)
                    )
                }
                if isRoot, let location = rootActionLocation,
                   let ref = recordArtifactRef(from: outcome, into: assistantIndex) {
                    // Same step, same artifact touched twice (a run then a
                    // self-correcting re-run) must not double the affordance
                    // — de-duplicated inside `attachArtifact`.
                    transcript[assistantIndex].work.attachArtifact(ref, stepIndex: location.stepIndex)
                }
                DiagnosticLog.default.event("deliver result begin", detail: "call=\(call.id)")
                try await deliverToolResult(
                    threadID: rootID,
                    callID: call.id,
                    dispatchNonce: dispatchNonce,
                    capabilitySetDigest: capabilitySetDigest,
                    status: outcome.status,
                    resultJSON: outcome.resultJSON
                )
                DiagnosticLog.default.event("deliver result end", detail: "call=\(call.id)")
            case let .interactionRequired(interaction):
                // A child agent may be the requester, but the root chat owns
                // the single authoritative user interaction, and the backend
                // always tags this event's SSE envelope with the ROOT
                // thread id regardless of which depth actually raised it
                // (gateway.rs pins `interaction_thread_id` to the root's own
                // id_prefix through the whole spawn_subagent/resume_child_agent
                // recursion) — unlike message.delta/tool.call, which do tag
                // with the emitting agent's own id. So `tid`/`isRoot` cannot
                // distinguish root- from subagent-origin here; `decode`
                // already validated the origin/origin_thread_id/origin_path/
                // parent_thread_id lineage against `interaction.threadID`.
                guard interaction.threadID == rootID else {
                    throw SessionInteractionError.invalidPayload
                }
                let prepared = try prepareInteraction(
                    interaction, threadID: rootID
                )
                try persistPendingInteraction(interaction, threadID: rootID)
                do {
                    try capabilityHost?.suspendTurn()
                } catch {
                    removePersistedInteraction(id: interaction.id)
                    throw error
                }
                guard interaction.kind == .reportDraftReady else {
                    publishInteraction(prepared, assistantIndex: assistantIndex)
                    return
                }
                pendingSuspendedInteraction = (prepared, assistantIndex)
            case let .reportDraft(preview):
                guard isRoot, let suspended = pendingSuspendedInteraction,
                      case let .report(report) = suspended.prepared.payload
                else { break }
                // Defensive integrity check (Task 11): our own digest rule
                // must hash the just-published draft text identically to
                // the backend's preview, or something is silently wrong
                // before the user ever gets to review/confirm anything.
                guard preview.draftDigest == AIRequestIntegrity.contentDigest(report.description) else {
                    removePersistedInteraction(id: interactionID(suspended.prepared.payload))
                    throw AITransportError.protocolViolation(code: "report_draft_digest_mismatch")
                }
            case let .reportReady(grant):
                guard isRoot else { break }
                lastReportReadyGrant = grant
            case .interactionReceipt:
                break
            case let .protocolError(code):
                throw AITransportError.protocolViolation(code: code)
            case let .complete(tokens):
                if isRoot {
                    totalTokens += tokens
                    // Settle immediately rather than waiting for this
                    // function to return (the turn-end `defer` below is the
                    // safety net for every OTHER exit path — error, thrown
                    // transport failure, cancellation, interaction
                    // suspension — where there is no `message.complete` to
                    // hook). `settleWork` is idempotent, so the defer's own
                    // call becomes a no-op here.
                    settleWork(assistantIndex: assistantIndex, assistantTurnID: assistantTurnID)
                }
            case let .error(code, message):
                if isRoot { lastError = message.isEmpty ? code : message }
            }
            }
            DiagnosticLog.default.event("turn end (stream EOF)", detail: "thread=\(threadID)")
            DiagnosticLog.default.flush()
            if let suspended = pendingSuspendedInteraction {
                publishInteraction(suspended.prepared, assistantIndex: suspended.assistantIndex)
                return
            }
            guard validatedResumeReceipt else {
                throw AITransportError.protocolViolation(
                    code: "interaction_receipt_required"
                )
            }
            try capabilityHost?.finishTurn()
        } catch {
            DiagnosticLog.default.event(
                "turn end (threw)", detail: "thread=\(threadID) error=\(error)"
            )
            DiagnosticLog.default.flush()
            capabilityHost?.abandonTurn()
            if resume != nil, validatedResumeReceipt {
                // Once the authenticated receipt has arrived, any later
                // transport failure is ambiguous: the one-shot action may
                // already have advanced the backend continuation.
                throw AITransportError.interactionResumeAmbiguous
            }
            throw error
        }
    }

    private func deliverToolResult(
        threadID: String,
        callID: String,
        dispatchNonce: String,
        capabilitySetDigest: String,
        status: String,
        resultJSON: String?
    ) async throws {
        do {
            try await transport.postToolResult(
                threadID: threadID,
                callID: callID,
                dispatchNonce: dispatchNonce,
                capabilitySetDigest: capabilitySetDigest,
                status: status,
                resultJSON: resultJSON
            )
        } catch {
            if Self.isAmbiguousOneShotDeliveryError(error) {
                throw AITransportError.toolResultDeliveryAmbiguous
            }
            throw error
        }
    }

    private static func isAmbiguousOneShotDeliveryError(
        _ error: Error
    ) -> Bool {
        if error is URLError { return true }
        if case let AITransportError.badResponse(code, _) = error {
            return code == 408 || code == 429 || (500...599).contains(code)
        }
        if case let AITransportError.protocolViolation(code) = error {
            return code == "interaction_receipt_required"
                || code == "invalid_interaction_receipt"
        }
        return false
    }

    /// Sends a (partial or final) proposed SQL/query string to whichever
    /// executor is active — `LocalCapabilityHost` needs the tool name to
    /// validate the proposal against the negotiated capability set; a plain
    /// executor doesn't.
    private func dispatchPropose(_ name: String, _ sql: String) {
        if let host = executor as? LocalCapabilityHost {
            host.streamPropose(sql, for: name)
        } else {
            executor.streamPropose(sql)
        }
    }

    /// Cursor `scanPartialStringValue` carries across `.toolArgDelta` events for
    /// the same streaming tool call, so each delta resumes scanning exactly
    /// where the previous one stopped.
    private struct PartialStringScan {
        var cursor: String.Index?
        var escaped = false
        var isComplete = false
        var result = ""
    }

    /// Extract the string value of the first matching key in `keys` from an
    /// incomplete JSON object fragment (e.g. `{"sql":"SELECT * FR` →
    /// `SELECT * FR`), resuming `state` from the previous call instead of
    /// rescanning all of `fragment` from the start every time — `fragment`
    /// (`streamingArgBuffer`) only ever grows, so a full rescan per delta was
    /// quadratic in the final argument length. Used to mirror streaming tool
    /// args into the editor tab before the full JSON is parseable.
    ///
    /// Returns `nil` whenever this call added nothing new to the value (the
    /// key hasn't appeared yet, or the value already closed on an earlier
    /// call) — the caller only needs to hear about it when it actually grew.
    private func scanPartialStringValue(
        keys: [String], from fragment: String, state: inout PartialStringScan
    ) -> String? {
        guard !state.isComplete else { return nil }
        if state.cursor == nil {
            for key in keys {
                guard let keyRange = fragment.range(of: "\"\(key)\":") else { continue }
                // Consume optional whitespace, then the opening quote.
                var afterKey = fragment[keyRange.upperBound...]
                while afterKey.first == " " { afterKey = afterKey.dropFirst() }
                guard afterKey.first == "\"" else { continue }
                state.cursor = fragment.index(after: afterKey.startIndex)
                break
            }
            guard state.cursor != nil else { return nil }
        }
        let lengthBefore = state.result.count
        var index = state.cursor!
        while index < fragment.endIndex {
            let ch = fragment[index]
            index = fragment.index(after: index)
            if state.escaped {
                switch ch {
                case "n": state.result.append("\n")
                case "t": state.result.append("\t")
                case "r": state.result.append("\r")
                default: state.result.append(ch)
                }
                state.escaped = false
            } else if ch == "\\" {
                state.escaped = true
            } else if ch == "\"" {
                state.isComplete = true
                break
            } else {
                state.result.append(ch)
            }
        }
        state.cursor = index
        return state.result.count > lengthBefore ? state.result : nil
    }

    /// `replace` discards whatever text a prior round accumulated instead
    /// of appending — used when a delta's round/segmentID (or, for legacy
    /// providers, a preceding `tool.call`) marks the start of a new round
    /// (Task 13). Defaults to false so the `.plan` case, which has no round
    /// concept, keeps its existing always-append behavior.
    /// Mutates in place through the dictionary's own storage rather than
    /// read-modify-write. `var sub = subThreads[id]` creates a second live
    /// reference to the value, so appending to its string forced a full copy of
    /// the accumulated sub-agent text on every token — quadratic in the final
    /// length, the same mistake `.delta` documents on the root transcript.
    private func appendSub(_ threadID: String, text: String, parentTurnID: UUID, replace: Bool = false) {
        if subThreads[threadID] == nil {
            subThreads[threadID] = SubAgentTranscript(id: threadID, parentTurnID: parentTurnID)
            subThreadIDsByParentTurn[parentTurnID, default: []].append(threadID)
        }
        if replace {
            subThreads[threadID]?.text = text
        } else {
            subThreads[threadID]?.text += text
        }
    }

    private func noteSubTool(_ threadID: String, _ name: String, parentTurnID: UUID) {
        if subThreads[threadID] == nil {
            subThreadIDsByParentTurn[parentTurnID, default: []].append(threadID)
        }
        var sub = subThreads[threadID] ?? SubAgentTranscript(id: threadID, parentTurnID: parentTurnID)
        sub.tools.append(name)
        subThreads[threadID] = sub
    }

    /// AI-31 (docs/draft/09.md): if this tool call's result carries an
    /// `artifact_id` (AI-30's create_debug_tab/propose_sql/propose_query/
    /// run_sql/run_tab_statements), attach a reference to it on the root
    /// turn so the bubble can link to it — mutates `transcript[index]`
    /// in place (not a copy-then-reassign) for the same reason `.delta`
    /// does: a second live reference to the array would force a full
    /// copy-on-write copy of every turn on every tool call.
    /// Appends one round's sub-block, if that round did anything worth showing.
    ///
    /// A round with tools but no narration still counts (a lone `run_sql` the
    /// model did not describe) — gating on narration alone once left silent
    /// tool-only rounds invisible in the working block.
    /// `openIndex` is the step a `progress.note` already published for this round.
    /// When set, the round's tools/artifacts/actions are filled into that step
    /// rather than appended as a new one — otherwise narrating and then acting
    /// would show as two sub-blocks for one step.
    /// Settles a turn's working block: closes whatever step is still open
    /// (the last round crosses no boundary of its own, so its sub-block
    /// would otherwise never settle — including a narrate-then-answer turn
    /// whose only step is that narration) and promotes any leftover
    /// un-narrated preview text into the answer, now that the turn is
    /// confirmed to have no more rounds. Idempotent — safe to call once
    /// eagerly from `.complete` and again from the turn-end `defer`, and
    /// safe against the 404-retry path calling `streamTurn` twice for one
    /// logical turn. Guarded on the turn still being the one this call
    /// started (same index and id — `runTurn`'s own `defer` can remove an
    /// errored empty turn).
    private func settleWork(assistantIndex: Int, assistantTurnID: UUID) {
        guard transcript.indices.contains(assistantIndex),
              transcript[assistantIndex].id == assistantTurnID else { return }
        guard transcript[assistantIndex].work.finish(now: Date()) else { return }
        // Whatever un-narrated `message.delta` prose the last step was still
        // buffering (see `.delta`'s case in `streamTurn`) is now confirmed to
        // be the answer, not narration for a round that wasn't done —
        // promote it. Reached from every exit path via the turn-end `defer`,
        // so a round still buffering when the stream ends on a provider
        // error still surfaces its partial text as the response, instead of
        // leaving `text` empty and tripping `runTurn`'s own defer that
        // removes an empty errored turn outright.
        transcript[assistantIndex].text += transcript[assistantIndex].work.promoteProvisionalText()
    }

    // MARK: - Working-block action detail (docs/feature/09)

    /// Caps below exist because these strings live in the transcript for the
    /// whole session. A `run_sql` result can be megabytes; copying it here to
    /// render one summary line would hold it in memory long after the tab that
    /// owns it already has it.
    private static let maxActionDetailLines = 6
    private static let maxActionDetailLength = 120

    private static func actionStatus(for status: String) -> AIToolAction.Status {
        switch status {
        case "ok": return .completed
        case "denied": return .denied
        default: return .failed
        }
    }

    /// One `key: value` line per argument, shortest first so the most
    /// identifying ones (a table name) are not pushed out by a long SQL string.
    ///
    /// `payloadKey` is excluded: that argument gets its own full-width preview
    /// row, and listing it here too showed the same SQL twice under one action.
    private static func actionInputs(
        from args: [String: String], excluding payloadKey: String?
    ) -> [String] {
        args
            .filter { $0.key != payloadKey }
            .sorted { ($0.value.count, $0.key) < ($1.value.count, $1.key) }
            .prefix(maxActionDetailLines)
            .map { "\($0.key): \(truncate($0.value))" }
    }

    /// Result keys that describe how the app was wired, not what the tool found.
    /// The artifact and tab they identify are already surfaced as their own
    /// openable rows, so repeating them fills the `Result` block with six lines
    /// of plumbing and pushes the actual outcome out of view.
    private static let plumbingResultKeys: Set<String> = [
        "artifact_id", "artifact_version", "tab_id", "tab_title", "pane", "proposed",
        "created", "ran", "dispatch_nonce", "capability_set_digest",
    ]

    /// A shallow summary of the result JSON — top-level keys with a count for
    /// arrays and a truncated value for scalars. Deliberately not a deep render:
    /// the point is "what came back", not the data itself.
    private static func actionOutputs(from resultJSON: String?) -> [String] {
        guard let resultJSON,
              let data = resultJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys
            .filter { !plumbingResultKeys.contains($0) }
            .sorted()
            .prefix(maxActionDetailLines)
            .map { key in
                switch object[key] {
                case let array as [Any]: return "\(key): \(array.count) item(s)"
                case let dictionary as [String: Any]: return "\(key): \(dictionary.count) field(s)"
                case let value?: return "\(key): \(truncate(String(describing: value)))"
                default: return key
                }
            }
    }

    /// The one argument worth showing in full for this tool, if any.
    ///
    /// Per-tool rather than "the longest argument": which argument matters is a
    /// property of the tool, and guessing by length would surface a stray
    /// `title` over the SQL beside it. Keys mirror
    /// `QueryToolExecutor`'s parameter schemas.
    ///
    /// Capped well above the inline limit but still bounded — a pathological
    /// generated statement must not sit in the transcript unbounded.
    private static let maxPayloadLength = 32 * 1024

    /// Returns the key as well as the value so `actionInputs` can skip it —
    /// otherwise the same argument renders twice under one action.
    private static func actionPayload(
        name: String, args: [String: String]
    ) -> (key: String, value: String)? {
        let key: String?
        switch name {
        // What was run.
        case "run_sql", "run_tab_statements", "explain_query": key = "sql"
        // What was written into a tab.
        case "propose_sql", "propose_query", "create_debug_tab": key = args["sql"] != nil ? "sql" : "query"
        // What was read.
        case "get_schema": key = "tables"
        case "get_stats", "get_sample_rows": key = "table"
        case "search_schema", "search_conversation", "graph_query": key = "query"
        default: key = nil
        }
        guard let key, let value = args[key], !value.isEmpty else { return nil }
        return (key, String(value.prefix(maxPayloadLength)))
    }

    private static func truncate(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
        guard flattened.count > maxActionDetailLength else { return flattened }
        return flattened.prefix(maxActionDetailLength) + "…"
    }

    /// Returns the ref it recorded (nil when the result carried no artifact) so
    /// the caller can also attach it to the round's own `AIWorkStep`.
    @discardableResult
    private func recordArtifactRef(from outcome: ToolOutcome, into index: Int) -> ArtifactRef? {
        guard let json = outcome.resultJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifactIDString = object["artifact_id"] as? String,
              let artifactID = UUID(uuidString: artifactIDString),
              let versionNumber = object["artifact_version"] as? Int,
              let artifact = try? store.artifact(id: artifactID),
              transcript.indices.contains(index)
        else { return nil }
        let ref = ArtifactRef(
            artifactID: artifactID, versionNumber: versionNumber,
            title: artifact.title, kind: artifact.kind
        )
        // The same artifact/tab is commonly touched by more than one tool
        // call in a turn (a run, then a self-correcting re-run) — update its
        // existing chip in place instead of appending a duplicate.
        if let existing = transcript[index].artifactRefs.firstIndex(where: { $0.artifactID == artifactID }) {
            transcript[index].artifactRefs[existing] = ref
        } else {
            transcript[index].artifactRefs.append(ref)
        }
        return ref
    }

    /// nil for an empty list (the common case) rather than persisting `"[]"`.
    private static func encodeArtifactRefs(_ refs: [ArtifactRef]) -> String? {
        guard !refs.isEmpty, let data = try? JSONEncoder().encode(refs) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeArtifactRefs(_ json: String?) -> [ArtifactRef] {
        guard let json, let data = json.data(using: .utf8),
              let refs = try? JSONDecoder().decode([ArtifactRef].self, from: data)
        else { return [] }
        return refs
    }

    /// Run one turn entirely on-device via LocalAgentLoop (AI-20). Conversation
    /// ownership remains local and clarification uses the same pending UI.
    ///
    /// Queues under the same conditions `admitSend` already does for the
    /// backend path (AI-08), instead of silently no-oping while streaming.
    /// Outcome of admitting a newly submitted on-device prompt
    /// (`admitSendLocal`) — mirrors `SendAdmission` for the local path.
    public enum SendLocalAdmission: Sendable {
        case ignored
        case queued
        case run(text: String, assistantIndex: Int, provider: any LocalCompletionProvider)
    }

    /// Synchronous half of `sendLocal`, mirroring `admitSend`'s split: decides
    /// how `text` should be handled and, for the immediate-run case, appends
    /// the user's bubble *and* the empty assistant bubble (via `beginTurn`)
    /// to `transcript` right away. Without this split, `sendLocal` was a
    /// single `async func` whose `transcript.append` only ran once its
    /// wrapping `Task` got a turn on the MainActor — unlike the backend path,
    /// the user's own bubble and the "preparing" indicator could lag behind
    /// Send by however long the MainActor was busy. `AIPanelController.
    /// prepareSend` must call this directly on the Enter/Send call stack, same
    /// as `admitSend`.
    public func admitSendLocal(_ text: String, provider: any LocalCompletionProvider) -> SendLocalAdmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ignored }
        lastLocalProvider = provider
        guard activeInteraction == nil, pendingReportDraft == nil, !isStreaming else {
            queuedMessages.append(trimmed)
            queuedMessageWasDisplayed.append(false)
            queuedMessageRunsLocally.append(true)
            return .queued
        }
        transcript.append(AITurn(role: .user, text: trimmed))
        let (assistant, _) = beginTurn()
        return .run(text: trimmed, assistantIndex: assistant, provider: provider)
    }

    /// Runs the async continuation for an admission already decided by
    /// `admitSendLocal` — the other half of the split described there.
    public func runLocal(_ admission: SendLocalAdmission) async {
        switch admission {
        case .ignored, .queued:
            return
        case let .run(text, assistantIndex, provider):
            await runLocalTurn(text, provider: provider, assistant: assistantIndex)
        }
    }

    public func sendLocal(_ text: String, provider: any LocalCompletionProvider) async {
        await runLocal(admitSendLocal(text, provider: provider))
    }

    /// The async continuation for a local turn whose bubbles are already on
    /// the transcript (via `beginTurn()`) — mirrors `runTurn`'s role for the
    /// backend path. Called from `sendLocal` directly for an immediate
    /// send, and from `drainQueuedMessageIfReady` for a queued one.
    private func runLocalTurn(_ trimmed: String, provider: any LocalCompletionProvider, assistant: Int) async {
        let priorTranscript = localPromptTranscript()
        let transcriptCount = transcript.count - 1
        defer {
            isStreaming = false
            runningTool = nil
            drainQueuedMessageIfReady()
        }

        let tools = executor.toolSpecs
        let capabilityHost = executor as? LocalCapabilityHost
        do {
            let thread = try await ensureThread()
            try capabilityHost?.beginLocalTurn(with: tools)
            let loop = LocalAgentLoop(provider: provider, executor: executor)
            let outcome = await loop.runUntilInteraction(
                userText: trimmed, tools: tools,
                priorTranscript: priorTranscript, resumeAction: nil
            ) { piece in
                // Mutate through `transcript`'s own storage, not a `var
                // updated = self.transcript` copy first — a second live
                // reference to the same buffer defeats the uniqueness
                // check, forcing a full COW copy of every turn on every
                // single token (see the backend `.delta` case's own note).
                self.transcript[assistant].text += piece
            }
            switch outcome {
            case let .completed(answer):
                try capabilityHost?.finishTurn()
                if answer.isEmpty, transcript[assistant].text.isEmpty {
                    lastError = "The on-device model didn't return an answer."
                }
                let persisted = await persistTurn(
                    threadID: thread, userText: trimmed,
                    assistantText: transcript[assistant].text
                )
                applyPersistedMessageIDs(persisted, assistant: assistant)
                if !persisted.isEmpty {
                    let indexer = embeddingIndexer
                    Task { await indexer.index(persisted) }
                }
            case let .clarification(clarification):
                let pending = try prepareLocalInteraction(
                    clarification, threadID: thread, provider: provider
                )
                try capabilityHost?.suspendTurn()
                transcript[assistant].text = clarification.question
                activeInteraction = pending
                let persisted = await persistTurn(
                    threadID: thread, userText: trimmed,
                    assistantText: clarification.question,
                    assistantMetadata: "local:interaction"
                )
                applyPersistedMessageIDs(persisted, assistant: assistant)
            }
        } catch {
            capabilityHost?.abandonTurn()
            requiresClientUpdate = error is LocalCapabilityError
            lastError = Self.describe(error)
            if transcript.count > transcriptCount {
                transcript.removeLast(transcript.count - transcriptCount)
            }
        }
    }

    private func localPromptTranscript() -> String {
        transcript.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(turn.role == .user ? "User" : "Assistant"): \(text)\n"
        }.joined()
    }

    /// New chat: forget the current thread so the next send() opens a fresh one.
    public func startNewThread() {
        guard canChangeThread else { return }
        threadID = nil
        transcript = []
        subThreads = [:]
        subThreadIDsByParentTurn = [:]
        activeInteraction = nil
        pendingReportDraft = nil
        confirmedReportDraft = nil
        clearReportContextReview()
        reportSubmissionState = .idle
        queuedMessages = []
        queuedMessageWasDisplayed = []
        queuedMessageRunsLocally = []
        lastError = nil
        requiresClientUpdate = false
        capabilityErrorLocalizationKey = nil
        controlDeliveryErrorLocalizationKey = nil
        totalTokens = 0
    }

    /// Drops the staged (pre-confirm) summary review. The consented copy on
    /// `confirmedReportDraft` is deliberately untouched — that one is the
    /// record of what the user agreed to, not a cache.
    private func clearReportContextReview() {
        reportContextSummary = nil
        isPreparingReportContextSummary = false
        reportContextSummaryUnavailable = false
    }

    /// Open a saved conversation for display + continuation (AI-21).
    public func loadThread(id: String, turns: [AITurn]) {
        guard canChangeThread else { return }
        threadID = id
        transcript = turns
        subThreads = [:]
        subThreadIDsByParentTurn = [:]
        lastError = nil
        capabilityErrorLocalizationKey = nil
        controlDeliveryErrorLocalizationKey = nil
        // A confirmed draft's report_ready_token is bound to the thread it
        // was minted on (review finding, Task 11 fix round): without this,
        // switching away from a just-confirmed thread A to any other thread
        // B — `canChangeThread` deliberately doesn't gate on
        // `confirmedReportDraft` — left A's still-live card and token
        // rendering under B.
        confirmedReportDraft = nil
        clearReportContextReview()
        reportSubmissionState = .idle
        restorePendingInteraction(threadID: id)
        restorePendingReportDraft(threadID: id)
    }

    /// The current thread id, if a conversation has started (for the panel to
    /// highlight the active thread).
    public var currentThreadID: String? { threadID }
    public var currentDialect: String { dialect }
    public var currentConnectionKey: String? { connectionKey }

    /// The device's saved conversations for this dialect + connection, most-recent
    /// first (Q17, docs/agents/architecture/11 §7.3, connectionKey per v28). No real
    /// pagination needed locally; prefix to limit while preserving public signature.
    public func availableThreads(limit: Int = 50, beforeUpdatedAt: Int? = nil, beforeID: String? = nil) async -> [AIThreadSummary] {
        let records = (try? store.aiThreads(dialect: dialect, connectionKey: connectionKey)) ?? []
        return Array(records.prefix(limit).map { record in
            let title: String
            if let t = record.title, !t.isEmpty {
                title = t
            } else {
                title = "Untitled"
            }
            return AIThreadSummary(
                id: record.id.uuidString,
                title: title,
                updatedAt: record.updatedAt.timeIntervalSince1970
            )
        })
    }

    /// Open a saved conversation by id (fetches + displays its transcript from local BerryStore).
    public func openThread(_ id: String) async {
        guard canChangeThread else { return }
        do {
            guard let uuid = UUID(uuidString: id) else {
                throw AITransportError.badResponse(statusCode: 400, message: "Invalid thread ID")
            }
            guard (try store.aiThread(id: uuid)) != nil else {
                throw AITransportError.badResponse(statusCode: 404, message: "Thread not found")
            }
            loadThread(id: id, turns: try activeTurns(threadID: uuid))
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Reconstructs `AITurn`s for a thread's ACTIVE path (AI-35) — the
    /// branch-aware replacement for a flat `store.aiMessages` read, shared by
    /// `openThread` and `selectSibling` so both rebuild the transcript the
    /// same way.
    private func activeTurns(threadID uuid: UUID) throws -> [AITurn] {
        try store.activeAIMessages(threadID: uuid).compactMap { record -> AITurn? in
            let text = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            switch record.role {
            case "user": return AITurn(role: .user, text: text, messageID: record.id)
            case "assistant":
                // AI-31: without this, an artifact's bubble link only ever
                // lived in the in-memory session — reopening this thread
                // from history/after a restart would silently drop it even
                // though the artifact itself is still there.
                return AITurn(
                    role: .assistant, text: text,
                    artifactRefs: Self.decodeArtifactRefs(record.artifactsJSON),
                    messageID: record.id
                )
            default: return nil
            }
        }
    }

    /// Delete a saved conversation from local store; if it was the open one, start fresh.
    public func deleteThread(_ id: String) async {
        guard canChangeThread else { return }
        if let uuid = UUID(uuidString: id) {
            try? store.deleteAIThread(id: uuid)
        }
        if threadID == id { startNewThread() }
    }

    /// Fetches (once) the bounded conversation summary that attaching context
    /// would send, so the user reviews the actual scope before consenting to
    /// it rather than a bare toggle (Task 12, human ruling). Reuses the
    /// existing stateless `/v1/ai/summarize` fold the rolling summary
    /// already goes through; `previous: ""` because this is a standalone
    /// summary of the attachable scope, not a continuation of the thread's
    /// own rolling one.
    ///
    /// The chat is blocked while a report review is open, so the scope cannot
    /// move underneath a fetched summary — one fetch per review is enough.
    public func prepareReportContextSummary() async {
        guard pendingReport != nil, reportContextSummary == nil,
              !isPreparingReportContextSummary else { return }
        let messages = recentReportContext(attach: true)
        // The backend's /v1/ai/summarize flatly rejects an empty messages
        // array (400 empty_summary_messages) — reachable whenever the
        // reportable window is empty (e.g. a brand-new thread, or every
        // persisted row so far is the local:interaction marker this filters
        // out). Treat "nothing to summarize yet" as its own case rather than
        // spending a network round trip just to fail the same way a real
        // error would.
        guard !messages.isEmpty else {
            reportContextSummaryUnavailable = true
            return
        }
        isPreparingReportContextSummary = true
        reportContextSummaryUnavailable = false
        let summary = await transport.summarize(previous: "", messages: messages)
        isPreparingReportContextSummary = false
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= AIReportPolicy.maxContextBytes else {
            // Nothing the user could have read and agreed to, so there is
            // nothing to bind a consent digest to either.
            reportContextSummaryUnavailable = true
            return
        }
        reportContextSummary = summary
    }

    /// Confirming does not submit the report (Task 11) — reaching
    /// `report.ready` only mints a `report_ready_token` bound to exactly the
    /// digest of what's currently displayed. Submission is the separate,
    /// explicit `submitConfirmedReport()` action below (Task 12); reaching
    /// readiness must never auto-submit.
    ///
    /// With context attached, the digest bound here is the digest of the
    /// summary the user has already been shown (`reportContextSummary`), not
    /// of the live message scope: the backend re-derives
    /// `sha256(conversation_summary)` from the submitted bytes and compares
    /// it to what this credential sealed. Confirming with context but no
    /// reviewed summary would therefore mint a credential nothing could ever
    /// spend, so it is refused outright.
    public func resolveReport(confirmed: Bool, attachContext: Bool) async {
        updateReportAttachContext(attachContext)
        if confirmed, attachContext, reportContextSummary == nil {
            // Consent needs something to have been given to. Refused before
            // `beginResolvingReport` so the one-shot interaction is not spent
            // and the review stays open once the summary does arrive.
            reportContextSummaryUnavailable = true
            return
        }
        guard let active = beginResolvingReport(),
              case let .report(report) = active.payload,
              case let .backend(interaction) = active.origin else { return }
        do {
            var reportBlock: AIReportConfirmation?
            var consentedSummary: String?
            if confirmed {
                consentedSummary = report.attachContext ? reportContextSummary : nil
                reportBlock = AIReportConfirmation(
                    draftDigest: AIRequestIntegrity.contentDigest(report.description),
                    includeContext: report.attachContext,
                    contextDigest: consentedSummary.map(AIRequestIntegrity.contentDigest)
                )
            }
            try await resumeInteraction(
                threadID: active.threadID,
                interactionID: report.id,
                token: interaction.resumeToken,
                action: confirmed ? .accepted : .declined,
                protocolText: "",
                displayText: nil,
                report: reportBlock
            )
            if confirmed, let grant = lastReportReadyGrant, grant.callID == report.id {
                confirmedReportDraft = ConfirmedReportDraft(
                    text: report.description,
                    category: report.category,
                    severity: report.severity,
                    includeContext: report.attachContext,
                    conversationSummary: consentedSummary,
                    threadID: active.threadID,
                    callID: report.id,
                    clientRequestID: Self.makeClientRequestID(),
                    readyToken: grant.reportReadyToken,
                    readyDraftDigest: grant.draftDigest,
                    readyIncludeContext: grant.includeContext,
                    readyContextDigest: grant.contextDigest,
                    readyExpiresAtUnix: grant.expiresAtUnix
                )
                reportSubmissionState = .idle
            }
            finishResolution(of: report.id)
        } catch {
            failResolution(of: report.id, error: error)
        }
    }

    /// A `client_request_id` the backend accepts: 16…128 chars of
    /// `[A-Za-z0-9_-]`. A lowercased UUID is 36 of them.
    private static func makeClientRequestID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Submits the confirmed report — the only call in this client that ever
    /// reaches `POST /v1/agent/report`, and only from an explicit user action
    /// (Task 12). Sends exactly the bytes the token was minted for: the
    /// digests are computed from the same values that go into the body, so
    /// there is nothing separately supplied that could disagree with them.
    public func submitConfirmedReport() async {
        // A second tap while one is in flight, or after this report already
        // landed, must not open a second submission.
        if case .submitting = reportSubmissionState { return }
        if case .submitted = reportSubmissionState { return }
        guard let draft = confirmedReportDraft, let token = reportReadyToken else {
            reportSubmissionState = .failed(.notReady)
            return
        }
        let summary = draft.includeContext ? draft.conversationSummary : nil
        guard draft.text.utf8.count <= AIReportPolicy.maxDraftBytes,
              (summary?.utf8.count ?? 0) <= AIReportPolicy.maxContextBytes else {
            reportSubmissionState = .failed(.tooLarge)
            return
        }
        let submission = AIReportSubmission(
            threadID: draft.threadID,
            callID: draft.callID,
            reportReadyToken: token,
            draft: draft.text,
            conversationSummary: summary,
            clientRequestID: draft.clientRequestID
        )
        reportSubmissionState = .submitting
        do {
            let receipt = try await submitWithIdempotentRetry(submission)
            reportSubmissionState = .submitted(duplicate: receipt.duplicate)
            confirmedReportDraft = nil
            reportContextSummary = nil
        } catch {
            let failure = Self.reportSubmissionFailure(for: error)
            reportSubmissionState = .failed(failure)
            if failure == .notReady || failure == .reviewExpired {
                // The credential is dead; the local card would otherwise keep
                // showing a token that only this device still believes in.
                confirmedReportDraft = nil
                reportContextSummary = nil
            }
        }
    }

    /// The idempotent-retry contract (backend Task 4): a dropped response or
    /// a `503` is retried with the SAME `client_request_id` and byte-identical
    /// payload, so a first attempt that actually landed comes back as
    /// `duplicate: true` instead of storing a second report. Minting a fresh
    /// id for the same content would be a logically new submission and would
    /// be refused with `409`. Exactly one automatic retry — anything still
    /// failing is surfaced for an explicit user retry, which reuses the same
    /// id (it lives on `confirmedReportDraft`) for the same reason.
    private func submitWithIdempotentRetry(
        _ submission: AIReportSubmission
    ) async throws -> AIReportReceipt {
        do {
            return try await transport.submitReport(submission)
        } catch {
            guard Self.isRetryableReportSubmissionError(error) else { throw error }
            return try await transport.submitReport(submission)
        }
    }

    private static func isRetryableReportSubmissionError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case AIReportSubmissionError.unavailable = error { return true }
        return false
    }

    private static func reportSubmissionFailure(
        for error: Error
    ) -> ReportSubmissionFailure {
        if case let AIReportSubmissionError.notReady(reason) = error {
            return reason == "control_token_expired" ? .reviewExpired : .notReady
        }
        if case AIReportSubmissionError.alreadySubmitted = error { return .alreadySubmitted }
        if case AIReportSubmissionError.tooLarge = error { return .tooLarge }
        if case AIReportSubmissionError.unavailable = error { return .unavailable }
        if case AITransportError.notAuthorized = error { return .notAuthorized }
        if error is URLError { return .unavailable }
        // 426 and 400 both mean this client assembled the request wrong, as
        // does a malformed receipt — retrying identical bytes cannot help.
        return .clientError
    }

    public func updateReportAttachContext(_ value: Bool) {
        guard var active = activeInteraction, !active.isResolving,
              case var .report(report) = active.payload else { return }
        report.attachContext = value
        active.payload = .report(report)
        activeInteraction = active
    }

    /// Lets the user revise the agent's canonical draft before confirming
    /// (Task 11) — free and local, same as `updateReportAttachContext`; no
    /// digest/token exists yet at this stage to invalidate.
    public func updateReportDescription(_ text: String) {
        guard var active = activeInteraction, !active.isResolving,
              case var .report(report) = active.payload else { return }
        report.description = text
        active.payload = .report(report)
        activeInteraction = active
    }

    /// Edits the already-confirmed draft (Task 11). `reportReadyToken`
    /// recomputes on every read, so this alone is enough to invalidate a
    /// previously-minted token — reverting to the exact original bytes
    /// makes it valid again, since the token is bound to a digest, not to
    /// this particular edit session.
    public func updateConfirmedReportDraftText(_ text: String) {
        guard var draft = confirmedReportDraft else { return }
        draft.text = text
        confirmedReportDraft = draft
    }

    /// Flips the attach-context choice on an already-confirmed draft (Task
    /// 11) — a changed choice invalidates `reportReadyToken` the same way a
    /// text edit does, since the token was minted for a specific
    /// `include_context` value.
    public func updateConfirmedReportDraftAttachContext(_ value: Bool) {
        guard var draft = confirmedReportDraft else { return }
        draft.includeContext = value
        confirmedReportDraft = draft
    }

    /// Discards the confirmed draft without submitting it (Task 11), and
    /// clears whatever the last submission attempt left on screen (Task 12).
    /// Nothing is cancelled server-side: an unspent credential simply expires.
    public func dismissConfirmedReportDraft() {
        confirmedReportDraft = nil
        clearReportContextReview()
        reportSubmissionState = .idle
    }

    /// The Task 4.1 consent gate: only past this call does the rough text
    /// (plus optional recent context) ever reach the backend, and even then
    /// only as an ordinary refinement turn — `persist: false` below is the
    /// hard constraint that keeps it and this turn's exchange out of
    /// `ai_message`/the embedding indexer. Declining/cancelling deletes the
    /// local draft and makes no network call at all.
    public func resolveReportDraft(confirmed: Bool, attachContext: Bool) async {
        updateReportDraftAttachContext(attachContext)
        guard let draft = pendingReportDraft, activeInteraction == nil, !isStreaming else { return }
        pendingReportDraft = nil
        if let id = UUID(uuidString: draft.id) {
            _ = try? store.deletePendingReportDraft(threadID: id)
        }
        guard confirmed else { return }
        // Off means no local context at all, not just the normal recentWindow
        // trim — the whole point of the toggle is an opt-out.
        let context: AITurnContext? = draft.attachContext
            ? nil : AITurnContext(summary: "", recentMessages: [])
        transcript.append(AITurn(role: .user, text: draft.text))
        let (assistant, assistantTurnID) = beginTurn()
        await runTurn(
            draft.text, assistant: assistant, assistantTurnID: assistantTurnID,
            persist: false, contextOverride: context
        )
    }

    public func updateReportDraftAttachContext(_ value: Bool) {
        guard var draft = pendingReportDraft, let id = UUID(uuidString: draft.id) else { return }
        draft.attachContext = value
        pendingReportDraft = draft
        guard var record = try? store.pendingReportDraft(threadID: id) else { return }
        record.attachContext = value
        try? store.savePendingReportDraft(record)
    }

    public func resolveClarification(_ resolution: ClarificationResolution) async {
        guard let active = beginResolvingClarification(),
              case let .clarification(clarification) = active.payload else {
            return
        }
        let action: AIInteractionResume.Action
        let protocolText: String
        let displayText: String
        switch resolution {
        case let .answer(answer):
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                failResolution(of: clarification.id, error: SessionInteractionError.invalidPayload)
                return
            }
            action = .answered
            protocolText = trimmed
            displayText = trimmed
        case let .decline(text):
            action = .declined
            protocolText = ""
            displayText = text
        case let .cancel(text):
            action = .cancelled
            protocolText = ""
            displayText = text
        }

        do {
            switch active.origin {
            case let .backend(interaction):
                try await resumeInteraction(
                    threadID: active.threadID,
                    interactionID: clarification.id,
                    token: interaction.resumeToken,
                    action: action,
                    protocolText: protocolText,
                    displayText: displayText
                )
            case let .local(provider):
                try await resumeLocalInteraction(
                    threadID: active.threadID,
                    provider: provider,
                    action: action,
                    protocolText: protocolText,
                    displayText: displayText
                )
            }
            finishResolution(of: clarification.id)
        } catch {
            failResolution(of: clarification.id, error: error)
        }
    }

    private func recentReportContext(attach: Bool) -> [AIContextMessage] {
        // AI-35: active path only — a report must never attach an
        // edited-away version of the conversation.
        guard attach, let threadID, let id = UUID(uuidString: threadID),
              let all = try? store.activeAIMessages(threadID: id) else { return [] }
        let reportable = all.filter { $0.toolCalls != "local:interaction" }
        let cutoff = max(0, reportable.count - AIConversationPolicy.recentWindow)
        return Array(reportable[cutoff...].map {
            AIContextMessage(role: $0.role, content: $0.content)
        })
    }

    private func persistPendingInteraction(
        _ interaction: AIInteraction,
        threadID: String
    ) throws {
        guard let rootID = UUID(uuidString: threadID) else {
            throw SessionInteractionError.invalidPayload
        }
        let args: [String: Any]
        let allowedActions: [String]
        switch interaction.kind {
        case .clarifyRequest:
            var value: [String: Any] = [
                "question": interaction.question ?? "",
                "reason": interaction.reason ?? "",
            ]
            if !interaction.choices.isEmpty {
                value["choices"] = interaction.choices
            }
            if !interaction.allowFreeText {
                value["allow_free_text"] = false
            }
            args = value
            allowedActions = ["answered", "declined", "cancelled"]
        case .reportDraftReady:
            var value: [String: Any] = ["draft": interaction.draft ?? ""]
            if let category = interaction.category {
                value["category"] = category
            }
            if let severity = interaction.severity {
                value["severity"] = severity
            }
            value["unknowns"] = interaction.unknowns
            args = value
            allowedActions = ["accepted", "declined", "cancelled"]
        }
        let argsData = try JSONSerialization.data(
            withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let actionsData = try JSONSerialization.data(
            withJSONObject: allowedActions,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let argsJSON = String(data: argsData, encoding: .utf8),
              let actionsJSON = String(data: actionsData, encoding: .utf8) else {
            throw SessionInteractionError.invalidPayload
        }
        try store.savePendingAIInteraction(AIPendingInteractionRecord(
            id: interaction.id, threadID: rootID,
            kind: interaction.kind.rawValue, argsJSON: argsJSON,
            resumeToken: interaction.resumeToken,
            origin: interaction.origin.rawValue,
            originThreadID: interaction.originThreadID,
            originPath: interaction.originPath,
            parentThreadID: interaction.parentThreadID,
            expiresAtUnix: interaction.expiresAtUnix,
            registryVersion: interaction.registryVersion,
            toolVersion: interaction.toolVersion,
            schemaVersion: interaction.schemaVersion,
            allowedActionsJSON: actionsJSON, createdAt: now()
        ))
    }

    private func restorePendingInteraction(threadID: String) {
        guard activeInteraction == nil,
              let rootID = UUID(uuidString: threadID),
              let record = try? store.pendingAIInteraction(threadID: rootID)
        else { return }
        guard record.expiresAtUnix > Int64(now().timeIntervalSince1970) else {
            removePersistedInteraction(id: record.id)
            controlDeliveryErrorLocalizationKey =
                "This AI request expired. Ask the agent to try again."
            return
        }
        guard record.state == "pending" else {
            // The app stopped after choosing an action but before proving a
            // receipt. Replaying that one-shot token could duplicate work.
            removePersistedInteraction(id: record.id)
            controlDeliveryErrorLocalizationKey =
                "Your response may have been received, so BerryDB will not send it again automatically."
            return
        }
        let expectedActions = record.kind == AIInteraction.Kind.clarifyRequest.rawValue
            ? ["answered", "declined", "cancelled"]
            : ["accepted", "declined", "cancelled"]
        guard let actionData = record.allowedActionsJSON.data(using: .utf8),
              let actions = try? JSONDecoder().decode(
                  [String].self, from: actionData
              ),
              actions == expectedActions,
              let argsData = record.argsJSON.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: argsData),
              let wireData = try? JSONSerialization.data(withJSONObject: [
                  "call_id": record.id,
                  "kind": record.kind,
                  "args": args,
                  "resume_token": record.resumeToken,
                  "origin": record.origin,
                  "origin_thread_id": record.originThreadID,
                  "origin_path": record.originPath,
                  "parent_thread_id": record.parentThreadID,
                  "expires_at_unix": NSNumber(value: record.expiresAtUnix),
                  "registry_version": record.registryVersion,
                  "tool_version": record.toolVersion,
                  "schema_version": record.schemaVersion,
                  "thread_id": threadID,
              ]),
              case let .interactionRequired(interaction) =
                  AIEvent.decode(event: "interaction.required", data: wireData),
              let restored = try? prepareInteraction(
                  interaction, threadID: threadID
              )
        else {
            removePersistedInteraction(id: record.id)
            controlDeliveryErrorLocalizationKey =
                "The saved AI request could not be restored safely."
            return
        }
        activeInteraction = restored
    }

    /// Mirrors `restorePendingInteraction` for the Task 4.1 pre-consent
    /// draft: reads back the same local `ai_pending_report_draft` row
    /// `beginReportDraft` wrote, so it reappears after an app restart.
    /// Mutually exclusive with a restored backend interaction by
    /// construction — `resolveReportDraft` deletes the row before any
    /// backend interaction for this thread can exist.
    private func restorePendingReportDraft(threadID: String) {
        guard activeInteraction == nil, pendingReportDraft == nil,
              let id = UUID(uuidString: threadID),
              let record = try? store.pendingReportDraft(threadID: id)
        else { return }
        pendingReportDraft = PendingReportDraft(
            id: threadID, text: record.text, attachContext: record.attachContext
        )
    }

    @discardableResult
    private func removePersistedInteraction(id: String) -> Bool {
        do {
            return try store.deletePendingAIInteraction(id: id)
        } catch {
            // The in-memory grant is still abandoned by the caller. A row
            // already marked `resolving` remains a non-replayable tombstone;
            // an expired row also fails closed when restoration checks TTL.
            controlDeliveryErrorLocalizationKey =
                "The saved AI request could not be restored safely."
            return false
        }
    }

    private func expireInteractionIfNeeded(
        _ interaction: ActiveInteraction
    ) -> Bool {
        guard case let .backend(envelope) = interaction.origin,
              envelope.expiresAtUnix <= Int64(now().timeIntervalSince1970)
        else { return false }
        removePersistedInteraction(id: interactionID(interaction.payload))
        activeInteraction = nil
        controlDeliveryErrorLocalizationKey =
            "This AI request expired. Ask the agent to try again."
        drainQueuedMessageIfReady()
        return true
    }

    private func prepareInteraction(
        _ interaction: AIInteraction,
        threadID: String
    ) throws -> ActiveInteraction {
        guard activeInteraction == nil
                || (activeInteraction?.isResolving == true
                    && activeInteraction?.threadID == threadID) else {
            throw SessionInteractionError.conflictingInteraction
        }
        guard interaction.expiresAtUnix > Int64(now().timeIntervalSince1970) else {
            throw SessionInteractionError.interactionExpired
        }
        switch interaction.kind {
        case .clarifyRequest:
            guard let question = interaction.question,
                  !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  question.utf8.count <= 8_192 else {
                throw SessionInteractionError.invalidPayload
            }
            return ActiveInteraction(
                threadID: threadID,
                payload: .clarification(PendingClarification(
                    id: interaction.id,
                    question: question,
                    reason: interaction.reason,
                    choices: interaction.choices,
                    allowFreeText: interaction.allowFreeText,
                    origin: interaction.origin,
                    originThreadID: interaction.originThreadID,
                    originPath: interaction.originPath
                )),
                origin: .backend(interaction),
                isResolving: false
            )

        case .reportDraftReady:
            guard let draft = interaction.draft,
                  !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  draft.utf8.count <= 32_768 else {
                throw SessionInteractionError.invalidPayload
            }
            return ActiveInteraction(
                threadID: threadID,
                payload: .report(PendingReport(
                    id: interaction.id,
                    description: draft,
                    category: interaction.category,
                    severity: interaction.severity
                )),
                origin: .backend(interaction),
                isResolving: false
            )
        }
    }

    private func publishInteraction(
        _ interaction: ActiveInteraction,
        assistantIndex: Int
    ) {
        if case let .clarification(clarification) = interaction.payload,
           transcript.indices.contains(assistantIndex) {
            let question = clarification.question
            if transcript.indices.contains(assistantIndex) {
                let existing = transcript[assistantIndex].text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.isEmpty {
                    transcript[assistantIndex].text = question
                } else if !existing.contains(question) {
                    transcript[assistantIndex].text += "\n\n\(question)"
                }
            }
        }
        if case .report = interaction.payload {
            // A new review gets a fresh scope review (Task 12) — a summary
            // staged for an earlier report must never be silently reused as
            // this one's consented context.
            clearReportContextReview()
        }
        activeInteraction = interaction
    }

    private func beginResolvingClarification() -> ActiveInteraction? {
        guard var active = activeInteraction, !active.isResolving,
              active.threadID == threadID,
              case .clarification = active.payload else { return nil }
        guard !expireInteractionIfNeeded(active) else { return nil }
        active.isResolving = true
        activeInteraction = active
        lastError = nil
        return active
    }

    private func beginResolvingReport() -> ActiveInteraction? {
        guard var active = activeInteraction, !active.isResolving,
              active.threadID == threadID,
              case .report = active.payload else { return nil }
        guard !expireInteractionIfNeeded(active) else { return nil }
        active.isResolving = true
        activeInteraction = active
        lastError = nil
        return active
    }

    private func interactionID(_ payload: InteractionPayload) -> String {
        switch payload {
        case let .clarification(value): value.id
        case let .report(value): value.id
        }
    }

    private func finishResolution(of id: String) {
        if let active = activeInteraction,
           interactionID(active.payload) == id {
            activeInteraction = nil
        }
        drainQueuedMessageIfReady()
    }

    private func failResolution(of id: String, error: Error) {
        if case AITransportError.interactionResumeAmbiguous = error {
            if let active = activeInteraction,
               interactionID(active.payload) == id {
                activeInteraction = nil
            }
            lastError = nil
            controlDeliveryErrorLocalizationKey =
                "Your response may have been received, so BerryDB will not send it again automatically."
            drainQueuedMessageIfReady()
            return
        }
        if var active = activeInteraction,
           interactionID(active.payload) == id {
            active.isResolving = false
            activeInteraction = active
        }
        lastError = Self.describe(error)
    }

    private func resumeInteraction(
        threadID expectedThreadID: String,
        interactionID: String,
        token: String,
        action: AIInteractionResume.Action,
        protocolText: String,
        displayText: String?,
        report: AIReportConfirmation? = nil
    ) async throws {
        guard !isStreaming else {
            throw SessionInteractionError.conflictingInteraction
        }
        guard threadID == expectedThreadID else {
            throw SessionInteractionError.threadChanged
        }
        lastError = nil
        controlDeliveryErrorLocalizationKey = nil
        lastReportReadyGrant = nil
        let userText = displayText.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : $0
        }
        let transcriptCount = transcript.count
        if let userText, !userText.isEmpty {
            transcript.append(AITurn(role: .user, text: userText))
        }
        transcript.append(AITurn(role: .assistant, text: ""))
        let assistant = transcript.count - 1
        let assistantTurnID = transcript[assistant].id
        isStreaming = true
        defer {
            isStreaming = false
            runningTool = nil
        }
        do {
            let tools = await resolveTools(for: protocolText)
            let capabilities = try (executor as? LocalCapabilityHost)?.beginTurn(with: tools)
            let (context, pendingSummaryFold) = await buildContext(threadID: expectedThreadID)
            let candidateResume = try AIRequestIntegrity.interactionResume(
                token: token,
                action: action,
                text: protocolText,
                threadID: expectedThreadID,
                context: context
            )
            let persisted = UUID(uuidString: expectedThreadID).flatMap {
                try? store.pendingAIInteraction(threadID: $0)
            }
            var resume: AIInteractionResume
            if let persisted,
               persisted.id == interactionID,
               persisted.state == "pending",
               persisted.selectedAction == action.rawValue,
               persisted.responseText == protocolText,
               let clientRequestID = persisted.clientRequestID,
               let requestDigest = persisted.requestDigest {
                resume = AIInteractionResume(
                    token: token, action: action,
                    clientRequestID: clientRequestID,
                    requestDigest: requestDigest
                )
            } else {
                resume = candidateResume
            }
            if let report {
                resume = AIInteractionResume(
                    token: resume.token, action: resume.action,
                    clientRequestID: resume.clientRequestID,
                    requestDigest: resume.requestDigest, report: report
                )
            }
            guard try store.markPendingAIInteractionResolving(
                id: interactionID, action: action.rawValue,
                responseText: protocolText,
                clientRequestID: resume.clientRequestID,
                requestDigest: resume.requestDigest
            ) else {
                throw SessionInteractionError.invalidPayload
            }
            try await streamTurn(
                threadID: expectedThreadID, text: protocolText, tools: tools,
                capabilities: capabilities, context: context,
                resume: resume,
                assistantIndex: assistant, assistantTurnID: assistantTurnID
            )
            let persistedRecords = await persistTurn(
                threadID: expectedThreadID, userText: userText,
                assistantText: transcript[assistant].text,
                userMetadata: "local:interaction",
                assistantMetadata: "local:interaction",
                assistantArtifactRefs: transcript[assistant].artifactRefs
            )
            applyPersistedMessageIDs(persistedRecords, assistant: assistant)
            if let pendingSummaryFold {
                let sessionStore = store
                let sessionTransport = transport
                Task { await Self.applySummaryFold(pendingSummaryFold, store: sessionStore, transport: sessionTransport) }
            }
            removePersistedInteraction(id: interactionID)
        } catch {
            if transcript.count > transcriptCount {
                transcript.removeLast(transcript.count - transcriptCount)
            }
            let interactionResumeAmbiguous: Bool
            if case AITransportError.interactionResumeAmbiguous = error {
                interactionResumeAmbiguous = true
            } else if case let AITransportError.badResponse(code, _) = error,
               code == 429 {
                interactionResumeAmbiguous = false
            } else {
                interactionResumeAmbiguous =
                    Self.isAmbiguousOneShotDeliveryError(error)
            }
            if interactionResumeAmbiguous {
                removePersistedInteraction(id: interactionID)
                throw AITransportError.interactionResumeAmbiguous
            }
            try? store.resetPendingAIInteraction(id: interactionID)
            throw error
        }
    }

    private func resumeLocalInteraction(
        threadID expectedThreadID: String,
        provider: any LocalCompletionProvider,
        action: AIInteractionResume.Action,
        protocolText: String,
        displayText: String
    ) async throws {
        guard !isStreaming else {
            throw SessionInteractionError.conflictingInteraction
        }
        guard threadID == expectedThreadID else {
            throw SessionInteractionError.threadChanged
        }
        let priorTranscript = localPromptTranscript()
        let transcriptCount = transcript.count
        transcript.append(AITurn(role: .user, text: displayText))
        transcript.append(AITurn(role: .assistant, text: ""))
        let assistant = transcript.count - 1
        isStreaming = true
        defer {
            isStreaming = false
            runningTool = nil
        }

        let tools = executor.toolSpecs
        let capabilityHost = executor as? LocalCapabilityHost
        do {
            try capabilityHost?.beginLocalTurn(with: tools)
            let loop = LocalAgentLoop(provider: provider, executor: executor)
            let outcome = await loop.runUntilInteraction(
                userText: protocolText, tools: tools,
                priorTranscript: priorTranscript, resumeAction: action
            ) { piece in
                self.transcript[assistant].text += piece
            }
            switch outcome {
            case .completed:
                try capabilityHost?.finishTurn()
                let persisted = await persistTurn(
                    threadID: expectedThreadID, userText: displayText,
                    assistantText: transcript[assistant].text,
                    userMetadata: "local:interaction",
                    assistantMetadata: "local:interaction"
                )
                applyPersistedMessageIDs(persisted, assistant: assistant)
            case let .clarification(clarification):
                let next = try prepareLocalInteraction(
                    clarification,
                    threadID: expectedThreadID,
                    provider: provider
                )
                try capabilityHost?.suspendTurn()
                transcript[assistant].text = clarification.question
                activeInteraction = next
                let persisted = await persistTurn(
                    threadID: expectedThreadID, userText: displayText,
                    assistantText: clarification.question,
                    userMetadata: "local:interaction",
                    assistantMetadata: "local:interaction"
                )
                applyPersistedMessageIDs(persisted, assistant: assistant)
            }
        } catch {
            capabilityHost?.abandonTurn()
            if transcript.count > transcriptCount {
                transcript.removeLast(transcript.count - transcriptCount)
            }
            throw error
        }
    }

    private func prepareLocalInteraction(
        _ clarification: LocalClarification,
        threadID: String,
        provider: any LocalCompletionProvider
    ) throws -> ActiveInteraction {
        guard !clarification.question
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionInteractionError.invalidPayload
        }
        return ActiveInteraction(
            threadID: threadID,
            payload: .clarification(PendingClarification(
                question: clarification.question,
                reason: clarification.reason,
                choices: clarification.choices,
                allowFreeText: clarification.allowFreeText
            )),
            origin: .local(provider: provider),
            isResolving: false
        )
    }

    /// The thread id is now purely local (Q17 §7.4) — a fresh UUID, saved to
    /// `BerryStore` right away so the first `appendAIMessage` in
    /// `persistTurn` has a parent row to attach to. No backend round trip:
    /// `schemaDigest` (still accepted for API-source compatibility) is
    /// unused now — the backend never learns about a thread's existence.
    private func ensureThread() async throws -> String {
        if let threadID { return threadID }
        let id = UUID()
        let now = Date()
        try? await store.saveAIThreadAsync(AIThreadRecord(id: id, dialect: dialect, connectionKey: connectionKey, createdAt: now, updatedAt: now))
        threadID = id.uuidString
        return id.uuidString
    }

    /// The client is the source of truth for the tool list (05 §4): the
    /// static tools plus this turn's top-K skill:<name> shortcuts (07 §7),
    /// ranked against this turn's message.
    ///
    /// The rank call is bounded (Task 7.2): a slow or hung `rankSkills`
    /// must never delay `streamTurn`, so the wait races against
    /// `skillRankTimeout` and, on timeout, falls back to the static tools
    /// alone for this turn only — the static tools are always present,
    /// never an empty list. A completed, *non-empty* rank is cached by
    /// skill content/version (`SkillRankInput.contentHash`, the versioning
    /// signal `SkillRanking` already exposes — no new scheme invented) plus
    /// the normalized query, so a repeated query against the same installed
    /// skills skips the round trip. A timed-out attempt, and an empty
    /// result (`rankSkills`' own documented shape for "no match" *and* "the
    /// call failed" — the two are indistinguishable at this layer), are
    /// never cached: caching an empty result under a transient failure
    /// would silently deny skill tools to that exact query for the rest of
    /// the session, so every fast-but-empty call gets a fresh attempt next
    /// time instead. There's no separate "skills changed" notification to
    /// hook (none exists today) — baking the content signature into the
    /// cache key makes a stale entry simply unreachable once the installed
    /// skill set differs.
    private func resolveTools(for query: String) async -> [AIToolSpec] {
        let tools = executor.toolSpecs
        guard let skills else { return tools }
        let inputs = skills.skillsForRanking()
        guard !inputs.isEmpty else { return tools }

        let cacheKey = Self.skillRankCacheKey(
            inputs: inputs,
            normalizedQuery: query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
        let topK: [String]
        if let cached = skillRankCache[cacheKey] {
            topK = cached
        } else if let ranked = await boundedRankSkills(inputs: inputs, query: query) {
            if !ranked.isEmpty {
                skillRankCache[cacheKey] = ranked
            }
            topK = ranked
        } else {
            return tools
        }
        return tools + topK.compactMap { skills.skillToolSpec(named: $0) }
    }

    private static func skillRankCacheKey(inputs: [SkillRankInput], normalizedQuery: String) -> String {
        let signature = inputs.map { "\($0.name)#\($0.contentHash)" }.joined(separator: "|")
        return "\(signature)::\(normalizedQuery)"
    }

    /// Races `transport.rankSkills` against `skillRankTimeout`; `nil` means
    /// the timeout won. Uses a pair of unstructured `Task`s racing into a
    /// shared continuation — the same shape as
    /// `ProcessMCPServerConnection.request`'s timeout race — rather than a
    /// `TaskGroup`, which implicitly awaits every child (including the
    /// loser) before returning and would defeat the bound.
    private func boundedRankSkills(inputs: [SkillRankInput], query: String) async -> [String]? {
        let transport = self.transport
        let timeout = skillRankTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let race = RankRace(continuation)
            let rankTask = Task {
                let result = await transport.rankSkills(skills: inputs, query: query)
                await race.resume(with: result)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeout.berryNanoseconds)
                await race.resume(with: nil)
                rankTask.cancel()
            }
        }
    }

    /// Guards a `CheckedContinuation` against a double-resume when the rank
    /// call and the timeout both race for it (Task 7.2). An `actor` so both
    /// unstructured tasks can call in without a manual lock.
    private actor RankRace {
        private let continuation: CheckedContinuation<[String]?, Never>
        private var resumed = false

        init(_ continuation: CheckedContinuation<[String]?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: [String]?) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let transport = error as? AITransportError {
            switch transport {
            case let .badResponse(code, message):
                if let message, !message.isEmpty {
                    return "AI Server error (HTTP \(code)): \(message)"
                }
                return "AI Server returned an unexpected status (HTTP \(code))."
            case .notAuthorized:
                return "Your session has expired or is not authorized (401)."
            case .clientUpdateRequired:
                return "This AI backend requires a newer client."
            case .capabilityRejected:
                return "AI capability negotiation failed."
            case .capabilityNegotiationFailed:
                return "AI capability negotiation did not complete."
            case .interactionResumeUnsupported:
                return "This AI transport cannot resume an interaction."
            case let .protocolViolation(code):
                return code
            case .interactionResumeAmbiguous:
                return "interaction_resume_ambiguous"
            case .toolResultDeliveryAmbiguous:
                return "tool_result_delivery_ambiguous"
            }
        }
        if let urlErr = error as? URLError {
            if urlErr.code == .networkConnectionLost {
                return "The network connection to the AI Server was lost. Check the AI Backend Service (127.0.0.1:8787)."
            }
            if urlErr.code == .cannotConnectToHost {
                return "Could not connect to the AI Backend at 127.0.0.1:8787. Check whether the AI backend server is running."
            }
            if urlErr.code == .timedOut {
                return "The request to the AI Server timed out."
            }
        }
        return error.localizedDescription
    }

    private static func capabilityErrorLocalizationKey(for code: String) -> String {
        switch code {
        case "duplicate_capability",
             "unknown_capability",
             "server_owned_capability",
             "capability_namespace_conflict",
             "capability_descriptor_too_large",
             "invalid_capability_schema",
             "invalid_capability_version",
             "too_many_dynamic_capabilities":
            return "The local AI capability set is invalid."
        case "capability_tier_forbidden",
             "capability_disabled",
             "dynamic_capability_not_allowed":
            return "An AI capability is not available."
        case "client_update_required",
             "capability_version_required",
             "stale_capability",
             "unsupported_handler_version":
            return "Update BerryDB to continue using AI."
        default:
            return "AI capability negotiation failed."
        }
    }
}
