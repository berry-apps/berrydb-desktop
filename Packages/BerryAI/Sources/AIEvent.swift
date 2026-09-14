import CoreFoundation
import Foundation

/// A negotiated local-capability call delivered to the desktop
/// Backend-owned tools and interactions are handled
/// by AgentHarness on the server; only authorization-stamped local calls reach
/// the desktop executor, where DangerGuard and approval still apply.
public struct AIToolCall: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Opaque one-shot dispatch grant minted by the backend. It is control
    /// state only and must never enter logs, chat, embeddings, or search.
    public let dispatchNonce: String?
    /// Shallow scalar arguments, stringified (e.g. run_sql → ["sql": "..."]).
    public let args: [String: String]
    public let registryVersion: String?
    public let toolVersion: String?
    public let schemaVersion: String?
    public let risk: String?
    public let approval: String?
    public let capabilitySetDigest: String?

    public init(
        id: String,
        name: String,
        args: [String: String],
        dispatchNonce: String? = nil,
        registryVersion: String? = nil,
        toolVersion: String? = nil,
        schemaVersion: String? = nil,
        risk: String? = nil,
        approval: String? = nil,
        capabilitySetDigest: String? = nil
    ) {
        self.id = id
        self.name = name
        self.dispatchNonce = dispatchNonce
        self.args = args
        self.registryVersion = registryVersion
        self.toolVersion = toolVersion
        self.schemaVersion = schemaVersion
        self.risk = risk
        self.approval = approval
        self.capabilitySetDigest = capabilitySetDigest
    }
}

/// A decoded gateway event tagged with the thread it belongs to
/// The root thread is the conversation; any
/// other id is a sub-agent spawned by the backend.
public struct AIStreamEvent: Sendable, Equatable {
    public let threadID: String?
    public let event: AIEvent

    public init(threadID: String?, event: AIEvent) {
        self.threadID = threadID
        self.event = event
    }
}

public struct AIInteraction: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case clarifyRequest = "clarify_request"
        case reportDraftReady = "report_draft_ready"
    }

    public enum Origin: String, Equatable, Sendable {
        case root
        case subagent
    }

    public let id: String
    public let kind: Kind
    /// Opaque, single-interaction continuation nonce. It is transport state,
    /// never display text or conversation content.
    public let resumeToken: String
    public let origin: Origin
    /// Root chat thread that owns the one visible interaction card.
    public let threadID: String
    /// Exact stream/thread that requested the interaction.
    public let originThreadID: String
    /// Authenticated lineage (`root` or `root/subN`).
    public let originPath: String
    public let parentThreadID: String
    public let expiresAtUnix: Int64
    public let registryVersion: String
    public let toolVersion: String
    public let schemaVersion: String
    public let question: String?
    public let reason: String?
    public let choices: [String]
    public let allowFreeText: Bool
    public let draft: String?
    public let category: String?
    public let severity: String?
    public let unknowns: [String]

    public init(
        id: String,
        kind: Kind,
        resumeToken: String,
        origin: Origin = .root,
        threadID: String = "",
        originThreadID: String = "",
        originPath: String = "root",
        parentThreadID: String = "",
        expiresAtUnix: Int64 = .max,
        registryVersion: String = "",
        toolVersion: String = "",
        schemaVersion: String = "",
        question: String? = nil,
        reason: String? = nil,
        choices: [String] = [],
        allowFreeText: Bool = true,
        draft: String? = nil,
        category: String? = nil,
        severity: String? = nil,
        unknowns: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.resumeToken = resumeToken
        self.origin = origin
        self.threadID = threadID
        self.originThreadID = originThreadID
        self.originPath = originPath
        self.parentThreadID = parentThreadID
        self.expiresAtUnix = expiresAtUnix
        self.registryVersion = registryVersion
        self.toolVersion = toolVersion
        self.schemaVersion = schemaVersion
        self.question = question
        self.reason = reason
        self.choices = choices
        self.allowFreeText = allowFreeText
        self.draft = draft
        self.category = category
        self.severity = severity
        self.unknowns = unknowns
    }
}

public struct AIInteractionReceipt: Equatable, Sendable {
    public let receiptID: String
    public let clientRequestID: String
    public let requestDigest: String
    public let duplicate: Bool
    public let threadID: String

