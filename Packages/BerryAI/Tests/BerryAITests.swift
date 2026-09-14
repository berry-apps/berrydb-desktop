import BerryStore
import Foundation
import Testing
@testable import BerryAI

private func makeStore() -> BerryStore {
    try! BerryStore(path: ":memory:")
}

/// this file's tests seed a thread's messages directly via
/// `appendAIMessage`, bypassing the real send/persistTurn flow that
/// maintains the message tree — this chains each message's `parentID` and
/// advances the thread's `activeLeafMessageID` the same way `persistTurn`
/// does, so `buildContext`/`openThread`/`recentReportContext` (which now
/// read the ACTIVE path only) see them.
@discardableResult
private func seedActiveMessages(
    _ store: BerryStore, threadID: UUID, _ messages: [AIMessageRecord]
) throws -> [AIMessageRecord] {
    var previous: UUID?
    var chained: [AIMessageRecord] = []
    for message in messages {
        var next = message
        next.parentID = previous
        try store.appendAIMessage(next)
        previous = next.id
        chained.append(next)
    }
    try store.setActiveLeafMessage(threadID: threadID, messageID: previous)
    return chained
}

/// Polls `condition` with cooperative yields instead of an artificial sleep
/// — same pattern as the pre-existing embedding-indexer poll below, factored
/// out because Task 7.1's background summary refresh needs it repeatedly.
@MainActor
private func waitUntil(
    _ condition: () throws -> Bool
) async throws {
    for _ in 0..<1_000 {
        if try condition() { return }
        await Task.yield()
    }
}

/// Cross-contract fixture minted by the backend test with kid `2026_07`,
/// key bytes 0x07×32, nonce 0×12, and AAD
/// `berrydb.interaction/v1/2026_07`.
private let validInteractionToken =
    "v1.2026_07.AAAAAAAAAAAAAAAAGvrC24PmfpqEJbVGph453MSLy9QXudgwYnrw5SaHbgOfqCog6p0F06fVlgvqxivea_aZbfQondMLozo3WapOv2aF5Gk4"

private func interactionWire(
    callID: String = "i1",
    kind: String = "clarify_request",
    args: [String: Any] = [
        "question": "Which database?", "reason": "Target required",
    ],
    origin: String = "root",
    rootThreadID: String = "thread-a",
    originThreadID: String? = nil,
    originPath: String? = nil,
    parentThreadID: String? = nil,
    token: String = validInteractionToken,
    expiresAtUnix: Int64 = 4_102_444_800,
    extra: [String: Any] = [:]
) -> Data {
    let child = origin == "subagent"
    var object: [String: Any] = [
        "call_id": callID,
        "kind": kind,
        "args": args,
        "resume_token": token,
        "origin": origin,
        "origin_thread_id": originThreadID
            ?? (child ? "\(rootThreadID)-sub1" : rootThreadID),
        "origin_path": originPath ?? (child ? "root/sub1" : "root"),
        "parent_thread_id": parentThreadID ?? rootThreadID,
        "expires_at_unix": NSNumber(value: expiresAtUnix),
        "registry_version": "2026-07-29",
        "tool_version": "1.0.0",
        "schema_version": "1",
        "thread_id": rootThreadID,
    ]
    object.merge(extra) { _, new in new }
    return try! JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys]
    )
}

private func interactionFixture(
    id: String = "clarify-1",
    rootThreadID: String,
    childNumber: Int? = nil,
    expiresAtUnix: Int64 = 4_102_444_800
) -> AIInteraction {
    let childID = childNumber.map { "\(rootThreadID)-sub\($0)" }
    return AIInteraction(
        id: id, kind: .clarifyRequest,
        resumeToken: validInteractionToken,
        origin: childID == nil ? .root : .subagent,
        threadID: rootThreadID,
        originThreadID: childID ?? rootThreadID,
        originPath: childNumber.map { "root/sub\($0)" } ?? "root",
        parentThreadID: rootThreadID,
        expiresAtUnix: expiresAtUnix,
        registryVersion: "2026-07-29",
        toolVersion: "1.0.0", schemaVersion: "1",
        question: "Which database?", reason: "Target required",
        choices: ["staging", "production"], allowFreeText: true
    )
}

private func normalizedMockInteractionEvent(
    _ event: AIEvent,
    rootThreadID: String,
    eventThreadID: String
) -> AIEvent {
    guard case let .interactionRequired(value) = event,
          value.threadID.isEmpty else { return event }
    let isRoot = rootThreadID == eventThreadID
    let childSuffix = eventThreadID.hasPrefix("\(rootThreadID)-sub")
        ? String(eventThreadID.dropFirst("\(rootThreadID)-sub".count)) : "1"
    return .interactionRequired(AIInteraction(
        id: value.id, kind: value.kind, resumeToken: value.resumeToken,
        origin: isRoot ? .root : .subagent,
        threadID: rootThreadID, originThreadID: eventThreadID,
        originPath: isRoot ? "root" : "root/sub\(childSuffix)",
        parentThreadID: rootThreadID,
        expiresAtUnix: value.expiresAtUnix,
        registryVersion: value.registryVersion.isEmpty
            ? "test" : value.registryVersion,
        toolVersion: value.toolVersion.isEmpty ? "test" : value.toolVersion,
        schemaVersion: value.schemaVersion.isEmpty
            ? "test" : value.schemaVersion,
        question: value.question, reason: value.reason,
        choices: value.choices, allowFreeText: value.allowFreeText,
        draft: value.draft, category: value.category,
        severity: value.severity, unknowns: value.unknowns
    ))
}

// MARK: - SSE parsing

@Test func parsesExactGatewayStream() {
    // Two SSE frames exactly as berrydb-backend's gateway writes them: each is
    // `event:`/`data:` lines closed by a blank line (\n\n).
    let stream =
        "event: message.delta\n" +
        #"data: {"text":"Let me look at the schema. "}"# + "\n" +
        "\n" +
        "event: tool.call\n" +
        #"data: {"args":{},"call_id":"thr-1-c0","dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","capability_set_digest":"digest","name":"get_schema"}"# + "\n" +
        "\n"
    let parser = SSEParser()
    let events = parser.feed(stream)
    #expect(events.count == 2)
    #expect(events[0] == SSERawEvent(event: "message.delta", data: #"{"text":"Let me look at the schema. "}"#))
    #expect(events[1] == SSERawEvent(event: "tool.call", data: #"{"args":{},"call_id":"thr-1-c0","dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","capability_set_digest":"digest","name":"get_schema"}"#))
}

@Test func buffersPartialLinesAcrossChunks() {
    let parser = SSEParser()
    #expect(parser.feed("event: message.del").isEmpty)
    #expect(parser.feed("ta\ndata: {\"text\":\"hi\"}\n").isEmpty)
    let events = parser.feed("\n")
    #expect(events == [SSERawEvent(event: "message.delta", data: #"{"text":"hi"}"#)])
}

@Test func ignoresHeartbeatComments() {
    let parser = SSEParser()
    let events = parser.feed(": keep-alive\n\nevent: message.complete\ndata: {\"usage\":{\"total_tokens\":42}}\n\n")
    #expect(events == [SSERawEvent(event: "message.complete", data: #"{"usage":{"total_tokens":42}}"#)])
}

@Test func sseEventsFromRawByteStreamPreservesBlankLineDelimiters() async throws {
    // Regression for the empty-bubble bug: URLSession.AsyncBytes.lines DROPS the
    // blank lines that delimit SSE events, so the parser never dispatched and no
    // event ever reached the client. Feeding raw bytes must recover every frame.
    let wire =
        "event: message.delta\n" +
        #"data: {"text":"pong","thread_id":"thr-1"}"# + "\n\n" +
        "event: message.complete\n" +
        #"data: {"thread_id":"thr-1","usage":{"total_tokens":5}}"# + "\n\n"
    let bytes = AsyncStream<UInt8> { continuation in
        for byte in Array(wire.utf8) { continuation.yield(byte) }
        continuation.finish()
    }
    var events: [SSERawEvent] = []
    for try await event in sseEvents(from: bytes) { events.append(event) }
    #expect(events.count == 2)
    #expect(events[0] == SSERawEvent(event: "message.delta", data: #"{"text":"pong","thread_id":"thr-1"}"#))
    #expect(events[1].event == "message.complete")
}

// MARK: - Event decoding

// MARK: - Restoring a saved conversation

@Test func conversationTurnsKeepsUserAndAnsweredAssistantMessages() {
    let messages: [[String: Any]] = [
        ["role": "user", "content": "how many tables?"],
        // A tool-call round: assistant with no text → not a display bubble.
        ["role": "assistant", "content": "", "tool_calls": [["id": "c", "name": "get_schema"]]],
        ["role": "tool", "content": "{\"objects\":[]}", "tool_call_id": "c"],
        ["role": "assistant", "content": "You have **3** tables."],
    ]
    let turns = conversationTurns(from: messages)
    #expect(turns.count == 2)
    #expect(turns[0].role == .user)
    #expect(turns[0].text == "how many tables?")
    #expect(turns[1].role == .assistant)
    #expect(turns[1].text == "You have **3** tables.")
}

@Test func decodesToolCallWithStringifiedArgs() {
    let data = Data(#"{"call_id":"c1","dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","capability_set_digest":"digest","name":"run_sql","args":{"sql":"SELECT 1","limit":100},"registry_version":"r1","tool_version":"1.0.0","schema_version":"1","risk":"read","approval":"never","thread_id":"thread-a"}"#.utf8)
    let event = AIEvent.decode(event: "tool.call", data: data)
    #expect(event == .toolCall(AIToolCall(
        id: "c1", name: "run_sql",
        args: ["sql": "SELECT 1", "limit": "100"],
        dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
        registryVersion: "r1", toolVersion: "1.0.0",
        schemaVersion: "1", risk: "read", approval: "never",
        capabilitySetDigest: "digest"
    )))
}

@Test func rejectsToolCallWithoutOneShotDispatchBinding() {
    let missingNonce = Data(
        #"{"call_id":"c1","name":"run_sql","capability_set_digest":"digest","args":{}}"#.utf8
    )
    let missingDigest = Data(
        #"{"call_id":"c1","name":"run_sql","dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","args":{}}"#.utf8
    )
    #expect(AIEvent.decode(event: "tool.call", data: missingNonce)
        == .protocolError(code: "invalid_tool_call_contract"))
    #expect(AIEvent.decode(event: "tool.call", data: missingDigest)
        == .protocolError(code: "invalid_tool_call_contract"))
}

@Test func malformedKnownToolCallFailsClosedInsteadOfBeingDropped() {
    let invalidPayloads = [
        #"{"call_id":"c1","name":"get_schema","args":{},"capability_set_digest":"digest"}"#,
        #"{"call_id":"c1","name":"get_schema","args":[],"dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","capability_set_digest":"digest","registry_version":"1","tool_version":"1","schema_version":"1","risk":"read","approval":"none"}"#,
        #"{"call_id":"c1","name":"get_schema","args":{},"dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","capability_set_digest":"digest","registry_version":"1","tool_version":"1","schema_version":"1","risk":"read","approval":"none","unexpected":true}"#,
    ]

    for payload in invalidPayloads {
        #expect(
            AIEvent.decode(event: "tool.call", data: Data(payload.utf8))
                == .protocolError(code: "invalid_tool_call_contract")
        )
    }
    #expect(AIEvent.decode(event: "future.event", data: Data("{}".utf8)) == nil)
}

@Test func interactionReceiptAndCanonicalResumeDigestMatchBackendFixture() throws {
    let digest = String(repeating: "a", count: 64)
    let receipt = AIEvent.decode(
        event: "interaction.receipt",
        data: Data(#"{"receipt_id":"receipt-1","client_request_id":"request-1","request_digest":"\#(digest)","duplicate":false,"thread_id":"thread-a"}"#.utf8)
    )
    #expect(receipt == .interactionReceipt(AIInteractionReceipt(
        receiptID: "receipt-1",
        clientRequestID: "request-1",
        requestDigest: digest,
        duplicate: false,
        threadID: "thread-a"
    )))
    #expect(AIEvent.decode(
        event: "interaction.receipt",
        data: Data(#"{"receipt_id":"receipt-1","client_request_id":"request-1","request_digest":"\#(digest)","duplicate":false,"thread_id":"thread-a","unexpected":true}"#.utf8)
    ) == .protocolError(code: "invalid_interaction_receipt"))

    let resume = try AIRequestIntegrity.interactionResume(
        token: "AbCdEf0123456789AbCdEf0123456789",
        action: .answered,
        text: "staging",
        threadID: "thread-a",
        context: AITurnContext(
            summary: "s",
            recentMessages: [AIContextMessage(role: "user", content: "hello")]
        )
    )
    #expect(UUID(uuidString: resume.clientRequestID) != nil)
    #expect(resume.requestDigest
        == "7f469e29b85f66a7b2d0f266a9060a52f1226f3a427ba994019db83b8b97af9a")
}

/// The report draft digest rule (Task 11): SHA-256 of
/// the exact UTF-8 bytes, no normalization — verified against a fixture
/// computed independently (`shasum -a 256`), including a multibyte/
/// multilingual draft, since a byte-exact rule is exactly where a naive
/// Unicode-aware implementation could silently diverge from the backend.
@Test func contentDigestHashesTheExactUTF8BytesWithNoNormalization() {
    #expect(AIRequestIntegrity.contentDigest("")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".prefix(64))
    #expect(AIRequestIntegrity.contentDigest("báo cáo lỗi 日本語")
        == "bc783842a3e62e945cf40d96df42eb97cdf0ea2e9357a3f117f36fd85e0bd484".prefix(64))
    // A trailing space is a different report.
    #expect(AIRequestIntegrity.contentDigest("report")
        != AIRequestIntegrity.contentDigest("report "))
}

// MARK: - Report submission proof (Task 12, backend `report_submission_proof`)

private let submissionProofThreadID = "thread-abc"
private let submissionProofCallID = "report-1"
private let submissionProofDraft =
    "Opening the history panel shows an empty list after restart."
private let submissionProofSummary =
    "The user reported that the history panel is empty after restart."
private let submissionProofToken = "rr1.kid.\(String(repeating: "A", count: 64))"

private func submissionProofFixture(
    summary: String?,
    threadID: String = submissionProofThreadID,
    callID: String = submissionProofCallID,
    draft: String = submissionProofDraft,
    token: String = submissionProofToken
) -> AIReportSubmission {
    AIReportSubmission(
        threadID: threadID, callID: callID, reportReadyToken: token,
        draft: draft, conversationSummary: summary,
        clientRequestID: "client-request-000001"
    )
}

/// The highest-risk value in the whole flow: the server recomputes this from
/// the same inputs and refuses any mismatch, so an implementation that reads
/// correctly but joins differently would fail *every* real submission with an
/// opaque error.
///
/// The two expected digests are therefore NOT derived from this
/// implementation. They were computed independently as
/// `printf '%s\000%s\000…' … | shasum -a 256` over the backend's field order,
/// and cross-checked against a separate Python `hashlib` run:
///
///     sha256("berrydb.report-submit/v1\0thread-abc\0report-1\0"
///            "<sha256(draft)>\0" "0" "\0" "" "\0" "<token>")
///       = a67fec8a…
///     …with "1" and sha256(summary) in place of "0" and ""
///       = b696dab9…
@Test func reportSubmissionDigestMatchesTheBackendsNULJoinedProof() {
    #expect(AIRequestIntegrity.contentDigest(submissionProofDraft)
        == "5d0be0c09b8d29c1b1fb90036616c6bd41ac308537e271e39db415913019982c")
    #expect(AIRequestIntegrity.contentDigest(submissionProofSummary)
        == "8765d72a5e77465f64b8450a0fe4f0159b8955e99c61b8b732af3e663a374c71")

    #expect(
        AIRequestIntegrity.reportSubmissionDigest(submissionProofFixture(summary: nil))
            == "a67fec8aba41f1ada0cae7ee5b3f637c480d0b9d147e0b84e1dae423da4b4c14",
        "the no-context proof must hash \"0\" and an empty context slot"
    )
    #expect(
        AIRequestIntegrity.reportSubmissionDigest(
            submissionProofFixture(summary: submissionProofSummary)
        ) == "b696dab9d5405fb26929b99953753b9de7875cea3c2451cc3cd5e0107ef751b5",
        "the with-context proof must hash \"1\" and sha256(conversation_summary)"
    )
}

/// Every input is bound: swapping any one of them has to change the proof,
/// or the field it stands for could be altered in transit undetected. The
/// separator matters too — a plain concatenation would let a byte moved
/// across a field boundary hash identically.
@Test func reportSubmissionDigestBindsEveryFieldAndItsBoundaries() {
    let base = AIRequestIntegrity.reportSubmissionDigest(
        submissionProofFixture(summary: submissionProofSummary)
    )
    let variants: [(String, AIReportSubmission)] = [
        ("thread", submissionProofFixture(summary: submissionProofSummary, threadID: "thread-abd")),
        ("call", submissionProofFixture(summary: submissionProofSummary, callID: "report-2")),
        ("draft", submissionProofFixture(summary: submissionProofSummary, draft: "\(submissionProofDraft) ")),
        ("summary", submissionProofFixture(summary: "\(submissionProofSummary) ")),
        ("consent", submissionProofFixture(summary: nil)),
        ("token", submissionProofFixture(summary: submissionProofSummary, token: "rr1.kid.\(String(repeating: "B", count: 64))")),
    ]
    for (field, variant) in variants {
        #expect(
            AIRequestIntegrity.reportSubmissionDigest(variant) != base,
            "changing the \(field) must change the submission proof"
        )
    }
    // Field boundaries: moving a character across the thread/call boundary
    // keeps the concatenation identical but must not keep the digest.
    #expect(
        AIRequestIntegrity.reportSubmissionDigest(
            submissionProofFixture(summary: nil, threadID: "thread-ab", callID: "creport-1")
        ) != AIRequestIntegrity.reportSubmissionDigest(submissionProofFixture(summary: nil))
    )
}

/// `include_context` is not a field a caller can set: it is exactly
/// "a summary is attached", mirroring the backend's own refusal when the two
/// disagree. Without this, a request could claim consent it had no scope for.
@Test func reportSubmissionIncludeContextIsDerivedFromTheSummaryItself() {
    #expect(submissionProofFixture(summary: submissionProofSummary).includeContext)
    #expect(!submissionProofFixture(summary: nil).includeContext)
    #expect(submissionProofFixture(summary: "").includeContext,
            "an empty-but-present summary is still an attached scope, not an absent one")
}

@Test func decodesDeltaCompleteAndError() {
    #expect(AIEvent.decode(event: "message.delta", data: Data(#"{"text":"hello"}"#.utf8)) == .delta("hello"))
    #expect(AIEvent.decode(event: "plan.delta", data: Data(#"{"text":"planning"}"#.utf8)) == .plan("planning"))
    #expect(AIEvent.decode(event: "message.complete", data: Data(#"{"usage":{"total_tokens":42}}"#.utf8)) == .complete(totalTokens: 42))
    #expect(AIEvent.decode(event: "error", data: Data(#"{"code":"quota_exceeded","message":"over limit"}"#.utf8)) == .error(code: "quota_exceeded", message: "over limit"))
}

/// Task 13: the backend now sends round/segment_id/provisional additively
/// on every `message.delta`. `provisional` is unconditionally `true` on
/// every round (even the final one), so decode must carry it through
/// as-is rather than trying to interpret it.
@Test func decodesDeltaRoundBoundaryMetadata() {
    #expect(AIEvent.decode(
        event: "message.delta",
        data: Data(#"{"text":"hi","round":2,"segment_id":"thr-abc-r2","provisional":true}"#.utf8)
    ) == .delta(AIEventDelta(text: "hi", round: 2, segmentID: "thr-abc-r2", provisional: true)))
}

@Test func unknownEventDecodesToNil() {
    #expect(AIEvent.decode(event: "message.future", data: Data("{}".utf8)) == nil)
}

@Test func decodesCapabilityAcceptanceAndAuthoritativeToolMetadata() {
    let acceptance = AIEvent.decode(
        event: "capabilities.accepted",
        data: Data(#"{"protocol_version":1,"registry_version":"r1","schema_version":"s1","capability_set_digest":"abc","accepted":[{"id":"get_schema","tool_version":"1.0.0","schema_version":"1","handler_version":"1.0.0","risk":"read","approval":"never"}],"rejected":[]}"#.utf8)
    )
    #expect(acceptance == .capabilitiesAccepted(AICapabilityAcceptance(
        protocolVersion: 1, registryVersion: "r1", schemaVersion: "s1",
        capabilitySetDigest: "abc",
        accepted: [.init(
            id: "get_schema", toolVersion: "1.0.0", schemaVersion: "1",
            handlerVersion: "1.0.0", risk: "read", approval: "never"
        )],
        rejected: []
    )))

    let call = AIEvent.decode(
        event: "tool.call",
        data: Data(#"{"call_id":"c","dispatch_nonce":"AbCdEf0123456789AbCdEf0123456789","name":"get_schema","args":{},"registry_version":"r1","tool_version":"1.0.0","schema_version":"1","risk":"read","approval":"never","capability_set_digest":"digest","thread_id":"thread-a"}"#.utf8)
    )
    #expect(call == .toolCall(AIToolCall(
        id: "c", name: "get_schema", args: [:],
        dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
        registryVersion: "r1", toolVersion: "1.0.0",
        schemaVersion: "1", risk: "read", approval: "never",
        capabilitySetDigest: "digest"
    )))
}

@MainActor
private final class CapabilityExecutor: AIToolExecutor {
    let toolSpecs: [AIToolSpec]
    private(set) var calls: [AIToolCall] = []
    private(set) var proposedSQL: [String] = []
    var generation = "capability-executor:0"
    var capabilityGeneration: String { generation }

    init(toolSpecs: [AIToolSpec]) {
        self.toolSpecs = toolSpecs
    }

    func execute(_ call: AIToolCall) async -> ToolOutcome {
        calls.append(call)
        return .ok("{}")
    }

    func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return await execute(call)
    }

    func streamPropose(_ partialSQL: String) {
        proposedSQL.append(partialSQL)
    }
}

@MainActor
private final class LegacyOnlyExecutor: AIToolExecutor {
    private(set) var calls = 0
    func execute(_ call: AIToolCall) async -> ToolOutcome {
        calls += 1
        return .ok("{}")
    }
}

@MainActor
@Test func localCapabilityHostSendsOnlyStaticIDsAndStrictDynamicDescriptors() throws {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "run_sql", description: "client text", parametersJSON: #"{"type":"object","properties":{"sql":{"type":"string"}}}"#),
        AIToolSpec(name: "mcp:catalog:lookup", description: "Lookup", parametersJSON: #"{"type":"object"}"#),
    ])
    let host = LocalCapabilityHost(executor: executor)
    let advert = try host.beginTurn(with: executor.toolSpecs)

    #expect(advert.handlers == [.init(id: "run_sql", handlerVersion: "1.0.0")])
    #expect(advert.dynamicTools.map(\.name) == ["mcp:catalog:lookup"])
}

@MainActor
@Test func localCapabilityHostRejectsMetadataMismatchBeforeDispatch() async throws {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "get_schema", description: "Schema", parametersJSON: #"{"type":"object"}"#),
    ])
    let host = LocalCapabilityHost(executor: executor)
    _ = try host.beginTurn(with: executor.toolSpecs)
    try host.setTransportMode(.negotiated)
    try host.accept(.init(
        protocolVersion: 1, registryVersion: "r1", schemaVersion: "s1",
        capabilitySetDigest: "digest",
        accepted: [.init(
            id: "get_schema", toolVersion: "1.0.0", schemaVersion: "1",
            handlerVersion: "1.0.0", risk: "read", approval: "never"
        )],
        rejected: []
    ))
    let outcome = await host.execute(.init(
        id: "c", name: "get_schema", args: [:],
        registryVersion: "r1", toolVersion: "1.0.0",
        schemaVersion: "1", risk: "read", approval: "never",
        capabilitySetDigest: "different-digest"
    ))
    #expect(outcome.status == "error")
    #expect(executor.calls.isEmpty)
}

