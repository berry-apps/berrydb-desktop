# Merge queued messages into one turn

## Problem

`drainQueuedMessageIfReady()` (`AISession.swift`) drains `queuedMessages` one
item at a time: when a turn finishes, it pops exactly one queued message,
starts a brand new turn for it, and only pops the next one after *that* turn
fully completes (streamed + persisted). If a user queues several messages
while one is streaming, each gets its own full round trip — the wait for the
last queued message is the sum of every turn ahead of it. There is no
artificial delay between turns (the next one fires the instant the previous
one's `isStreaming` flips false, in the same `defer`), but the accumulation
itself reads as "the queue eats time" — reported live while testing the
on-device path.

## Goal

When a turn finishes and there are 2+ messages waiting in `queuedMessages`,
send them together as **one** turn instead of one-by-one: one user bubble,
one `ai_message` row, one model round trip, one assistant reply. A queue of
exactly one message is unaffected — same plain-text bubble, same single row,
byte-for-byte the same as today.

## Non-goals

- No change to how messages get *added* to the queue (`admitSend`,
  `admitSendLocal`, and the report/interaction completion sites keep
  queuing exactly as they do today). Only how the queue is *drained*
  changes.
- No merging across a `runsLocally` boundary — a run of consecutive queued
  items only merges with its neighbors while they share the same
  local/backend destination (see Edge cases).
- No cap on how many queued messages can merge into one turn. Bounded
  naturally by how many times a user can type-and-send while one turn is
  still streaming; an artificial limit would be speculative (YAGNI).
- No change to `AI-35` edit/versioning. A merged turn persists as a single
  `ai_message` row, editable/forkable as one unit, same as any other single
  turn — there is no way to edit "just message 2 of the merged 3" after the
  fact, and this spec doesn't add one.

## Architecture

The only touched function is `AISession.drainQueuedMessageIfReady()`. Today
it does:

```
guard !isStreaming, activeInteraction == nil, !queuedMessages.isEmpty else { return }
let next = queuedMessages.removeFirst()
... (pop the matching queuedMessageWasDisplayed / queuedMessageRunsLocally entries)
append bubble, beginTurn(), dispatch one turn for `next`
```

It becomes: instead of popping exactly one entry, pop a **run** of
consecutive entries from the front of `queuedMessages` — stop the run at the
first entry whose `runsLocally` differs from the run's first entry, or at
the first entry whose `queuedMessageWasDisplayed` is `true` (see Edge
cases), or at the end of the queue. Combine the run's texts (numbering rule
below), append one bubble, `beginTurn()` once, and dispatch one turn — local
or backend, whichever the run's (single, shared) `runsLocally` value says.

This keeps every other call site untouched: `admitSend`/`admitSendLocal`
still push one entry per message; the three other call sites of
`drainQueuedMessageIfReady` (interaction/report completion) are unaffected
because they only ever call the same function, which now merges by itself.

## Components

No new types. One new private helper on `AISession`:

- `private func drainMergeableRun() -> (texts: [String], runsLocally: Bool)?`
  — pure queue-popping logic (loops over `queuedMessages`/
  `queuedMessageWasDisplayed`/`queuedMessageRunsLocally` in lockstep,
  removing the merged prefix from all three, stopping per the rules above).
  Returns `nil` if the queue is empty. Kept as its own method (not inlined
  into `drainQueuedMessageIfReady`) specifically so it's unit-testable
  without going through a full turn.
- `drainQueuedMessageIfReady()` calls it, formats `texts` into the outgoing
  string, and does the existing append-bubble/`beginTurn()`/dispatch work
  unchanged.

## Data flow

1. Turn N finishes → its `defer` calls `drainQueuedMessageIfReady()`.
2. `drainMergeableRun()` pops the leading same-`runsLocally` run (e.g. 3
   entries) off `queuedMessages` and its two parallel arrays.
3. Formatting:
   - 1 text → used verbatim (no numbering, no change from today).
   - 2+ texts → joined as `"1) <first>\n2) <second>\n3) <third>"`.
4. `transcript.append(AITurn(role: .user, text: formatted))` — one bubble.
5. `beginTurn()` — one empty assistant bubble / `isStreaming = true`.
6. Dispatch exactly one turn (`runLocalTurn` or `runTurn`) with `formatted`
   as its text. Persistence (`persistTurn`) writes one `ai_message` row, same
   as any other turn — no schema change.

## Edge cases

- **Mixed local/backend queue.** `queuedMessageRunsLocally` is tracked
  per-entry today (in case the on-device toggle changes between sends). The
  run only extends while consecutive entries share the same value, so a
  queue like `[local, local, backend]` merges the first two into one
  on-device turn and leaves `backend` for the next drain. A single request
  is never split across local and backend.
- **`queuedMessageWasDisplayed == true`.** No current call site ever pushes
  `true` (all three append sites use `false`; the `true` fallback only
  fires if the parallel array is empty while `queuedMessages` isn't, a
  desync that shouldn't happen). The run stops before any such entry rather
  than guessing how to merge an already-shown bubble's text into a new one
  — dead code path today, but this keeps the merge correct if that ever
  changes.
- **Single-item queue.** Explicitly the same code path and same output as
  before this change — no numbering prefix, so no regression for the
  common case.

## Testing

- Extend the existing on-device queue test
  (`aSecondLocalSendWhileStreamingQueuesInsteadOfVanishing`-style setup):
  queue 3 messages while one turn streams, let it finish, assert exactly
  one new user bubble with text `"1) second\n2) third\n3) fourth"`, one new
  assistant bubble, and (via the store) exactly one new `ai_message` row for
  it.
- Same shape for the backend queue path (`MockTransport`-based).
- Regression test: queue exactly one message → drained text is the raw
  string, no `"1) "` prefix.
- `drainMergeableRun` unit test: a queue mixing `runsLocally` values only
  pops the leading same-destination run, leaving the rest queued.

## Rollout

Backend-only change inside `AISession`/`BerryAI` — no server contract
change, no migration. Regular `make test` gate; no feature flag needed given
the fallback (single-item queue) is behaviorally identical to today.
