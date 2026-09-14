import Foundation
import Testing

@testable import BerryAI

/// Pure, synchronous tests of `AIWorkBlock`'s state machine — no transport,
/// no `AISession`, no `@MainActor`. This is where the step-boundary event
/// grammar (note / bare tool call / round boundary / turn end, in every
/// combination that mattered live across the reverted #107-114 session) is
/// enumerated directly, so each case is provable in isolation rather than
/// rediscovered one at a time through live testing.
@Suite("AIWorkBlock state machine")
struct AIWorkBlockTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func action(_ name: String, status: AIToolAction.Status = .running) -> AIToolAction {
        AIToolAction(name: name, status: status)
    }

    // MARK: - Identity and open-step invariants

    @Test func openingAStepAssignsAStableIDThatLaterAppendsDoNotChange() {
        var block = AIWorkBlock()
        block.note("Reading the schema.", now: t0)
        let id = block.steps[0].id
        block.note("Still reading.", now: t0)
        #expect(block.steps[0].id == id, "appending to the same open step must not change its identity")
    }

    @Test func atMostOneStepIsOpenAcrossARandomizedLegalSequence() {
        // "Legal" here means note/toolCall/roundBoundary in any order and
        // count — the invariant must hold regardless of the specific
        // sequence, not just the hand-picked cases below.
        var block = AIWorkBlock()
        var seed: UInt64 = 42
        func nextStep() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int(seed % 3)
        }
        for i in 0..<50 {
            let now = t0.addingTimeInterval(Double(i))
            switch nextStep() {
            case 0: block.note("note \(i)", now: now)
            case 1: _ = block.toolCallStarted(name: "tool\(i)", inputs: [], payload: nil, now: now)
            default: block.roundBoundaryCrossed(now: now)
            }
            let openCount = block.steps.filter { $0.phase == .open }.count
            #expect(openCount <= 1, "more than one open step after step \(i) of the randomized sequence")
        }
    }

    @Test func aClosedStepIsNeverMutatedAgain() {
        var block = AIWorkBlock()
        block.note("First.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        block.roundBoundaryCrossed(now: t0.addingTimeInterval(1))
        let frozen = block.steps[0]
        #expect(frozen.phase == .closed)

        // Nothing that happens afterward may touch it.
        block.note("Second.", now: t0.addingTimeInterval(2))
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(3))
        block.finish(now: t0.addingTimeInterval(4))

        #expect(block.steps[0] == frozen)
    }

    // MARK: - Event grammar (N = note, T = tool call, boundary = round crossing)

    @Test func nThenT_oneStepWithNarrationAndOneAction() {
        var block = AIWorkBlock()
        block.note("Reading the schema.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)

        #expect(block.steps.count == 1)
        #expect(block.steps[0].narration == "Reading the schema.")
        #expect(block.steps[0].actions.map(\.name) == ["get_schema"])
    }

    @Test func nNThenT_consecutiveNotesJoinWithASpace() {
        var block = AIWorkBlock()
        block.note("Let me look.", now: t0)
        block.note("Focusing on users.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)

        #expect(block.steps.count == 1)
        #expect(block.steps[0].narration == "Let me look. Focusing on users.")
    }

    /// Regression guard: a note-triggered close must carry every
    /// field (narration + actions + artifacts) onto the frozen step, not
    /// just the ones a separate reconciliation pass remembered to copy.
    @Test func nTnT_twoStepsEachWithItsOwnNarrationAndAction() {
        var block = AIWorkBlock()
        block.note("Step one.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        block.note("Step two.", now: t0.addingTimeInterval(1))
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(1))

        #expect(block.steps.count == 2)
        #expect(block.steps[0].narration == "Step one.")
        #expect(block.steps[0].actions.map(\.name) == ["get_schema"])
        #expect(block.steps[1].narration == "Step two.")
        #expect(block.steps[1].actions.map(\.name) == ["run_sql"])
    }

    /// Regression guard: a bare tool call (no preceding
    /// note) still opens/attaches to a step immediately, with empty
    /// narration, visible while the tool runs.
    @Test func tAlone_oneStepWithEmptyNarrationAndOneAction() {
        var block = AIWorkBlock()
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)

        #expect(block.steps.count == 1)
        #expect(block.steps[0].narration.isEmpty)
        #expect(block.steps[0].actions.map(\.name) == ["get_schema"])
    }

    /// Regression guard: a bare tool call must NOT leave
    /// `openIndex` dangling on a finished, narration-less step — the next
    /// note must open its own fresh step, not land on the old one.
    @Test func tNthenT_bareCallDoesNotAbsorbTheNextNotesStep() {
        var block = AIWorkBlock()
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        block.note("Now checking rows.", now: t0.addingTimeInterval(1))
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(1))

        #expect(block.steps.count == 2)
        #expect(block.steps[0].narration.isEmpty)
        #expect(block.steps[0].actions.map(\.name) == ["get_schema"])
        #expect(block.steps[1].narration == "Now checking rows.")
        #expect(block.steps[1].actions.map(\.name) == ["run_sql"])
    }

 /// A deliberate merge: the wire cannot distinguish "one round
    /// batched two calls" from "two consecutive un-narrated rounds" (no
    /// round id on `tool.call`, strictly serial dispatch) — two bare calls
    /// merge into one step as the honest response to that ambiguity.
    @Test func tT_twoBareCallsMergeIntoOneStepInArrivalOrder() {
        var block = AIWorkBlock()
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(1))

        #expect(block.steps.count == 1)
        #expect(block.steps[0].actions.map(\.name) == ["get_schema", "run_sql"])
    }

    @Test func nTT_oneStepWithNarrationAndTwoActions() {
        var block = AIWorkBlock()
        block.note("Doing two things.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(1))

        #expect(block.steps.count == 1)
        #expect(block.steps[0].narration == "Doing two things.")
        #expect(block.steps[0].actions.map(\.name) == ["get_schema", "run_sql"])
    }

    /// Every close trigger must produce an identical frozen step from an
    /// identical prefix (ensures round-closing carries
    /// `actions`/`artifactRefs` onto the frozen step).
    @Test func everyCloseTriggerProducesTheSameFrozenStep() {
        func stepAfterClosing(_ close: (inout AIWorkBlock, Date) -> Void) -> AIWorkStep {
            var block = AIWorkBlock()
            block.note("Reading the schema.", now: t0)
            let location = block.toolCallStarted(name: "get_schema", inputs: ["x"], payload: "SELECT 1", now: t0)
            block.toolCallFinished(
                stepIndex: location.stepIndex, actionIndex: location.actionIndex,
                status: .completed, outputs: ["2 tables"]
            )
            block.attachArtifact(
                ArtifactRef(artifactID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, versionNumber: 1, title: "x", kind: .editorTab),
                stepIndex: location.stepIndex
            )
            close(&block, t0.addingTimeInterval(2))
            return block.steps[0]
        }

        let viaNextNote = stepAfterClosing { block, now in
            block.note("Next step.", now: now)
        }
        let viaRoundBoundary = stepAfterClosing { block, now in
            block.roundBoundaryCrossed(now: now)
        }
        let viaFinish = stepAfterClosing { block, now in
            block.finish(now: now)
        }

        for step in [viaNextNote, viaRoundBoundary, viaFinish] {
            #expect(step.narration == "Reading the schema.")
            #expect(step.actions.count == 1)
            #expect(step.actions[0].status == .completed)
            #expect(step.actions[0].outputs == ["2 tables"])
            #expect(step.artifactRefs.count == 1)
            #expect(step.phase == .closed)
        }
    }

    // MARK: - Tool call lifecycle

    @Test func anActionIsRunningImmediatelyThenFlipsAfterItResolves() {
        var block = AIWorkBlock()
        let location = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0)
        #expect(block.steps[location.stepIndex].actions[location.actionIndex].status == .running)

        block.toolCallFinished(
            stepIndex: location.stepIndex, actionIndex: location.actionIndex,
            status: .completed, outputs: ["ok"]
        )
        #expect(block.steps[location.stepIndex].actions[location.actionIndex].status == .completed)
        #expect(block.steps[location.stepIndex].actions[location.actionIndex].outputs == ["ok"])
        #expect(block.steps.flatMap(\.actions).count == 1, "the same action updates in place, not a second one")
    }

    @Test func artifactsAreDeDupedByArtifactIDOnTheSameStep() {
        var block = AIWorkBlock()
        let location = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0)
        let ref = ArtifactRef(artifactID: UUID(), versionNumber: 1, title: "run", kind: .editorTab)
        block.attachArtifact(ref, stepIndex: location.stepIndex)
        block.attachArtifact(ref, stepIndex: location.stepIndex)
        #expect(block.steps[location.stepIndex].artifactRefs.count == 1, "the same artifact touched twice must not double the affordance")
    }

    // MARK: - Turn end

    @Test func finishIsIdempotentAndDoesNotRestampDuration() {
        var block = AIWorkBlock()
        block.note("Working.", now: t0)
        #expect(block.finish(now: t0.addingTimeInterval(5)) == true)
        let firstDuration = block.duration
        #expect(block.finish(now: t0.addingTimeInterval(50)) == false, "a second finish call must be a no-op")
        #expect(block.duration == firstDuration, "duration must not be restamped by the redundant call")
    }

    @Test func finishOnAnEmptyBlockLeavesDurationNil() {
        var block = AIWorkBlock()
        #expect(block.finish(now: t0) == true, "finish still runs (idempotency-guard only), but there was never anything to time")
        #expect(block.duration == nil)
    }

    @Test func promotingProvisionalTextRemovesAStepThatOnlyEverHeldPreviewText() {
        var block = AIWorkBlock()
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        block.roundBoundaryCrossed(now: t0.addingTimeInterval(1))
        block.appendProvisionalText("The answer is 42.", now: t0.addingTimeInterval(2))
        #expect(block.steps.count == 2)

        let promoted = block.promoteProvisionalText()
        #expect(promoted == "The answer is 42.")
        #expect(block.steps.count == 1, "the preview-only step is removed once its text has moved to the answer")
    }

    @Test func promotingProvisionalTextKeepsAStepThatAlsoHasActions() {
        var block = AIWorkBlock()
        let location = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        block.appendProvisionalText("Also some prose.", now: t0.addingTimeInterval(1))
        let idBefore = block.steps[location.stepIndex].id

        let promoted = block.promoteProvisionalText()
        #expect(promoted == "Also some prose.")
        #expect(block.steps.count == 1, "a step with real actions must survive promotion, only its preview text clears")
        #expect(block.steps[0].id == idBefore, "surviving steps keep their identity across promotion")
        #expect(block.steps[0].provisionalText.isEmpty)
    }

    @Test func removingTheTrailingPreviewStepDoesNotChangeAnyEarlierStepsIdentity() {
        var block = AIWorkBlock()
        block.note("First step.", now: t0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        let firstID = block.steps[0].id

        block.roundBoundaryCrossed(now: t0.addingTimeInterval(1))
        block.appendProvisionalText("Trailing prose.", now: t0.addingTimeInterval(2))
        _ = block.promoteProvisionalText()

        #expect(block.steps.count == 1)
        #expect(block.steps[0].id == firstID, "the surviving earlier step's identity must be untouched by removing a later one")
    }

    @Test func hadToolCallAndToolCallCountTrackRealToolCallsOnly() {
        var block = AIWorkBlock()
        #expect(block.hadToolCall == false)
        #expect(block.toolCallCount == 0)
        _ = block.toolCallStarted(name: "get_schema", inputs: [], payload: nil, now: t0)
        _ = block.toolCallStarted(name: "run_sql", inputs: [], payload: nil, now: t0.addingTimeInterval(1))
        #expect(block.hadToolCall == true)
        #expect(block.toolCallCount == 2)
    }

    @Test func startedAtIsSetOnceByWhicheverEventHappensFirst() {
        var block = AIWorkBlock()
        #expect(block.startedAt == nil)
        block.noteReasoning(now: t0)
        #expect(block.startedAt == t0)
        block.note("Later.", now: t0.addingTimeInterval(10))
        #expect(block.startedAt == t0, "the clock starts once, from the first event, not the latest")
    }
}