@MainActor
@Test func streamProposalRequiresExactAcceptedCapabilityAndActiveLease() throws {
    let specs = [
        AIToolSpec(
            name: "propose_sql", description: "Propose",
            parametersJSON: #"{"type":"object"}"#
        ),
        AIToolSpec(
            name: "get_schema", description: "Schema",
            parametersJSON: #"{"type":"object"}"#
        ),
    ]
    let executor = CapabilityExecutor(toolSpecs: specs)
    let host = LocalCapabilityHost(executor: executor)
    _ = try host.beginTurn(with: specs)
    try host.setTransportMode(.negotiated)
    try host.accept(.init(
        protocolVersion: 1, registryVersion: "r1", schemaVersion: "s1",
        capabilitySetDigest: "digest",
        accepted: [.init(
            id: "get_schema", toolVersion: "1.0.0", schemaVersion: "1",
            handlerVersion: "1.0.0", risk: "read", approval: "never"
        )],
        rejected: [.init(id: "propose_sql", code: "disabled")]
    ))

    host.streamPropose("SELECT rejected", for: "propose_sql")
    #expect(executor.proposedSQL.isEmpty)

    _ = try host.beginTurn(with: specs)
    try host.setTransportMode(.negotiated)
    try host.accept(.init(
        protocolVersion: 1, registryVersion: "r1", schemaVersion: "s1",
        capabilitySetDigest: "digest",
        accepted: specs.map {
            .init(
                id: $0.name, toolVersion: "1.0.0", schemaVersion: "1",
                handlerVersion: "1.0.0", risk: "read", approval: "never"
            )
        },
        rejected: []
    ))
    host.streamPropose("SELECT accepted", for: "propose_sql")
    #expect(executor.proposedSQL == ["SELECT accepted"])

    executor.generation = "capability-executor:changed"
    host.streamPropose("SELECT stale", for: "propose_sql")
    #expect(executor.proposedSQL == ["SELECT accepted"])
}

/// Reported live: the app crashed mid-conversation ("freed pointer was not
/// the last allocation", a swift_task_dealloc fatal error) in
/// `EditorTabView.warmReferencedColumns`. Root cause: `AISession` dispatched
/// every `.toolArgDelta`'s partial SQL straight to `streamPropose`, which
/// writes `document.text` on the active editor tab — dozens of times a
/// second at peak. Every one of those writes fires `EditorTabView`'s
/// `.onChange(of: document.text)`, which cancels and recreates its own
/// `warmReferencedColumns` Task; recreating a Task that fast hit a Swift
/// Concurrency runtime crash.
///
/// `AISession` now throttles dispatch to at most one per ~100ms, always the
/// latest scanned value, so four deltas arriving faster than that collapse
/// into a single, correctly-assembled call instead of four. This also pins
/// correctness of the incremental scan across a value split over several
/// fragments, including one that splits mid-escape-sequence (`\` and `n`
/// arrive in separate deltas) — the scan runs on every delta regardless of
/// throttling, so a naive "just remember an offset" fix would still get the
/// final value wrong even though only one call reaches the mock.
@MainActor
@Test func toolArgDeltaCoalescesRapidDeltasIntoOneCorrectDispatch() async throws {
    let transport = MockTransport(
        before: [
            .toolArgDelta(name: "propose_sql", argDelta: "{\"query\":\"SELECT "),
            .toolArgDelta(name: "propose_sql", argDelta: "1\\"),
            .toolArgDelta(name: "propose_sql", argDelta: "n2"),
            .toolArgDelta(name: "propose_sql", argDelta: "\"}"),
            .toolCall(AIToolCall(
                id: "c0", name: "propose_sql", args: ["query": "SELECT 1\n2"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [.delta("Done."), .complete(totalTokens: 1)]
    )
    let executor = CapabilityExecutor(toolSpecs: [])
    let session = AISession(
        transport: transport, executor: executor,
        dialect: "postgres", schemaDigest: "abc", store: makeStore()
    )

    await session.send("propose a query")

    #expect(
        executor.proposedSQL == ["SELECT 1\n2"],
        "four deltas arriving faster than the throttle window must coalesce into one dispatch of the correctly-assembled value, not one dispatch per delta"
    )
}

@MainActor
@Test func localCapabilityHostKeepsExplicitOldServerFallback() async throws {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "get_schema", description: "Schema", parametersJSON: #"{"type":"object"}"#),
    ])
    let host = LocalCapabilityHost(executor: executor)
    _ = try host.beginTurn(with: executor.toolSpecs)
    try host.setTransportMode(.legacy)

    let outcome = await host.execute(.init(id: "legacy", name: "get_schema", args: [:]))
    #expect(outcome.status == "ok")
    #expect(executor.calls.count == 1)
}

@MainActor
@Test func metadataToolCallWithoutAcceptanceFailsClosed() async throws {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "get_schema", description: "Schema", parametersJSON: #"{"type":"object"}"#),
    ])
    let host = LocalCapabilityHost(executor: executor)
    _ = try host.beginTurn(with: executor.toolSpecs)
    try host.setTransportMode(.negotiated)

    let outcome = await host.execute(.init(
        id: "c", name: "get_schema", args: [:],
        registryVersion: "r1", toolVersion: "1.0.0",
        schemaVersion: "1", risk: "metadata_read", approval: "none",
        capabilitySetDigest: "digest"
    ))
    #expect(outcome.status == "error")
    #expect(executor.calls.isEmpty)
}

@MainActor
@Test func capabilitySnapshotRejectsMidTurnHandlerReplacementAndConnectionSwitch() async throws {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "get_schema", description: "Schema", parametersJSON: #"{"type":"object"}"#),
    ])
    let host = LocalCapabilityHost(executor: executor)
    _ = try host.beginTurn(with: executor.toolSpecs)
    try host.setTransportMode(.legacy)

    executor.generation = "capability-executor:1"
    let replaced = await host.execute(.init(id: "c1", name: "get_schema", args: [:]))
    #expect(replaced.status == "error")

    _ = try host.beginTurn(with: executor.toolSpecs)
    try host.setTransportMode(.legacy)
    host.invalidate()
    let switched = await host.execute(.init(id: "c2", name: "get_schema", args: [:]))
    #expect(switched.status == "error")
    #expect(executor.calls.isEmpty)
}

@MainActor
@Test func defaultExecutorLeaseFailsClosedBeforeDispatch() async {
    let executor = LegacyOnlyExecutor()
    let lease = AIExecutionLease(validate: { true })

    let outcome = await executor.execute(
        .init(id: "c", name: "anything", args: [:]),
        lease: lease
    )

    #expect(outcome.status == "denied")
    #expect(executor.calls == 0)
}

// MARK: - Session orchestration

/// A deterministic suspension point for proving UI-facing session state is
/// published before an async transport preflight completes.
private actor AsyncGate {
    private var hasEntered = false
    private var isReleased = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        hasEntered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilEntered() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// Scripts one paused agent round: yields events, waits for the tool result,
/// then yields the rest — mirroring the gateway's SSE pause on `tool.call`.
private final class MockTransport: AITransport, @unchecked Sendable {
    let beforeToolResult: [AIEvent]
    let afterToolResult: [AIEvent]
    private var continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation?
    /// The thread id `postMessage` was actually called with (Q17: now a local
    /// UUID minted by `AISession.ensureThread`, not transport-issued) — events
    /// echo it back, same as the real gateway echoing whatever `thread_id`
    /// came in on the request.
    private var activeThreadID = "thr-mock"
 // `AITransport` conformance methods are plain (non-actor-isolated)
    // async funcs — calling one from `@MainActor`-isolated `AISession` code
    // doesn't pin its body to the MainActor, and a background fold Task
    // (`AISession.applySummaryFold`, fire-and-forget alongside the main turn)
    // can genuinely call back into the SAME `MockTransport` instance while
    // another call is already in flight. Every mutable property below used
    // to be a bare `var` with no synchronization — undefined behavior under
    // concurrent mutation, and the likely source of a `swift test` full-suite
    // crash (`Index out of range` in `ContiguousArrayBuffer`) that a smaller
    // test selection never reproduced. One lock, guarding all of it, mirrors
    // the `embeddingLock`/`_embedInputs` pattern already used for `embed(_:)`
    // below — that one was already understood to need it; this generalizes
    // it to every other piece of shared mutable state on this class.
    private let stateLock = NSLock()
    private var _postedResults: [
        (
            callID: String,
            dispatchNonce: String,
            capabilitySetDigest: String,
            status: String
        )
    ] = []
    var postedResults: [(callID: String, dispatchNonce: String, capabilitySetDigest: String, status: String)] {
        stateLock.withLock { _postedResults }
    }
    private var _postedResultJSONs: [String?] = []
    var postedResultJSONs: [String?] { stateLock.withLock { _postedResultJSONs } }
    private var _receivedTools: [AIToolSpec] = []
    var receivedTools: [AIToolSpec] { stateLock.withLock { _receivedTools } }
    private var _receivedCapabilities: AICapabilityAdvertisement?
    var receivedCapabilities: AICapabilityAdvertisement? { stateLock.withLock { _receivedCapabilities } }
    private var _receivedContext: AITurnContext?
    var receivedContext: AITurnContext? { stateLock.withLock { _receivedContext } }
    private var _loadThreadCalls: [String] = []
    var loadThreadCalls: [String] { stateLock.withLock { _loadThreadCalls } }
    private var _reportSubmissions: [AIReportSubmission] = []
    var reportSubmissions: [AIReportSubmission] { stateLock.withLock { _reportSubmissions } }
    /// Thrown (and removed) by the next `submitReport`, so a scripted
    /// failure-then-success pair exercises the idempotent retry.
    var reportSubmissionErrors: [Error] = []
    var reportSubmissionReceipts: [AIReportReceipt] = []
    private let embeddingLock = NSLock()
    private var _embedInputs: [String] = []
    var embedReply: [Float] = []
    private var _summarizeCalls: [(previous: String, messages: [AIContextMessage])] = []
    var summarizeCalls: [(previous: String, messages: [AIContextMessage])] {
        stateLock.withLock { _summarizeCalls }
    }
    var summarizeReply = ""
    var loadThreadReply: [AITurn] = []
    var rankReply: [String] = []
    var rankGate: AsyncGate?
    private var _rankCallCount = 0
    var rankCallCount: Int { stateLock.withLock { _rankCallCount } }
    var summarizeGate: AsyncGate?
    var responseGate: AsyncGate?
    var responseError: Error?
    var resumePreflightError: Error?
    var resumeError: Error?
    var toolResultErrors: [Error] = []
    private var _toolResultAttempts = 0
    var toolResultAttempts: Int { stateLock.withLock { _toolResultAttempts } }
    var consumeToolResultBeforeError = false
    private var _serverConsumedToolResults = 0
    var serverConsumedToolResults: Int { stateLock.withLock { _serverConsumedToolResults } }
    /// Extra events tagged with a (usually sub-agent) thread id, yielded after `before`.
    var childEvents: [(threadID: String, event: AIEvent)] = []
    var childEventsBeforeRoot = false
    var resumeEvents: [AIEvent] = []
    var omitResumeReceipt = false
    private var _messageRequests: [
        (text: String, resume: AIInteractionResume?, context: AITurnContext?)
    ] = []
    var messageRequests: [(text: String, resume: AIInteractionResume?, context: AITurnContext?)] {
        stateLock.withLock { _messageRequests }
    }

    init(before: [AIEvent], after: [AIEvent]) {
        beforeToolResult = before
        afterToolResult = after
    }

    func rankSkills(skills: [SkillRankInput], query: String) async -> [String] {
        stateLock.withLock { _rankCallCount += 1 }
        if let rankGate { await rankGate.enterAndWait() }
        return rankReply
    }

    func createThread(dialect: String, schemaDigest: String) async throws -> String {
        "thr-mock"
    }

    func postMessage(threadID: String, text: String, tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(threadID: threadID, text: text, tools: tools, context: nil, dialect: "")
    }

    func postMessage(threadID: String, text: String, tools: [AIToolSpec], context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(
            threadID: threadID, text: text, tools: tools, capabilities: nil,
            context: context, dialect: dialect, resume: nil
        )
    }

    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(
            threadID: threadID, text: text, tools: tools,
            capabilities: capabilities, context: context, dialect: dialect,
            resume: nil
        )
    }

    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String, resume: AIInteractionResume?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        stateLock.withLock {
            _receivedTools = tools
            _receivedCapabilities = capabilities
            _receivedContext = context
            _messageRequests.append((text, resume, context))
        }
        activeThreadID = threadID
        let isResumeRequest = resume != nil
        if isResumeRequest, let resumePreflightError {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: resumePreflightError)
            }
        }
        var preparedEvents = resume == nil ? beforeToolResult : resumeEvents
        if let resume, !omitResumeReceipt {
            preparedEvents.insert(.interactionReceipt(AIInteractionReceipt(
                receiptID: "receipt-\(resume.clientRequestID)",
                clientRequestID: resume.clientRequestID,
                requestDigest: resume.requestDigest,
                duplicate: false,
                threadID: threadID
            )), at: 0)
        }
        let initialEvents = preparedEvents
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
            if let responseGate = self.responseGate {
                Task {
                    await responseGate.enterAndWait()
                    self.yieldInitialEvents(
                        initialEvents, to: continuation, threadID: threadID,
                        isResumeRequest: isResumeRequest
                    )
                }
                return
            }
            self.yieldInitialEvents(
                initialEvents, to: continuation, threadID: threadID,
                isResumeRequest: isResumeRequest
            )
        }
    }

    private func yieldInitialEvents(
        _ initialEvents: [AIEvent],
        to continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation,
        threadID: String,
        isResumeRequest: Bool
    ) {
        if childEventsBeforeRoot {
            for child in childEvents {
                continuation.yield(AIStreamEvent(
                    threadID: child.threadID,
                    event: normalizedMockInteractionEvent(
                        child.event, rootThreadID: threadID,
                        eventThreadID: child.threadID
                    )
                ))
            }
        }
        for event in initialEvents {
            continuation.yield(AIStreamEvent(
                threadID: threadID,
                event: normalizedMockInteractionEvent(
                    event, rootThreadID: threadID, eventThreadID: threadID
                )
            ))
        }
        if !childEventsBeforeRoot {
            for child in childEvents {
                continuation.yield(AIStreamEvent(
                    threadID: child.threadID,
                    event: normalizedMockInteractionEvent(
                        child.event, rootThreadID: threadID,
                        eventThreadID: child.threadID
                    )
                ))
            }
        }
        if let responseError {
            continuation.finish(throwing: responseError)
            return
        }
        if isResumeRequest, let resumeError {
            continuation.finish(throwing: resumeError)
            return
        }
        // A tool call pauses the stream until postToolResult resumes it;
        // otherwise the round is done, so close now (as the gateway does).
        let hasToolCall = initialEvents.contains { if case .toolCall = $0 { true } else { false } }
        if !hasToolCall { continuation.finish() }
    }

    func postToolResult(
        threadID: String, callID: String, dispatchNonce: String,
        capabilitySetDigest: String, status: String, resultJSON: String?
    ) async throws {
        stateLock.withLock { _toolResultAttempts += 1 }
        if !toolResultErrors.isEmpty {
            if consumeToolResultBeforeError {
                stateLock.withLock { _serverConsumedToolResults += 1 }
            }
            throw toolResultErrors.removeFirst()
        }
        stateLock.withLock {
            _postedResults.append((callID, dispatchNonce, capabilitySetDigest, status))
            _postedResultJSONs.append(resultJSON)
        }
        for event in afterToolResult { continuation?.yield(AIStreamEvent(threadID: activeThreadID, event: event)) }
        continuation?.finish()
    }

    private var _listThreadsCalls = 0
    var listThreadsCalls: Int { stateLock.withLock { _listThreadsCalls } }
    private var _deleteThreadCalls: [String] = []
    var deleteThreadCalls: [String] { stateLock.withLock { _deleteThreadCalls } }

    func listThreads(dialect: String? = nil, limit: Int = 50, beforeUpdatedAt: Int? = nil, beforeID: String? = nil) async -> [AIThreadSummary] {
        stateLock.withLock { _listThreadsCalls += 1 }
        return []
    }

    func loadThread(id: String) async throws -> [AITurn] {
        stateLock.withLock { _loadThreadCalls.append(id) }
        return loadThreadReply
    }

    func submitReport(_ submission: AIReportSubmission) async throws -> AIReportReceipt {
        stateLock.withLock { _reportSubmissions.append(submission) }
        if !reportSubmissionErrors.isEmpty {
            throw reportSubmissionErrors.removeFirst()
        }
        if !reportSubmissionReceipts.isEmpty {
            return reportSubmissionReceipts.removeFirst()
        }
        return AIReportReceipt(
            submissionID: "sub-\(submission.clientRequestID)", duplicate: false
        )
    }

    func embed(text: String) async -> [Float] {
        embeddingLock.withLock {
            _embedInputs.append(text)
            return embedReply
        }
    }

    func embedInputs() -> [String] {
        embeddingLock.withLock { _embedInputs }
    }

    func summarize(previous: String, messages: [AIContextMessage]) async -> String {
        stateLock.withLock { _summarizeCalls.append((previous, messages)) }
        if let summarizeGate { await summarizeGate.enterAndWait() }
        return summarizeReply
    }

    func deleteThread(id: String) async throws {
        stateLock.withLock { _deleteThreadCalls.append(id) }
    }
}

/// Breaks the chicken-and-egg between a session and an executor hook that needs
/// to read it.
@MainActor
private final class SessionBox {
    weak var session: AISession?
}

private struct SchemaExecutor: AIToolExecutor {
    let outcome: ToolOutcome
    var specs: [AIToolSpec] = []
    /// Called while the tool is executing, so a test can observe transcript state
    /// at exactly that moment — which is what the panel is showing mid-action.
    /// No-op by default, so every other test is unaffected.
    var onExecute: (@MainActor () -> Void)?

    func execute(_ call: AIToolCall) async -> ToolOutcome {
        if let onExecute { await MainActor.run { onExecute() } }
        return outcome
    }
    var toolSpecs: [AIToolSpec] { specs }
}

private final class SessionScriptedLocal: LocalCompletionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]

    init(_ replies: [String]) {
        self.replies = replies
    }

    static func isAvailable() -> Bool { true }

    func complete(prompt: String) async throws -> String {
        lock.withLock {
            replies.isEmpty ? "done" : replies.removeFirst()
        }
    }
}

@MainActor
private final class InvalidatingCapabilityExecutor: AIToolExecutor {
    let toolSpecs = [
        AIToolSpec(
            name: "get_schema", description: "Schema",
            parametersJSON: #"{"type":"object"}"#
        ),
    ]
    var capabilityGeneration = "local:0"
    private(set) var committedCalls = 0

    func execute(_ call: AIToolCall) async -> ToolOutcome {
        .denied
    }

    func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        capabilityGeneration = "local:1"
        guard lease.isValid else { return .denied }
        committedCalls += 1
        return .ok("{}")
    }
}

private struct LegacyResumeDroppingTransport: AITransport {
    func createThread(dialect: String, schemaDigest: String) async throws -> String { "unused" }
    func postMessage(
        threadID: String, text: String, tools: [AIToolSpec]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func postToolResult(
        threadID: String, callID: String, dispatchNonce: String,
        capabilitySetDigest: String, status: String, resultJSON: String?
    ) async throws {}
    func rankSkills(skills: [SkillRankInput], query: String) async -> [String] { [] }
}

@Test func transportDefaultFailsExplicitlyInsteadOfDroppingResume() async {
    let transport = LegacyResumeDroppingTransport()
    let stream = transport.postMessage(
        threadID: "t", text: "", tools: [], capabilities: nil,
        context: nil, dialect: "postgres",
        resume: AIInteractionResume(
            token: "AbCdEf0123456789AbCdEf0123456789", action: .declined
        )
    )
    do {
        for try await _ in stream {}
        Issue.record("Expected an explicit unsupported-resume error")
    } catch {
        #expect(error as? AITransportError == .interactionResumeUnsupported)
    }
}

/// An executor whose `execute(_:)` suspends until the test explicitly resumes
/// it — lets a test deterministically observe a turn "still in flight"
/// (isStreaming == true) without racing against real async scheduling.
@MainActor
private final class PausableExecutor: AIToolExecutor {
    let outcome: ToolOutcome
    var toolSpecs: [AIToolSpec] { [] }
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var shouldResumeImmediately = false

    init(outcome: ToolOutcome) { self.outcome = outcome }

    func execute(_ call: AIToolCall) async -> ToolOutcome {
        hasEntered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if !shouldResumeImmediately {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                resumeContinuation = cont
            }
        }
        return outcome
    }

    /// Suspends until `execute` has actually been entered (i.e. the turn has
    /// reached the paused tool call and `isStreaming` is guaranteed true).
    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enteredContinuation = cont
        }
    }

    func resume() {
        shouldResumeImmediately = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

@MainActor
@Test func runsToolCallInlineAndResumesStream() async {
    let transport = MockTransport(
        before: [.delta("Let me look. "), .toolCall(AIToolCall(
            id: "thr-mock-c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("You have one table."), .complete(totalTokens: 42)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.currentThreadID != nil)
    #expect(transport.postedResults.count == 1)
    #expect(transport.postedResults.first?.callID == "thr-mock-c0")
    #expect(
        transport.postedResults.first?.dispatchNonce
            == "AbCdEf0123456789AbCdEf0123456789"
    )
    #expect(transport.postedResults.first?.capabilitySetDigest == "digest")
    #expect(transport.postedResults.first?.status == "ok")
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    #expect(session.transcript.last?.text == "You have one table.")
    #expect(session.totalTokens == 42)
    #expect(session.isStreaming == false)
    #expect(session.lastError == nil)
}

/// a tool result carrying artifact_id/artifact_version
/// ('s create_debug_tab/run_sql/etc.) attaches an ArtifactRef to the live
/// turn, and that ref survives persistTurn + a fresh openThread reload from the
/// same BerryStore — the bubble's link must still resolve after a history
/// reload/app restart, not just within the live session.
@MainActor
@Test func toolCallArtifactRefSurvivesPersistAndReload() async throws {
    let store = makeStore()
    let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
    try store.saveArtifact(artifact)
    try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")

    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "thr-mock-c0", name: "create_debug_tab", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("Created it."), .complete(totalTokens: 10)]
    )
    let outcome = ToolOutcome.ok(
        #"{"created":true,"artifact_id":"\#(artifact.id.uuidString)","artifact_version":1}"#
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: outcome),
        dialect: "postgres",
        schemaDigest: "abc",
        store: store
    )

    await session.send("write a query")

    let liveRef = try #require(session.transcript.last?.artifactRefs.first)
    #expect(liveRef.artifactID == artifact.id)
    #expect(liveRef.versionNumber == 1)
    #expect(liveRef.title == "Top customers")
    #expect(liveRef.kind == .editorTab)

    let threadID = try #require(session.currentThreadID)
    await session.openThread(threadID)

    #expect(session.transcript.last?.artifactRefs == [liveRef])
}

/// the working block's sub-block shows the action that ran, and
/// the user expects to click it to see what that action produced. The action
/// badge was pure `Label` text with nothing behind it, because `AIWorkStep`
/// carried only narration + tool names — no artifact identity, so there was
/// nothing for a tap to open even if one were wired up.
///
/// The artifact a round's tool produced must therefore land on that round's own
/// step, not only on the turn-level `artifactRefs` used by the chips under the
/// bubble.
@MainActor
@Test func aRoundsArtifactIsAttachedToThatRoundsWorkStep() async throws {
    let store = makeStore()
    let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Ad-hoc run")
    try store.saveArtifact(artifact)
    try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")

    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Creating a debug tab. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "create_debug_tab", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(
            #"{"created":true,"artifact_id":"\#(artifact.id.uuidString)","artifact_version":1}"#
        )),
        dialect: "postgres",
        schemaDigest: "abc",
        store: store
    )

    await session.send("write a debug query")

    let step = try #require(session.transcript.last?.workSteps.first)
    #expect(step.toolNames == ["create_debug_tab"])
    let ref = try #require(step.artifactRefs.first)
    #expect(ref.artifactID == artifact.id)
    #expect(ref.title == "Ad-hoc run")
    #expect(ref.kind == .editorTab)
}

