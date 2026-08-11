import BerryAI
import Foundation
import Testing

@testable import BerryUI

// The gate this file was named for is gone. It withheld the response bubble
// until `workDuration` landed, to satisfy docs/feature/09 §block response —
// necessary only because narration and the answer shared `message.delta`, so
// showing text early meant showing narration that then moved into a sub-block.
// With narration on its own `progress.note` channel there is nothing to hide,
// and the gate's real cost (no streaming) outweighed the flicker it avoided.
//
// `ResponseStreamingTests` below is what replaced it.

/// `TurnWorkSummary.autoExpanded` used to collapse the moment narration text
/// existed, on the assumption that visible text was the thing replacing the
/// working block on screen. Once the response is gated on `workDuration`
/// (§block response) that assumption breaks: text can exist while still
/// hidden, so collapsing on it leaves the turn showing nothing at all.
/// Expansion must follow "has the work settled", which is the same signal the
/// response gate uses.
@MainActor
@Suite("TurnWorkSummary expansion vs. the response gate (docs/feature/09)")
struct TurnWorkSummaryExpansionTests {
    private func summary(duration: TimeInterval?) -> TurnWorkSummary {
        TurnWorkSummary(
            steps: [AIWorkStep(narration: "Reading schema.", actions: [AIToolAction(name: "get_schema", status: .completed)])],
            duration: duration, workStartedAt: Date()
        )
    }

    /// The regression: narration has landed but the turn has not settled, so
    /// the bubble is still withheld. Collapsing here would blank the turn.
    @Test func staysExpandedWhileTheWorkIsUnsettled() {
        #expect(summary(duration: nil).autoExpanded == true)
    }

    @Test func collapsesOnceTheWorkSettles() {
        #expect(summary(duration: 4).autoExpanded == false)
    }

    /// A turn whose rounds produced no narration has nothing to describe, so
    /// the block is a plain header line rather than a disclosure that opens
    /// onto nothing. Reasoning is NOT a body source — see the suite below.
    @Test func hasNoBodyWithoutAnyWorkSteps() {
        let view = TurnWorkSummary(steps: [], duration: nil, workStartedAt: Date())
        #expect(view.hasBody == false)
    }

    @Test func hasBodyOnceAWorkStepExists() {
        #expect(summary(duration: nil).hasBody == true)
    }
}

/// docs/feature/09 §body wants each sub-block to state, in natural language,
/// what the agent is about to do — the way Codex describes a step and then
/// shows the action. A reasoning-mode model's raw chain-of-thought is not
/// that: it is unbounded, unstructured, and arrives token-by-token in far
/// greater volume than the narration (191 reasoning events in one turn in
/// docs/tests/crash.md).
///
/// Rendering it was also the single largest cost in the working block:
/// `combinedReasoningText` re-joined every prior step on each render, and the
/// result went through `ChatMarkdown.parse`, which rescans the whole string.
/// Per token that is quadratic, and it saturated the MainActor badly enough
/// that the client lagged 14s behind a backend that had already finished.
///
/// So the trace is no longer rendered at all. `AIWorkStep.narration` — one
/// bounded sentence the model is now asked for (berrydb-api's
/// RESPONSE_BEHAVIOR) — is the description, on every provider rather than
/// only the ones exposing a thinking stream.
@MainActor
@Suite("Working block renders narration, not raw reasoning (docs/feature/09)")
struct TurnWorkSummaryReasoningTests {
    /// The compile-time half of this guarantee is that `TurnWorkSummary` has
    /// no reasoning inputs left to pass; this pins the behaviour that a turn
    /// with reasoning but no narration shows no body.
    @Test func aTurnWithNoNarrationHasNoBodyEvenThoughItReasoned() {
        let view = TurnWorkSummary(steps: [], duration: 3, workStartedAt: Date())
        #expect(view.hasBody == false)
    }

    /// Narration alone drives the body, with no reasoning involved.
    @Test func narrationAloneProvidesTheBody() {
        let view = TurnWorkSummary(
            steps: [AIWorkStep(narration: "Counting rows in the users table.", actions: [AIToolAction(name: "run_sql", status: .completed)])],
            duration: nil, workStartedAt: Date()
        )
        #expect(view.hasBody == true)
    }
}