    public init(
        receiptID: String,
        clientRequestID: String,
        requestDigest: String,
        duplicate: Bool,
        threadID: String
    ) {
        self.receiptID = receiptID
        self.clientRequestID = clientRequestID
        self.requestDigest = requestDigest
        self.duplicate = duplicate
        self.threadID = threadID
    }
}

/// The `report.draft` SSE event (Task 11): a digest-only
/// preview emitted immediately after the `interaction.required` envelope for
/// a `report_draft_ready` interaction, so the client can verify its own
/// digest rule (SHA-256 over exact UTF-8 bytes) hashes the draft the same
/// way the backend did, before the user ever reviews or confirms it. Carries
/// no token and no report content.
public struct AIReportDraftPreview: Equatable, Sendable {
    public let callID: String
    public let draftDigest: String
    public let category: String?
    public let severity: String?
    public let policyVersion: String
    public let registryVersion: String
    public let schemaVersion: String

    public init(
        callID: String,
        draftDigest: String,
        category: String? = nil,
        severity: String? = nil,
        policyVersion: String,
        registryVersion: String,
        schemaVersion: String
    ) {
        self.callID = callID
        self.draftDigest = draftDigest
        self.category = category
        self.severity = severity
        self.policyVersion = policyVersion
        self.registryVersion = registryVersion
        self.schemaVersion = schemaVersion
    }
}

/// The `report.ready` SSE event (Task 11): emitted on the
/// turn that resumes a `report_draft_ready` interaction with `action:
/// "accepted"` — the only place a `report_ready_token` is minted. Absent
/// from a turn entirely means nothing was issued (declined, cancelled, or
/// not a report interaction). The token itself contains no report content.
public struct AIReportReadyGrant: Equatable, Sendable {
    public let callID: String
    public let reportReadyToken: String
    public let draftDigest: String
    public let contextDigest: String?
    public let includeContext: Bool
    public let category: String?
    public let severity: String?
    public let edited: Bool
    public let policyVersion: String
    public let schemaVersion: String
    public let registryVersion: String
    public let expiresAtUnix: Int64

    public init(
        callID: String,
        reportReadyToken: String,
        draftDigest: String,
        contextDigest: String? = nil,
        includeContext: Bool,
        category: String? = nil,
        severity: String? = nil,
        edited: Bool,
        policyVersion: String,
        schemaVersion: String,
        registryVersion: String,
        expiresAtUnix: Int64
    ) {
        self.callID = callID
        self.reportReadyToken = reportReadyToken
        self.draftDigest = draftDigest
        self.contextDigest = contextDigest
        self.includeContext = includeContext
        self.category = category
        self.severity = severity
        self.edited = edited
        self.policyVersion = policyVersion
        self.schemaVersion = schemaVersion
        self.registryVersion = registryVersion
        self.expiresAtUnix = expiresAtUnix
    }
}

/// The payload of a `message.delta` SSE event (Task 13,
/// `text` is always present; the
/// round/segmentID/provisional metadata is additive and only sent by
/// backends that support round-boundary detection — old/local providers
/// leave them nil. `ExpressibleByStringLiteral` lets the ~35 pre-existing
/// `.delta("...")` call sites in BerryAITests keep compiling unchanged,
/// with the metadata defaulting to nil exactly as a legacy provider's
/// payload would decode.
public struct AIEventDelta: Equatable, Sendable, ExpressibleByStringLiteral {
    public let text: String
    /// The executor's round-loop counter (0-based). Stable for every delta
    /// within one round; increments for a new round of the same agent.
    public let round: Int?
    /// `"{agent_instance_id}-r{round}"`. Stable within a round, changes
    /// across rounds, and unique across a parent and its sub-agents even
    /// at the same numeric `round`.
    public let segmentID: String?
    /// Always `true`, unconditionally, on every delta from every round —
    /// including the round that turns out to be the final one. The backend
    /// does not predict which round ends in `tool.call` vs.
    /// `message.complete`, so this field alone can never decide what's
    /// committed; round-boundary tracking in `AISession.streamTurn` does
    /// that instead (task-13-context.md).
    public let provisional: Bool?

    public init(text: String, round: Int? = nil, segmentID: String? = nil, provisional: Bool? = nil) {
        self.text = text
        self.round = round
        self.segmentID = segmentID
        self.provisional = provisional
    }

    public init(stringLiteral value: String) {
        self.init(text: value)
    }
}