/// Each action expands to the inputs it ran with, the
/// result it produced, and a Completed/Running status. Tools that create no
/// artifact ("Reading schema", "Analyzing queries") therefore need their own
/// detail captured from the call's args and the outcome — otherwise their badge
/// has nothing behind it and clicking does nothing.
@MainActor
@Test func aRoundsToolCallsAreRecordedAsActionsWithArgsAndStatus() async throws {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Reading the schema. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: ["tables": "users"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["users"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    #expect(action.name == "get_schema")
    #expect(action.status == .completed)
    // `tables` is this tool's payload key, so it appears in the full-width
    // preview row rather than as an `inputs` bullet — see
    // `theArgumentShownAsThePayloadIsNotRepeatedInTheInputs`.
    #expect(action.payload == "users", "the call's arg is still shown, as the payload")
    #expect(!action.outputs.isEmpty, "the outcome must yield something to show")
}

/// Narration arrives on its own `progress.note` channel now (berrydb-api's
/// `note_progress` tool), so it must land in the round's `AIWorkStep` and never
/// in `AITurn.text`. That separation is what lets the answer stream: `text` is
/// unambiguously the answer.
@MainActor
@Test func aProgressNoteBecomesTheRoundsNarrationAndNeverBubbleText() async throws {
    let transport = MockTransport(
        before: [
            .progressNote("Reading the schema first."),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "You have 23 tables.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(
        session.transcript.last?.text == "You have 23 tables.",
        "the bubble holds only the answer — no narration leaked into it"
    )
    let step = try #require(session.transcript.last?.workSteps.first)
    #expect(step.narration == "Reading the schema first.")
}

/// Reported after `note_progress` shipped: the working block stopped separating
/// its steps and showed one merged blob.
///
/// The round boundary was only ever detected in `.delta`, because narration used
/// to arrive there — so a round ending was always marked by the next round's
/// first delta. With narration moved to `progress.note`, a typical tool-calling
/// round emits NO `message.delta` at all: note, tool.call, note, tool.call, and
/// the answer only in the final round. Nothing flushed the intermediate rounds,
/// so every note and tool piled into a single `AIWorkStep`.
@MainActor
@Test func eachNarratedToolRoundBecomesItsOwnWorkStep() async throws {
    let transport = MockTransport(
        before: [
            .progressNote("Reading the schema."),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .progressNote("Counting rows in the users table."),
            .toolCall(AIToolCall(
                id: "c1", name: "run_sql", args: ["sql": "SELECT count(*) FROM users"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
            .delta("There are 1,240 rows."),
            .complete(totalTokens: 5),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("how many users?")

    let steps = try #require(session.transcript.last?.workSteps)
    #expect(steps.count == 2, "two narrated tool rounds are two sub-blocks, not one merged step")
    #expect(steps.first?.narration == "Reading the schema.")
    #expect(steps.first?.toolNames == ["get_schema"])
    #expect(steps.last?.narration == "Counting rows in the users table.")
    #expect(steps.last?.toolNames == ["run_sql"])
    #expect(session.transcript.last?.text == "There are 1,240 rows.")
}

/// The flow is: state the action, THEN perform it. The user should
/// read "Reading the schema." while the schema is being read — not after.
///
/// Steps were only appended once their round had ended, so narration appeared
/// retroactively: the working block stayed empty through the whole tool call and
/// the description showed up only after the result was already in. A note must
/// create its step immediately, and the tool must attach to that existing step.
/// Observed from inside the tool call: `SchemaExecutor`'s `onExecute` runs while
/// the action is in flight, so what it sees is what the panel shows at that
/// moment. No production test hook — the executor is already injected.
@MainActor
@Test func narrationAppearsBeforeItsActionRuns() async throws {
    var narrationDuringCall: String?
    let transport = MockTransport(
        before: [
            .progressNote("Reading the schema."),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [.delta("Done."), .complete(totalTokens: 2)]
    )
    // `session` is captured by the hook, so it is built first and the executor
    // referencing it is assembled after — via a box the closure can read.
    let sessionBox = SessionBox()
    var executor = SchemaExecutor(outcome: .ok("{}"))
    executor.onExecute = {
        narrationDuringCall = sessionBox.session?.transcript.last?.workSteps.first?.narration
    }
    let session = AISession(
        transport: transport,
        executor: executor,
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )
    sessionBox.session = session

    await session.send("what tables exist?")

    #expect(
        narrationDuringCall == "Reading the schema.",
        "the description is visible while its action runs, not only after"
    )
    // Still one step once the tool finishes — the note created it, the tool
    // attached to it, nothing duplicated.
    #expect(session.transcript.last?.workSteps.count == 1)
    #expect(session.transcript.last?.workSteps.first?.toolNames == ["get_schema"])
}

/// Guardrail pinned before the Working Block v2 rewrite (state-machine
/// extraction into `AIWorkBlock`) — a plain-chat turn with no tool call at
/// all must produce no working block whatsoever, only the answer text. This
/// is the dominant case and the one most likely to regress silently if a
/// refactor accidentally starts a step/timer for every turn unconditionally.
@MainActor
@Test func aTurnWithNoToolCallProducesNoWorkingBlockAtAll() async throws {
    // Single-round, no tool call: everything has to be scripted in `before` —
    // MockTransport's `after` list only plays once a tool call resolves.
    let transport = MockTransport(
        before: [.delta("Two plus two is four."), .complete(totalTokens: 3)],
        after: []
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what's 2+2?")

    let turn = try #require(session.transcript.last)
    #expect(turn.text == "Two plus two is four.")
    #expect(turn.workSteps.isEmpty)
    #expect(turn.workDuration == nil, "no work happened, so there is nothing to have timed")
    #expect(!turn.hadToolCall)
}

/// Guardrail pinned before the Working Block v2 rewrite — a `tool.arg_delta`
/// whose tool call never actually arrives (the model changes its mind, or
/// the args turn out invalid and the call is dropped) must not manufacture a
/// working step on its own. Only a real `tool.call` publishes a step/action.
@MainActor
@Test func toolArgDeltaWithNoFollowingToolCallCreatesNoStep() async throws {
    let transport = MockTransport(
        before: [
            .toolArgDelta(name: "propose_sql", argDelta: "{\"query\":\"SELECT 1\"}"),
            .delta("Never mind, here's the answer directly."),
            .complete(totalTokens: 2),
        ],
        after: []
    )
    let executor = CapabilityExecutor(toolSpecs: [])
    let session = AISession(
        transport: transport, executor: executor,
        dialect: "postgres", schemaDigest: "abc", store: makeStore()
    )

    await session.send("propose a query")

    let turn = try #require(session.transcript.last)
    #expect(turn.workSteps.isEmpty, "an arg delta with no following tool.call must not create a step")
    #expect(turn.text == "Never mind, here's the answer directly.")
}

/// The boundary is "a note after a tool call", not "any note" — otherwise a model
/// that narrates twice before acting would flush an empty sub-block with no tool
/// in it. Consecutive notes join into the same step instead.
@MainActor
@Test func twoNotesBeforeOneToolCallStayInTheSameStep() async throws {
    let transport = MockTransport(
        before: [
            .progressNote("Let me look at the schema."),
            .progressNote("Focusing on the users table."),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [.delta("Done."), .complete(totalTokens: 2)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    let steps = try #require(session.transcript.last?.workSteps)
    #expect(steps.count == 1, "two notes before one tool are one step, not two")
    #expect(steps.first?.narration == "Let me look at the schema. Focusing on the users table.")
    #expect(steps.first?.toolNames == ["get_schema"])
}

/// A note with no tool call after it still has to surface — a round can narrate
/// and then answer directly.
@MainActor
@Test func aProgressNoteAloneStillProducesAWorkStep() async throws {
    // Single-round: no tool call, so `MockTransport` never reaches its `after`
    // list — everything has to be scripted in `before`.
    let transport = MockTransport(
        before: [
            .progressNote("Answering from what I already know."),
            .delta("No query needed."),
            .complete(totalTokens: 1),
        ],
        after: []
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("hi")

    #expect(session.transcript.last?.text == "No query needed.")
    #expect(
        session.transcript.last?.workSteps.first?.narration == "Answering from what I already know."
    )
}

/// the row's detail is truncated, so it cannot answer "what SQL
/// actually ran". The action keeps the untruncated primary argument for the
/// popover — extracted per tool, since the interesting argument differs: SQL for
/// a run, the written contents for a tab, the object list for a schema read.
@MainActor
@Test func aRunSQLActionKeepsItsFullStatementAsThePayload() async throws {
    let sql = "SELECT " + String(repeating: "very_long_column_name, ", count: 40) + "1"
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Running it. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "run_sql", args: ["sql": sql],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("run it")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    #expect(action.payload == sql, "the whole statement survives for the popover")
    #expect(
        action.inputs.allSatisfy { $0.count < sql.count },
        "the inline row is still truncated"
    )
}

/// Seen in a real panel: the SQL appeared twice under one action — once as the
/// payload preview line, once as an `inputs` bullet — because both render the
/// same `sql` argument. Whichever argument became the payload must not also be
/// listed as an input.
@MainActor
@Test func theArgumentShownAsThePayloadIsNotRepeatedInTheInputs() async throws {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Writing. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "propose_sql",
                args: ["sql": "SELECT 1", "title": "Untitled"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("write it")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    #expect(action.payload == "SELECT 1")
    #expect(
        action.inputs.allSatisfy { !$0.hasPrefix("sql:") },
        "the payload's own argument must not be duplicated as an input bullet"
    )
    #expect(
        action.inputs.contains { $0.hasPrefix("title:") },
        "other arguments are still worth listing"
    )
}

/// Also seen in that panel: the `Result` block listed `artifact_id`,
/// `artifact_version`, `pane`, `proposed`, `tab_id`, `tab_title` — six lines of
/// internal plumbing and nothing a reader wants. The artifact is already surfaced
/// as its own openable row, so these keys are noise.
@MainActor
@Test func resultSummaryHidesInternalPlumbingKeys() async throws {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Writing. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "propose_sql", args: ["sql": "SELECT 1"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("""
        {"artifact_id":"0D938F18-5584-4907-B98B-7B0805792FDB","artifact_version":1,\
        "pane":1,"proposed":1,"tab_id":"editor:5DF96F80","tab_title":"Untitled","rows":7}
        """)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("write it")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    for noise in ["artifact_id", "artifact_version", "pane", "proposed", "tab_id", "tab_title"] {
        #expect(
            !action.outputs.contains { $0.hasPrefix("\(noise):") },
            "\(noise) is plumbing, not a result"
        )
    }
    #expect(action.outputs.contains { $0.hasPrefix("rows:") }, "real result keys survive")
}

/// A schema read's payload is what it read, not a `sql` key it never had.
@MainActor
@Test func aSchemaReadActionKeepsTheObjectsItInspectedAsThePayload() async throws {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Reading. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: ["tables": "users, orders"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["users"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    #expect(action.payload == "users, orders")
}

/// A denied or failed tool must say so rather than reading as Completed.
@MainActor
@Test func aDeniedToolCallIsRecordedAsAFailedAction() async throws {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Trying. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "run_sql", args: ["sql": "DROP TABLE users"],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Denied.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .denied),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("drop it")

    let action = try #require(session.transcript.last?.workSteps.first?.actions.first)
    #expect(action.status == .denied)
}

/// A round whose tools produced nothing durable must not show a dead affordance
/// — no artifact means no clickable target on that sub-block.
@MainActor
@Test func aRoundWithNoArtifactLeavesItsWorkStepWithoutRefs() async {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Reading schema. ", round: 0, segmentID: "r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Done.", round: 1, segmentID: "r1", provisional: true)),
            .complete(totalTokens: 3),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.workSteps.first?.artifactRefs.isEmpty == true)
}

/// the same tab/artifact is commonly touched by more than one tool
/// call within a single turn (e.g. a run, then a self-correcting re-run) —
/// prevents duplicate chips from appearing on the bubble. Two tool calls returning the SAME artifact_id
/// must still leave exactly one chip, not one per call.
@MainActor
@Test func repeatedToolCallsOnTheSameArtifactLeaveExactlyOneChip() async throws {
    let store = makeStore()
    let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
    try store.saveArtifact(artifact)
    try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")

    let transport = MockTransport(
        before: [
            .toolCall(AIToolCall(
                id: "thr-mock-c0", name: "run_sql", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
            .toolCall(AIToolCall(
                id: "thr-mock-c1", name: "run_sql", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [.delta("Fixed and reran it."), .complete(totalTokens: 10)]
    )
    let outcome = ToolOutcome.ok(
        #"{"ran":true,"artifact_id":"\#(artifact.id.uuidString)","artifact_version":1}"#
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: outcome),
        dialect: "postgres",
        schemaDigest: "abc",
        store: store
    )

    await session.send("write a query, then fix the error and rerun it")

    #expect(session.transcript.last?.artifactRefs.count == 1)
    let ref = try #require(session.transcript.last?.artifactRefs.first)
    #expect(ref.artifactID == artifact.id)
    #expect(ref.versionNumber == 1)
}

@MainActor
@Test func deniedToolIsReportedToGateway() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "run_sql", args: ["sql": "DELETE FROM t"],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("Okay, I won't."), .complete(totalTokens: 5)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .denied),
        dialect: "postgres",
        schemaDigest: "abc", store: makeStore()
    )

    await session.send("delete everything")

    #expect(transport.postedResults.first?.status == "denied")
    #expect(session.transcript.last?.text == "Okay, I won't.")
}

@MainActor
@Test func ambiguousToolResultDeliveryIsNotRetriedOrResumedBlindly() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("Delivered."), .complete(totalTokens: 1)]
    )
    transport.toolResultErrors = [URLError(.networkConnectionLost)]
    transport.consumeToolResultBeforeError = true
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("inspect")

    #expect(transport.toolResultAttempts == 1)
    #expect(transport.serverConsumedToolResults == 1)
    #expect(transport.postedResults.isEmpty)
    #expect(!session.transcript.contains { $0.text == "Delivered." })
    #expect(session.controlDeliveryErrorLocalizationKey
        == "The result may have been received, so BerryDB stopped safely instead of sending it twice.")
}

@MainActor
@Test func permanentToolResultFailurePropagatesAndEndsClientTurn() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("must not resume")]
    )
    transport.toolResultErrors = [
        AITransportError.badResponse(
            statusCode: 400, message: "tool_result_rejected"
        ),
    ]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("inspect")

    #expect(transport.toolResultAttempts == 1)
    #expect(transport.postedResults.isEmpty)
    #expect(!session.isStreaming)
    #expect(session.lastError?.contains("tool_result_rejected") == true)
    #expect(!session.transcript.contains { $0.text.contains("must not resume") })
}

@MainActor
@Test func upgradeRequiredSetsLocalizedUIState() async {
    let transport = MockTransport(before: [], after: [])
    transport.responseError = AITransportError.clientUpdateRequired
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("hello")

    #expect(session.requiresClientUpdate)
    #expect(session.lastError != nil)
}

@MainActor
@Test func capabilityProtocolCodesMapToBoundedLocalizedUIKeys() async {
    let knownTransport = MockTransport(before: [], after: [])
    knownTransport.responseError = AITransportError.capabilityRejected(code: "invalid_capability_schema")
    let knownSession = AISession(
        transport: knownTransport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await knownSession.send("hello")

    #expect(knownSession.capabilityErrorLocalizationKey == "The local AI capability set is invalid.")
    #expect(knownSession.lastError == nil)

    let unknownTransport = MockTransport(before: [], after: [])
    unknownTransport.responseError = AITransportError.capabilityRejected(code: "future_server_code_with_details")
    let unknownSession = AISession(
        transport: unknownTransport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await unknownSession.send("hello")

    #expect(unknownSession.capabilityErrorLocalizationKey == "AI capability negotiation failed.")
    #expect(unknownSession.lastError == nil)
}

@MainActor
@Test func negotiatedResponseMissingAcceptanceFailsClosed() async {
    let transport = MockTransport(
        before: [.capabilityMode(.negotiated), .delta("must not authorize tools")],
        after: []
    )
    let local = CapabilityExecutor(toolSpecs: [
        AIToolSpec(name: "get_schema", description: "Schema", parametersJSON: #"{"type":"object"}"#),
    ])
    let session = AISession(
        transport: transport,
        executor: LocalCapabilityHost(executor: local),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("hello")

    #expect(session.requiresClientUpdate)
    #expect(local.calls.isEmpty)
    #expect(transport.receivedCapabilities?.handlers.map(\.id) == ["get_schema"])
}

@MainActor
@Test func preservesLocaleNeutralAgentStepLimitCodeForTheUI() async {
    let transport = MockTransport(
        before: [.error(code: "agent_step_limit", message: "")],
        after: []
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore()
    )

    await session.send("keep going")

    #expect(session.lastError == "agent_step_limit")
    #expect(session.transcript.map(\.role) == [.user])
    #expect(session.transcript.last?.text == "keep going")
}

@MainActor
@Test func removesEmptyAssistantPlaceholderAfterProviderError() async {
    let transport = MockTransport(before: [], after: [])
    transport.responseError = AITransportError.badResponse(
        statusCode: 503,
        message: "provider unavailable"
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore()
    )

    await session.send("inspect this schema")

    #expect(session.lastError == "AI Server error (HTTP 503): provider unavailable")
    #expect(session.transcript.map(\.role) == [.user])
    #expect(session.transcript.last?.text == "inspect this schema")
}

@MainActor
@Test func preservesPartialAssistantTextAfterProviderError() async {
    let transport = MockTransport(
        before: [
            .delta("Partial answer"),
            .error(code: "provider_error", message: "provider unavailable"),
        ],
        after: []
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore()
    )

    await session.send("inspect this schema")

    #expect(session.lastError == "provider unavailable")
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    #expect(session.transcript.last?.text == "Partial answer")
}

@MainActor
@Test func preservesEmptyParentTurnWhenSubAgentOutputExistsAfterRootError() async throws {
    let transport = MockTransport(
        before: [.error(code: "provider_error", message: "root failed")],
        after: []
    )
    transport.childEventsBeforeRoot = true
    transport.childEvents = [
        (threadID: "thr-mock-sub0", event: .delta("Sub-agent result")),
    ]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore()
    )

    await session.send("delegate this")

    #expect(session.lastError == "root failed")
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    let parent = try #require(session.transcript.last)
    #expect(parent.text.isEmpty)
    #expect(session.subThreads(for: parent.id).map(\.text) == ["Sub-agent result"])
    #expect(session.subThreads["thr-mock-sub0"]?.parentTurnID == parent.id)
}

/// Task 13: with explicit round/segmentID metadata (not just the
/// tool.call-boundary fallback), a changed round starts a fresh `text`
/// buffer even though both rounds emit provisional narration before their
/// own tool call — but round 0's narration is preserved in `steps` rather
/// than discarded, so the transcript can render it as collapsed history.
@MainActor
@Test func multipleToolRoundsWithBackendRoundMetadataKeepOnlyTheFinalRound() async {
    let transport = MockTransport(
        before: [
            .delta(AIEventDelta(text: "Round zero narration. ", round: 0, segmentID: "thr-mock-r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta(AIEventDelta(text: "Round one final answer.", round: 1, segmentID: "thr-mock-r1", provisional: true)),
            .complete(totalTokens: 7),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.text == "Round one final answer.")
    // Compared field-by-field rather than whole-struct: `actions` carries this
 // round's per-tool detail and is asserted by its own tests.
    #expect(session.transcript.last?.workSteps.count == 1)
    #expect(session.transcript.last?.workSteps.first?.narration == "Round zero narration. ")
    #expect(session.transcript.last?.workSteps.first?.toolNames == ["get_schema"])
    #expect(session.transcript.last?.workDuration != nil, "a multi-round turn records how long its tool-calling phase took once complete")
    #expect(session.transcript.last?.workStartedAt != nil)
    #expect(session.transcript.last?.toolCallCount == 1)
}

/// A reasoning-mode provider's chain-of-thought is no longer accumulated at all.
///
/// It stopped being rendered when the working block moved to narration-based
/// sub-blocks, but the text was still being appended to `AITurn.reasoning` on
/// every token — and `transcript` is `@Observable`, so each of those writes
/// invalidated the whole view tree for a string nothing displays. A live log
/// showed 5684 reasoning events in one round, so that is
/// 5684 pointless invalidations plus the O(n) string growth behind them.
///
/// The trace is not sent back to the backend (`AITransport` never reads it) and
/// is not persisted (`AIChatRecord` has no column for it), so nothing else
/// depended on it being kept. The turn must still know that reasoning HAPPENED,
/// because that is what makes the working block appear for a round that
/// narrates nothing.
@MainActor
@Test func reasoningIsNotAccumulatedButStillMarksTheTurnAsHavingWorked() async {
    let transport = MockTransport(
        before: [
            .reasoning(AIEventDelta(text: "Thinking hard. ", round: 0, segmentID: "r0")),
            .reasoning(AIEventDelta(text: "Still thinking. ", round: 0, segmentID: "r0")),
        ],
        after: [.delta("Answer."), .complete(totalTokens: 1)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("hello")

    #expect(session.transcript.last?.hadReasoning == true, "the working block still needs to appear")
    #expect(session.transcript.last?.workDuration != nil, "and it must settle when the turn ends")
}

/// Superseded by the test above — kept as the record of what the old behaviour
/// was, now asserting the trace is dropped rather than preserved.
@MainActor
@Test func reasoningTraceIsForwardedAndPreservedAcrossRounds() async {
    let transport = MockTransport(
        before: [
            .reasoning(AIEventDelta(text: "Thinking about round zero. ", round: 0, segmentID: "thr-mock-r0")),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .reasoning(AIEventDelta(text: "Thinking about the final answer. ", round: 1, segmentID: "thr-mock-r1")),
            .delta(AIEventDelta(text: "Final answer.", round: 1, segmentID: "thr-mock-r1", provisional: true)),
            .complete(totalTokens: 7),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.text == "Final answer.")
    #expect(session.transcript.last?.hadReasoning == true)
}

/// A reasoning-mode provider emits `reasoning.delta` BEFORE `message.delta`
/// within the same round, so `.reasoning` is the event that first observes a
/// round boundary. `RoundCursor.startsNewRound` is mutating, so a single
/// cursor shared by both cases lets whichever arrives first consume the
/// boundary — leaving `.delta` to concatenate every round's narration into
/// one runaway `text` and never flush a `workSteps` sub-block. Each event
/// stream needs its own cursor over the same round metadata.
@MainActor
@Test func reasoningBeforeNarrationInTheSameRoundStillFlushesWorkStepsAndResetsText() async {
    let transport = MockTransport(
        before: [
            .reasoning(AIEventDelta(text: "Thinking about round zero. ", round: 0, segmentID: "thr-mock-r0")),
            .delta(AIEventDelta(text: "Round zero narration. ", round: 0, segmentID: "thr-mock-r0", provisional: true)),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .reasoning(AIEventDelta(text: "Thinking about the final answer. ", round: 1, segmentID: "thr-mock-r1")),
            .delta(AIEventDelta(text: "Round one final answer.", round: 1, segmentID: "thr-mock-r1", provisional: true)),
            .complete(totalTokens: 7),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.text == "Round one final answer.")
    #expect(session.transcript.last?.workSteps.count == 1)
    #expect(session.transcript.last?.workSteps.first?.narration == "Round zero narration. ")
    #expect(session.transcript.last?.workSteps.first?.toolNames == ["get_schema"])
    // The trace text is discarded now (see `AITurn.hadReasoning`); what still
    // matters here is that a reasoning event arriving BEFORE this round's
    // narration does not stop `.delta` from seeing the round boundary — the
    // assertions above are the actual regression guard.
    #expect(session.transcript.last?.hadReasoning == true)
}

/// A single-round turn (no tool calls at all) never went through a round
/// boundary, so it has nothing to summarize as "Worked for Xs" — `workSteps`
/// and `workDuration` both stay empty/nil.
@MainActor
@Test func singleRoundTurnHasNoStepsOrWorkDuration() async {
    let transport = MockTransport(before: [.delta("Just an answer."), .complete(totalTokens: 1)], after: [])
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("hello")

    #expect(session.transcript.last?.text == "Just an answer.")
    #expect(session.transcript.last?.workSteps.isEmpty == true)
    #expect(session.transcript.last?.hadToolCall == false)
    #expect(session.transcript.last?.toolCallCount == 0)
    #expect(session.transcript.last?.workDuration == nil)
    #expect(session.transcript.last?.workStartedAt == nil)
}

/// A round with zero narration before its tool call must not leave a
/// stray leading/trailing artifact once the next round's text replaces
/// it. It DOES still get a `workSteps` entry now: empty
/// narration paired with the tool(s) that ran, so a silent tool-only round
/// (e.g. a lone `run_sql`) still shows up as an action badge in the working
/// block instead of vanishing — the old plain-`String` `steps` had no way
/// to carry "nothing said, but this ran" at all. `hadToolCall`/`workDuration`
/// must still be set too: a tool-calling turn that never narrates anything
/// is exactly the case that used to leave the UI showing nothing at all
/// until the final answer.
@MainActor
@Test func emptyPreToolTextLeavesNoArtifactAfterRoundReplace() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("Final answer."), .complete(totalTokens: 1)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.text == "Final answer.")
    #expect(session.transcript.last?.workSteps.count == 1)
    #expect(session.transcript.last?.workSteps.first?.narration == "")
    #expect(session.transcript.last?.workSteps.first?.toolNames == ["get_schema"])
    #expect(session.transcript.last?.hadToolCall == true)
    #expect(session.transcript.last?.toolCallCount == 1)
    #expect(session.transcript.last?.workDuration != nil)
}

/// Legacy/local providers send no round metadata at all — deltas within
/// the same round still concatenate normally, and a tool.call still marks
/// a boundary that starts a fresh `text` buffer, but the previous round's
/// narration (however many separate deltas it arrived as) is preserved in
/// `workSteps` rather than discarded.
@MainActor
@Test func legacyDeltasWithoutRoundMetadataConcatenateWithinARoundButResetAcrossToolCallBoundary() async {
    let transport = MockTransport(
        before: [
            .delta("Checking "), .delta("things. "),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [.delta("Answer "), .delta("here."), .complete(totalTokens: 1)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.transcript.last?.text == "Answer here.")
    #expect(session.transcript.last?.workSteps.count == 1)
    #expect(session.transcript.last?.workSteps.first?.narration == "Checking things. ")
    #expect(session.transcript.last?.workSteps.first?.toolNames == ["get_schema"])
}

/// The `appendSub` sub-agent path gets the same round-boundary fix as the
/// root transcript: a sub-agent's round 1 text replaces round 0's
/// provisional narration instead of concatenating with it.
@MainActor
@Test func subAgentRoundBoundaryReplacesProvisionalNarrationTooInsteadOfConcatenating() async {
    let transport = MockTransport(before: [], after: [])
    transport.childEvents = [
        (threadID: "thr-mock-sub0", event: .delta(AIEventDelta(text: "Sub round zero. ", round: 0, segmentID: "sub0-r0", provisional: true))),
        (threadID: "thr-mock-sub0", event: .delta(AIEventDelta(text: "Sub round one only.", round: 1, segmentID: "sub0-r1", provisional: true))),
    ]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )

    await session.send("delegate a subtask")

    #expect(session.subThreads["thr-mock-sub0"]?.text == "Sub round one only.")
}

/// Provider error: a round's provisional narration must not survive once a
/// later round has started, even if that later round errors out before
/// `message.complete` — only the latest round's partial text is kept.
@MainActor
@Test func providerErrorAfterANewRoundStartedKeepsOnlyTheNewRoundsPartialText() async {
    let transport = MockTransport(
        before: [
            .delta("Let me check. "),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        after: [
            .delta("Partial next round answer"),
            .error(code: "provider_error", message: "provider unavailable"),
        ]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.lastError == "provider unavailable")
    #expect(session.transcript.last?.text == "Partial next round answer")
    // The turn is over (the stream ended on an error, so no `message.complete`
    // is coming), and the working block must settle to "Worked for Xs" rather
    // than tick "Working…" forever — see
    // `aTurnThatEndsWithoutMessageCompleteStillSettlesItsWorkingBlock`.
    #expect(session.transcript.last?.workDuration != nil)
}

/// The reported hang: the working block ticks "Working…" forever and never
/// settles. `workDuration` is set ONLY in the `message.complete` handler, but
/// `gateway.rs` has several paths that end a turn with an `error` event and no
/// `message.complete` at all (a provider failure, an unauthorized tool, the
/// step-limit dead end). `runTurn`'s `defer` clears `isStreaming` on every one
/// of those paths, so the spinner stops — but nothing ever fills in
/// `workDuration`, leaving `TurnWorkSummary` permanently expanded on a live
/// timer for a turn that has already finished.
///
/// This is also why the hang hides the answer outright now that
/// `TurnView.showsResponseText` gates the bubble on `workDuration`
/// (response): an unsettled working block means the
/// partial text never renders. The settle must therefore be driven by "the
/// turn ended", not by "message.complete arrived".
@MainActor
@Test func aTurnThatEndsWithoutMessageCompleteStillSettlesItsWorkingBlock() async {
    let transport = MockTransport(
        before: [
            .delta("Reading the schema first. "),
            .toolCall(AIToolCall(
                id: "c0", name: "get_schema", args: [:],
                dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
                capabilitySetDigest: "digest"
            )),
        ],
        // Stream dies here: an error and then EOF, with no `message.complete`.
        after: [.error(code: "provider_error", message: "provider unavailable")]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "abc",
        store: makeStore()
    )

    await session.send("what tables exist?")

    #expect(session.isStreaming == false, "the turn is over")
    #expect(
        session.transcript.last?.workDuration != nil,
        "a turn that had a working block must settle it even when the stream ends without message.complete"
    )
}

/// Cancellation: resuming after a cancelled clarification runs `streamTurn`
/// again on a fresh assistant turn. If that resumed turn itself narrates
/// through a tool round before answering, the round-boundary fix must
/// apply there too — proving the fix isn't specific to the initial `send`
/// call path.
@MainActor
@Test func cancelledInteractionResumeStillAppliesRoundBoundaryToItsOwnToolRound() async throws {
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1",
            kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Proceed with the default?",
            allowFreeText: true
        ))],
        after: [.delta("Round one final answer."), .complete(totalTokens: 1)]
    )
    transport.resumeEvents = [
        .delta("Round zero narration. "),
        .toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        )),
    ]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("do it")
    await session.resolveClarification(.cancel(displayText: "Cancel"))

    #expect(session.transcript.last?.text == "Round one final answer.")
}

/// Persistence: `persistTurn` must have received only the committed
/// answer, not the discarded provisional narration — reload the thread
/// from local storage and confirm the same.
@MainActor
@Test func reloadedThreadShowsOnlyTheCommittedAnswerNotDiscardedProvisionalNarration() async throws {
    let store = makeStore()
    let transport = MockTransport(
        before: [.delta("Let me look. "), .toolCall(AIToolCall(
            id: "thr-mock-c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("You have one table."), .complete(totalTokens: 42)]
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok(#"{"tables":["t"]}"#)),
        dialect: "postgres",
        schemaDigest: "abc",
        store: store
    )

    await session.send("what tables exist?")
    let threadIDString = try #require(session.currentThreadID)

    await session.openThread(threadIDString)

    #expect(session.transcript.map(\.text) == ["what tables exist?", "You have one table."])
    #expect(!session.transcript.contains { $0.text.contains("Let me look") })
}

private struct FakeSkillRanker: SkillRanking {
    func skillsForRanking() -> [SkillRankInput] { [SkillRankInput(name: "pg", description: "d", contentHash: "h")] }
    func skillToolSpec(named name: String) -> AIToolSpec? {
        AIToolSpec(name: "skill:\(name)", description: "d", parametersJSON: "{}")
    }
}

/// A `SkillRanking` whose installed skill set can change between turns, for
/// exercising `resolveTools`' cache invalidation (Task 7.2): the cache key
/// is derived from this output, so mutating it mid-test simulates skills
/// being installed/uninstalled without needing a separate notification.
private final class VersionedSkillRanker: SkillRanking {
    var inputs: [SkillRankInput]
    var specsByName: [String: AIToolSpec]

    init(inputs: [SkillRankInput], specsByName: [String: AIToolSpec]) {
        self.inputs = inputs
        self.specsByName = specsByName
    }

    func skillsForRanking() -> [SkillRankInput] { inputs }
    func skillToolSpec(named name: String) -> AIToolSpec? { specsByName[name] }
}

@MainActor
@Test func publishesLocalFeedbackBeforeSkillRankingReturns() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let gate = AsyncGate()
    transport.rankGate = gate
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore(),
        skills: FakeSkillRanker()
    )

    let sendTask = Task { await session.send("inspect this schema") }
    await gate.waitUntilEntered()

    #expect(session.isStreaming)
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    #expect(session.transcript.last?.text == "")

    await gate.release()
    await sendTask.value
}

/// Task 7.1: crossing `summaryThreshold` used to force every subsequent turn
/// to pay a synchronous `summarize()` round trip before `postMessage` could
/// even start. Now that fold runs in the background after the turn persists,
/// so a *second* send shows its own immediate local feedback even while an
/// *earlier* turn's fold is still in flight — turns don't wait on each
/// other's refresh either.
@MainActor
@Test func sendShowsImmediateFeedbackWhileAnEarlierTurnsSummaryRefreshIsStillInFlight() async throws {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let summarizeGate = AsyncGate()
    transport.summarizeGate = summarizeGate
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0...AIConversationPolicy.summaryThreshold).map { seq in
        AIMessageRecord(
            threadID: threadID,
            seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)",
            createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    // First turn crosses summaryThreshold; its background fold is held open
    // by the gate instead of returning.
    await session.send("continue")
    await summarizeGate.waitUntilEntered()
    #expect(!session.isStreaming, "the visible turn already finished; the fold never delayed it")

    // A second send still shows immediate local feedback despite the first
    // turn's fold not having returned yet. Clear the shared gate first so
    // the second turn's own fold (if any) doesn't collide with the first's
    // already-in-flight `enterAndWait()`.
    transport.summarizeGate = nil
    let responseGate = AsyncGate()
    transport.responseGate = responseGate
    let secondTask = Task { await session.send("and again") }
    await responseGate.waitUntilEntered()

    #expect(session.isStreaming)
    #expect(session.transcript.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(session.transcript.last?.text == "")

    await responseGate.release()
    await secondTask.value
    await summarizeGate.release()
}

@MainActor
@Test func publishesLocalFeedbackBeforeGatewayResponds() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let gate = AsyncGate()
    transport.responseGate = gate
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x",
        store: makeStore()
    )

    let sendTask = Task { await session.send("hello") }
    await gate.waitUntilEntered()

    #expect(session.isStreaming)
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    #expect(session.transcript.last?.text == "")

    await gate.release()
    await sendTask.value
}

@MainActor
@Test func injectsRankedSkillToolsForTheTurn() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    transport.rankReply = ["pg"]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: FakeSkillRanker()
    )
    await session.send("optimize this query")
    #expect(transport.receivedTools.contains { $0.name == "skill:pg" })
    #expect(transport.receivedTools.contains { $0.name == "get_schema" })
}

/// Task 7.2: a hung `rankSkills` must not delay the turn past
/// `skillRankTimeout` — the turn proceeds with the static tools alone
/// instead of waiting indefinitely.
@MainActor
@Test func fallsBackToStaticToolsWhenSkillRankingExceedsItsBound() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let gate = AsyncGate()
    transport.rankGate = gate // never released — models a hung rankSkills call
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: FakeSkillRanker(),
        skillRankTimeout: .milliseconds(30)
    )

    // The rank gate is never released, so `send` can only return via the
    // timeout branch — there's no other path back. The elapsed check is a
    // generous safety net (not a tight timing assertion, which would be
    // flaky under a heavily parallel full-suite run) against a regression
    // that removes the bound entirely and hangs forever.
    let clock = ContinuousClock()
    let started = clock.now
    await session.send("optimize this query")
    let elapsed = clock.now - started

    #expect(elapsed < .seconds(10), "a hung rank call must not block the turn indefinitely")
    #expect(transport.receivedTools.contains { $0.name == "get_schema" }, "static tools must survive a rank timeout")
    #expect(!transport.receivedTools.contains { $0.name == "skill:pg" })

    await gate.release() // let the abandoned rank task finish instead of leaking past the test
}

/// Task 7.2: `rankSkills` failing fast (its documented empty-on-failure
/// shape) must still leave the static tools available — the same fallback
/// the timeout path uses, exercised on its own without needing the bound
/// to fire.
@MainActor
@Test func fallsBackToStaticToolsWhenSkillRankingReturnsNoResult() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    transport.rankReply = []
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: FakeSkillRanker()
    )

    await session.send("optimize this query")

    #expect(!transport.receivedTools.isEmpty)
    #expect(transport.receivedTools.contains { $0.name == "get_schema" })
    #expect(!transport.receivedTools.contains { $0.name == "skill:pg" })
}

/// Task 7.2 (review fix): an empty-but-fast rank result must not be cached
/// — a transient failure that happened to return quickly must not silently
/// deny skill tools to the same literal query for the rest of the session.
/// A repeated identical query must still call `rankSkills` again, giving a
/// later attempt (which might succeed) a fresh chance.
@MainActor
@Test func doesNotCacheAnEmptyRankResultSoARepeatedQueryTriesAgain() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    transport.rankReply = []
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: FakeSkillRanker()
    )

    await session.send("optimize this query")
    #expect(transport.rankCallCount == 1)

    // The backend recovers; the identical query must not be short-circuited
    // by a stale empty-result cache entry from the first, failed attempt.
    transport.rankReply = ["pg"]
    await session.send("optimize this query")

    #expect(transport.rankCallCount == 2, "an empty rank result must not be cached — the identical query must retry")
    #expect(transport.receivedTools.contains { $0.name == "skill:pg" })
    #expect(transport.receivedTools.contains { $0.name == "get_schema" })
}