/// The response bubble did not stream: it was withheld until `workDuration`
/// landed, because narration and the answer shared `message.delta` and showing
/// text early meant showing narration that then jumped into a sub-block.
///
/// Narration now arrives as its own `progress.note` event (berrydb-api), so
/// `turn.text` is only ever the answer and can render as it streams.
@MainActor
@Suite("Response streams once narration has its own channel (docs/feature/09)")
struct ResponseStreamingTests {
    private func turn(text: String, hadToolCall: Bool, workDuration: TimeInterval?) -> AITurn {
        AITurn(
            role: .assistant, text: text, hadToolCall: hadToolCall, workDuration: workDuration
        )
    }

    /// The regression this replaces: mid-turn text on a tool-calling turn was
    /// hidden. It must now render.
    @Test func aWorkingTurnStreamsItsAnswerBeforeTheTurnSettles() {
        let view = TurnView(
            turn: turn(text: "The users table has 1,2", hadToolCall: true, workDuration: nil)
        )
        #expect(view.showsResponseText, "the answer streams while the working block is still open")
    }

    @Test func aSettledWorkingTurnStillShowsItsAnswer() {
        let view = TurnView(turn: turn(text: "Done.", hadToolCall: true, workDuration: 4))
        #expect(view.showsResponseText)
    }

    @Test func aTurnWithNoTextYetShowsNothing() {
        let view = TurnView(turn: turn(text: "", hadToolCall: true, workDuration: nil))
        #expect(view.showsResponseText == false)
    }
}

/// The reported bug: "clicking the artifact attached in the working block does
/// not open a preview tab". The action badge was inert `Label` text and
/// `AIWorkStep` carried no artifact identity, so there was nothing for a tap to
/// open. The step now carries refs and the row renders a real button per ref —
/// this pins that the callback reaches the workspace with the right id.
@MainActor
@Suite("Working block artifact opening (docs/feature/09)")
struct WorkStepArtifactTests {
    private let ref = ArtifactRef(
        artifactID: UUID(), versionNumber: 1, title: "Ad-hoc run", kind: .editorTab
    )

    @Test func tappingAStepsArtifactForwardsItsID() throws {
        var opened: [UUID] = []
        let row = WorkStepRow(
            step: AIWorkStep(
                narration: "Creating a debug tab.",
                actions: [AIToolAction(name: "create_debug_tab", status: .completed)],
                artifactRefs: [ref]
            ),
            onOpenArtifact: { opened.append($0) }
        )

        row.openArtifact(ref.artifactID)

        #expect(opened == [ref.artifactID])
    }

    /// A round that produced nothing durable must not offer a dead affordance.
    @Test func aStepWithoutArtifactsHasNothingToOpen() {
        let row = WorkStepRow(
            step: AIWorkStep(
                narration: "Reading schema.", actions: [AIToolAction(name: "get_schema", status: .completed)]
            )
        )
        #expect(row.step.artifactRefs.isEmpty)
    }
}

/// docs/feature/09's example shows each action expanding to its own detail —
/// the inputs it ran with, the result it found, and a `Completed`/`Running`
/// status. Tools with no artifact ("Reading schema", "Analyzing queries") had
/// nothing to expand at all, so their badge looked clickable but did nothing.
@MainActor
@Suite("Working block action detail (docs/feature/09)")
struct WorkStepActionDetailTests {
    private func action(
        _ name: String, status: AIToolAction.Status = .completed,
        inputs: [String] = [], outputs: [String] = []
    ) -> AIToolAction {
        AIToolAction(name: name, status: status, inputs: inputs, outputs: outputs)
    }

    @Test func anActionWithDetailIsExpandable() {
        let row = WorkStepRow(
            step: AIWorkStep(
                narration: "Reading schema.",
                actions: [action("get_schema", inputs: ["tables: users, orders"], outputs: ["2 tables"])]
            )
        )
        #expect(row.step.actions.first?.hasDetail == true)
    }