/// One parsed SSE event from the AI gateway.
public enum AIEvent: Equatable, Sendable {
    /// Per-response transport signal derived from the authenticated HTTP
    /// response, never from model-controlled SSE payload.
    case capabilityMode(AICapabilityTransportMode)
    case delta(AIEventDelta)
    /// A reasoning-mode provider's internal chain-of-thought for the current
 /// round (2026-08-03) — real progress the model
    /// is generating regardless, forwarded so the UI has something to show
    /// during a round that narrates nothing else. Same round/segmentID
    /// shape as `delta`, no `provisional` field (reasoning is never the
    /// committed answer).
    case reasoning(AIEventDelta)
 /// A streamed piece of the optional planner pass.
    case plan(String)
    /// One sentence of narration from the backend's `note_progress` tool
 /// what the model is about to do, on its own channel.
    ///
    /// The channel is the point. Narration used to arrive as `message.delta`
    /// alongside the answer, so the client could not tell them apart: it showed
    /// narration in the response bubble until a round boundary moved it into a
    /// sub-block, and the only way to hide that was to withhold the bubble until
    /// the turn finished — which cost streaming. With narration separated,
    /// `.delta` is unambiguously the answer.
    case progressNote(String)
    /// A streaming fragment of a tool argument (e.g. the `sql` arg of `propose_sql`).
    /// Lets the client mirror the query into the editor tab in real-time.
    case toolArgDelta(name: String, argDelta: String)
    case capabilitiesAccepted(AICapabilityAcceptance)
    case toolCall(AIToolCall)
    case interactionRequired(AIInteraction)
    case interactionReceipt(AIInteractionReceipt)
    /// Digest-only preview of a `report_draft_ready` draft (Task 11).
    case reportDraft(AIReportDraftPreview)
    /// The signed `report_ready_token` grant for an accepted report review (Task 11).
    case reportReady(AIReportReadyGrant)
    /// A known control-plane event failed strict validation. Unlike an
    /// unknown future SSE name, this must be surfaced so a suspended backend
    /// request is cancelled instead of silently waiting forever.
    case protocolError(code: String)
    case complete(totalTokens: Int)
    case error(code: String, message: String)

    /// Short case name for `DiagnosticLog`. Deliberately not
    /// `String(describing:)`, which renders the whole associated payload —
    /// including streamed text — making per-event log lines both enormous and
    /// a place model output can leak into a file on disk.
    var diagnosticKind: String {
        switch self {
        case .capabilityMode: return "capability_mode"
        case .delta: return "message.delta"
        case .reasoning: return "reasoning.delta"
        case .plan: return "plan.delta"
        case .progressNote: return "progress.note"
        case .toolArgDelta: return "tool.arg_delta"
        case .capabilitiesAccepted: return "capabilities.accepted"
        case .toolCall: return "tool.call"
        case .interactionRequired: return "interaction.required"
        case .interactionReceipt: return "interaction.receipt"
        case .reportDraft: return "report.draft"
        case .reportReady: return "report.ready"
        case .protocolError: return "protocol_error"
        case .complete: return "message.complete"
        case .error: return "error"
        }
    }