/// Task 7.2: a successful rank is cached by skill content/version plus the
/// normalized query, so an identical query (modulo case/whitespace) against
/// the same installed skills skips the round trip.
@MainActor
@Test func cachesASuccessfulRankSoARepeatedIdenticalQuerySkipsTheRoundTrip() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    transport.rankReply = ["pg"]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: FakeSkillRanker()
    )

    await session.send("Optimize This Query")
    await session.send("  optimize this query  ")

    #expect(transport.rankCallCount == 1, "same skills + normalized query should reuse the cached rank")
    #expect(transport.receivedTools.contains { $0.name == "skill:pg" })
}

/// Task 7.2: the cache is keyed by skill content/version, so a repeated
/// query against a *changed* installed skill set must not reuse the stale
/// entry from before the change.
@MainActor
@Test func doesNotReuseACachedSkillRankAfterTheInstalledSkillSetChanges() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let ranker = VersionedSkillRanker(
        inputs: [SkillRankInput(name: "pg", description: "d", contentHash: "h1")],
        specsByName: ["pg": AIToolSpec(name: "skill:pg", description: "d", parametersJSON: "{}")]
    )
    transport.rankReply = ["pg"]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [AIToolSpec(name: "get_schema", description: "d", parametersJSON: "{}")]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore(),
        skills: ranker
    )

    await session.send("optimize this query")
    #expect(transport.receivedTools.contains { $0.name == "skill:pg" })
    #expect(transport.rankCallCount == 1)

    // Simulate "pg" being uninstalled and "sql" installed in its place.
    ranker.inputs = [SkillRankInput(name: "sql", description: "d2", contentHash: "h2")]
    ranker.specsByName = ["sql": AIToolSpec(name: "skill:sql", description: "d2", parametersJSON: "{}")]
    transport.rankReply = ["sql"]

    await session.send("optimize this query")

    #expect(transport.rankCallCount == 2, "a changed skill set must trigger a fresh rank call, not a stale cache hit")
    #expect(transport.receivedTools.contains { $0.name == "skill:sql" })
    #expect(!transport.receivedTools.contains { $0.name == "skill:pg" })
    #expect(transport.receivedTools.contains { $0.name == "get_schema" })
}

@MainActor
@Test func advertisesToolSpecsToGateway() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}"), specs: [
            AIToolSpec(name: "get_schema", description: "d", parametersJSON: #"{"type":"object"}"#),
        ]),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )
    await session.send("hi")
    #expect(transport.receivedTools.map(\.name) == ["get_schema"])
}

@MainActor
@Test func accumulatesPlannerPlanIntoTheTurn() async {
    let transport = MockTransport(before: [.plan("Step 1. "), .plan("Step 2."), .delta("Answer."), .complete(totalTokens: 0)], after: [])
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )
    await session.send("do it")
    #expect(session.transcript.last?.plan == "Step 1. Step 2.")
    #expect(session.transcript.last?.text == "Answer.")
}

@MainActor
@Test func routesSubAgentEventsToSubThreads() async {
    let transport = MockTransport(before: [], after: [])
    transport.childEvents = [
        (threadID: "thr-mock-sub0", event: .delta("Sub working. ")),
        (threadID: "thr-mock-sub0", event: .delta("Done.")),
    ]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )
    await session.send("delegate a subtask")
    #expect(session.subThreads["thr-mock-sub0"]?.text == "Sub working. Done.")
    let turnID = session.transcript.last!.id
    #expect(session.subThreads(for: turnID).count == 1)
    #expect(session.subThreads["thr-mock-sub0"]?.parentTurnID == turnID)
    // The root assistant turn stays empty — child text didn't leak into it.
    #expect(session.transcript.last?.text == "")
}

/// Reported live: the panel got dramatically slower the longer a session ran.
/// `subThreads(for:)` used to early-exit only when the WHOLE session had no
/// sub-agents at all — once ANY turn anywhere had spawned one, every OTHER
/// turn's own (empty) lookup still filtered and sorted the entire
/// `subThreads` dictionary, every streamed token, for a conversation that by
/// then had accumulated many turns and many sub-agents across hours of use.
/// `subThreadIDsByParentTurn` replaces that with a direct per-turn lookup —
/// this pins that two different turns' sub-agents stay correctly separated
/// under it, the thing an index like that is most likely to get wrong.
@MainActor
@Test func subThreadsForATurnDoesNotLeakSubAgentsFromOtherTurns() async {
    let transport = MockTransport(before: [], after: [])
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )

    transport.childEvents = [(threadID: "thr-mock-sub-a", event: .delta("A's sub-agent."))]
    await session.send("first")
    let turnA = session.transcript.last!.id

    transport.childEvents = [(threadID: "thr-mock-sub-b", event: .delta("B's sub-agent."))]
    await session.send("second")
    let turnB = session.transcript.last!.id

    #expect(session.subThreads(for: turnA).map(\.id) == ["thr-mock-sub-a"])
    #expect(session.subThreads(for: turnB).map(\.id) == ["thr-mock-sub-b"])
}

/// A sub-agent both streaming text (`appendSub`) and calling a tool
/// (`noteSubTool`) are the two places that create its `subThreads` entry and
/// therefore the two places that index it — this pins that whichever one
/// gets there first, the other does not append a second, duplicate index
/// entry for the same child thread.
@MainActor
@Test func subThreadIndexDoesNotDuplicateWhenTextAndToolActivityBothArriveForTheSameChild() async {
    let transport = MockTransport(before: [], after: [])
    transport.childEvents = [
        (threadID: "thr-mock-sub-c", event: .delta("Working. ")),
        (threadID: "thr-mock-sub-c", event: .toolCall(AIToolCall(
            id: "sub0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))),
    ]
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres",
        schemaDigest: "x", store: makeStore()
    )

    await session.send("delegate")

    let turnID = session.transcript.last!.id
    #expect(session.subThreads(for: turnID).count == 1)
}

/// the composer stays usable while a turn streams — sending another
/// message queues it instead of dropping it, and it runs automatically once
/// the in-flight turn finishes.
@MainActor
@Test func queuesASendWhileStreamingAndRunsItAutomaticallyAfterward() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("done"), .complete(totalTokens: 1)]
    )
    let executor = PausableExecutor(outcome: .ok("{}"))
    let session = AISession(transport: transport, executor: executor, dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.send("first") }
    await executor.waitUntilEntered() // first turn is now paused mid-flight, isStreaming == true
    #expect(session.isStreaming == true)

    await session.send("second")

    // Queued while the first turn streams — not a transcript bubble yet
    // (only `queuedMessagesStrip` shows it in the UI), so it doesn't read as
    // already sent before it's actually dispatched.
    #expect(session.transcript.map(\.role) == [.user, .assistant])
    #expect(session.transcript.map(\.text) == ["first", ""])
    #expect(session.queuedMessages == ["second"])

    executor.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() } // let the auto-drained "second" turn finish

    #expect(session.queuedMessages.isEmpty)
    #expect(session.transcript.map(\.role) == [.user, .assistant, .user, .assistant])
    #expect(session.transcript.map(\.text) == ["first", "done", "second", "done"])
    #expect(session.lastError == nil)
}

/// Reported live: the AI panel scrolled to a fresh `send()`'s new bubble
/// directly and immediately, but a message dequeued from's queue
/// (once the previous turn finishes) only ever caught up later via the
/// slower reactive path. `onTurnAdmitted` is what the panel hooks to
/// trigger the same direct scroll for both — this pins that it actually
/// fires for BOTH the initial send AND the auto-drained queued turn, not
/// just the first.
@MainActor
@Test func onTurnAdmittedFiresForBothTheInitialSendAndTheAutoDrainedQueuedTurn() async {
    let transport = MockTransport(
        before: [.toolCall(AIToolCall(
            id: "c0", name: "get_schema", args: [:],
            dispatchNonce: "AbCdEf0123456789AbCdEf0123456789",
            capabilitySetDigest: "digest"
        ))],
        after: [.delta("done"), .complete(totalTokens: 1)]
    )
    let executor = PausableExecutor(outcome: .ok("{}"))
    let session = AISession(transport: transport, executor: executor, dialect: "postgres", schemaDigest: "abc", store: makeStore())
    var admittedCount = 0
    session.onTurnAdmitted = { admittedCount += 1 }

    let firstTask = Task { await session.send("first") }
    await executor.waitUntilEntered()
    #expect(admittedCount == 1, "the initial send must fire onTurnAdmitted synchronously")

    await session.send("second")
    #expect(admittedCount == 1, "a message that only queues (no bubble yet) must not fire onTurnAdmitted")

    executor.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() } // let the auto-drained "second" turn finish

    #expect(admittedCount == 2, "the queued message getting its own bubble once drained must also fire onTurnAdmitted")
}

/// follow-up, reported live: a device with Apple-Intelligence-only
/// access (no real license) whose on-device toggle was off had `prepareSend`
/// return nil for every send — the message vanished with no bubble and no
/// error, no matter how many times it was retried. `admitBlocked` is the
/// fix's building block: whenever `AIPanelController` finds nowhere to
/// actually route a turn, it must still show the user's own message like
/// any other send, with a plain-text explanation instead of silence.
@MainActor
@Test func admitBlockedShowsBothBubblesWithNoNetworkCall() async {
    let transport = MockTransport(before: [], after: [])
    let executor = SchemaExecutor(outcome: .ok("{}"))
    let session = AISession(transport: transport, executor: executor, dialect: "postgres", schemaDigest: "abc", store: makeStore())

    session.admitBlocked("hello", reason: "On-device AI is off and there is no license.")

    #expect(session.transcript.count == 2)
    #expect(session.transcript[0].role == .user)
    #expect(session.transcript[0].text == "hello")
    #expect(session.transcript[1].role == .assistant)
    #expect(session.transcript[1].text == "On-device AI is off and there is no license.")
    #expect(!session.isStreaming)
}