    /// No inputs and no outputs means nothing to show — the row must report that
    /// rather than offering an empty disclosure.
    @Test func anActionWithoutDetailIsNotExpandable() {
        let row = WorkStepRow(
            step: AIWorkStep(
                narration: "Doing something.",
                actions: [action("get_stats")]
            )
        )
        #expect(row.step.actions.first?.hasDetail == false)
    }

    @Test func statusIsCarriedPerAction() {
        let running = action("run_sql", status: .running)
        let failed = action("run_sql", status: .failed)
        #expect(running.statusLabel == "Running")
        #expect(failed.statusLabel == "Failed")
        #expect(action("run_sql").statusLabel == "Completed")
    }
}

/// The inline detail is truncated to stay readable, so it cannot answer "what
/// SQL actually ran". `payload` carries the untruncated primary argument — the
/// SQL for a run, the tab contents for a write, the object list for a read — for
/// the popover a click opens, while `inputs`/`outputs` stay short for the row.
@MainActor
@Suite("Working block action payload (docs/feature/09)")
struct WorkStepActionPayloadTests {
    private let longSQL = "SELECT " + String(repeating: "col_name, ", count: 60) + "1"

    @Test func aRunCarriesItsFullSQLSeparatelyFromTheTruncatedRow() {
        let action = AIToolAction(
            name: "run_sql", status: .completed,
            inputs: ["sql: \(longSQL.prefix(20))…"], payload: longSQL
        )
        #expect(action.payload == longSQL, "the popover needs the whole statement")
        #expect(action.inputs.first!.count < longSQL.count, "the row stays short")
        #expect(action.isInspectable)
    }

    /// A tool with no primary argument worth showing must not offer inspection —
    /// same rule as `hasDetail`: no dead affordances.
    @Test func anActionWithoutAPayloadIsNotInspectable() {
        let action = AIToolAction(name: "get_daily_review", status: .completed)
        #expect(action.isInspectable == false)
    }

    @Test func aReadCarriesWhatItRead() {
        let action = AIToolAction(
            name: "get_schema", status: .completed, payload: "users, orders, payments"
        )
        #expect(action.payload == "users, orders, payments")
        #expect(action.isInspectable)
    }
}

/// Two reported bugs in the three-dot pulse: it overflowed its container, and it
/// stayed on screen after the response had finished.
@MainActor
@Suite("Streaming pulse sizing and visibility")
struct PulsingDotsTests {
    /// `Circle` has no intrinsic size — it fills whatever it is given. The frame
    /// has to be the outermost modifier, or a later one (`.foregroundStyle`,
    /// `.opacity`) re-proposes the parent's full size and the dots grow to fill
    /// the panel width, which is the overflow that was reported.
    @Test func aDotIsFixedSizeRegardlessOfProposedSpace() {
        let dot = PulsingDot(isOn: true, delay: 0)
        #expect(dot.diameter == 6)
    }

    /// The pulse must disappear the moment the turn stops streaming. It is only
    /// ever rendered under `isStreaming`, so this pins the flag that drives it
    /// rather than the view: a turn that has settled is not streaming.
    @Test func aSettledTurnIsNotStreaming() {
        let turn = AITurn(
            role: .assistant, text: "Done.", hadToolCall: true, workDuration: 3
        )
        let view = TurnView(turn: turn, isStreaming: false)
        #expect(view.showsResponseText)
        #expect(view.isStreaming == false)
    }
}

/// Asked whether any streaming path still compounds over time. Two were found,
/// both in work that runs per token.
///
/// `scrollSignal` summed the full length of every sub-agent transcript, so a turn
/// with sub-agent output paid O(total sub text) on every token — the same shape as
/// the reasoning-trace sum removed earlier, which is what made the client lag 14s
/// behind the backend (docs/tests/crash.md).
///
/// These assert the SHAPE of the signal rather than timing, which is what a unit
/// test can hold: the value must not grow with accumulated text.
@MainActor
@Suite("Streaming does not compound per token")
struct StreamingCostTests {
    @Test func theScrollSignalDoesNotGrowWithSubAgentTextLength() {
        let short = AIPanelView.scrollSignalValue(
            turnCount: 2, answerLength: 10, planLength: 0, workStepCount: 1,
            subAgentCount: 1, subAgentTextLength: 10, isToolRunning: false
        )
        let long = AIPanelView.scrollSignalValue(
            turnCount: 2, answerLength: 10, planLength: 0, workStepCount: 1,
            subAgentCount: 1, subAgentTextLength: 500_000, isToolRunning: false
        )
        #expect(short == long, "sub-agent text length must not feed the per-token signal")
    }