    /// Decodes an event from its SSE name + JSON data. Unknown event names
    /// return nil so new server events don't break old clients.
    public static func decode(event: String, data: Data) -> AIEvent? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch event {
        case "message.delta":
            return .delta(AIEventDelta(
                text: object?["text"] as? String ?? "",
                round: object?["round"] as? Int,
                segmentID: object?["segment_id"] as? String,
                provisional: object?["provisional"] as? Bool
            ))
        case "reasoning.delta":
            return .reasoning(AIEventDelta(
                text: object?["text"] as? String ?? "",
                round: object?["round"] as? Int,
                segmentID: object?["segment_id"] as? String
            ))
        case "plan.delta":
            return .plan(object?["text"] as? String ?? "")
        case "progress.note":
            let text = (object?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty note would append a blank sub-block.
            return text.isEmpty ? nil : .progressNote(text)
        case "tool.arg_delta":
            guard let name = object?["name"] as? String,
                  let argDelta = object?["arg_delta"] as? String else { return nil }
            return .toolArgDelta(name: name, argDelta: argDelta)
        case "tool.call":
            let invalid = AIEvent.protocolError(
                code: "invalid_tool_call_contract"
            )
            let allowedKeys: Set<String> = [
                "call_id", "dispatch_nonce", "name", "args",
                "registry_version", "tool_version", "schema_version",
                "risk", "approval", "capability_set_digest", "thread_id",
            ]
            guard data.count <= 512 * 1_024,
                  let object,
                  Set(object.keys) == allowedKeys,
                  let id = boundedNonblankString(
                      object["call_id"], maxBytes: 256
                  ),
                  let name = boundedNonblankString(
                      object["name"], maxBytes: 128
                  ),
                  let dispatchNonce = object["dispatch_nonce"] as? String,
                  isControlToken(dispatchNonce),
                  let capabilityDigest = boundedNonblankString(
                      object["capability_set_digest"], maxBytes: 128
                  ),
                  let registryVersion = boundedNonblankString(
                      object["registry_version"], maxBytes: 64
                  ),
                  let toolVersion = boundedNonblankString(
                      object["tool_version"], maxBytes: 64
                  ),
                  let schemaVersion = boundedNonblankString(
                      object["schema_version"], maxBytes: 64
                  ),
                  let risk = boundedNonblankString(
                      object["risk"], maxBytes: 32
                  ),
                  let approval = boundedNonblankString(
                      object["approval"], maxBytes: 32
                  ),
                  boundedNonblankString(
                      object["thread_id"], maxBytes: 256
                  ) != nil,
                  let rawArgs = object["args"] as? [String: Any],
                  (try? JSONSerialization.data(
                      withJSONObject: rawArgs
                  ).count).map({ $0 <= 256 * 1_024 }) == true
            else { return invalid }
            var args: [String: String] = [:]
            for (key, value) in rawArgs {
                guard !key.isEmpty, key.utf8.count <= 128 else {
                    return invalid
                }
                args[key] = stringify(value)
            }
            return .toolCall(AIToolCall(
                id: id,
                name: name,
                args: args,
                dispatchNonce: dispatchNonce,
                registryVersion: registryVersion,
                toolVersion: toolVersion,
                schemaVersion: schemaVersion,
                risk: risk,
                approval: approval,
                capabilitySetDigest: capabilityDigest
            ))
        case "interaction.required":
            guard data.count <= 128 * 1_024 else {
                return .protocolError(code: "invalid_interaction_contract")
            }
            return decodeInteraction(object)
        case "interaction.receipt":
            let invalid = AIEvent.protocolError(
                code: "invalid_interaction_receipt"
            )
            let exactKeys: Set<String> = [
                "receipt_id", "client_request_id", "request_digest",
                "duplicate", "thread_id",
            ]
            guard data.count <= 2 * 1_024,
                  let object,
                  Set(object.keys) == exactKeys,
                  let receiptID = boundedNonblankString(
                      object["receipt_id"], maxBytes: 128
                  ),
                  let clientRequestID = boundedNonblankString(
                      object["client_request_id"], maxBytes: 128
                  ),
                  let requestDigest = object["request_digest"] as? String,
                  isSHA256Hex(requestDigest),
                  let duplicateValue = object["duplicate"],
                  isJSONBoolean(duplicateValue),
                  let duplicate = duplicateValue as? Bool,
                  let threadID = boundedNonblankString(
                      object["thread_id"], maxBytes: 256
                  )
            else { return invalid }
            return .interactionReceipt(AIInteractionReceipt(
                receiptID: receiptID,
                clientRequestID: clientRequestID,
                requestDigest: requestDigest,
                duplicate: duplicate,
                threadID: threadID
            ))
        case "report.draft":
            let invalid = AIEvent.protocolError(code: "invalid_report_draft_contract")
            let exactKeys: Set<String> = [
                "call_id", "draft_digest", "category", "severity",
                "policy_version", "registry_version", "schema_version",
                "thread_id",
            ]
            guard data.count <= 4 * 1_024,
                  let object,
                  Set(object.keys) == exactKeys,
                  let callID = boundedNonblankString(
                      object["call_id"], maxBytes: 256
                  ),
                  let draftDigest = object["draft_digest"] as? String,
                  isSHA256Hex(draftDigest),
                  let category = nullableBoundedString(
                      object["category"], maxBytes: 64
                  ),
                  let severity = nullableBoundedString(
                      object["severity"], maxBytes: 32
                  ),
                  let policyVersion = boundedNonblankString(
                      object["policy_version"], maxBytes: 32
                  ),
                  let registryVersion = boundedNonblankString(
                      object["registry_version"], maxBytes: 64
                  ),
                  let schemaVersion = boundedNonblankString(
                      object["schema_version"], maxBytes: 64
                  ),
                  boundedNonblankString(object["thread_id"], maxBytes: 256) != nil
            else { return invalid }
            return .reportDraft(AIReportDraftPreview(
                callID: callID, draftDigest: draftDigest,
                category: category, severity: severity,
                policyVersion: policyVersion,
                registryVersion: registryVersion,
                schemaVersion: schemaVersion
            ))
        case "report.ready":
            let invalid = AIEvent.protocolError(code: "invalid_report_ready_contract")
            let exactKeys: Set<String> = [
                "call_id", "report_ready_token", "draft_digest",
                "context_digest", "include_context", "category", "severity",
                "edited", "policy_version", "schema_version",
                "registry_version", "expires_at_unix", "thread_id",
            ]
            guard data.count <= 8 * 1_024,
                  let object,
                  Set(object.keys) == exactKeys,
                  let callID = boundedNonblankString(
                      object["call_id"], maxBytes: 256
                  ),
                  let token = object["report_ready_token"] as? String,
                  isReportReadyToken(token),
                  let draftDigest = object["draft_digest"] as? String,
                  isSHA256Hex(draftDigest),
                  let contextDigest = nullableSHA256Hex(object["context_digest"]),
                  let includeContextValue = object["include_context"],
                  isJSONBoolean(includeContextValue),
                  let includeContext = includeContextValue as? Bool,
                  includeContext == (contextDigest != nil),
                  let category = nullableBoundedString(
                      object["category"], maxBytes: 64
                  ),
                  let severity = nullableBoundedString(
                      object["severity"], maxBytes: 32
                  ),
                  let editedValue = object["edited"],
                  isJSONBoolean(editedValue),
                  let edited = editedValue as? Bool,
                  let policyVersion = boundedNonblankString(
                      object["policy_version"], maxBytes: 32
                  ),
                  let schemaVersion = boundedNonblankString(
                      object["schema_version"], maxBytes: 64
                  ),
                  let registryVersion = boundedNonblankString(
                      object["registry_version"], maxBytes: 64
                  ),
                  let expiresAtUnix = jsonInt64(object["expires_at_unix"]),
                  expiresAtUnix > 0,
                  boundedNonblankString(object["thread_id"], maxBytes: 256) != nil
            else { return invalid }
            return .reportReady(AIReportReadyGrant(
                callID: callID, reportReadyToken: token,
                draftDigest: draftDigest, contextDigest: contextDigest,
                includeContext: includeContext,
                category: category, severity: severity, edited: edited,
                policyVersion: policyVersion, schemaVersion: schemaVersion,
                registryVersion: registryVersion, expiresAtUnix: expiresAtUnix
            ))
        case "capabilities.accepted":
            guard let object,
                  let protocolVersion = object["protocol_version"] as? Int,
                  let registryVersion = object["registry_version"] as? String,
                  let schemaVersion = object["schema_version"] as? String,
                  let digest = object["capability_set_digest"] as? String,
                  let rawAccepted = object["accepted"] as? [[String: Any]],
                  let rawRejected = object["rejected"] as? [[String: Any]]
            else { return nil }
            let accepted = rawAccepted.compactMap { item -> AIAcceptedCapability? in
                guard let id = item["id"] as? String,
                      let toolVersion = item["tool_version"] as? String,
                      let schemaVersion = item["schema_version"] as? String,
                      let handlerVersion = item["handler_version"] as? String,
                      let risk = item["risk"] as? String,
                      let approval = item["approval"] as? String
                else { return nil }
                return AIAcceptedCapability(
                    id: id, toolVersion: toolVersion,
                    schemaVersion: schemaVersion, handlerVersion: handlerVersion,
                    risk: risk, approval: approval
                )
            }
            let rejected = rawRejected.compactMap { item -> AIRejectedCapability? in
                guard let id = item["id"] as? String,
                      let code = item["code"] as? String else { return nil }
                return AIRejectedCapability(id: id, code: code)
            }
            guard accepted.count == rawAccepted.count,
                  rejected.count == rawRejected.count else { return nil }
            return .capabilitiesAccepted(AICapabilityAcceptance(
                protocolVersion: protocolVersion,
                registryVersion: registryVersion,
                schemaVersion: schemaVersion,
                capabilitySetDigest: digest,
                accepted: accepted,
                rejected: rejected
            ))
        case "message.complete":
            let usage = object?["usage"] as? [String: Any]
            return .complete(totalTokens: usage?["total_tokens"] as? Int ?? 0)
        case "error":
            return .error(
                code: object?["code"] as? String ?? "unknown",
                message: object?["message"] as? String ?? ""
            )
        default:
            return nil
        }
    }

