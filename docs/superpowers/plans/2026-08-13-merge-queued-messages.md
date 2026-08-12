# Merge Queued Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a turn finishes and 2+ messages are waiting in `AISession.queuedMessages`, drain and send them as one merged turn (one bubble, one `ai_message` row, one reply) instead of one turn per queued message.

**Architecture:** `drainQueuedMessageIfReady()` currently pops exactly one queued entry per call. It changes to pop a leading run of consecutive entries that share the same `runsLocally` destination via a new private helper, `drainMergeableRun()`. A run of 1 behaves byte-for-byte as today (no numbering, existing `wasDisplayed` bubble logic preserved). A run of 2+ is numbered (`"1) …\n2) …"`) and always gets a new bubble.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), existing `BerryAI` package test doubles (`MockTransport`, `PausableLocalProvider`, `AsyncGate`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-13-merge-queued-messages-design.md` — read it before starting; this plan implements it exactly.
- No schema/migration change — a merged turn persists as one `ai_message` row via the existing `persistTurn` path, unchanged.
- No new public API surface. `drainMergeableRun` and the changed body of `drainQueuedMessageIfReady` stay `private` on `AISession`, matching every other helper in that file (no existing helper in `AISession.swift` uses bare `internal`).
- Numbering format is exactly `"\(i)) \(text)"` joined with `"\n"`, 1-indexed, only applied when the run has 2+ items.
- A run only extends across consecutive queue entries sharing the same `runsLocally` value AND `queuedMessageWasDisplayed == false`; it always drains at least 1 entry regardless.

---

### Task 1: Merge queued messages in `drainQueuedMessageIfReady`

**Files:**
- Modify: `Packages/BerryAI/Sources/AISession.swift:1086-1109` (replace `drainQueuedMessageIfReady`, add `drainMergeableRun` immediately above it)
- Test: `Packages/BerryAI/Tests/BerryAITests.swift` (add new tests near the existing on-device queue test, `aSecondLocalSendWhileStreamingQueuesInsteadOfVanishing`, currently ~line 3129-3154)

**Interfaces:**
- Consumes: `AISession.queuedMessages: [String]`, `queuedMessageWasDisplayed: [Bool]`, `queuedMessageRunsLocally: [Bool]`, `lastLocalProvider: (any LocalCompletionProvider)?`, `beginTurn() -> (index: Int, id: UUID)`, `runTurn(_:assistant:assistantTurnID:)`, `runLocalTurn(_:provider:assistant:)` — all already exist, no signature changes.
- Produces: `drainMergeableRun() -> (texts: [String], runsLocally: Bool, firstWasDisplayed: Bool)` — private, used only by `drainQueuedMessageIfReady` in this same file. No other task/file depends on it.

- [ ] **Step 1: Write the failing tests**

Add these four tests to `Packages/BerryAI/Tests/BerryAITests.swift`, right after `aSecondLocalSendWhileStreamingQueuesInsteadOfVanishing` (~line 3154):

```swift
@MainActor
@Test func drainMergesQueuedBackendMessagesIntoOneNumberedTurn() async {
    let transport = MockTransport(before: [.delta("reply"), .complete(totalTokens: 1)], after: [])
    let gate = AsyncGate()
    transport.responseGate = gate
    let session = AISession(transport: transport, executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.send("first") }
    await gate.waitUntilEntered()

    _ = session.admitSend("second")
    _ = session.admitSend("third")
    #expect(session.queuedMessages == ["second", "third"])

    await gate.release()
    await firstTask.value
    while session.isStreaming { await Task.yield() }

    #expect(session.transcript.map(\.text) == ["first", "reply", "1) second\n2) third", "reply"])
    #expect(session.queuedMessages.isEmpty)
}

@MainActor
@Test func drainMergesQueuedLocalMessagesIntoOneNumberedTurn() async {
    let provider = PausableLocalProvider(finalText: "reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.runLocal(session.admitSendLocal("first", provider: provider)) }
    await provider.waitUntilEntered()

    _ = session.admitSendLocal("second", provider: provider)
    _ = session.admitSendLocal("third", provider: provider)
    #expect(session.queuedMessages == ["second", "third"])

    provider.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() }

    #expect(session.transcript.map(\.text) == ["first", "reply", "1) second\n2) third", "reply"])
    #expect(session.queuedMessages.isEmpty)
}

@MainActor
@Test func drainOnlyMergesTheLeadingRunThatSharesTheSameDestination() async {
    let localProvider = PausableLocalProvider(finalText: "local reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.runLocal(session.admitSendLocal("first", provider: localProvider)) }
    await localProvider.waitUntilEntered()

    _ = session.admitSendLocal("second", provider: localProvider)
    _ = session.admitSendLocal("third", provider: localProvider)
    _ = session.admitSend("fourth")
    #expect(session.queuedMessages == ["second", "third", "fourth"])

    localProvider.resume()
    await firstTask.value

    // The merge for "second"+"third" fires synchronously in the same defer
    // that closes "first" out — observable immediately, before its own
    // reply streams, and before "fourth" (a different destination) ever
    // gets a chance to also drain.
    #expect(session.transcript.map(\.text) == ["first", "local reply", "1) second\n2) third", ""])
    #expect(session.queuedMessages == ["fourth"], "the backend-destined item stays queued for its own drain")
    #expect(session.isStreaming == true)
}

@MainActor
@Test func drainOfExactlyOneQueuedMessageStaysUnnumbered() async {
    let provider = PausableLocalProvider(finalText: "reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.runLocal(session.admitSendLocal("first", provider: provider)) }
    await provider.waitUntilEntered()

    _ = session.admitSendLocal("second", provider: provider)

    provider.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() }

    #expect(session.transcript.map(\.text) == ["first", "reply", "second", "reply"], "a lone queued message is never numbered")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "drainMerges|drainOnlyMerges|drainOfExactlyOne"`

Expected: all four FAIL. The first three fail on the `#expect(session.transcript.map(\.text) == ...)` merge assertions (today's code drains one at a time, so `"1) second\n2) third"` never appears — you'll see e.g. `transcript.map(\.text)` containing `"second"` and `"third"` as two separate bubbles, or the mixed-destination test seeing all three drained/interleaved instead of stopping at the destination boundary). The fourth (`drainOfExactlyOneQueuedMessageStaysUnnumbered`) should already PASS since it doesn't exercise merging — if it fails, something else is wrong; stop and investigate before continuing.

- [ ] **Step 3: Implement `drainMergeableRun` and rewrite `drainQueuedMessageIfReady`**

Replace lines 1086-1109 of `Packages/BerryAI/Sources/AISession.swift` (the current `drainQueuedMessageIfReady` method) with:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "drainMerges|drainOnlyMerges|drainOfExactlyOne"`

Expected: all four PASS.

- [ ] **Step 5: Run the full BerryAI test suite**

Run: `swift test --filter BerryAITests`

Expected: PASS, including `aSecondLocalSendWhileStreamingQueuesInsteadOfVanishing` (the pre-existing single-item queue test) unchanged — it's the regression guard proving a lone queued message still gets no numbering prefix.

- [ ] **Step 6: Run the full project test suite**

Run: `make test`

Expected: PASS (~1377+ tests, 0 failures) — this also exercises `BerryUI`/`AIPanelController` call sites of the queue indirectly (nothing there changes, but this is the project's required full gate per `CLAUDE.md` before any commit).

- [ ] **Step 7: Commit**

```bash
git add Packages/BerryAI/Sources/AISession.swift Packages/BerryAI/Tests/BerryAITests.swift
git commit -m "$(cat <<'EOF'
feat(ai): merge queued messages into one turn instead of one-by-one

drainQueuedMessageIfReady popped exactly one queued message per call, so
each queued message paid for its own full round trip — the wait for the
Nth queued message was the sum of every turn ahead of it. It now drains a
run of consecutive queued messages that share the same local/backend
destination into one bubble/turn/ai_message row (numbered "1) ...\n2) ..."
when 2+), instead of one turn per message. A queue of exactly one message
is unaffected.

See docs/superpowers/specs/2026-08-13-merge-queued-messages-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