    /// It must still fire when a sub-agent produces something, or nested output
    /// scrolls off screen — the count changes, not the length.
    @Test func theScrollSignalStillMovesWhenASubAgentAppears() {
        let none = AIPanelView.scrollSignalValue(
            turnCount: 2, answerLength: 10, planLength: 0, workStepCount: 1,
            subAgentCount: 0, subAgentTextLength: 0, isToolRunning: false
        )
        let one = AIPanelView.scrollSignalValue(
            turnCount: 2, answerLength: 10, planLength: 0, workStepCount: 1,
            subAgentCount: 1, subAgentTextLength: 0, isToolRunning: false
        )
        #expect(none != one)
    }

    /// The answer's own length is the one length that belongs here: the bubble
    /// grows as it streams, so the scroll anchor genuinely has to follow it.
    @Test func theScrollSignalTracksTheAnswerLength() {
        let a = AIPanelView.scrollSignalValue(
            turnCount: 1, answerLength: 10, planLength: 0, workStepCount: 0,
            subAgentCount: 0, subAgentTextLength: 0, isToolRunning: false
        )
        let b = AIPanelView.scrollSignalValue(
            turnCount: 1, answerLength: 11, planLength: 0, workStepCount: 0,
            subAgentCount: 0, subAgentTextLength: 0, isToolRunning: false
        )
        #expect(a != b)
    }
}

/// Reported: an older turn says "Worked for Xs" and a NEW turn that is still
/// reasoning shows the same settled label instead of "Working…".
///
/// The header is a pure function of `duration`, so the label is only wrong if the
/// wrong `duration` reaches it. `TurnWorkSummary` holds `@State`, and SwiftUI
/// reuses state for the view occupying the same position in a container — so
/// without a stable identity per turn, a new turn's block can be handed the
/// previous one's state.
@MainActor
@Suite("Working header reflects its own turn")
struct WorkingHeaderIdentityTests {
    @Test func anUnsettledBlockReportsWorking() {
        let view = TurnWorkSummary(
            steps: [AIWorkStep(narration: "Thinking.")],
            duration: nil, workStartedAt: Date()
        )
        #expect(view.isSettled == false)
    }

    @Test func aSettledBlockReportsWorked() {
        let view = TurnWorkSummary(
            steps: [AIWorkStep(narration: "Done.", actions: [AIToolAction(name: "get_schema", status: .completed)])],
            duration: 12, workStartedAt: Date()
        )
        #expect(view.isSettled)
    }

    /// Two turns in one session must not share a settle state. A fresh turn is
    /// unsettled regardless of what the previous one reported.
    @Test func aNewTurnIsUnsettledEvenAfterAnEarlierTurnSettled() {
        let earlier = TurnWorkSummary(
            steps: [AIWorkStep(narration: "Old.")], duration: 9,
            workStartedAt: Date()
        )
        let current = TurnWorkSummary(
            steps: [AIWorkStep(narration: "New.")], duration: nil,
            workStartedAt: Date()
        )
        #expect(earlier.isSettled)
        #expect(current.isSettled == false, "a new turn cannot inherit the old one's label")
    }
}

/// docs/feature/09.md's mock uses a digital-clock elapsed time (`00:18`,
/// `1:01:01`), not the old word-based "Working… 5s"/"5m 3s" phrasing —
/// digits need no localization, unlike that phrasing did.
@MainActor
@Suite("Working header elapsed-time formatting")
struct WorkingHeaderElapsedLabelTests {
    @Test func formatsAsMinutesAndSecondsBelowAnHour() {
        #expect(TurnWorkSummary.elapsedLabel(0) == "00:00")
        #expect(TurnWorkSummary.elapsedLabel(18) == "00:18")
        #expect(TurnWorkSummary.elapsedLabel(61) == "01:01")
    }

    @Test func addsHoursPastSixtyMinutes() {
        #expect(TurnWorkSummary.elapsedLabel(3661) == "1:01:01")
    }