    private static func decodeInteraction(
        _ object: [String: Any]?
    ) -> AIEvent {
        let invalid = AIEvent.protocolError(
            code: "invalid_interaction_contract"
        )
        guard let object else { return invalid }
        let allowedEnvelopeKeys: Set<String> = [
            "call_id", "kind", "args", "resume_token", "origin",
            "registry_version", "tool_version", "schema_version",
            "thread_id", "origin_thread_id", "origin_path",
            "parent_thread_id", "expires_at_unix",
        ]
        guard Set(object.keys) == allowedEnvelopeKeys,
              let id = boundedNonblankString(
                  object["call_id"], maxBytes: 256
              ),
              let rawKind = object["kind"] as? String,
              let kind = AIInteraction.Kind(rawValue: rawKind),
              let resumeToken = object["resume_token"] as? String,
              isInteractionResumeToken(resumeToken),
              let rawOrigin = object["origin"] as? String,
              let origin = AIInteraction.Origin(rawValue: rawOrigin),
              let threadID = boundedNonblankString(
                  object["thread_id"], maxBytes: 256
              ),
              let originThreadID = boundedNonblankString(
                  object["origin_thread_id"], maxBytes: 256
              ),
              let originPath = boundedNonblankString(
                  object["origin_path"], maxBytes: 64
              ),
              let parentThreadID = boundedNonblankString(
                  object["parent_thread_id"], maxBytes: 256
              ),
              let expiresAtUnix = jsonInt64(object["expires_at_unix"]),
              expiresAtUnix > 0,
              let registryVersion = boundedNonblankString(
                  object["registry_version"], maxBytes: 64
              ),
              let toolVersion = boundedNonblankString(
                  object["tool_version"], maxBytes: 64
              ),
              let schemaVersion = boundedNonblankString(
                  object["schema_version"], maxBytes: 64
              ),
              let args = object["args"] as? [String: Any]
        else { return invalid }
        switch origin {
        case .root:
            guard originThreadID == threadID,
                  parentThreadID == threadID,
                  originPath == "root" else { return invalid }
        case .subagent:
            let prefix = "\(threadID)-sub"
            let suffix = originThreadID.hasPrefix(prefix)
                ? originThreadID.dropFirst(prefix.count) : ""
            guard parentThreadID == threadID,
                  originPath == "root/sub\(suffix)",
                  !suffix.isEmpty,
                  suffix.allSatisfy(\.isNumber) else { return invalid }
        }

        switch kind {
        case .clarifyRequest:
            let allowed: Set<String> = [
                "question", "reason", "choices", "allow_free_text",
            ]
            guard Set(args.keys).isSubset(of: allowed),
                  let question = boundedNonblankString(
                      args["question"], maxBytes: 1_024
                  ),
                  let reason = boundedNonblankString(
                      args["reason"], maxBytes: 1_024
                  )
            else { return invalid }
            var choices: [String] = []
            if let rawChoices = args["choices"] {
                guard let array = rawChoices as? [Any], array.count <= 5 else {
                    return invalid
                }
                for value in array {
                    guard let choice = boundedNonblankString(
                        value, maxBytes: 256
                    ) else { return invalid }
                    choices.append(choice)
                }
            }
            var allowFreeText = true
            if let value = args["allow_free_text"] {
                guard isJSONBoolean(value), let boolean = value as? Bool else {
                    return invalid
                }
                allowFreeText = boolean
            }
            return .interactionRequired(AIInteraction(
                id: id, kind: kind, resumeToken: resumeToken,
                origin: origin, threadID: threadID,
                originThreadID: originThreadID, originPath: originPath,
                parentThreadID: parentThreadID,
                expiresAtUnix: expiresAtUnix,
                registryVersion: registryVersion,
                toolVersion: toolVersion, schemaVersion: schemaVersion,
                question: question, reason: reason, choices: choices,
                allowFreeText: allowFreeText
            ))

        case .reportDraftReady:
            let allowed: Set<String> = [
                "draft", "category", "severity", "unknowns",
            ]
            guard Set(args.keys).isSubset(of: allowed),
                  let draft = boundedNonblankString(
                      args["draft"], maxBytes: 16 * 1_024
                  )
            else { return invalid }
            let category = boundedOptionalString(
                args["category"], maxBytes: 64
            )
            let severity = boundedOptionalString(
                args["severity"], maxBytes: 32
            )
            if args["category"] != nil, category == nil { return invalid }
            if args["severity"] != nil, severity == nil { return invalid }
            var unknowns: [String] = []
            if let rawUnknowns = args["unknowns"] {
                guard let array = rawUnknowns as? [Any], array.count <= 8 else {
                    return invalid
                }
                for value in array {
                    guard let unknown = boundedNonblankString(
                        value, maxBytes: 512
                    ) else { return invalid }
                    unknowns.append(unknown)
                }
            }
            guard unknowns.isEmpty else { return invalid }
            return .interactionRequired(AIInteraction(
                id: id, kind: kind, resumeToken: resumeToken,
                origin: origin, threadID: threadID,
                originThreadID: originThreadID, originPath: originPath,
                parentThreadID: parentThreadID,
                expiresAtUnix: expiresAtUnix,
                registryVersion: registryVersion,
                toolVersion: toolVersion, schemaVersion: schemaVersion,
                draft: draft, category: category,
                severity: severity, unknowns: unknowns
            ))
        }
    }