@MainActor
@Test func admitBlockedIgnoresWhitespaceOnlyText() async {
    let transport = MockTransport(before: [], after: [])
    let executor = SchemaExecutor(outcome: .ok("{}"))
    let session = AISession(transport: transport, executor: executor, dialect: "postgres", schemaDigest: "abc", store: makeStore())

    session.admitBlocked("   ", reason: "unreachable")

    #expect(session.transcript.isEmpty)
}

/// lets `AIPanelController` check, before committing to a
/// send, whether `admitSend` would run immediately or queue — needed
/// because an auto-trial attempt (starting a real trial before actually
/// running the turn) must not be interleaved with a message that's about
/// to queue instead of run, which would leave the queued message
/// orphaned if the trial attempt then failed.
@MainActor
@Test func canRunImmediatelyReflectsWhetherATurnIsAlreadyActive() async {
    let session = AISession(
        transport: MockTransport(before: [.delta("hi"), .complete(totalTokens: 1)], after: []),
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "abc", store: makeStore()
    )
    #expect(session.canRunImmediately)

    let task = Task { await session.send("first") }
    while !session.isStreaming { await Task.yield() }
    #expect(!session.canRunImmediately)

    await task.value
    #expect(session.canRunImmediately)
}

@MainActor
@Test func failActiveTurnFillsInTheReasonAndDrainsTheQueue() async {
    let session = AISession(
        transport: MockTransport(before: [], after: []),
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "abc", store: makeStore()
    )
    guard case let .run(_, assistantIndex, assistantTurnID) = session.admitSend("hello") else {
        Issue.record("expected .run for an immediate send")
        return
    }
    // A message queued behind the active turn must still surface once
    // the turn ends — same as any other way a turn can end.
    _ = session.admitSend("queued one") // .queued, since the first turn is "active" (isStreaming true)

    session.failActiveTurn(assistantIndex: assistantIndex, assistantTurnID: assistantTurnID, reason: "couldn't start trial")

    #expect(session.transcript[assistantIndex].text == "couldn't start trial")
    // The queued message auto-drains immediately (synchronously, inside
    // failActiveTurn's own defer) — isStreaming can already be true again
    // for ITS turn by the time failActiveTurn returns, same as runTurn's
    // own defer. Wait for that drained turn to actually finish too.
    while session.isStreaming { await Task.yield() }
    #expect(session.transcript.contains { $0.text == "queued one" })
}

/// Pausable on-device provider — mirrors `PausableExecutor` above, but for
/// `LocalCompletionProvider.stream(prompt:)` instead of a tool executor, so
/// a test can hold a local turn open exactly like `PausableExecutor` holds
/// a tool call open.
private final class PausableLocalProvider: LocalCompletionProvider, @unchecked Sendable {
    static func isAvailable() -> Bool { true }
    let finalText: String
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    private var shouldResumeImmediately = false

    init(finalText: String) { self.finalText = finalText }

    func complete(prompt: String) async throws -> String {
        var result = ""
        for try await delta in stream(prompt: prompt) { result += delta }
        return result
    }

    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                self.hasEntered = true
                self.enteredContinuation?.resume()
                self.enteredContinuation = nil
                if !self.shouldResumeImmediately {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        self.resumeContinuation = cont
                    }
                }
                continuation.yield(self.finalText)
                continuation.finish()
            }
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            enteredContinuation = cont
        }
    }

    func resume() {
        shouldResumeImmediately = true
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

/// Sending a second message while an on-device reply is still streaming
/// must queue rather than being dropped (no bubble, no queue indicator),
/// matching the backend queue path.
@MainActor
@Test func aSecondLocalSendWhileStreamingQueuesInsteadOfVanishing() async {
    let provider = PausableLocalProvider(finalText: "first reply")
    let executor = SchemaExecutor(outcome: .ok("{}"))
    let session = AISession(transport: MockTransport(before: [], after: []), executor: executor, dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.sendLocal("first", provider: provider) }
    await provider.waitUntilEntered()

    await session.sendLocal("second", provider: provider)
    #expect(session.queuedMessages == ["second"], "must queue, not silently drop, while a local turn is streaming")
    #expect(session.transcript.count == 2, "only the first turn's own bubbles exist yet — the second is queued, not shown")

    provider.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() } // let the auto-drained "second" turn finish

    #expect(session.transcript.count == 4, "the queued message must get its own bubble once drained, same as the backend queue")
    #expect(session.transcript[2].text == "second")
    #expect(session.transcript[3].text == "first reply", "drained locally too, not routed through the backend")
}

/// Queued messages sharing the same destination (local vs backend) merge into
/// one turn instead of paying separate round-trip waits for each queued message.
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

/// Reported live: a queued (not-yet-sent) message should still be
/// removable before it drains.
@MainActor
@Test func removeQueuedMessageDropsItBeforeItEverDrains() async {
    let provider = PausableLocalProvider(finalText: "reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.runLocal(session.admitSendLocal("first", provider: provider)) }
    await provider.waitUntilEntered()

    _ = session.admitSendLocal("second", provider: provider)
    _ = session.admitSendLocal("third", provider: provider)
    #expect(session.queuedMessages == ["second", "third"])

    session.removeQueuedMessage(at: 0)
    #expect(session.queuedMessages == ["third"], "removing index 0 drops \"second\", leaving \"third\"")

    provider.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() }

    #expect(session.transcript.map(\.text) == ["first", "reply", "third", "reply"], "the removed message never sends")
}

@MainActor
@Test func removeQueuedMessageAtOutOfBoundsIndexIsANoop() async {
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())
    session.removeQueuedMessage(at: 0)
    session.removeQueuedMessage(at: -1)
    #expect(session.queuedMessages.isEmpty)
}

/// Reported live: with Apple Intelligence on, the user's own bubble and the
/// "preparing" (empty assistant bubble / typing) indicator lagged behind
/// pressing Send. Root cause: unlike the backend path (`admitSend`, called
/// synchronously from `AIPanelController.prepareSend()` on the Enter/Send
/// call stack — see its doc comment), `sendLocal` was a single `async func`
/// with no synchronous half, so its `transcript.append` only ran once the
/// wrapping `Task` actually got a turn on the MainActor — which a busy
/// MainActor can delay arbitrarily. `admitSendLocal` mirrors `admitSend`'s
/// split to close that gap.
@MainActor
@Test func admitSendLocalAppendsBothBubblesSynchronouslyBeforeAnyAwait() async {
    let provider = PausableLocalProvider(finalText: "reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let admission = session.admitSendLocal("hello", provider: provider)

    // No `await` has happened yet — the user's bubble AND the empty
    // assistant "preparing" bubble must already be on the transcript.
    #expect(session.transcript.map(\.text) == ["hello", ""])
    #expect(session.isStreaming == true)

    let task = Task { await session.runLocal(admission) }
    await provider.waitUntilEntered()
    provider.resume()
    await task.value

    #expect(session.transcript.map(\.text) == ["hello", "reply"])
}

/// Same synchronous guarantee for the queued case (a local turn is already
/// streaming): the second message must land in `queuedMessages` immediately,
/// not only once its own wrapping `Task` runs.
@MainActor
@Test func admitSendLocalQueuesSynchronouslyWhileAnotherLocalTurnStreams() async {
    let provider = PausableLocalProvider(finalText: "first reply")
    let session = AISession(transport: MockTransport(before: [], after: []), executor: SchemaExecutor(outcome: .ok("{}")), dialect: "postgres", schemaDigest: "abc", store: makeStore())

    let firstTask = Task { await session.runLocal(session.admitSendLocal("first", provider: provider)) }
    await provider.waitUntilEntered()

    let secondAdmission = session.admitSendLocal("second", provider: provider)
    #expect(session.queuedMessages == ["second"], "must queue synchronously, before any await")
    #expect(session.transcript.count == 2, "only the first turn's own bubbles exist yet")

    await session.runLocal(secondAdmission)
    provider.resume()
    await firstTask.value
    while session.isStreaming { await Task.yield() }

    #expect(session.transcript.count == 4)
    #expect(session.transcript[2].text == "second")
    #expect(session.transcript[3].text == "first reply")
}

@MainActor
@Test func reusesThreadAcrossMessages() async {
    let transport = MockTransport(before: [.complete(totalTokens: 1)], after: [])
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "mysql",
        schemaDigest: "d", store: makeStore()
    )
    await session.send("hi")
    let firstThreadID = session.currentThreadID
    await session.send("again")
    #expect(session.currentThreadID == firstThreadID, "the local thread id must stay stable across messages in the same conversation")
    #expect(session.totalTokens == 2)
}

/// Reported crash/leak audit: `startNetworkMonitor()`'s own doc comment
/// claimed dropping the last reference to `AISession` stopped its
/// `NWPathMonitor` "as part of its own deinit" — but a *started*
/// `NWPathMonitor` runs until `.cancel()` is called explicitly; nothing did
/// that. `bind()` discards the old `AISession` on every genuine connection
/// switch, so each one leaked its monitor and dedicated `DispatchQueue`
/// forever. `NWPathMonitor` exposes no "is cancelled" introspection to
/// assert on directly, so this checks the closest observable proxy: the
/// session itself must actually deallocate once its last strong reference
/// is dropped (a real reference cycle involving the monitor's captured
/// `[weak self]` handler — a bug the fix's `deinit` would also catch — would
/// show up here as a failure to deallocate).
@MainActor
@Test func discardingASessionDeallocatesIt() async {
    weak var weakSession: AISession?
    do {
        let transport = MockTransport(before: [], after: [])
        let session = AISession(
            transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
            dialect: "postgres", schemaDigest: "d", store: makeStore()
        )
        weakSession = session
    }
    #expect(weakSession == nil)
}

// MARK: - Q17: client-authoritative chat history

@MainActor
@Test func availableThreadsReturnsLocallySavedThreadsNewestUpdatedFirst() async throws {
    let store = makeStore()
    let transport = MockTransport(before: [], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    let id1 = UUID()
    let id2 = UUID()
    let now = Date()
    let earlier = now.addingTimeInterval(-100)

    try store.saveAIThread(AIThreadRecord(id: id1, dialect: "postgres", title: "Older Thread", createdAt: earlier, updatedAt: earlier))
    try store.saveAIThread(AIThreadRecord(id: id2, dialect: "postgres", title: "Newer Thread", createdAt: now, updatedAt: now))

    let threads = await session.availableThreads()

    #expect(threads.count == 2)
    #expect(threads[0].id == id2.uuidString)
    #expect(threads[0].title == "Newer Thread")
    #expect(threads[1].id == id1.uuidString)
    #expect(threads[1].title == "Older Thread")
    #expect(transport.listThreadsCalls == 0)
}

/// Scopes threads by connection profile id: threads previously scoped by
/// `dialect` alone would cause two distinct connections of the SAME dialect
/// (e.g. two Postgres profiles) to share one thread list and active conversation
/// (v28).
@MainActor
@Test func availableThreadsExcludesThreadsFromADifferentConnectionSharingTheSameDialect() async throws {
    let store = makeStore()
    let transport = MockTransport(before: [], after: [])
    let sessionA = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", connectionKey: "profile-a", schemaDigest: "d", store: store
    )
    let sessionB = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", connectionKey: "profile-b", schemaDigest: "d", store: store
    )

    let now = Date()
    try store.saveAIThread(AIThreadRecord(dialect: "postgres", connectionKey: "profile-a", title: "A's chat", createdAt: now, updatedAt: now))
    try store.saveAIThread(AIThreadRecord(dialect: "postgres", connectionKey: "profile-b", title: "B's chat", createdAt: now, updatedAt: now))

    let threadsForA = await sessionA.availableThreads()
    let threadsForB = await sessionB.availableThreads()

    #expect(threadsForA.map(\.title) == ["A's chat"])
    #expect(threadsForB.map(\.title) == ["B's chat"])
}

@MainActor
@Test func openThreadLoadsMessagesFromLocalStoreIntoTranscript() async throws {
    let store = makeStore()
    let transport = MockTransport(before: [], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    let threadID = UUID()
    let now = Date()
    try store.saveAIThread(AIThreadRecord(id: threadID, dialect: "postgres", title: "Test", createdAt: now, updatedAt: now))
 // openThread reads the ACTIVE path — chain parentID + advance the
    // thread's leaf the same way persistTurn does, not just flat inserts.
    var previous: UUID?
    for message in [
        AIMessageRecord(threadID: threadID, seq: 0, role: "user", content: "What tables exist?", createdAt: now),
        AIMessageRecord(threadID: threadID, seq: 1, role: "assistant", content: "You have 5 tables.", createdAt: now),
        AIMessageRecord(threadID: threadID, seq: 2, role: "assistant", content: "", toolCalls: "[...]", createdAt: now),
        AIMessageRecord(threadID: threadID, seq: 3, role: "tool", content: "{}", toolCallID: "c1", createdAt: now),
    ] {
        var next = message
        next.parentID = previous
        try store.appendAIMessage(next)
        previous = next.id
    }
    try store.setActiveLeafMessage(threadID: threadID, messageID: previous)

    await session.openThread(threadID.uuidString)

    #expect(session.currentThreadID == threadID.uuidString)
    #expect(session.transcript.count == 2)
    #expect(session.transcript[0].role == .user)
    #expect(session.transcript[0].text == "What tables exist?")
    #expect(session.transcript[1].role == .assistant)
    #expect(session.transcript[1].text == "You have 5 tables.")
    #expect(transport.loadThreadCalls.isEmpty)
}

@MainActor
@Test func deleteThreadRemovesItFromLocalStoreAndStartsNewThreadIfActive() async throws {
    let store = makeStore()
    let transport = MockTransport(before: [], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    let threadID = UUID()
    let now = Date()
    try store.saveAIThread(AIThreadRecord(id: threadID, dialect: "postgres", title: "To Delete", createdAt: now, updatedAt: now))
    try store.appendAIMessage(AIMessageRecord(threadID: threadID, seq: 0, role: "user", content: "Hello", createdAt: now))

    await session.openThread(threadID.uuidString)
    #expect(session.currentThreadID == threadID.uuidString)

    await session.deleteThread(threadID.uuidString)

    #expect(try store.aiThread(id: threadID) == nil)
    #expect(try store.aiMessages(threadID: threadID).isEmpty)
    #expect(session.currentThreadID == nil)
    #expect(session.transcript.isEmpty)
    #expect(transport.deleteThreadCalls.isEmpty)
}

@MainActor
@Test func sendPersistsTheTurnLocallyInsteadOfRelyingOnTheBackend() async throws {
    let transport = MockTransport(before: [.delta("Hi there!"), .complete(totalTokens: 3)], after: [])
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    await session.send("hello")

    let threadID = try #require(session.currentThreadID)
    let id = try #require(UUID(uuidString: threadID))
    let saved = try store.aiMessages(threadID: id)
    #expect(saved.map(\.role) == ["user", "assistant"])
    #expect(saved.map(\.content) == ["hello", "Hi there!"])
    let thread = try store.aiThread(id: id)
    #expect(thread?.title == "hello")
}

@MainActor
@Test func successfulTurnEagerlyIndexesBothPersistedMessages() async throws {
    let transport = MockTransport(before: [.delta("Hi there!"), .complete(totalTokens: 3)], after: [])
    transport.embedReply = Array(
        repeating: 0.1, count: BerryStore.aiMessageEmbeddingDimension
    )
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    await session.send("hello")
    let id = try #require(UUID(uuidString: session.currentThreadID ?? ""))
    for _ in 0..<1_000 {
        if try store.aiMessagesMissingEmbeddings(threadID: id).isEmpty { break }
        await Task.yield()
    }

    #expect(try store.aiMessagesMissingEmbeddings(threadID: id).isEmpty)
    #expect(Set(transport.embedInputs()) == ["hello", "Hi there!"])
}

// MARK: -: edit & version messages

@MainActor
@Test func editingAMessageForksTheTranscriptAndSiblingSwitchRestoresTheOriginal() async throws {
    let transport = MockTransport(before: [.delta("Hi there!"), .complete(totalTokens: 3)], after: [])
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    await session.send("first")
    await session.send("second")
    #expect(session.transcript.map(\.text) == ["first", "Hi there!", "second", "Hi there!"])
    let originalFirstMessageID = try #require(session.transcript[0].messageID)
    // Two versions don't exist at this fork point yet — nothing to navigate.
    #expect(session.siblings(of: originalFirstMessageID) == [originalFirstMessageID])

    let admission = try #require(session.prepareEdit(messageID: originalFirstMessageID, newText: "first-edited"))
    await session.run(admission)

    // The edit forked: "second" and its reply are gone from the ACTIVE
    // transcript (still on disk, just not on this path) — not deleted.
    #expect(session.transcript.map(\.text) == ["first-edited", "Hi there!"])
    let editedFirstMessageID = try #require(session.transcript[0].messageID)
    #expect(Set(session.siblings(of: editedFirstMessageID)) == Set([originalFirstMessageID, editedFirstMessageID]))

    await session.selectSibling(messageID: originalFirstMessageID)

    // Switching back to the original resolves to ITS OWN tip — the whole
    // original conversation, "second" included, reappears untouched.
    #expect(session.transcript.map(\.text) == ["first", "Hi there!", "second", "Hi there!"])
}

@MainActor
@Test func prepareEditRefusesForAnUnknownMessageID() async throws {
    let transport = MockTransport(before: [.delta("Hi there!"), .complete(totalTokens: 3)], after: [])
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    await session.send("first")

    #expect(session.prepareEdit(messageID: UUID(), newText: "edited") == nil)
}

@MainActor
@Test func ensureThreadNeverCallsTheBackendCreateThreadEndpoint() async {
    let transport = MockTransport(before: [.complete(totalTokens: 0)], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("hi")
    // A locally-minted thread id is a real UUID — the old "thr-mock" sentinel
    // only ever came back from MockTransport.createThread, which nothing
    // calls anymore.
    #expect(UUID(uuidString: session.currentThreadID ?? "") != nil)
}

@MainActor
@Test func laterTurnsSendPriorHistoryAsContextInsteadOfNothing() async {
    let transport = MockTransport(before: [.delta("ok"), .complete(totalTokens: 1)], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("first")
    #expect(transport.receivedContext?.recentMessages.isEmpty == true, "nothing to send as context on the very first turn")

    await session.send("second")
    #expect(transport.receivedContext?.recentMessages.map(\.content) == ["first", "ok"])
    #expect(transport.receivedContext?.recentMessages.map(\.role) == ["user", "assistant"])
}

@MainActor
@Test func longThreadSummariesFoldIncrementallyAndPersistCursor() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    transport.summarizeReply = "summary one"
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("first new prompt")

    // No summary exists yet, so this turn's own context is the raw
    // unsummarized tail plus recent window, sent immediately (Task 7.1) —
    // it never waits on a fold.
    #expect(transport.receivedContext?.summary == "")
    #expect(transport.receivedContext?.recentMessages.map(\.content) == (0..<22).map { "message \($0)" })

    // The fold itself runs in the background, after this turn persists.
    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(transport.summarizeCalls.count == 1)
    #expect(transport.summarizeCalls[0].previous == "")
    #expect(transport.summarizeCalls[0].messages.map(\.content) == (0..<14).map { "message \($0)" })
    #expect(try store.aiThread(id: threadID)?.summary == "summary one")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 13)

    transport.summarizeReply = "summary two"
    await session.send("second new prompt")

    // Still the last *successful* summary — "summary two" only lands once
    // this turn's own background fold (below) completes.
    #expect(transport.receivedContext?.summary == "summary one")

    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq == 15 }
    #expect(transport.summarizeCalls.count == 2)
    #expect(transport.summarizeCalls[1].previous == "summary one")
    #expect(transport.summarizeCalls[1].messages.map(\.content) == ["message 14", "message 15"])
    #expect(try store.aiThread(id: threadID)?.summary == "summary two")
}

@MainActor
@Test func longThreadSummaryFoldExcludesInteractionMarkedRows() async throws {
    // Regression alongside buildContextExcludesInteractionMarkedRowsFromLaterUnrelatedTurns:
    // once a thread crosses summaryThreshold, the foldable prefix is sent
    // verbatim to transport.summarize() — an interaction-marked row must
    // never be part of that payload either.
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    transport.summarizeReply = "summary one"
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: seq == 4 ? "Which database?" : "message \(seq)",
            toolCalls: seq == 4 ? "local:interaction" : nil,
            createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("first new prompt")

    #expect(transport.receivedContext?.recentMessages.map(\.content).contains("Which database?") == false)

    try await waitUntil { transport.summarizeCalls.count == 1 }
    #expect(!transport.summarizeCalls[0].messages.map(\.content).contains("Which database?"))
}

@MainActor
@Test func summaryFailureKeepsPreviousSummaryAndCursor() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", summary: "known summary",
        summaryThroughSeq: 11, createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("new prompt")

    // Never waits on the fold — this turn's own context is the last
    // *successful* summary, sent immediately (Task 7.1).
    #expect(transport.receivedContext?.summary == "known summary")

    // transport.summarizeReply defaults to "" (a failed fold); the
    // background refresh must leave the previous summary/cursor untouched.
    try await waitUntil { transport.summarizeCalls.count == 1 }
    #expect(transport.summarizeCalls.first?.previous == "known summary")
    #expect(transport.summarizeCalls.first?.messages.map(\.content) == ["message 12", "message 13"])
    // Give the (no-op, since the fold "failed") write-back its chance to run
    // before asserting nothing changed.
    for _ in 0..<50 { await Task.yield() }
    #expect(try store.aiThread(id: threadID)?.summary == "known summary")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 11)
}

/// Task 7.1's core requirement: the summarize round trip must never sit on
/// the critical path of a turn. The mock's fold is gated and never released
/// during this test — if `buildContext` still awaited it inline, `send`
/// below would never return and the test would hang/time out instead of
/// completing.
@MainActor
@Test func summaryRefreshDoesNotBlockNextPostMessage() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    let gate = AsyncGate()
    transport.summarizeGate = gate
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("continue")

    #expect(!session.isStreaming)
    #expect(session.transcript.last?.text == "answer")
    #expect(transport.messageRequests.count == 1)

    await gate.release() // don't leak a permanently-suspended background task
}

/// Task 7.1: a stale background fold (started by an earlier turn, delayed —
/// e.g. a slow response) that completes *after* a later turn's own fold
/// already advanced the cursor must not move `summaryThroughSeq` backward,
/// or a slow response could silently regress the persisted summary.
@MainActor
@Test func overlappingSendsDoNotLetAnOutdatedSummaryResultClobberANewerCursor() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    let staleGate = AsyncGate()
    transport.summarizeGate = staleGate
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    // First turn's fold starts (target cursor 13) and is held open — a
    // stand-in for a slow response.
    await session.send("first new prompt")
    await staleGate.waitUntilEntered()

    // A second turn runs to completion, including its own (ungated) fold,
    // which reaches a newer cursor first.
    transport.summarizeGate = nil
    transport.summarizeReply = "summary from the second turn"
    await session.send("second new prompt")
    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq == 15 }
    #expect(try store.aiThread(id: threadID)?.summary == "summary from the second turn")

    // The stale first fold now returns — its target cursor (13) is older
    // than what's already stored (15), so it must be rejected.
    transport.summarizeReply = "stale summary from the first turn"
    await staleGate.release()

    for _ in 0..<50 { await Task.yield() }
    #expect(try store.aiThread(id: threadID)?.summary == "summary from the second turn")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 15)
}

