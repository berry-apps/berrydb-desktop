import Foundation

/// One step of an AI turn's "working" activity (docs/feature/09) — one
/// model narration (`progress.note`) plus every tool call that ran without
/// its own narration, in arrival order. See `AIWorkBlock` for the state
/// machine that produces these.
///
/// Replaces the reverted narration work's split between a published
/// `AIWorkStep` and four round-scoped shadow buffers
/// (`rootRoundNarration`/`Tools`/`Artifacts`/`Actions`) reconciled by a
/// separate `flushRoundStep` at *some* boundaries but not others — the
/// direct cause of a real regression (a round-closing path that reset the
/// buffers without ever writing `actions`/`artifactRefs`, because only
/// `flushRoundStep` did that and it didn't run on that path). Every fact
/// here is written straight onto the step the instant it is known, so
/// closing a step is a pure phase flip with nothing left to forget.
public struct AIWorkStep: Identifiable, Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case open, closed }

    public let id: UUID
    public var narration: String
    /// Un-narrated `message.delta` prose that arrived while this step was
    /// open and no round had narrated yet — see `AIWorkBlock`'s answer-
    /// channel handling in `AISession.streamTurn`. Rendered live inside the
    /// step, and promoted into `AITurn.text` once the turn is confirmed to
    /// have no more rounds; never treated as this step's own narration.
    public var provisionalText: String
    /// The only source of tool identity for this step — a step's action
    /// badges are keyed on and de-duplicated by this array alone. A
    /// separately-mutated `toolNames` list used to diverge from this exact
    /// data (PR #112's root cause: a round-closing path updated one but not
    /// the other); `toolNames` below is now a read-only derivation of it.
    public var actions: [AIToolAction]
    /// Artifacts this step's tool(s) produced (docs/feature/09) — what makes
    /// the sub-block's action badge openable.
    public var artifactRefs: [ArtifactRef]
    public internal(set) var phase: Phase
    public let startedAt: Date
    public internal(set) var endedAt: Date?

    /// Tool names in this step, derived from `actions`. Read-only: `actions`
    /// is the only place tool identity is written.
    public var toolNames: [String] { actions.map(\.name) }

    public init(
        narration: String,
        actions: [AIToolAction] = [],
        artifactRefs: [ArtifactRef] = [],
        provisionalText: String = "",
        phase: Phase = .closed,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        id: UUID = UUID()
    ) {
        self.id = id
        self.narration = narration
        self.provisionalText = provisionalText
        self.actions = actions
        self.artifactRefs = artifactRefs
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One AI turn's whole "working" state machine (docs/feature/09) — the
/// step list plus the live/settled timer. Owned by `AITurn.work`; every
/// mutation goes through this type's own methods so a step's lifecycle
/// (open → closed) and the block's timer (unset → set once) are each
/// enforced in one place instead of scattered across `AISession.streamTurn`.
///
/// **Invariants, enforced by construction, not by convention:**
/// - At most one step is `.open` at a time (`openIndex` only ever looks at
///   the LAST step, and every mutator that opens a new one implicitly closes
///   whatever was open by construction of the array itself never having two
///   open entries — see `openStep`).
/// - A `.closed` step is never mutated again (every mutator below only ever
///   touches `steps[openIndex]`, and `openIndex` stops resolving to a closed
///   step the instant it closes).
/// - A bare tool call (no preceding note) never closes the open step — only
///   a note or a round/turn boundary does. See `toolCallStarted`'s doc
///   comment (PR #108(a): a narration-less round used to absorb the NEXT
///   round's note because nothing closed it first).
public struct AIWorkBlock: Sendable, Equatable {
    public private(set) var steps: [AIWorkStep] = []
    public private(set) var startedAt: Date?
    /// `nil` until the turn is confirmed to have no more rounds (`finish`).
    public private(set) var duration: TimeInterval?
    public private(set) var hadToolCall = false
    public private(set) var hadReasoning = false
    public private(set) var toolCallCount = 0

    public init() {}

    /// Constructs a block with pre-set state directly, bypassing the state
    /// machine's own mutators — for building test fixtures (a `TurnView`/
    /// `TurnWorkSummary` render test wants a specific `AITurn.work` without
    /// replaying a whole event sequence) and for `AITurn.init`'s existing
    /// `workSteps`/`hadToolCall`/`workDuration`/`workStartedAt` parameters.
    /// Real turns always start from `AIWorkBlock()` and reach this state only
    /// through `note`/`toolCallStarted`/`finish`/etc.
    public init(
        steps: [AIWorkStep] = [], startedAt: Date? = nil, duration: TimeInterval? = nil,
        hadToolCall: Bool = false, hadReasoning: Bool = false, toolCallCount: Int = 0
    ) {
        self.steps = steps
        self.startedAt = startedAt
        self.duration = duration
        self.hadToolCall = hadToolCall
        self.hadReasoning = hadReasoning
        self.toolCallCount = toolCallCount
    }

    /// The single step, if any, still accepting new facts. `nil` once it has
    /// closed — nothing here ever reopens a closed step (Invariant: no
    /// `.closed` → `.open` transition anywhere in this type).
    public var openStepIndex: Int? {
        guard let last = steps.indices.last, steps[last].phase == .open else { return nil }
        return last
    }

    private mutating func startClock(now: Date) {
        if startedAt == nil { startedAt = now }
    }

    @discardableResult
    private mutating func openStep(narration: String, now: Date) -> Int {
        startClock(now: now)
        steps.append(AIWorkStep(narration: narration, phase: .open, startedAt: now))
        return steps.count - 1
    }

    /// Closes whatever step is open, if any. The ONLY writer of `.closed` —
    /// every closing trigger (a following note, a round boundary, turn end)
    /// routes through this, so a step's final content is always whatever was
    /// written onto it up to this call, never a separately-reconciled copy.
    mutating func closeOpenStep(now: Date) {
        guard let i = openStepIndex else { return }
        steps[i].phase = .closed
        steps[i].endedAt = now
    }

    /// `.progressNote` — narration for the current (or a fresh) step.
    ///
    /// Two notes in a row before any tool call join into the same step's
    /// narration (a model that narrates twice before acting must not produce
    /// an empty sub-block in between). A note arriving once the open step
    /// already has an action closes it and starts a new one — a note always
    /// means a new decision, unlike a bare tool call, which does not close
    /// (see `toolCallStarted`).
    public mutating func note(_ text: String, now: Date) {
        startClock(now: now)
        if let i = openStepIndex {
            if steps[i].actions.isEmpty {
                steps[i].narration = steps[i].narration.isEmpty ? text : steps[i].narration + " " + text
                return
            }
            closeOpenStep(now: now)
        }
        openStep(narration: text, now: now)
    }

    /// Appends un-narrated `message.delta` prose to the open step's preview
    /// (opening a step with empty narration first if none is open). This
    /// text might be the final answer, or might be narration for a round
    /// that isn't done yet — the ambiguity `AISession.streamTurn`'s `.delta`
    /// case resolves by checking whether the open step already has
    /// narration (if so, the delta goes straight to `AITurn.text` instead of
    /// here — see that case). It streams live either way, just inside the
    /// working block until `promoteProvisionalText` moves it once the turn
    /// confirms there are no more rounds.
    public mutating func appendProvisionalText(_ text: String, now: Date) {
        let i = openStepIndex ?? openStep(narration: "", now: now)
        steps[i].provisionalText += text
    }

    /// A `.delta` round boundary (from `AISession`'s `RoundCursor`) — closes
    /// whatever step is open, WITHOUT opening a fresh one. A new step only
    /// ever opens from a note or a tool call, never from plain answer text.
    public mutating func roundBoundaryCrossed(now: Date) {
        closeOpenStep(now: now)
    }

    /// `.toolCall` beginning — publishes the action as `.running`
    /// immediately, before the tool executes, so it is visible while the
    /// call is in flight rather than appearing only once it resolves (PR
    /// #107's fix, now true by construction rather than a special case).
    ///
    /// A bare tool call (no open step, i.e. no preceding note this round)
    /// still attaches to whatever step is CURRENTLY open rather than always
    /// starting fresh — deliberately: the wire cannot distinguish "one round
    /// batched two calls" from "two consecutive un-narrated rounds" (backend
    /// tool.call events carry no round id and are dispatched strictly
    /// serially), so two bare calls merge into one step as the honest
    /// response to that ambiguity, instead of guessing.
    ///
    /// `inputs`/`payload` are already fully known from the call's arguments
    /// before it executes, so they render immediately too — only `status`
    /// and `outputs` are unknown until `toolCallFinished`.
    ///
    /// Returns the location to update once the tool resolves.
    public mutating func toolCallStarted(
        name: String, inputs: [String], payload: String?, now: Date
    ) -> (stepIndex: Int, actionIndex: Int) {
        startClock(now: now)
        hadToolCall = true
        toolCallCount += 1
        let stepIndex = openStepIndex ?? openStep(narration: "", now: now)
        steps[stepIndex].actions.append(
            AIToolAction(name: name, status: .running, inputs: inputs, payload: payload)
        )
        return (stepIndex, steps[stepIndex].actions.count - 1)
    }

    /// Sets a step's narration directly — used only by `AISession.streamTurn`'s
    /// `.toolCall` case, for the turn's first tool call: a model that
    /// narrated in plain prose via `message.delta` instead of calling
    /// `note_progress` (exactly as before `note_progress` existed) has that
    /// prose sitting in `AITurn.text` with nowhere to go once a tool call
    /// finally arrives — this degrades it into the step's narration, same as
    /// an explicit note would have produced. Only ever called when the step
    /// at `stepIndex` has no narration yet (an explicit `progress.note`
    /// always wins; this is a fallback for when one never came).
    public mutating func setFallbackNarration(_ narration: String, at stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        steps[stepIndex].narration = narration
    }

    /// `.toolCall` result arriving — updates the same action in place, by
    /// the location `toolCallStarted` returned. Tolerates the location no
    /// longer existing (defensive; not expected given the strictly
    /// sequential await between start and finish on one MainActor loop, but
    /// cheap to guard rather than assume).
    public mutating func toolCallFinished(
        stepIndex: Int, actionIndex: Int, status: AIToolAction.Status, outputs: [String]
    ) {
        guard steps.indices.contains(stepIndex), steps[stepIndex].actions.indices.contains(actionIndex) else { return }
        steps[stepIndex].actions[actionIndex].status = status
        steps[stepIndex].actions[actionIndex].outputs = outputs
    }

    /// Attaches an artifact ref to the step that produced it, de-duplicated
    /// by artifact id — the same step re-touching one artifact twice (a run
    /// then a self-correcting re-run) must not double the affordance.
    public mutating func attachArtifact(_ ref: ArtifactRef, stepIndex: Int) {
        guard steps.indices.contains(stepIndex) else { return }
        guard !steps[stepIndex].artifactRefs.contains(where: { $0.artifactID == ref.artifactID }) else { return }
        steps[stepIndex].artifactRefs.append(ref)
    }

    /// `.reasoning` — starts the same clock a note or tool call would;
    /// records only that reasoning happened, never the text itself (see
    /// `AITurn.hadReasoning`'s doc comment for why: accumulating an
    /// unbounded, unrendered trace onto an `@Observable` array cost a full
    /// view-tree invalidation per token for nothing).
    public mutating func noteReasoning(now: Date) {
        startClock(now: now)
        hadReasoning = true
    }

    /// Turn end, called from every exit path (`message.complete`, `error`,
    /// a thrown transport error, cancellation, interaction suspension) — see
    /// `AISession.streamTurn`'s turn-end `defer`. Idempotent: the 404-retry
    /// path can invoke this twice for one logical turn (once per
    /// `streamTurn` call), and only the first should stamp `duration`.
    /// Returns whether this call actually settled the block (`false` on a
    /// redundant second call), so the caller can gate promotion on it too.
    @discardableResult
    public mutating func finish(now: Date) -> Bool {
        guard duration == nil else { return false }
        closeOpenStep(now: now)
        if let startedAt {
            duration = now.timeIntervalSince(startedAt)
        }
        return true
    }

    /// Moves the last step's leftover `provisionalText` (un-narrated
    /// `message.delta` prose that was buffered because a tool had run and
    /// this round hadn't narrated — see `AnswerChannel`) into the returned
    /// string, for the caller to append onto `AITurn.text`. Call once, from
    /// `finish`'s caller, after `finish` has returned `true`.
    ///
    /// If that step turns out to have held nothing else (no narration, no
    /// actions — it only ever existed to host the preview), it is removed:
    /// once its text has moved to the answer, an empty row in the working
    /// block would have nothing to show.
    public mutating func promoteProvisionalText() -> String {
        guard let i = steps.indices.last, !steps[i].provisionalText.isEmpty else { return "" }
        let text = steps[i].provisionalText
        steps[i].provisionalText = ""
        if steps[i].narration.isEmpty, steps[i].actions.isEmpty {
            steps.remove(at: i)
        }
        return text
    }
}