    private static func boundedNonblankString(
        _ value: Any?,
        maxBytes: Int
    ) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maxBytes else { return nil }
        return value
    }

    private static func boundedOptionalString(
        _ value: Any?,
        maxBytes: Int
    ) -> String? {
        guard let value = value as? String,
              value.utf8.count <= maxBytes else { return nil }
        return value
    }

    /// Unlike `boundedOptionalString` (which treats an absent key as "no
    /// value" but a present-non-string value, including JSON `null`, as
    /// invalid), the new report events always send every key, with `null`
    /// as the explicit "no value" for `category`/`severity`/`context_digest`
    /// (Task 11 wire contract). Returns the outer `nil` only for a key that's
    /// present with a non-null, non-string, or oversized value.
    private static func nullableBoundedString(
        _ value: Any?,
        maxBytes: Int
    ) -> String?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let string = value as? String,
              string.utf8.count <= maxBytes else { return nil }
        return .some(string)
    }

    private static func nullableSHA256Hex(_ value: Any?) -> String?? {
        guard let value, !(value is NSNull) else { return .some(nil) }
        guard let string = value as? String, isSHA256Hex(string) else { return nil }
        return .some(string)
    }

    private static func isControlToken(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Backend-minted AES-256-GCM grant:
    /// `v1.<kid>.<base64url-without-padding ciphertext>`.
    private static func isInteractionResumeToken(_ value: String) -> Bool {
        guard value.utf8.count >= 68, value.utf8.count <= 65_572 else {
            return false
        }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0] == "v1",
              (1...32).contains(segments[1].utf8.count),
              (64...65_536).contains(segments[2].utf8.count) else {
            return false
        }
        let isBase64URL: (Substring) -> Bool = { segment in
            segment.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        return isBase64URL(segments[1]) && isBase64URL(segments[2])
    }

    /// Backend-minted AES-256-GCM grant, same sealed-token shape as
    /// `isInteractionResumeToken` but under the `rr1` version tag and its
    /// own AEAD domain (Task 11 — `report_ready_token`, distinct from the
    /// interaction resume token so one can never be replayed as the other).
    private static func isReportReadyToken(_ value: String) -> Bool {
        guard value.utf8.count >= 69, value.utf8.count <= 65_573 else {
            return false
        }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0] == "rr1",
              (1...32).contains(segments[1].utf8.count),
              (64...65_536).contains(segments[2].utf8.count) else {
            return false
        }
        let isBase64URL: (Substring) -> Bool = { segment in
            segment.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
        }
        return isBase64URL(segments[1]) && isBase64URL(segments[2])
    }

    private static func jsonInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              !isJSONBoolean(number) else { return nil }
        let integerTypes: Set<String> = [
            "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q",
        ]
        guard integerTypes.contains(String(cString: number.objCType)) else {
            return nil
        }
        return number.int64Value
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func stringify(_ value: Any) -> String {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: "\(value)"
        }
    }
}