/// Task 7.1: the fold is fired via an unstructured `Task { ... }`, not a
/// structured child of the turn that discovered it (the turn's own async
/// call has already returned by the time the fold is observable — that's
/// the whole point). Cancelling whatever drove that turn afterward (e.g. the
/// view's task tree going away) must not reach a fold already in flight.
@MainActor
@Test func summaryRefreshSurvivesCancellationOfItsOriginatingTurn() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    let gate = AsyncGate()
    transport.summarizeGate = gate
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    let outer = Task { await session.send("first new prompt") }
    await outer.value
    await gate.waitUntilEntered()
    outer.cancel()

    transport.summarizeReply = "summary despite cancellation"
    await gate.release()

    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(try store.aiThread(id: threadID)?.summary == "summary despite cancellation")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 13)
}

/// Task 7.1: `applySummaryFold` captures `store`/`transport` explicitly, not
/// `self` — so a fold already in flight keeps running even after the
/// `AISession` that scheduled it has no remaining references (app close).
@MainActor
@Test func summaryRefreshSurvivesTheSessionBeingDeallocated() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    let gate = AsyncGate()
    transport.summarizeGate = gate
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<22).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })

    do {
        let session = AISession(
            transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
            dialect: "postgres", schemaDigest: "d", store: store
        )
        session.loadThread(id: threadID.uuidString, turns: [])
        await session.send("first new prompt")
        await gate.waitUntilEntered()
    } // `session`'s last strong reference goes out of scope here.

    transport.summarizeReply = "summary after app close"
    await gate.release()

    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(try store.aiThread(id: threadID)?.summary == "summary after app close")
}

/// Task 7.1: if `previous summary + unsummarized tail + recent window`
/// would exceed the backend's hard context cap
/// (`AIConversationPolicy.contextMessageHardCap`/`contextByteHardCap`), the
/// turn must degrade explicitly — a visible marker, a bounded message count
/// — instead of quietly truncating, and the fold that would absorb the
/// dropped messages fires right away rather than waiting for this turn's
/// own (possibly failing) persist step.
@MainActor
@Test func oversizedUnsummarizedTailDegradesExplicitlyAndRefreshesUrgently() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    transport.summarizeReply = "urgent summary"
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    // Cursor is nil (never folded), so the whole foldable prefix becomes the
    // unsummarized tail — far more than fits under the hard cap.
    try seedActiveMessages(store, threadID: threadID, (0..<200).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("continue")

    // Degrades explicitly: the sent context says so instead of silently
    // dropping the oldest not-yet-summarized messages.
    #expect(transport.receivedContext?.summary.contains("omitted") == true)
    // Stays comfortably under the backend's 64-message hard cap.
    let sentCount = transport.receivedContext?.recentMessages.count ?? 0
    #expect(sentCount > 0 && sentCount < AIConversationPolicy.contextMessageHardCap)
    // The newest content is kept; the oldest is what gets dropped.
    #expect(transport.receivedContext?.recentMessages.contains { $0.content == "message 199" } == true)
    #expect(transport.receivedContext?.recentMessages.contains { $0.content == "message 0" } == false)

    // The urgent fold fires immediately rather than waiting on this turn's
    // own persist step.
    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(transport.summarizeCalls.count == 1)
    #expect(try store.aiThread(id: threadID)?.summary == "urgent summary")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 191)
}

/// perf plan (item A1): `buildContext`'s SQLite read must
/// overlap with a slow `resolveTools`/skill-rank round trip instead of
/// waiting for it — otherwise every send pays both latencies back to back
/// instead of just the slower of the two.
@MainActor
@Test func buildContextOverlapsWithSlowSkillRanking() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    transport.summarizeReply = "urgent summary"
    let gate = AsyncGate()
    transport.rankGate = gate // never released here — models a slow skill-rank round trip
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    // Cursor is nil, so buildContext's oversized-unsummarized-tail branch
    // fires an immediate summarize() call as a side effect of actually
    // running — a signal independent of whether resolveTools has resolved.
    try seedActiveMessages(store, threadID: threadID, (0..<200).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store,
        skills: FakeSkillRanker(),
        skillRankTimeout: .seconds(5)
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    let sendTask = Task { await session.send("continue") }

    // Proves buildContext ran — and its immediate summarize side effect
    // fired — while resolveTools is still stuck behind the never-released
    // rank gate. Before the fix, buildContext never even started until
    // toolsTask resolved, so this would hang until waitUntil's loop exhausts.
    try await waitUntil { transport.summarizeCalls.count == 1 }
    #expect(transport.summarizeCalls.count == 1)

    await gate.release()
    await sendTask.value
}

/// Task 7.1: the same explicit-degrade path also applies when the *byte
/// size* (not just the message count) of the unsummarized tail would exceed
/// the backend's 256 KiB context cap.
@MainActor
@Test func oversizedByteUnsummarizedTailAlsoDegradesExplicitly() async throws {
    let transport = MockTransport(before: [.delta("answer"), .complete(totalTokens: 1)], after: [])
    transport.summarizeReply = "urgent byte-bound summary"
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    let bigContent = String(repeating: "A", count: 15_000)
    try seedActiveMessages(store, threadID: threadID, (0..<30).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: seq < 22 ? bigContent : "short \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("continue")

    #expect(transport.receivedContext?.summary.contains("omitted") == true)
    // Well under the message-count cap, but bounded by total byte size.
    let sentCount = transport.receivedContext?.recentMessages.count ?? 0
    #expect(sentCount < AIConversationPolicy.contextMessageHardCap)
    let sentBytes = (transport.receivedContext?.recentMessages ?? [])
        .reduce(0) { $0 + $1.content.utf8.count }
    #expect(sentBytes < AIConversationPolicy.contextByteHardCap)

    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(try store.aiThread(id: threadID)?.summary == "urgent byte-bound summary")
}

/// Task 7.1: the urgent fold for an oversized tail must not depend on this
/// turn succeeding — otherwise a thread whose backlog is already too big to
/// send would never shrink it if the turn that discovered the problem also
/// happens to fail (e.g. a network error).
@MainActor
@Test func urgentRefreshRunsEvenWhenTheOversizedTurnItselfFails() async throws {
    let transport = MockTransport(before: [], after: [])
    transport.responseError = URLError(.networkConnectionLost)
    transport.summarizeReply = "urgent summary despite turn failure"
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    try seedActiveMessages(store, threadID: threadID, (0..<200).map { seq in
        AIMessageRecord(
            threadID: threadID, seq: seq,
            role: seq.isMultiple(of: 2) ? "user" : "assistant",
            content: "message \(seq)", createdAt: Date()
        )
    })
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("continue")

    // A network error now queues a silent retry instead of surfacing as
    // `lastError` (AISession's connectivity-retry handling) — this is still
    // "the turn itself failed" for this test's purposes (no reply text was
    // produced), just via the other signal.
    #expect(session.isWaitingForNetwork, "the turn itself failed")

    try await waitUntil { try store.aiThread(id: threadID)?.summaryThroughSeq != nil }
    #expect(try store.aiThread(id: threadID)?.summary == "urgent summary despite turn failure")
    #expect(try store.aiThread(id: threadID)?.summaryThroughSeq == 191)
}

@Test func decodesBackendInteractionWithoutTreatingItAsALocalTool() {
    let event = AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(
            args: [
                "question": "Which database?",
                "reason": "Target required",
                "choices": ["staging", "production"],
                "allow_free_text": true,
            ],
            origin: "subagent"
        )
    )

    #expect(event == .interactionRequired(AIInteraction(
        id: "i1",
        kind: .clarifyRequest,
        resumeToken: validInteractionToken,
        origin: .subagent,
        threadID: "thread-a",
        originThreadID: "thread-a-sub1",
        originPath: "root/sub1",
        parentThreadID: "thread-a",
        expiresAtUnix: 4_102_444_800,
        registryVersion: "2026-07-29",
        toolVersion: "1.0.0",
        schemaVersion: "1",
        question: "Which database?",
        reason: "Target required",
        choices: ["staging", "production"],
        allowFreeText: true
    )))
}

@MainActor
@Test func interactionWithoutAnOpaqueResumeTokenIsRejected() {
    let event = AIEvent.decode(
        event: "interaction.required",
        data: Data(#"{"call_id":"i1","kind":"clarify_request","args":{"question":"Which database?"}}"#.utf8)
    )
    #expect(event == .protocolError(code: "invalid_interaction_contract"))
}

@Test func interactionRejectsUnknownKindAndOriginInsteadOfGuessing() {
    #expect(AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(kind: "future_kind", args: [:])
    ) == .protocolError(code: "invalid_interaction_contract"))
    #expect(AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(origin: "future_origin")
    ) == .protocolError(code: "invalid_interaction_contract"))
}

@Test func interactionDecoderMatchesStrictBackendBoundsAndTypes() {
    let invalidArgs: [[String: Any]] = [
        ["question": "Q"],
        ["question": "Q", "reason": "R", "choices": ["1", "2", "3", "4", "5", "6"]],
        ["question": "Q", "reason": "R", "choices": ["ok", 7]],
        ["question": "Q", "reason": "R", "allow_free_text": "yes"],
        ["question": "Q", "reason": "R", "unexpected": true],
        ["question": "Q", "reason": "R", "proposed_answer": "blocked"],
    ]
    for args in invalidArgs {
        #expect(
            AIEvent.decode(
                event: "interaction.required",
                data: interactionWire(callID: "i", args: args)
            )
                == .protocolError(code: "invalid_interaction_contract")
        )
    }
    let oversizedQuestion = String(repeating: "q", count: 1_025)
    #expect(
        AIEvent.decode(
            event: "interaction.required",
            data: interactionWire(args: [
                "question": oversizedQuestion, "reason": "R",
            ])
        )
            == .protocolError(code: "invalid_interaction_contract")
    )

    for invalidToken in [
        "v1.primary.AAAA=",
        "v2.primary.\(String(repeating: "A", count: 64))",
        "v1.primary.\(String(repeating: "A", count: 63))",
        "v1..\(String(repeating: "A", count: 64))",
    ] {
        #expect(AIEvent.decode(
            event: "interaction.required",
            data: interactionWire(token: invalidToken)
        ) == .protocolError(code: "invalid_interaction_contract"))
    }

    // The envelope is exact: omitted, extra, or inconsistent lineage fields
    // are all terminal protocol violations.
    #expect(
        AIEvent.decode(
            event: "interaction.required",
            data: interactionWire(extra: ["unexpected": true])
        )
            == .protocolError(code: "invalid_interaction_contract")
    )
    #expect(AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(
            origin: "subagent", originThreadID: "thread-a-sub2",
            originPath: "root/sub1"
        )
    ) == .protocolError(code: "invalid_interaction_contract"))

    let reportWithUnknowns = AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(
            callID: "r", kind: "report_draft_ready",
            args: [
                "draft": "Clear report", "category": "ui",
                "severity": "medium", "unknowns": ["exact build"],
            ]
        )
    )
    #expect(reportWithUnknowns
        == .protocolError(code: "invalid_interaction_contract"))

    let report = AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(
            callID: "r", kind: "report_draft_ready",
            args: [
                "draft": "Clear report", "category": "ui",
                "severity": "medium", "unknowns": [],
            ]
        )
    )
    #expect(report == .interactionRequired(AIInteraction(
        id: "r", kind: .reportDraftReady,
        resumeToken: validInteractionToken, origin: .root,
        threadID: "thread-a", originThreadID: "thread-a",
        originPath: "root", parentThreadID: "thread-a",
        expiresAtUnix: 4_102_444_800,
        registryVersion: "2026-07-29", toolVersion: "1.0.0",
        schemaVersion: "1",
        draft: "Clear report", category: "ui", severity: "medium"
    )))

    #expect(
        AIEvent.decode(
            event: "interaction.required",
            data: interactionWire(
                callID: "r", kind: "report_draft_ready",
                args: [
                    "draft": "D",
                    "unknowns": (0..<9).map { "u\($0)" },
                ]
            )
        )
            == .protocolError(code: "invalid_interaction_contract")
    )
    let oversizedDraft = String(repeating: "d", count: 16 * 1_024 + 1)
    let oversizedUnknown = String(repeating: "u", count: 513)
    let invalidReportArgs: [[String: Any]] = [
        ["draft": ""],
        ["draft": oversizedDraft],
        ["draft": "D", "category": String(repeating: "c", count: 65)],
        ["draft": "D", "severity": String(repeating: "s", count: 33)],
        ["draft": "D", "unknowns": [oversizedUnknown]],
        ["draft": "D", "unknowns": [7]],
        ["draft": "D", "unexpected": true],
    ]
    for args in invalidReportArgs {
        #expect(
            AIEvent.decode(
                event: "interaction.required",
                data: interactionWire(
                    callID: "r", kind: "report_draft_ready", args: args
                )
            )
                == .protocolError(code: "invalid_interaction_contract")
        )
    }
}

// MARK: - report.draft / report.ready decoding (Task 11)

private let validReportReadyToken =
    "rr1.2026_07." + String(repeating: "A", count: 64)

private func reportDraftWire(
    callID: String = "report-1",
    draftDigest: Any = String(repeating: "b", count: 64),
    category: Any = "desktop",
    severity: Any = "high",
    policyVersion: Any = "1.0.0",
    registryVersion: Any = "2026-07-29",
    schemaVersion: Any = "1",
    threadID: Any = "thread-a",
    extra: [String: Any] = [:]
) -> Data {
    var object: [String: Any] = [
        "call_id": callID,
        "draft_digest": draftDigest,
        "category": category,
        "severity": severity,
        "policy_version": policyVersion,
        "registry_version": registryVersion,
        "schema_version": schemaVersion,
        "thread_id": threadID,
    ]
    object.merge(extra) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func reportReadyWire(
    callID: String = "report-1",
    token: Any = validReportReadyToken,
    draftDigest: Any = String(repeating: "b", count: 64),
    contextDigest: Any = NSNull(),
    includeContext: Any = false,
    category: Any = "desktop",
    severity: Any = "high",
    edited: Any = false,
    policyVersion: Any = "1.0.0",
    schemaVersion: Any = "1",
    registryVersion: Any = "2026-07-29",
    expiresAtUnix: Any = NSNumber(value: 4_102_444_800),
    threadID: Any = "thread-a",
    extra: [String: Any] = [:]
) -> Data {
    var object: [String: Any] = [
        "call_id": callID,
        "report_ready_token": token,
        "draft_digest": draftDigest,
        "context_digest": contextDigest,
        "include_context": includeContext,
        "category": category,
        "severity": severity,
        "edited": edited,
        "policy_version": policyVersion,
        "schema_version": schemaVersion,
        "registry_version": registryVersion,
        "expires_at_unix": expiresAtUnix,
        "thread_id": threadID,
    ]
    object.merge(extra) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Test func decodesReportDraftPreviewWithNullableCategoryAndSeverity() {
    let digest = String(repeating: "b", count: 64)
    let event = AIEvent.decode(event: "report.draft", data: reportDraftWire(draftDigest: digest))
    #expect(event == .reportDraft(AIReportDraftPreview(
        callID: "report-1", draftDigest: digest,
        category: "desktop", severity: "high",
        policyVersion: "1.0.0", registryVersion: "2026-07-29",
        schemaVersion: "1"
    )))

    let withoutClassification = AIEvent.decode(
        event: "report.draft",
        data: reportDraftWire(draftDigest: digest, category: NSNull(), severity: NSNull())
    )
    #expect(withoutClassification == .reportDraft(AIReportDraftPreview(
        callID: "report-1", draftDigest: digest,
        category: nil, severity: nil,
        policyVersion: "1.0.0", registryVersion: "2026-07-29",
        schemaVersion: "1"
    )))
}

@Test func reportDraftPreviewDecoderMatchesStrictBackendBoundsAndTypes() {
    // Not a lowercase-hex SHA-256.
    #expect(AIEvent.decode(event: "report.draft", data: reportDraftWire(draftDigest: "not-a-digest"))
        == .protocolError(code: "invalid_report_draft_contract"))
    #expect(AIEvent.decode(
        event: "report.draft",
        data: reportDraftWire(draftDigest: String(repeating: "B", count: 64))
    ) == .protocolError(code: "invalid_report_draft_contract"))
    // category/severity present but neither a string nor JSON null.
    #expect(AIEvent.decode(event: "report.draft", data: reportDraftWire(category: 7))
        == .protocolError(code: "invalid_report_draft_contract"))
    // Exact key set: an extra key is terminal, same as interaction.receipt.
    #expect(AIEvent.decode(
        event: "report.draft",
        data: reportDraftWire(extra: ["unexpected": true])
    ) == .protocolError(code: "invalid_report_draft_contract"))
    // A missing key is terminal too.
    var missingSeverity = (try! JSONSerialization.jsonObject(
        with: reportDraftWire()
    ) as! [String: Any])
    missingSeverity.removeValue(forKey: "severity")
    #expect(AIEvent.decode(
        event: "report.draft",
        data: try! JSONSerialization.data(withJSONObject: missingSeverity)
    ) == .protocolError(code: "invalid_report_draft_contract"))
}

@Test func decodesReportReadyGrantAsProposedAndWhenEdited() {
    let digest = String(repeating: "b", count: 64)
    let asProposed = AIEvent.decode(event: "report.ready", data: reportReadyWire(draftDigest: digest))
    #expect(asProposed == .reportReady(AIReportReadyGrant(
        callID: "report-1", reportReadyToken: validReportReadyToken,
        draftDigest: digest, contextDigest: nil, includeContext: false,
        category: "desktop", severity: "high", edited: false,
        policyVersion: "1.0.0", schemaVersion: "1",
        registryVersion: "2026-07-29", expiresAtUnix: 4_102_444_800
    )))

    let contextDigest = String(repeating: "c", count: 64)
    let editedWithContext = AIEvent.decode(
        event: "report.ready",
        data: reportReadyWire(
            draftDigest: digest, contextDigest: contextDigest,
            includeContext: true, edited: true
        )
    )
    #expect(editedWithContext == .reportReady(AIReportReadyGrant(
        callID: "report-1", reportReadyToken: validReportReadyToken,
        draftDigest: digest, contextDigest: contextDigest, includeContext: true,
        category: "desktop", severity: "high", edited: true,
        policyVersion: "1.0.0", schemaVersion: "1",
        registryVersion: "2026-07-29", expiresAtUnix: 4_102_444_800
    )))
}

@Test func reportReadyGrantDecoderMatchesStrictBackendBoundsAndTypes() {
    // include_context/context_digest must agree (present iff true).
    #expect(AIEvent.decode(
        event: "report.ready",
        data: reportReadyWire(contextDigest: String(repeating: "c", count: 64), includeContext: false)
    ) == .protocolError(code: "invalid_report_ready_contract"))
    #expect(AIEvent.decode(
        event: "report.ready",
        data: reportReadyWire(contextDigest: NSNull(), includeContext: true)
    ) == .protocolError(code: "invalid_report_ready_contract"))
    // The interaction resume token domain must never validate here — one
    // token can never be replayed as the other.
    #expect(AIEvent.decode(event: "report.ready", data: reportReadyWire(token: validInteractionToken))
        == .protocolError(code: "invalid_report_ready_contract"))
    #expect(AIEvent.decode(event: "report.ready", data: reportReadyWire(token: "rr2.kid.\(String(repeating: "A", count: 64))"))
        == .protocolError(code: "invalid_report_ready_contract"))
    #expect(AIEvent.decode(event: "report.ready", data: reportReadyWire(expiresAtUnix: NSNumber(value: 0)))
        == .protocolError(code: "invalid_report_ready_contract"))
    #expect(AIEvent.decode(
        event: "report.ready",
        data: reportReadyWire(extra: ["unexpected": true])
    ) == .protocolError(code: "invalid_report_ready_contract"))
}

@MainActor
@Test func malformedInteractionSurfacesProtocolErrorAndEndsTurn() async {
    let transport = MockTransport(
        before: [.protocolError(code: "invalid_interaction_contract")],
        after: []
    )
    let session = AISession(
        transport: transport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("inspect")

    #expect(!session.isStreaming)
    #expect(session.pendingClarification == nil)
    #expect(session.lastError == "invalid_interaction_contract")
}

@MainActor
@Test func clarificationSuspendsThenResumesInAFreshStatelessRequest() async throws {
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1",
            kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Which database?",
            reason: "Target required",
            choices: ["staging", "production"],
            allowFreeText: true
        ))],
        after: []
    )
    transport.resumeEvents = [.delta("Using staging."), .complete(totalTokens: 2)]
    transport.embedReply = Array(repeating: 0.1, count: BerryStore.aiMessageEmbeddingDimension)
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    await session.send("inspect it")

    #expect(session.pendingClarification?.question == "Which database?")
    #expect(session.isStreaming == false)
    #expect(session.isInteractionPending)
    #expect(!session.canChangeThread)
    #expect(transport.postedResults.isEmpty)
    #expect(transport.messageRequests.count == 1)
    let threadIDString = try #require(session.currentThreadID)
    let threadID = try #require(UUID(uuidString: threadIDString))
    let beforeResume = try store.aiMessages(threadID: threadID)
    #expect(beforeResume.map(\.role) == ["user", "assistant"])
    #expect(beforeResume.map(\.content) == ["inspect it", "Which database?"])
    #expect(beforeResume[1].toolCalls == "local:interaction")

    await session.resolveClarification(.answer("staging"))

    #expect(!session.isInteractionPending)
    #expect(session.canChangeThread)
    #expect(transport.messageRequests.count == 2)
    #expect(transport.messageRequests[1].text == "staging")
    #expect(transport.messageRequests[1].resume?.token
        == "AbCdEf0123456789AbCdEf0123456789")
    #expect(transport.messageRequests[1].resume?.action == .answered)
    #expect(UUID(uuidString:
        transport.messageRequests[1].resume?.clientRequestID ?? "") != nil)
    #expect(transport.messageRequests[1].resume?.requestDigest.count == 64)
    // "Which database?" is marked local:interaction — buildContext excludes
    // it (mirrors recentReportContext) so control-plane content never
    // resurfaces as conversational context, here or in any later turn.
    #expect(transport.messageRequests[1].context?.recentMessages.map(\.content) == [
        "inspect it",
    ])
    #expect(session.transcript.last?.text == "Using staging.")
    let persisted = try store.aiMessages(threadID: threadID)
    #expect(persisted.map(\.content) == [
        "inspect it", "Which database?", "staging", "Using staging.",
    ])
    #expect(persisted[2].toolCalls == "local:interaction")
    #expect(persisted[3].toolCalls == "local:interaction")
    #expect(!transport.embedInputs().contains("Which database?"))
    #expect(!transport.embedInputs().contains("staging"))
    #expect(!transport.embedInputs().contains("AbCdEf0123456789AbCdEf0123456789"))
}

/// Regression for a review finding on Task 4.1: a resolved interaction's
/// local:interaction rows were excluded from embedding but NOT from
/// `buildContext`, so once persisted (e.g. by the existing
/// resolveClarification/resumeInteraction path, or a Task 4.1 report
/// refinement that ran a mid-flight clarify_request) they could resurface
/// verbatim as context — and, past `summaryThreshold`, get folded into
/// `transport.summarize()` — for a later, wholly unrelated turn.
@MainActor
@Test func buildContextExcludesInteractionMarkedRowsFromLaterUnrelatedTurns() async throws {
    let transport = MockTransport(before: [.delta("ok"), .complete(totalTokens: 1)], after: [])
    let store = makeStore()
    let threadID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
    ))
    // Simulate an already-resolved clarify_request round, same shape
    // resolveClarification/resumeInteraction already persist.
    try seedActiveMessages(store, threadID: threadID, [
        AIMessageRecord(threadID: threadID, seq: 0, role: "user", content: "inspect it", createdAt: Date()),
        AIMessageRecord(
            threadID: threadID, seq: 1, role: "assistant", content: "Which database?",
            toolCalls: "local:interaction", createdAt: Date()
        ),
        AIMessageRecord(
            threadID: threadID, seq: 2, role: "user", content: "staging",
            toolCalls: "local:interaction", createdAt: Date()
        ),
        AIMessageRecord(
            threadID: threadID, seq: 3, role: "assistant", content: "Using staging.",
            toolCalls: "local:interaction", createdAt: Date()
        ),
    ])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: threadID.uuidString, turns: [])

    await session.send("what tables are there?")

    #expect(transport.receivedContext?.recentMessages.map(\.content) == ["inspect it"])
}