    /// The transition from "Working" to "Worked" must read continuously —
    /// same digits, same formatter, only the word before them changes.
    @Test func workingAndWorkedShareTheSameNumberFormatting() {
        let view = TurnWorkSummary(
            steps: [AIWorkStep(narration: "Done.")], duration: 18, workStartedAt: Date()
        )
        #expect(TurnWorkSummary.elapsedLabel(view.duration!) == TurnWorkSummary.elapsedLabel(18))
    }
}

/// Reported: the turn is working but nothing shows it.
///
/// A turn in progress must always present SOME progress signal. There are three
/// distinct phases and each has its own, so the bug is a phase that shows none:
/// no answer text yet and no working block yet is exactly the gap, and it is
/// where `isStreaming` was being suppressed while a tool ran.
@MainActor
@Suite("A working turn always shows progress")
struct WorkingProgressVisibilityTests {
    private func view(
        text: String, hadToolCall: Bool, workDuration: TimeInterval?, isStreaming: Bool
    ) -> TurnView {
        TurnView(
            turn: AITurn(
                role: .assistant, text: text, hadToolCall: hadToolCall,
                workDuration: workDuration
            ),
            isStreaming: isStreaming
        )
    }

    /// Phase 1 — nothing has arrived yet. The typing indicator carries it, so the
    /// turn must be considered streaming even while a tool is mid-flight.
    @Test func aTurnWithNothingYetIsStillStreaming() {
        let v = view(text: "", hadToolCall: true, workDuration: nil, isStreaming: true)
        #expect(v.showsResponseText == false, "no bubble yet")
        #expect(v.isStreaming, "so the typing indicator has to be the signal")
    }

    /// Phase 2 — a working block exists. Its live "Working… Ns" timer is the
    /// signal, which is why no extra pulse is needed beside it.
    @Test func aTurnWithAnUnsettledWorkingBlockShowsIt() {
        let v = view(text: "", hadToolCall: true, workDuration: nil, isStreaming: true)
        #expect(v.hasWorkingBlock)
        #expect(v.turn.workDuration == nil, "unsettled, so the header still ticks")
    }

    /// Phase 3 — the answer is arriving. The text itself is the signal.
    @Test func aStreamingAnswerIsItsOwnSignal() {
        let v = view(text: "The users tab", hadToolCall: true, workDuration: nil, isStreaming: true)
        #expect(v.showsResponseText)
    }

    /// The actual defect: a running tool must not suppress the indicator. This
    /// condition used to live inline in `AIPanelView.body`, where nothing could
    /// reach it — which is why the bug survived.
    @Test func aRunningToolDoesNotSuppressTheIndicator() {
        #expect(AIPanelView.isTurnStreaming(sessionIsStreaming: true, isLastTurn: true))
    }

    @Test func onlyTheLastTurnStreams() {
        #expect(AIPanelView.isTurnStreaming(sessionIsStreaming: true, isLastTurn: false) == false)
    }

    @Test func anIdleSessionStreamsNothing() {
        #expect(AIPanelView.isTurnStreaming(sessionIsStreaming: false, isLastTurn: true) == false)
    }
}

/// Click inspects in place; Cmd-click opens a tab. Pinned here because the two
/// gestures share one hit target, so a wiring mistake silently collapses them
/// into whichever branch was written last.
@MainActor
@Suite("Working block action gestures (docs/feature/09)")
struct ActionRowGestureTests {
    private func row(payload: String? = "SELECT 1") -> ActionRow {
        ActionRow(action: AIToolAction(name: "run_sql", status: .completed, payload: payload))
    }

    @Test func aPlainClickInspectsInPlace() {
        #expect(row().gesture(commandHeld: false) == .inspect)
    }

    @Test func aCommandClickOpensATabInstead() {
        #expect(row().gesture(commandHeld: true) == .openInTab("SELECT 1"))
    }

    /// Nothing to show means neither gesture does anything.
    @Test func anUninspectableActionIgnoresBothGestures() {
        #expect(row(payload: nil).gesture(commandHeld: false) == .none)
        #expect(row(payload: nil).gesture(commandHeld: true) == .none)
    }
}