@MainActor
@Test func clarificationSupportsOnlyAnswerDeclineAndCancel() async throws {
    func makeInteractionTransport() -> MockTransport {
        let transport = MockTransport(
            before: [.interactionRequired(AIInteraction(
                id: "clarify-1",
                kind: .clarifyRequest,
                resumeToken: "AbCdEf0123456789AbCdEf0123456789",
                question: "Proceed with the default?",
                allowFreeText: true
            ))],
            after: []
        )
        transport.resumeEvents = [.delta("Done."), .complete(totalTokens: 1)]
        return transport
    }

    let answerTransport = makeInteractionTransport()
    let answerSession = AISession(
        transport: answerTransport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await answerSession.send("do it")
    await answerSession.resolveClarification(.answer("Use staging"))
    #expect(answerTransport.messageRequests[1].text == "Use staging")
    #expect(answerTransport.messageRequests[1].resume?.action == .answered)
    #expect(answerSession.transcript.contains { $0.text == "Use staging" })

    let declineTransport = makeInteractionTransport()
    let declineSession = AISession(
        transport: declineTransport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await declineSession.send("do it")
    await declineSession.resolveClarification(.decline(displayText: "Decline"))
    #expect(declineTransport.messageRequests[1].text.isEmpty)
    #expect(declineTransport.messageRequests[1].resume?.action == .declined)

    let cancelTransport = makeInteractionTransport()
    let cancelStore = makeStore()
    let cancelSession = AISession(
        transport: cancelTransport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: cancelStore
    )
    await cancelSession.send("do it")
    await cancelSession.resolveClarification(.cancel(displayText: "Cancel"))
    #expect(cancelSession.pendingClarification == nil)
    #expect(cancelTransport.messageRequests.count == 2)
    #expect(cancelTransport.messageRequests[1].resume?.action == .cancelled)
    let thread = try #require(cancelSession.currentThreadID)
    let messages = try cancelStore.aiMessages(threadID: #require(UUID(uuidString: thread)))
    #expect(messages.map(\.content).contains("Cancel"))
    #expect(!messages.contains { $0.content.contains("AbCdEf0123456789") })
}

@MainActor
@Test func pendingInteractionRestoresAfterAppRestartForItsExactThread() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("berrydb-ai-restart-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let rootID = UUID()
    var savedTurns: [AITurn] = []
    do {
        let store = try BerryStore(path: path)
        try store.saveAIThread(AIThreadRecord(
            id: rootID, dialect: "postgres",
            createdAt: Date(), updatedAt: Date()
        ))
        let transport = MockTransport(
            before: [.interactionRequired(interactionFixture(
                rootThreadID: rootID.uuidString
            ))],
            after: []
        )
        let session = AISession(
            transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
            dialect: "postgres", schemaDigest: "d", store: store
        )
        session.loadThread(id: rootID.uuidString, turns: [])
        await session.send("inspect")
        #expect(session.pendingClarification?.originPath == "root")
        #expect(try store.pendingAIInteraction(threadID: rootID) != nil)
        savedTurns = session.transcript
    }

    let reopenedStore = try BerryStore(path: path)
    let resumedTransport = MockTransport(before: [], after: [])
    resumedTransport.resumeEvents = [
        .delta("Using staging."), .complete(totalTokens: 1),
    ]
    let restored = AISession(
        transport: resumedTransport,
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: reopenedStore
    )
    restored.loadThread(id: rootID.uuidString, turns: savedTurns)

    #expect(restored.pendingClarification?.question == "Which database?")
    #expect(restored.pendingClarification?.originThreadID == rootID.uuidString)
    await restored.resolveClarification(.answer("staging"))
    #expect(resumedTransport.messageRequests.last?.resume?.token
        == validInteractionToken)
    #expect(try reopenedStore.pendingAIInteraction(threadID: rootID) == nil)
}

@MainActor
@Test func expiredAndWrongThreadInteractionsNeverRestore() throws {
    let store = makeStore()
    let rootID = UUID()
    let otherID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: rootID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    try store.saveAIThread(AIThreadRecord(
        id: otherID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    let args = #"{"question":"Which database?","reason":"Target required"}"#
    try store.savePendingAIInteraction(.init(
        id: "expired", threadID: rootID, kind: "clarify_request",
        argsJSON: args, resumeToken: validInteractionToken, origin: "root",
        originThreadID: rootID.uuidString, originPath: "root",
        parentThreadID: rootID.uuidString, expiresAtUnix: 1_999,
        registryVersion: "2026-07-29", toolVersion: "1.0.0",
        schemaVersion: "1",
        allowedActionsJSON: #"["answered","declined","cancelled"]"#,
        createdAt: Date(timeIntervalSince1970: 1_000)
    ))
    let wrongThreadSession = AISession(
        transport: MockTransport(before: [], after: []),
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store,
        now: { Date(timeIntervalSince1970: 1_500) }
    )
    wrongThreadSession.loadThread(id: otherID.uuidString, turns: [])
    #expect(wrongThreadSession.pendingClarification == nil)
    #expect(try store.pendingAIInteraction(threadID: rootID) != nil)

    wrongThreadSession.loadThread(id: rootID.uuidString, turns: [])
    #expect(wrongThreadSession.pendingClarification?.question == "Which database?")

    let expiredSession = AISession(
        transport: MockTransport(before: [], after: []),
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store,
        now: { Date(timeIntervalSince1970: 2_000) }
    )
    expiredSession.loadThread(id: rootID.uuidString, turns: [])
    #expect(expiredSession.pendingClarification == nil)
    #expect(expiredSession.controlDeliveryErrorLocalizationKey
        == "This AI request expired. Ask the agent to try again.")
    #expect(try store.pendingAIInteraction(threadID: rootID) == nil)
}

@MainActor
@Test func childClarificationUsesOneRootCardAndPreservesDeclineLineage() async throws {
    let store = makeStore()
    let rootID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: rootID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    let transport = MockTransport(before: [], after: [])
    transport.childEvents = [(
        threadID: "\(rootID.uuidString)-sub1",
        event: .interactionRequired(interactionFixture(
            rootThreadID: rootID.uuidString, childNumber: 1
        ))
    )]
    transport.resumeEvents = [.complete(totalTokens: 1)]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: rootID.uuidString, turns: [])
    await session.send("delegate")

    #expect(session.pendingClarification?.origin == .subagent)
    #expect(session.pendingClarification?.originPath == "root/sub1")
    #expect(session.pendingClarification?.originThreadID
        == "\(rootID.uuidString)-sub1")
    await session.resolveClarification(.decline(displayText: "Decline"))
    #expect(transport.messageRequests.last?.resume?.action == .declined)
    #expect(transport.messageRequests.last?.resume?.token
        == validInteractionToken)
    #expect(try store.pendingAIInteraction(threadID: rootID) == nil)
}

@MainActor
@Test func childClarificationCancelConsumesTheRootOwnedControlRow() async throws {
    let store = makeStore()
    let rootID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: rootID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    let transport = MockTransport(before: [], after: [])
    transport.childEvents = [(
        threadID: "\(rootID.uuidString)-sub2",
        event: .interactionRequired(interactionFixture(
            id: "child-cancel", rootThreadID: rootID.uuidString,
            childNumber: 2
        ))
    )]
    transport.resumeEvents = [.complete(totalTokens: 1)]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: rootID.uuidString, turns: [])
    await session.send("delegate")
    await session.resolveClarification(.cancel(displayText: "Cancel"))

    #expect(transport.messageRequests.last?.resume?.action == .cancelled)
    #expect(try store.pendingAIInteraction(threadID: rootID) == nil)
}

/// The real (merged) backend always tags `interaction.required`'s SSE
/// envelope `thread_id` with the ROOT thread's own id, even when a
/// sub-agent (depth 1) is the one asking `clarify_request` — there is
/// exactly one authoritative interaction card per root thread, so the
/// envelope never carries a distinct child thread id for this event type
/// (unlike `message.delta`/`tool.call`, which do tag with the emitting
/// agent's own id). Confirmed against
/// `berrydb-api/src/ai/gateway.rs`: `run_agent`'s depth-0
/// call seeds `interaction_thread_id = id_prefix` (the root's own id), and
/// both the `spawn_subagent` recursion and `resume_child_agent` forward
/// that same `interaction_thread_id` unchanged into the child's own
/// `run_agent_inner` call — so a depth-1 `emit(AgentEvent { thread_id:
/// interaction_thread_id, .. })` still carries the root's id. The
/// backend's own test
/// `child_clarification_suspends_with_an_exact_restart_safe_continuation`
/// asserts exactly this: `interactions[0].thread_id == "thr-root"` while
/// `data["origin_thread_id"] == "thr-root-sub0"` on the very same event.
/// A subagent-origin interaction therefore always decodes with
/// `originThreadID != tid` — the session must not require them to match.
@MainActor
@Test func subagentClarificationArrivingOnTheRootThreadEnvelopeIsAccepted() async throws {
    let store = makeStore()
    let rootID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: rootID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    guard let decoded = AIEvent.decode(
        event: "interaction.required",
        data: interactionWire(origin: "subagent", rootThreadID: rootID.uuidString)
    ), case .interactionRequired = decoded else {
        Issue.record("expected a decoded subagent interaction")
        return
    }
    // Delivered on the same envelope as the root's own turn (`before`), not
    // via `childEvents` (a distinct thread id) — that's how the real
    // backend actually sends it, per the doc comment above.
    let transport = MockTransport(before: [decoded], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: rootID.uuidString, turns: [])
    await session.send("delegate")

    #expect(session.lastError == nil)
    #expect(session.pendingClarification?.origin == .subagent)
    #expect(session.pendingClarification?.originPath == "root/sub1")
    #expect(session.pendingClarification?.originThreadID
        == "\(rootID.uuidString)-sub1")
}

@MainActor
@Test func deterministicPreReceiptFailureReturnsControlRowToPending() async throws {
    let store = makeStore()
    let rootID = UUID()
    try store.saveAIThread(AIThreadRecord(
        id: rootID, dialect: "postgres",
        createdAt: Date(), updatedAt: Date()
    ))
    let transport = MockTransport(
        before: [.interactionRequired(interactionFixture(
            rootThreadID: rootID.uuidString
        ))],
        after: []
    )
    transport.resumePreflightError = AITransportError.badResponse(
        statusCode: 429, message: "retry later"
    )
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    session.loadThread(id: rootID.uuidString, turns: [])
    await session.send("inspect")
    await session.resolveClarification(.answer("staging"))

    #expect(session.pendingClarification != nil)
    let persisted = try store.pendingAIInteraction(threadID: rootID)
    let record = try #require(persisted)
    #expect(record.state == "pending")
    #expect(record.selectedAction == "answered")
    #expect(record.responseText == "staging")
    let stableRequestID = try #require(record.clientRequestID)
    let stableDigest = try #require(record.requestDigest)

    transport.resumePreflightError = nil
    transport.resumeEvents = [.complete(totalTokens: 1)]
    await session.resolveClarification(.answer("staging"))
    #expect(transport.messageRequests.last?.resume?.clientRequestID
        == stableRequestID)
    #expect(transport.messageRequests.last?.resume?.requestDigest
        == stableDigest)
    #expect(try store.pendingAIInteraction(threadID: rootID) == nil)
}

@MainActor
@Test func ambiguousInteractionResumeIsAbandonedInsteadOfReplayed() async {
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1", kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Which database?"
        ))],
        after: []
    )
    transport.resumeError = AITransportError.badResponse(statusCode: 503, message: "retry")
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("inspect")

    await session.resolveClarification(.answer("staging"))

    #expect(session.pendingClarification == nil)
    #expect(!session.isInteractionPending)
    #expect(!session.isInteractionResolving)
    #expect(transport.messageRequests.count == 2)
    #expect(session.controlDeliveryErrorLocalizationKey
        == "Your response may have been received, so BerryDB will not send it again automatically.")
}

@MainActor
@Test func missingResumeReceiptIsTerminalAndCannotReplayTheToken() async {
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1", kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Which database?"
        ))],
        after: []
    )
    transport.omitResumeReceipt = true
    transport.resumeEvents = [.delta("must not be accepted")]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("inspect")

    await session.resolveClarification(.answer("staging"))

    #expect(session.pendingClarification == nil)
    #expect(transport.messageRequests.count == 2)
    #expect(!session.transcript.contains { $0.text == "must not be accepted" })
    #expect(session.controlDeliveryErrorLocalizationKey
        == "Your response may have been received, so BerryDB will not send it again automatically.")
}

@MainActor
@Test func composerQueuesAndThreadMutationIsBlockedDuringInteraction() async {
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1", kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Which database?"
        ))],
        after: []
    )
    transport.resumeEvents = [.delta("Resolved."), .complete(totalTokens: 1)]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("inspect")
    let originalThread = session.currentThreadID

    await session.send("queued follow-up")
    session.startNewThread()
    await session.openThread(UUID().uuidString)

    #expect(session.currentThreadID == originalThread)
    #expect(session.queuedMessages == ["queued follow-up"])
    #expect(!session.transcript.contains { $0.text == "queued follow-up" })
}

// MARK: - Editable canonical draft + report_ready_token bookkeeping (Task 11)

private let reportDraftText =
    "Opening the history panel shows an empty list after restart."

/// What `/v1/ai/summarize` hands back for the attachable scope (Task 12) —
/// the bytes the user reviews, consents to, and submits.
private let reportContextSummaryText =
    "The user reported that the history panel is empty after restart."

/// Advances a fresh session through `/report` → consent-to-refine → the
/// backend's canonical draft review (`report_draft_ready` +
/// `report.draft`), stopping right before the user confirms/declines —
/// exactly the state `AIPanelView`'s report card renders.
@MainActor
private func makeSessionWithReviewedReportDraft(
    text: String = reportDraftText,
    category: String? = "ui",
    severity: String? = "medium",
    resumeEvents: [AIEvent] = [],
    summaryReply: String = reportContextSummaryText,
    store: BerryStore = makeStore()
) async -> (session: AISession, transport: MockTransport, draftDigest: String) {
    let digest = AIRequestIntegrity.contentDigest(text)
    let transport = MockTransport(
        before: [
            .interactionRequired(AIInteraction(
                id: "report-1", kind: .reportDraftReady,
                resumeToken: "AbCdEf0123456789AbCdEf0123456789",
                draft: text, category: category, severity: severity
            )),
            .reportDraft(AIReportDraftPreview(
                callID: "report-1", draftDigest: digest,
                category: category, severity: severity,
                policyVersion: "1.0.0", registryVersion: "r1", schemaVersion: "1"
            )),
        ],
        after: []
    )
    transport.resumeEvents = resumeEvents
    transport.summarizeReply = summaryReply
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    // Seed one real exchange before /report runs — prepareReportContextSummary
    // now refuses to call /v1/ai/summarize over an empty scope (the backend
    // itself rejects an empty messages array), so attach-context tests need
    // an actual reportable message in the store, same as real usage always
    // has some prior conversation before /report is invoked.
    let threadID = UUID()
    let seedNow = Date()
    try? store.saveAIThread(AIThreadRecord(id: threadID, dialect: "postgres", createdAt: seedNow, updatedAt: seedNow))
    _ = try? seedActiveMessages(store, threadID: threadID, [
        AIMessageRecord(threadID: threadID, seq: 0, role: "user", content: "The history panel looks empty after restart.", createdAt: seedNow),
        AIMessageRecord(threadID: threadID, seq: 1, role: "assistant", content: "Let me check the local store for that thread.", createdAt: seedNow),
    ])
    session.loadThread(id: threadID.uuidString, turns: [])
    await session.send("/report \(text)")
    await session.resolveReportDraft(confirmed: true, attachContext: false)
    return (session, transport, digest)
}

private func readyGrant(
    draftDigest: String,
    includeContext: Bool = false,
    contextDigest: String? = nil,
    edited: Bool = false,
    expiresAtUnix: Int64 = 4_102_444_800,
    token: String = "rr1.kid.\(String(repeating: "A", count: 64))"
) -> AIEvent {
    .reportReady(AIReportReadyGrant(
        callID: "report-1", reportReadyToken: token,
        draftDigest: draftDigest, contextDigest: contextDigest,
        includeContext: includeContext, category: "ui", severity: "medium",
        edited: edited, policyVersion: "1.0.0", schemaVersion: "1",
        registryVersion: "r1", expiresAtUnix: expiresAtUnix
    ))
}

@MainActor
@Test func confirmingTheReviewedReportOnlyMintsAReadyTokenAndNeverAutoSubmits() async throws {
    let (session, transport, digest) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [readyGrant(draftDigest: AIRequestIntegrity.contentDigest(reportDraftText)), .delta("Noted."), .complete(totalTokens: 1)]
    )
    #expect(session.pendingReport?.description == reportDraftText)

    await session.resolveReport(confirmed: true, attachContext: false)

    // The load-bearing behavior change (Task 11): reaching readiness is not
    // submission. Still true now that submission exists (Task 12) — only the
    // explicit `submitConfirmedReport()` action reaches the endpoint.
    #expect(transport.reportSubmissions.isEmpty)
    #expect(session.reportSubmissionState == .idle)
    #expect(session.pendingReport == nil)
    #expect(session.confirmedReportDraft?.text == reportDraftText)
    #expect(session.reportReadyToken == "rr1.kid.\(String(repeating: "A", count: 64))")

    let resume = try #require(transport.messageRequests.last?.resume)
    #expect(resume.action == .accepted)
    #expect(resume.report?.draftDigest == digest)
    #expect(resume.report?.includeContext == false)
    #expect(resume.report?.contextDigest == nil)
}

@MainActor
@Test func editingTheReportDraftBeforeConfirmIsFreeAndLocalWithNoTokenMintedYet() async {
    let (session, transport, _) = await makeSessionWithReviewedReportDraft()

    session.updateReportDescription("\(reportDraftText) It also drops the sort order.")

    #expect(session.pendingReport?.description == "\(reportDraftText) It also drops the sort order.")
    #expect(session.reportReadyToken == nil)
    #expect(session.confirmedReportDraft == nil)
    #expect(transport.messageRequests.count == 1, "editing the draft must not touch the network")
}

@MainActor
@Test func decliningTheReviewedReportMintsNoTokenAndSubmitsNothing() async throws {
    let (session, transport, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [.delta("Understood."), .complete(totalTokens: 1)]
    )

    await session.resolveReport(confirmed: false, attachContext: false)

    #expect(session.pendingReport == nil)
    #expect(session.confirmedReportDraft == nil)
    #expect(session.reportReadyToken == nil)
    #expect(transport.reportSubmissions.isEmpty)
    let resume = try #require(transport.messageRequests.last?.resume)
    #expect(resume.action == .declined)
    #expect(resume.report == nil)
}

/// The core of Task 11: any edit after confirmation invalidates the token
/// immediately, and there is no separate "isReady" flag that could drift
/// from it — `reportReadyToken` recomputes the digest comparison on every
/// read, so reverting to the exact confirmed bytes makes it valid again
/// (the token is bound to content, not to a particular edit session).
@MainActor
@Test func editingTheConfirmedReportInvalidatesTheStoredTokenUntilTheTextMatchesAgain() async {
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [readyGrant(draftDigest: digest), .delta("Noted."), .complete(totalTokens: 1)]
    )
    await session.resolveReport(confirmed: true, attachContext: false)
    #expect(session.reportReadyToken != nil)

    session.updateConfirmedReportDraftText("\(reportDraftText) Edited.")
    #expect(session.reportReadyToken == nil, "an edited draft must never show a stale token as valid")

    session.updateConfirmedReportDraftText(reportDraftText)
    #expect(session.reportReadyToken != nil, "reverting to the exact confirmed bytes restores it")
}

@MainActor
@Test func changingAttachContextAfterConfirmAlsoInvalidatesTheStoredToken() async {
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [readyGrant(draftDigest: digest, includeContext: false), .delta("Noted."), .complete(totalTokens: 1)]
    )
    await session.resolveReport(confirmed: true, attachContext: false)
    #expect(session.reportReadyToken != nil)

    session.updateConfirmedReportDraftAttachContext(true)
    #expect(session.reportReadyToken == nil)

    session.updateConfirmedReportDraftAttachContext(false)
    #expect(session.reportReadyToken != nil)
}

/// The token's bound context digest is compared on every read (Task 11 fix
/// round, Important #1), but since Task 12 it is compared against the
/// digest of the *consented summary bytes*, not against a live recomputation
/// of the message scope. So ordinary conversation activity after confirming
/// no longer invalidates it — correctly: the user agreed to these exact
/// bytes, and these exact bytes are what submission sends. (Under the old
/// live-scope binding, a context-attached report could never have been
/// submitted at all: the backend re-derives `sha256(conversation_summary)`
/// and would refuse every one of them as a binding mismatch.)
@MainActor
@Test func ambientConversationActivityAfterConfirmLeavesTheConsentedScopeAndItsTokenIntact() async throws {
    let store = makeStore()
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let summaryDigest = AIRequestIntegrity.contentDigest(reportContextSummaryText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [
            readyGrant(draftDigest: digest, includeContext: true, contextDigest: summaryDigest),
            .delta("Noted."), .complete(totalTokens: 1),
        ],
        store: store
    )

    await session.prepareReportContextSummary()
    await session.resolveReport(confirmed: true, attachContext: true)
    #expect(session.reportReadyToken != nil)

    // A new, ordinary (non-report) message persisted to this thread after
    // confirming — nothing about the draft text or the toggle changes.
    let threadID = try #require(UUID(uuidString: session.currentThreadID ?? ""))
    try store.appendAIMessage(AIMessageRecord(
        threadID: threadID, seq: 99, role: "user",
        content: "one more thing", createdAt: Date()
    ))

    #expect(session.reportReadyToken != nil)
    #expect(
        session.confirmedReportDraft?.conversationSummary == reportContextSummaryText,
        "the consented scope is frozen at what the user reviewed, not re-derived later"
    )
}

/// The token binds the digest of the summary the user actually read. A
/// credential minted against any other scope — the shape the pre-Task-12
/// live-message binding produced — must read as invalid rather than be
/// spent on a submission the backend would refuse anyway.
@MainActor
@Test func aTokenBoundToAnyScopeOtherThanTheReviewedSummaryReadsAsInvalid() async {
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [
            readyGrant(
                draftDigest: digest, includeContext: true,
                contextDigest: AIRequestIntegrity.contentDigest("a different scope")
            ),
            .delta("Noted."), .complete(totalTokens: 1),
        ]
    )

    await session.prepareReportContextSummary()
    await session.resolveReport(confirmed: true, attachContext: true)

    #expect(session.confirmedReportDraft != nil)
    #expect(session.reportReadyToken == nil)
}

/// Review fix (Task 11 fix round, Important #2): `confirmedReportDraft`
/// (and the token it exposes) is bound to the thread it was minted on and
/// must not survive switching to a different conversation — `canChangeThread`
/// deliberately ignores it (confirming doesn't block the chat), so without
/// this the confirmed card/token from thread A would render under thread B.
@MainActor
@Test func loadingADifferentThreadClearsAConfirmedReportDraftAndItsToken() async throws {
    let store = makeStore()
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [readyGrant(draftDigest: digest), .delta("Noted."), .complete(totalTokens: 1)],
        store: store
    )
    await session.resolveReport(confirmed: true, attachContext: false)
    #expect(session.confirmedReportDraft != nil)
    #expect(session.reportReadyToken != nil)

    session.loadThread(id: UUID().uuidString, turns: [])

    #expect(session.confirmedReportDraft == nil)
    #expect(session.reportReadyToken == nil)
}

@MainActor
@Test func reportReadyTokenIsNilOnceItsExpiryHasPassed() async {
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, _, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [readyGrant(draftDigest: digest, expiresAtUnix: 1_000), .delta("Noted."), .complete(totalTokens: 1)]
    )

    await session.resolveReport(confirmed: true, attachContext: false)

    #expect(session.confirmedReportDraft?.text == reportDraftText)
    #expect(session.reportReadyToken == nil, "an expired grant must never appear as a valid token")
}

/// The human ruling for Task 12: what "attach recent conversation" means is
/// generated and *shown* before the user confirms, and the confirmation binds
/// the digest of exactly those bytes. Binding anything else (a live
/// message-scope digest, say) mints a credential the backend can never
/// accept, because it re-derives `sha256(conversation_summary)` from the
/// submitted bytes.
@MainActor
@Test func confirmingWithAttachContextBindsTheDigestOfTheSummaryTheUserWasShown() async throws {
    let store = makeStore()
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let expectedContextDigest = AIRequestIntegrity.contentDigest(reportContextSummaryText)
    let (session, transport, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [
            readyGrant(
                draftDigest: digest, includeContext: true,
                contextDigest: expectedContextDigest
            ),
            .delta("Noted."), .complete(totalTokens: 1),
        ],
        store: store
    )

    await session.prepareReportContextSummary()
    #expect(session.reportContextSummary == reportContextSummaryText)
    // One stateless `/v1/ai/summarize` fold over the attachable scope alone
    // — not a continuation of the thread's own rolling summary.
    #expect(transport.summarizeCalls.last?.previous == "")

    await session.resolveReport(confirmed: true, attachContext: true)

    let resume = try #require(transport.messageRequests.last?.resume)
    #expect(resume.report?.includeContext == true)
    #expect(resume.report?.contextDigest == expectedContextDigest)
    #expect(session.confirmedReportDraft?.conversationSummary == reportContextSummaryText)
}

/// Consent needs something to have been given to. Confirming with context
/// attached before the summary exists must not spend the one-shot review —
/// the card stays open so the user can still read the scope and decide.
@MainActor
@Test func confirmingWithAttachContextBeforeTheSummaryIsReadyRefusesWithoutSpendingTheReview() async {
    let digest = AIRequestIntegrity.contentDigest(reportDraftText)
    let (session, transport, _) = await makeSessionWithReviewedReportDraft(
        resumeEvents: [
            readyGrant(
                draftDigest: digest, includeContext: true,
                contextDigest: AIRequestIntegrity.contentDigest(reportContextSummaryText)
            ),
            .delta("Noted."), .complete(totalTokens: 1),
        ]
    )
    let requestsBefore = transport.messageRequests.count

    await session.resolveReport(confirmed: true, attachContext: true)

    #expect(transport.messageRequests.count == requestsBefore, "no resume may be sent")
    #expect(session.pendingReport != nil, "the review must stay open")
    #expect(session.confirmedReportDraft == nil)
    #expect(session.reportContextSummaryUnavailable)

    // Once the scope has been fetched and shown, the same action goes through.
    await session.prepareReportContextSummary()
    await session.resolveReport(confirmed: true, attachContext: true)
    #expect(session.reportReadyToken != nil)
}

/// A summarize call that comes back empty leaves nothing the user could have
/// read, so there is nothing to consent to — and no digest to bind.
@MainActor
@Test func anEmptyConversationSummaryBlocksConfirmingWithContextAttached() async {
    let (session, _, _) = await makeSessionWithReviewedReportDraft(summaryReply: "   ")

    await session.prepareReportContextSummary()

    #expect(session.reportContextSummary == nil)
    #expect(session.reportContextSummaryUnavailable)

    await session.resolveReport(confirmed: true, attachContext: true)
    #expect(session.confirmedReportDraft == nil)
}

/// The backend's /v1/ai/summarize flatly rejects an empty messages array
/// (400 empty_summary_messages) — reachable whenever the reportable window
/// is empty, e.g. a brand-new thread with no prior exchange. Confirms this
/// is treated as "nothing to summarize yet" without ever spending a network
/// round trip that would only fail the same way.
@MainActor
@Test func attachContextWithNoReportableHistorySkipsTheNetworkCallEntirely() async {
    let text = reportDraftText
    let digest = AIRequestIntegrity.contentDigest(text)
    let transport = MockTransport(
        before: [
            .interactionRequired(AIInteraction(
                id: "report-1", kind: .reportDraftReady,
                resumeToken: "AbCdEf0123456789AbCdEf0123456789",
                draft: text, category: "ui", severity: "medium"
            )),
            .reportDraft(AIReportDraftPreview(
                callID: "report-1", draftDigest: digest,
                category: "ui", severity: "medium",
                policyVersion: "1.0.0", registryVersion: "r1", schemaVersion: "1"
            )),
        ],
        after: []
    )
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    // Deliberately no seeded thread/messages — a genuinely fresh thread.
    await session.send("/report \(text)")
    await session.resolveReportDraft(confirmed: true, attachContext: false)

    await session.prepareReportContextSummary()

    #expect(session.reportContextSummary == nil)
    #expect(session.reportContextSummaryUnavailable)
    #expect(transport.summarizeCalls.isEmpty)
}

// MARK: - Report submission (Task 12)

/// Confirms a report and leaves it sitting on `confirmedReportDraft` with a
/// live token — the exact state the "Send Report" action operates on.
@MainActor
private func makeSessionWithConfirmedReport(
    attachContext: Bool = false,
    text: String = reportDraftText,
    expiresAtUnix: Int64 = 4_102_444_800
) async -> (session: AISession, transport: MockTransport) {
    let (session, transport, _) = await makeSessionWithReviewedReportDraft(
        text: text,
        resumeEvents: [
            readyGrant(
                draftDigest: AIRequestIntegrity.contentDigest(text),
                includeContext: attachContext,
                contextDigest: attachContext
                    ? AIRequestIntegrity.contentDigest(reportContextSummaryText) : nil,
                expiresAtUnix: expiresAtUnix
            ),
            .delta("Noted."), .complete(totalTokens: 1),
        ]
    )
    if attachContext { await session.prepareReportContextSummary() }
    await session.resolveReport(confirmed: true, attachContext: attachContext)
    return (session, transport)
}

/// The first task that submits anything: exactly the approved bytes, the
/// credential they were approved under, and a proof computed from those same
/// bytes — nothing separately supplied that could disagree with them.
@MainActor
@Test func sendingTheConfirmedReportSubmitsExactlyTheApprovedBytesUnderItsToken() async throws {
    let (session, transport) = await makeSessionWithConfirmedReport()

    await session.submitConfirmedReport()

    let submission = try #require(transport.reportSubmissions.first)
    #expect(transport.reportSubmissions.count == 1)
    #expect(submission.draft == reportDraftText)
    #expect(submission.reportReadyToken == "rr1.kid.\(String(repeating: "A", count: 64))")
    #expect(submission.callID == "report-1")
    #expect(submission.threadID == session.currentThreadID)
    #expect(!submission.includeContext)
    #expect(submission.conversationSummary == nil)
    // The backend's `client_request_id` bound: 16…128 of [A-Za-z0-9_-].
    #expect((16...128).contains(submission.clientRequestID.count))
    #expect(submission.clientRequestID.allSatisfy {
        $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
    })
    #expect(session.reportSubmissionState == .submitted(duplicate: false))
    #expect(session.confirmedReportDraft == nil, "a sent report leaves no re-sendable card")
}

/// The consented scope travels as the summary bytes the user read, and keeps
/// doing so even after the conversation has moved on — what was agreed to is
/// what is stored.
@MainActor
@Test func sendingWithContextAttachedSubmitsTheSummaryBytesTheUserConsentedTo() async throws {
    let (session, transport) = await makeSessionWithConfirmedReport(attachContext: true)

    await session.submitConfirmedReport()

    let submission = try #require(transport.reportSubmissions.first)
    #expect(submission.includeContext)
    #expect(submission.conversationSummary == reportContextSummaryText)
    // And the proof commits to those exact bytes, per the backend's formula.
    #expect(
        AIRequestIntegrity.reportSubmissionDigest(submission)
            != AIRequestIntegrity.reportSubmissionDigest(AIReportSubmission(
                threadID: submission.threadID, callID: submission.callID,
                reportReadyToken: submission.reportReadyToken,
                draft: submission.draft,
                conversationSummary: "something else entirely",
                clientRequestID: submission.clientRequestID
            ))
    )
}

/// No token, no submission. An edit after confirming invalidates the token
/// (Task 11), and nothing may reach the endpoint on the strength of a card
/// that merely looks confirmed.
@MainActor
@Test func sendingAReportWhoseTokenNoLongerMatchesNeverReachesTheEndpoint() async {
    let (session, transport) = await makeSessionWithConfirmedReport()
    session.updateConfirmedReportDraftText("\(reportDraftText) Edited after confirming.")

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.isEmpty)
    #expect(session.reportSubmissionState == .failed(.notReady))
}

/// The idempotent-retry contract: a dropped response is retried with the SAME
/// `client_request_id` and byte-identical payload, so a first attempt that
/// actually landed comes back as a duplicate instead of storing a second
/// report. A fresh id here would be a logically new submission and would be
/// refused with `409`.
@MainActor
@Test func aDroppedResponseIsRetriedWithTheSameIdempotencyKeyAndIdenticalBytes() async throws {
    let (session, transport) = await makeSessionWithConfirmedReport(attachContext: true)
    transport.reportSubmissionErrors = [URLError(.networkConnectionLost)]
    transport.reportSubmissionReceipts = [
        AIReportReceipt(submissionID: "sub-1", duplicate: true),
    ]

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.count == 2)
    let first = try #require(transport.reportSubmissions.first)
    let second = try #require(transport.reportSubmissions.last)
    #expect(first.clientRequestID == second.clientRequestID)
    #expect(first == second, "a retry must be byte-identical, not merely similar")
    // `duplicate: true` is the backend acknowledging it already stored this
    // exact submission — success, not an error.
    #expect(session.reportSubmissionState == .submitted(duplicate: true))
    #expect(session.confirmedReportDraft == nil)
}

/// A service still unavailable after the automatic retry stops there rather
/// than hammering it, and keeps the confirmed card *and its idempotency key*
/// so an explicit retry is still the same submission, not a second one.
@MainActor
@Test func aStillUnavailableServiceStopsAfterOneRetryAndKeepsTheSameIdempotencyKey() async throws {
    let (session, transport) = await makeSessionWithConfirmedReport()
    transport.reportSubmissionErrors = [
        AIReportSubmissionError.unavailable(reason: "report_receipt_unavailable"),
        AIReportSubmissionError.unavailable(reason: "report_storage_unavailable_unrecoverable"),
    ]

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.count == 2)
    #expect(session.reportSubmissionState == .failed(.unavailable))
    #expect(session.confirmedReportDraft != nil, "a retryable failure must keep the card")

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.count == 3)
    #expect(
        Set(transport.reportSubmissions.map(\.clientRequestID)).count == 1,
        "an explicit retry is the same submission, so it reuses the same key"
    )
    #expect(session.reportSubmissionState == .submitted(duplicate: false))
}

/// The refusals that mean "this client built the request wrong" or "this
/// confirmation is spent" are never retried: identical bytes fail identically,
/// and a blind retry would only turn one wrong answer into two.
@MainActor
@Test func nonRetryableRefusalsAreSurfacedWithoutASecondAttempt() async {
    for (refusal, expected) in [
        (AIReportSubmissionError.alreadySubmitted, AISession.ReportSubmissionFailure.alreadySubmitted),
        (.refinementRequired, .clientError),
        (.malformedSubmission(code: "invalid_report_submission"), .clientError),
        (.tooLarge, .tooLarge),
    ] as [(AIReportSubmissionError, AISession.ReportSubmissionFailure)] {
        let (session, transport) = await makeSessionWithConfirmedReport()
        transport.reportSubmissionErrors = [refusal]

        await session.submitConfirmedReport()

        #expect(transport.reportSubmissions.count == 1, "\(refusal) must not be retried")
        #expect(session.reportSubmissionState == .failed(expected))
        #expect(session.confirmedReportDraft != nil)
    }
}

/// A dead credential can't be spent, and the local card must stop claiming
/// otherwise — it is the only thing still asserting readiness at that point.
@MainActor
@Test func aRefusedCredentialClearsTheConfirmedCardAndAsksForReconfirmation() async {
    for (reason, expected) in [
        ("control_token_expired", AISession.ReportSubmissionFailure.reviewExpired),
        ("control_binding_mismatch", .notReady),
        ("control_token_unknown", .notReady),
    ] as [(String, AISession.ReportSubmissionFailure)] {
        let (session, transport) = await makeSessionWithConfirmedReport()
        transport.reportSubmissionErrors = [AIReportSubmissionError.notReady(reason: reason)]

        await session.submitConfirmedReport()

        #expect(transport.reportSubmissions.count == 1)
        #expect(session.reportSubmissionState == .failed(expected))
        #expect(session.confirmedReportDraft == nil)
        #expect(session.reportReadyToken == nil)
    }
}

/// Double-submit: the second tap has nothing left to send, and must not open
/// a second submission on the strength of stale state.
@MainActor
@Test func sendingAnAlreadySentReportAgainDoesNothing() async {
    let (session, transport) = await makeSessionWithConfirmedReport()

    await session.submitConfirmedReport()
    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.count == 1)
    #expect(session.reportSubmissionState == .submitted(duplicate: false))
}

/// Pre-checked locally instead of spending a round trip to be told `413`.
@MainActor
@Test func anOversizedDraftIsRefusedLocallyInsteadOfBeingSent() async {
    let oversized = String(repeating: "a", count: AIReportPolicy.maxDraftBytes + 1)
    let (session, transport) = await makeSessionWithConfirmedReport(text: oversized)

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.isEmpty)
    #expect(session.reportSubmissionState == .failed(.tooLarge))
}

/// An expired credential is refused before the network sees it — the same
/// live check that greys out the button (Task 11), enforced in the action too.
@MainActor
@Test func sendingAReportWhoseReviewHasAlreadyExpiredNeverReachesTheEndpoint() async {
    let (session, transport) = await makeSessionWithConfirmedReport(expiresAtUnix: 1_000)

    await session.submitConfirmedReport()

    #expect(transport.reportSubmissions.isEmpty)
    #expect(session.reportSubmissionState == .failed(.notReady))
}

/// Coverage gap flagged in the Task 11 fix round: every other report test
/// raises `report_draft_ready` on a fresh, non-resume turn. The
/// `pendingSuspendedInteraction` stash-and-keep-draining logic in
/// `streamTurn` doesn't special-case `resume`, so this should already work
/// unchanged — a clarification round first, then the model raising
/// `report_draft_ready` on the very turn that resumes it.
@MainActor
@Test func reportDraftReadyArrivingOnAResumedClarificationTurnIsHandledTheSameWayAsOnAFreshTurn() async throws {
    let text = "The export button does nothing on macOS 14."
    let digest = AIRequestIntegrity.contentDigest(text)
    let transport = MockTransport(
        before: [.interactionRequired(AIInteraction(
            id: "clarify-1", kind: .clarifyRequest,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            question: "Which OS version?"
        ))],
        after: []
    )
    transport.resumeEvents = [
        .interactionRequired(AIInteraction(
            id: "report-1", kind: .reportDraftReady,
            resumeToken: "AbCdEf0123456789AbCdEf0123456789",
            draft: text, category: "ui", severity: "medium"
        )),
        .reportDraft(AIReportDraftPreview(
            callID: "report-1", draftDigest: digest,
            category: "ui", severity: "medium",
            policyVersion: "1.0.0", registryVersion: "r1", schemaVersion: "1"
        )),
    ]
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("please file a report")
    #expect(session.pendingClarification?.question == "Which OS version?")

    await session.resolveClarification(.answer("macOS 14"))

    #expect(session.pendingClarification == nil)
    #expect(session.pendingReport?.description == text)
}

@MainActor
@Test func malformedReportDraftDigestMismatchFailsClosedInsteadOfBeingIgnored() async {
    let transport = MockTransport(
        before: [
            .interactionRequired(AIInteraction(
                id: "report-1", kind: .reportDraftReady,
                resumeToken: "AbCdEf0123456789AbCdEf0123456789",
                draft: reportDraftText, category: "ui", severity: "medium"
            )),
            .reportDraft(AIReportDraftPreview(
                callID: "report-1",
                draftDigest: String(repeating: "0", count: 64),
                category: "ui", severity: "medium",
                policyVersion: "1.0.0", registryVersion: "r1", schemaVersion: "1"
            )),
        ],
        after: []
    )
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("/report \(reportDraftText)")
    await session.resolveReportDraft(confirmed: true, attachContext: false)

    #expect(session.pendingReport == nil)
    #expect(session.lastError == "report_draft_digest_mismatch")
}

@MainActor
@Test func reportRefinementTurnEndingInAnErrorLeavesNoPendingReportOrConfirmedDraft() async {
    let transport = MockTransport(
        before: [.error(code: "provider_unavailable", message: "The model is unavailable.")],
        after: []
    )
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )

    await session.send("/report \(reportDraftText)")
    await session.resolveReportDraft(confirmed: true, attachContext: false)

    #expect(session.pendingReport == nil)
    #expect(session.confirmedReportDraft == nil)
    #expect(session.reportReadyToken == nil)
    #expect(session.lastError == "The model is unavailable.")
}

@MainActor
@Test func reportSlashCommandMakesNoNetworkCallBeforeConsent() async throws {
    let transport = MockTransport(before: [.delta("ok"), .complete(totalTokens: 1)], after: [])
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )

    await session.send("/report Filters silently reset on reconnect.")

    #expect(session.pendingReportDraft?.text == "Filters silently reset on reconnect.")
    #expect(session.pendingReportDraft?.attachContext == true)
    #expect(session.isInteractionPending)
    #expect(transport.messageRequests.isEmpty)
    #expect(transport.reportSubmissions.isEmpty)
    #expect(session.transcript.isEmpty)

    let threadID = try #require(UUID(uuidString: session.currentThreadID ?? ""))
    #expect(try store.pendingReportDraft(threadID: threadID)?.text == "Filters silently reset on reconnect.")
    #expect(try store.aiMessages(threadID: threadID).isEmpty)
}

@MainActor
@Test func reportDraftDeclineDeletesTheLocalDraftWithNoReportCall() async throws {
    let transport = MockTransport(before: [], after: [])
    let store = makeStore()
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: store
    )
    await session.send("/report Something is broken.")
    let threadID = try #require(UUID(uuidString: session.currentThreadID ?? ""))

    await session.resolveReportDraft(confirmed: false, attachContext: true)

    #expect(session.pendingReportDraft == nil)
    #expect(!session.isInteractionPending)
    #expect(transport.messageRequests.isEmpty)
    #expect(transport.reportSubmissions.isEmpty)
    #expect(try store.pendingReportDraft(threadID: threadID) == nil)
}

@MainActor
@Test func reportDraftAttachContextOffSendsNoLocalContextToTheRefinementTurn() async throws {
    let transport = MockTransport(before: [.delta("Got it."), .complete(totalTokens: 1)], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    // A prior turn so there's something a naive implementation could leak.
    await session.send("hello")
    await session.send("/report Something is broken.")
    #expect(session.pendingReportDraft?.attachContext == true)

    session.updateReportDraftAttachContext(false)
    #expect(session.pendingReportDraft?.attachContext == false)

    await session.resolveReportDraft(confirmed: true, attachContext: false)

    #expect(transport.messageRequests.last?.context?.recentMessages.isEmpty == true)
    #expect(transport.messageRequests.last?.context?.summary.isEmpty == true)
}

@MainActor
@Test func reportDraftAttachContextOnSendsRecentConversationToTheRefinementTurn() async throws {
    let transport = MockTransport(before: [.delta("Got it."), .complete(totalTokens: 1)], after: [])
    let session = AISession(
        transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    await session.send("hello")
    await session.send("/report Something is broken.")

    await session.resolveReportDraft(confirmed: true, attachContext: true)

    #expect(transport.messageRequests.last?.context?.recentMessages.map(\.content) == ["hello", "Got it."])
}

@MainActor
@Test func pendingReportDraftSurvivesRestartAndReappearsOnReopen() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("berrydb-report-draft-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var threadIDString = ""
    var savedTurns: [AITurn] = []
    do {
        let store = try BerryStore(path: path)
        let transport = MockTransport(before: [], after: [])
        let session = AISession(
            transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
            dialect: "postgres", schemaDigest: "d", store: store
        )
        await session.send("/report Crashes when exporting CSV.")
        threadIDString = try #require(session.currentThreadID)
        savedTurns = session.transcript
    }

    let reopenedStore = try BerryStore(path: path)
    let resumedTransport = MockTransport(before: [], after: [])
    let restored = AISession(
        transport: resumedTransport, executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: reopenedStore
    )
    restored.loadThread(id: threadIDString, turns: savedTurns)

    #expect(restored.pendingReportDraft?.text == "Crashes when exporting CSV.")
    #expect(resumedTransport.messageRequests.isEmpty)
}

@MainActor
@Test func deletedReportDraftDoesNotReappearAfterRestart() async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("berrydb-report-draft-deleted-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }
    var threadIDString = ""
    var savedTurns: [AITurn] = []
    do {
        let store = try BerryStore(path: path)
        let transport = MockTransport(before: [], after: [])
        let session = AISession(
            transport: transport, executor: SchemaExecutor(outcome: .ok("{}")),
            dialect: "postgres", schemaDigest: "d", store: store
        )
        await session.send("/report Crashes when exporting CSV.")
        threadIDString = try #require(session.currentThreadID)
        await session.resolveReportDraft(confirmed: false, attachContext: true)
        savedTurns = session.transcript
    }

    let reopenedStore = try BerryStore(path: path)
    let restored = AISession(
        transport: MockTransport(before: [], after: []),
        executor: SchemaExecutor(outcome: .ok("{}")),
        dialect: "postgres", schemaDigest: "d", store: reopenedStore
    )
    restored.loadThread(id: threadIDString, turns: savedTurns)

    #expect(restored.pendingReportDraft == nil)
    let threadID = try #require(UUID(uuidString: threadIDString))
    #expect(try reopenedStore.pendingReportDraft(threadID: threadID) == nil)
}

@MainActor
@Test func onDeviceSessionUsesALocalCapabilitySnapshotForSafeTools() async {
    let executor = CapabilityExecutor(toolSpecs: [
        AIToolSpec(
            name: "get_schema", description: "Schema",
            parametersJSON: #"{"type":"object"}"#
        ),
    ])
    let session = AISession(
        transport: MockTransport(before: [], after: []),
        executor: LocalCapabilityHost(executor: executor),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    let provider = SessionScriptedLocal([
        #"{"tool":"get_schema","args":{}}"#,
        "One table.",
    ])

    await session.sendLocal("what tables?", provider: provider)

    #expect(executor.calls.map(\.name) == ["get_schema"])
    #expect(session.transcript.last?.text == "One table.")
    #expect(session.requiresClientUpdate == false)
}

@MainActor
@Test func onDeviceSessionLeaseFailsClosedWhenCapabilitiesInvalidate() async {
    let executor = InvalidatingCapabilityExecutor()
    let session = AISession(
        transport: MockTransport(before: [], after: []),
        executor: LocalCapabilityHost(executor: executor),
        dialect: "postgres", schemaDigest: "d", store: makeStore()
    )
    let provider = SessionScriptedLocal([
        #"{"tool":"get_schema","args":{}}"#,
        "Could not use the stale capability.",
    ])

    await session.sendLocal("what tables?", provider: provider)

    #expect(executor.committedCalls == 0)
    #expect(session.transcript.last?.text == "what tables?")
    #expect(session.requiresClientUpdate)
    #expect(session.lastError != nil)
}
