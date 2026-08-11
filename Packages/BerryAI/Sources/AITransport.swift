import BerryCore
import CryptoKit
import CoreFoundation
import Foundation

/// A `role`/`content` pair for stateless context sent to the backend (Q17,
/// docs/agents/architecture/11 §7.4) — a minimal `Sendable` stand-in for the
/// backend's `ai::provider::Message` (tool_calls/tool_call_id aren't needed
/// for summarization/context-building, only for the live tool-call loop).
public struct AIContextMessage: Sendable, Equatable {
    public var role: String
    public var content: String
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// The client-built turn context for a stateless `postMessage` (Q17 §7.4) —
/// replaces what the backend used to load from `berry_ai_threads`/
/// `berry_ai_messages`.
public struct AITurnContext: Sendable, Equatable {
    public var summary: String
    public var recentMessages: [AIContextMessage]
    public init(summary: String, recentMessages: [AIContextMessage]) {
        self.summary = summary
        self.recentMessages = recentMessages
    }
}

/// The user's explicit confirmation of a reviewed `report_draft_ready` draft
/// (Task 11, backend Task 3 §4) — digests only, per the additive `report`
/// block on the resume request. `report` is valid only alongside `action:
/// .accepted`; the reviewed text itself never rides along, only what it
/// hashes to. `contextDigest` must be present exactly when `includeContext`
/// is true (mirrors the backend's own `include_context != context_digest.is_some()` check).
public struct AIReportConfirmation: Sendable, Equatable {
    public let draftDigest: String
    public let includeContext: Bool
    public let contextDigest: String?

    public init(draftDigest: String, includeContext: Bool, contextDigest: String? = nil) {
        self.draftDigest = draftDigest
        self.includeContext = includeContext
        self.contextDigest = contextDigest
    }
}

/// Hard bounds `POST /v1/agent/report` enforces on a submission (backend Task
/// 4). Checked client-side first so an oversized draft/summary is refused
/// with a clear local message instead of a `413` round trip.
public enum AIReportPolicy {
    public static let maxDraftBytes = 16 * 1024
    public static let maxContextBytes = 16 * 1024
}

/// One confirmed report, ready to submit (Task 12, backend Task 4 §
/// `POST /v1/agent/report`).
///
/// `conversationSummary` is present exactly when the user consented to attach
/// conversation scope — the backend derives its own `include_context` check
/// from the same equivalence and refuses a request where consent and scope
/// disagree, so there is deliberately no separate boolean here that could
/// contradict it. `category`/`severity` are *not* fields: the backend reads
/// them from the credential, and anything a client claimed about them would
/// only ever be ignored.
public struct AIReportSubmission: Sendable, Equatable {
    public let threadID: String
    public let callID: String
    public let reportReadyToken: String
    /// The exact approved bytes, edits included — hashed, never normalized.
    public let draft: String
    /// The exact summary bytes the user was shown *before* confirming.
    public let conversationSummary: String?
    /// The backend's idempotency key. Stable across retries of identical
    /// bytes; a fresh id for the same content is a logically new submission
    /// and risks a `409`.
    public let clientRequestID: String

    public init(
        threadID: String,
        callID: String,
        reportReadyToken: String,
        draft: String,
        conversationSummary: String?,
        clientRequestID: String
    ) {
        self.threadID = threadID
        self.callID = callID
        self.reportReadyToken = reportReadyToken
        self.draft = draft
        self.conversationSummary = conversationSummary
        self.clientRequestID = clientRequestID
    }

    public var includeContext: Bool { conversationSummary != nil }
}

/// The `200 OK` acknowledgement. `duplicate` means this exact submission was
/// already stored earlier — the idempotent-retry contract's success answer,
/// not an error.
public struct AIReportReceipt: Sendable, Equatable {
    public let submissionID: String
    public let duplicate: Bool

    public init(submissionID: String, duplicate: Bool) {
        self.submissionID = submissionID
        self.duplicate = duplicate
    }
}

/// Every refusal `POST /v1/agent/report` can answer with (backend Task 4).
/// No case carries draft/summary text, the credential, or an identifier —
/// the backend's error bodies never contain them, so neither can these.
public enum AIReportSubmissionError: Error, Equatable {
    /// `426` — no valid ready token reached the backend. Unreachable from
    /// this client, which never submits without one: a client bug, not a
    /// retry case.
    case refinementRequired
    /// `400` — the request was assembled wrong (missing confirmation, blank
    /// draft, consent/scope disagreement, digest mismatch). Also a client bug.
    case malformedSubmission(code: String)
    /// `413` — draft or summary over `AIReportPolicy`'s bound.
    case tooLarge
    /// `403` — the credential no longer authorizes this submission.
    /// `control_token_expired` is the one reason worth its own message.
    case notReady(reason: String)
    /// `409` — this confirmation was already spent by a *different* payload.
    case alreadySubmitted
    /// `503` — retry with the SAME `clientRequestID` and identical bytes.
    case unavailable(reason: String)
}

/// Locale-neutral transport envelope for continuing a backend interaction in
/// a fresh stateless request. `token` is opaque to the desktop and must never
/// be persisted into chat content, logs, embeddings, or search results.
public struct AIInteractionResume: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable {
        case accepted
        case answered
        case declined
        case cancelled
    }

    public let token: String
    public let action: Action
    public let clientRequestID: String
    public let requestDigest: String
    /// Additive (Task 11): only ever set on an `.accepted` resume of a
    /// `report_draft_ready` interaction. `nil` means "confirmed as
    /// proposed, no conversation scope attached" when `action == .accepted`,
    /// and is simply not applicable for any other action.
    public let report: AIReportConfirmation?

    public init(
        token: String,
        action: Action,
        clientRequestID: String = "",
        requestDigest: String = "",
        report: AIReportConfirmation? = nil
    ) {
        self.token = token
        self.action = action
        self.clientRequestID = clientRequestID
        self.requestDigest = requestDigest
        self.report = report
    }
}

enum AIRequestIntegrity {
    static func contextObject(_ context: AITurnContext?) -> Any {
        guard let context else { return NSNull() }
        return [
            "summary": context.summary,
            "recent_messages": context.recentMessages.map {
                ["role": $0.role, "content": $0.content]
            },
        ]
    }

    static func digest(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// The report draft digest rule (Task 11, backend Task 3 §4): lowercase
    /// hex SHA-256 of the exact UTF-8 bytes — no normalization, no trimming,
    /// no case folding, so a trailing space hashes to a different report.
    /// Unlike `digest(_:)` above, this never goes through JSON encoding: any
    /// re-encoding could change the byte sequence (escaping, whitespace) and
    /// silently hash something other than what the user is looking at.
    static func contentDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    /// Domain separator for the submission proof — the backend's
    /// `REPORT_SUBMISSION_PROOF_DOMAIN`, byte for byte.
    static let reportSubmissionProofDomain = "berrydb.report-submit/v1"

    /// The `confirmation.submission_digest` a submission must present (Task
    /// 12, backend `report_submission_proof`):
    ///
    ///     sha256_hex(
    ///         "berrydb.report-submit/v1" ‖ NUL ‖ thread_id ‖ NUL ‖ call_id
    ///         ‖ NUL ‖ sha256_hex(draft) ‖ NUL ‖ (include_context ? "1" : "0")
    ///         ‖ NUL ‖ (include_context ? sha256_hex(summary) : "")
    ///         ‖ NUL ‖ report_ready_token
    ///     )
    ///
    /// A plain NUL-separated byte concatenation, deliberately *not* canonical
    /// JSON: the server recomputes it from the same inputs and refuses any
    /// mismatch, so this has to be reproducible here without agreeing on a
    /// key ordering. `\u{0}` encodes to the single byte `0x00` in UTF-8, and
    /// every input is already a digest, a bounded identifier, or the
    /// credential — no report content, so the proof cannot leak what it
    /// attests to.
    ///
    /// `include_context` is derived from `conversationSummary != nil` rather
    /// than passed separately, mirroring the backend's own
    /// `include_context != summary.is_some()` refusal: the two can never
    /// disagree because there is only one of them.
    static func reportSubmissionDigest(_ submission: AIReportSubmission) -> String {
        let contextDigest = submission.conversationSummary.map(contentDigest) ?? ""
        return contentDigest([
            reportSubmissionProofDomain,
            submission.threadID,
            submission.callID,
            contentDigest(submission.draft),
            submission.includeContext ? "1" : "0",
            contextDigest,
            submission.reportReadyToken,
        ].joined(separator: "\u{0}"))
    }

    static func interactionResume(
        token: String,
        action: AIInteractionResume.Action,
        text: String,
        threadID: String,
        context: AITurnContext?
    ) throws -> AIInteractionResume {
        let contextDigest = try digest(contextObject(context))
        let requestDigest = try digest([
            "action": action.rawValue,
            "context_digest": contextDigest,
            "text": text,
            "thread_id": threadID,
            "token": token,
        ])
        return AIInteractionResume(
            token: token,
            action: action,
            clientRequestID: UUID().uuidString.lowercased(),
            requestDigest: requestDigest
        )
    }
}

/// The AI gateway transport (docs/architecture/09 §3). Abstracted so the agent
/// loop can be driven by a mock in tests.
public protocol AITransport: Sendable {
    func createThread(dialect: String, schemaDigest: String) async throws -> String
    /// Streams SSE events for one message turn; stays open across a tool call
    /// (the gateway resumes after `postToolResult`). `tools` is the legacy
    /// compatibility shape; negotiated servers derive static descriptors from
    /// `capabilities`.
    func postMessage(threadID: String, text: String, tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Stateless variant (Q17 §7.4): carries the client-built `context` and
    /// `dialect` (there's no server-side thread row for the backend to read
    /// one from). Defaults to the 3-arg overload, ignoring both, so existing
    /// mock transports don't need updating.
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Capability-negotiated variant. The legacy tool list is intentionally
    /// sent alongside the advert for compatibility; new servers ignore it.
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error>
    /// Fresh-request continuation for a suspended backend interaction. The
    /// default keeps existing mock/custom transports source-compatible.
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String, resume: AIInteractionResume?) -> AsyncThrowingStream<AIStreamEvent, Error>
    func postToolResult(
        threadID: String,
        callID: String,
        dispatchNonce: String,
        capabilitySetDigest: String,
        status: String,
        resultJSON: String?
    ) async throws
    /// Top-K most relevant skill names for the query (docs/agents/architecture/07 §7).
    /// Returns [] on any failure — the caller falls back to no skill:<name> shortcuts.
    func rankSkills(skills: [SkillRankInput], query: String) async -> [String]

    /// The device's saved conversations, most-recent first (AI-21). Keyset cursor:
    /// pass the last thread's `(updatedAt, id)` to fetch the next page.
    func listThreads(dialect: String?, limit: Int, beforeUpdatedAt: Int?, beforeID: String?) async -> [AIThreadSummary]
    /// Rebuild a saved thread's display transcript from its stored messages (AI-21).
    func loadThread(id: String) async throws -> [AITurn]
    /// Delete a saved conversation (AI-21).
    func deleteThread(id: String) async throws
    /// Submits a confirmed report (`/report …`, docs/feature/05 F6) — the
    /// *only* path to `POST /v1/agent/report` since Task 12. The pre-Phase-4
    /// raw `{message, category, recent_messages}` shape has no receiver on
    /// the backend at all and is deliberately not expressible here.
    /// Idempotent for an identical `clientRequestID` + identical bytes.
    func submitReport(_ submission: AIReportSubmission) async throws -> AIReportReceipt
    /// Stateless embedding for local RAG (Q17 §7.4/§7.5) — the backend doesn't
    /// store `text` or the returned vector; the caller persists it locally.
    /// Empty on any failure, matching `rankSkills`' fallback shape.
    func embed(text: String) async -> [Float]
    /// Stateless conversation-summary fold (Q17 §7.4), replacing the old
    /// server-side rolling summary — the backend doesn't store `previous` or
    /// `messages`. Empty on any failure (caller keeps the old summary).
    func summarize(previous: String, messages: [AIContextMessage]) async -> String
}

/// Defaults so mock transports (tests) don't need the persistence methods.
public extension AITransport {
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(threadID: threadID, text: text, tools: tools)
    }
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(threadID: threadID, text: text, tools: tools, context: context, dialect: dialect)
    }
    func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String, resume: AIInteractionResume?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        guard resume == nil else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: AITransportError.interactionResumeUnsupported
                )
            }
        }
        return postMessage(
            threadID: threadID, text: text, tools: tools,
            capabilities: capabilities, context: context, dialect: dialect
        )
    }
    func listThreads(dialect: String? = nil, limit: Int = 50, beforeUpdatedAt: Int? = nil, beforeID: String? = nil) async -> [AIThreadSummary] { [] }
    func loadThread(id: String) async throws -> [AITurn] { [] }
    func deleteThread(id: String) async throws {}
    /// Mock/local transports that never submit a report still have to answer
    /// something. Failing closed as "retryable, nothing was stored" is the
    /// only safe default: silently succeeding would let a test (or a local
    /// provider) believe a report landed that never left the device.
    func submitReport(_ submission: AIReportSubmission) async throws -> AIReportReceipt {
        throw AIReportSubmissionError.unavailable(reason: "report_submission_unsupported")
    }
    func embed(text: String) async -> [Float] { [] }
    func summarize(previous: String, messages: [AIContextMessage]) async -> String { "" }
}

/// One saved conversation for the "past conversations" list (AI-21).
public struct AIThreadSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let updatedAt: Double

    public init(id: String, title: String, updatedAt: Double) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum AITransportError: Error, Equatable {
    case badResponse(statusCode: Int, message: String?)
    case clientUpdateRequired
    case capabilityRejected(code: String)
    case capabilityNegotiationFailed
    case interactionResumeUnsupported
    case protocolViolation(code: String)
    /// The request may have crossed the one-shot boundary before the response
    /// was lost. Retrying without a backend receipt could duplicate execution.
    case interactionResumeAmbiguous
    case toolResultDeliveryAmbiguous
    /// 401 only — no valid session token at all. 403 (quota exceeded, AI
    /// disabled, viewer role, ...) is a `badResponse` instead: the gateway
    /// sends a real message in those cases (e.g. "AI token quota exhausted")
    /// that the UI needs to actually show, not collapse into a generic
    /// "not authorized" that hides why the request was rejected.
    case notAuthorized
}

public enum AICapabilityCompatibilityPolicy: Sendable, Equatable {
    case requireNegotiation
    case allowServerDeclaredLegacy
    case allowHeaderlessLegacy
}

/// HTTP/SSE client for berrydb-backend's AI gateway.
public struct AIClient: AITransport {
    let baseURL: URL
    /// Read fresh on every request (rather than a value frozen at init) so a
    /// token minted by `reauthenticate` after a 401 is picked up on retry
    /// without having to rebuild this whole client/its owning `AISession`.
    let tokenProvider: @Sendable () -> String
    /// Called once when a request comes back 401 ("no valid session token at
    /// all") before retrying it once — typically re-syncs the license/device
    /// session against the backend so a token lost to a Keychain reset or a
    /// backend restart (in-memory token store) is silently replaced instead
    /// of surfacing "Your session has expired" for a still-valid license.
    let reauthenticate: @Sendable () async -> Void
    /// Read fresh per turn (docs/feature/07 §16, AI Database Coach) — the
    /// user's preferred explanation register ("beginner"/"intermediate"/
    /// "advanced"/"dba"), or nil to omit the field entirely (pre-existing
    /// server behavior, unset = its own default register). A closure rather
    /// than a threaded `postMessage` parameter so this stays additive: no
    /// protocol/overload signature change, no new AISession plumbing.
    let detailLevelProvider: @Sendable () -> String?
    /// Read fresh per turn (docs/draft/10.md TM-13/14) — the user's chosen
    /// AI model ("{provider_id}/{model_id}"), or nil to omit the field
    /// entirely (server falls back to its own default role, same as an old
    /// client that never sends `model`). Same closure-not-parameter shape as
    /// `detailLevelProvider`, for the same additive reason.
    let modelProvider: @Sendable () -> String?
    private let session: URLSession
    private let capabilityCompatibility: AICapabilityCompatibilityPolicy

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }

    public init(
        baseURL: URL,
        token: @escaping @Sendable () -> String,
        reauthenticate: @escaping @Sendable () async -> Void = {},
        detailLevel: @escaping @Sendable () -> String? = { nil },
        model: @escaping @Sendable () -> String? = { nil },
        session: URLSession? = nil,
        capabilityCompatibility: AICapabilityCompatibilityPolicy = .allowServerDeclaredLegacy
    ) {
        self.baseURL = baseURL
        self.tokenProvider = token
        self.reauthenticate = reauthenticate
        self.detailLevelProvider = detailLevel
        self.modelProvider = model
        self.session = session ?? Self.makeDefaultSession()
        self.capabilityCompatibility = capabilityCompatibility
    }

    private func request(_ path: String, method: String = "POST") -> URLRequest {
        // `appendingPathComponent` percent-escapes `?`/`&` instead of treating
        // them as a query string (it's for path segments, not URI references),
        // which broke listThreads' `?limit=&offset=&dialect=` — every call 404'd
        // and was swallowed by the `try?` below, leaving history silently empty.
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL) ?? baseURL)
        request.httpMethod = method
        request.setValue("Bearer \(tokenProvider())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func parseErrorMessage(from data: Data) -> String? {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let err = object["error"] as? String, !err.isEmpty { return err }
            if let msg = object["message"] as? String, !msg.isEmpty { return msg }
            if let detail = object["detail"] as? String, !detail.isEmpty { return detail }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private func parseCapabilityProtocolCode(from data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty,
              let reason = object["reason"] as? String, !reason.isEmpty else {
            return nil
        }
        return code
    }

    private func fetchData(
        for req: URLRequest,
        retryStaleConnection: Bool = true
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let urlErr as URLError where urlErr.code == .networkConnectionLost {
            guard retryStaleConnection else { throw urlErr }
            // Safe read/non-control requests may retry once over a fresh connection.
            return try await session.data(for: req)
        }
    }

    private func fetchBytes(
        for req: URLRequest,
        retryStaleConnection: Bool = true
    ) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            return try await session.bytes(for: req)
        } catch let urlErr as URLError where urlErr.code == .networkConnectionLost {
            guard retryStaleConnection else { throw urlErr }
            // Safe read/non-control requests may retry once over a fresh connection.
            return try await session.bytes(for: req)
        }
    }

    /// `fetchData`, but a 401 on the first attempt triggers `reauthenticate()`
    /// and one retry with a freshly-read `Authorization` header before giving
    /// up — a lost/stale token (Keychain reset, or the backend's in-memory
    /// token store losing state on restart) shouldn't need the user to notice
    /// "session expired", report it, and manually reactivate.
    private func fetchDataWithReauth(
        _ req: inout URLRequest, retryStaleConnection: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await fetchData(for: req, retryStaleConnection: retryStaleConnection)
        guard let http = response as? HTTPURLResponse else {
            throw AITransportError.badResponse(statusCode: 0, message: "No HTTP response")
        }
        guard http.statusCode == 401 else { return (data, http) }
        await reauthenticate()
        req.setValue("Bearer \(tokenProvider())", forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await fetchData(for: req, retryStaleConnection: retryStaleConnection)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw AITransportError.badResponse(statusCode: 0, message: "No HTTP response")
        }
        return (retryData, retryHTTP)
    }

    /// `fetchBytes`, with the same reauth-and-retry-once behavior as
    /// `fetchDataWithReauth` — safe here because the 401 check always happens
    /// before any SSE bytes are read from the stream (see `postMessage`
    /// below), so retrying is a fresh request, not a resumed one.
    private func fetchBytesWithReauth(
        _ req: inout URLRequest, retryStaleConnection: Bool = true
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (bytes, response) = try await fetchBytes(for: req, retryStaleConnection: retryStaleConnection)
        guard let http = response as? HTTPURLResponse else {
            throw AITransportError.badResponse(statusCode: 0, message: "No HTTP response")
        }
        guard http.statusCode == 401 else { return (bytes, http) }
        await reauthenticate()
        req.setValue("Bearer \(tokenProvider())", forHTTPHeaderField: "Authorization")
        let (retryBytes, retryResponse) = try await fetchBytes(for: req, retryStaleConnection: retryStaleConnection)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw AITransportError.badResponse(statusCode: 0, message: "No HTTP response")
        }
        return (retryBytes, retryHTTP)
    }

    /// The submission itself (Task 12). `retryStaleConnection: false`: retry
    /// is the *session's* job, because only it holds the `clientRequestID`
    /// that makes a second attempt idempotent rather than a second report.
    public func submitReport(_ submission: AIReportSubmission) async throws -> AIReportReceipt {
        var req = request("v1/agent/report")
        var body: [String: Any] = [
            "thread_id": submission.threadID,
            "call_id": submission.callID,
            "report_ready_token": submission.reportReadyToken,
            "draft": submission.draft,
            "include_context": submission.includeContext,
            "confirmation": [
                "client_request_id": submission.clientRequestID,
                "submission_digest": AIRequestIntegrity.reportSubmissionDigest(submission),
            ],
        ]
        if let summary = submission.conversationSummary {
            body["context"] = ["conversation_summary": summary]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await fetchDataWithReauth(&req, retryStaleConnection: false)
        if http.statusCode == 401 { throw AITransportError.notAuthorized }
        if http.statusCode != 200 {
            throw Self.reportSubmissionError(
                status: http.statusCode, body: parseControlError(from: data)
            )
        }
        guard let receipt = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              let submissionID = receipt["submission_id"] as? String,
              !submissionID.isEmpty, submissionID.utf8.count <= 128,
              let duplicate = receipt["duplicate"],
              CFGetTypeID(duplicate as CFTypeRef) == CFBooleanGetTypeID()
        else {
            throw AITransportError.protocolViolation(
                code: "invalid_report_submission_receipt"
            )
        }
        return AIReportReceipt(
            submissionID: submissionID,
            duplicate: (duplicate as? Bool) ?? false
        )
    }

    private func parseControlError(from data: Data) -> (code: String, reason: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("", "")
        }
        return (object["code"] as? String ?? "", object["reason"] as? String ?? "")
    }

    private static func reportSubmissionError(
        status: Int, body: (code: String, reason: String)
    ) -> Error {
        switch status {
        case 400: AIReportSubmissionError.malformedSubmission(code: body.code)
        case 403: AIReportSubmissionError.notReady(reason: body.reason)
        case 409: AIReportSubmissionError.alreadySubmitted
        case 413: AIReportSubmissionError.tooLarge
        case 426: AIReportSubmissionError.refinementRequired
        case 503: AIReportSubmissionError.unavailable(reason: body.reason)
        default: AITransportError.badResponse(
            statusCode: status, message: body.code.isEmpty ? nil : body.code
        )
        }
    }

    public func createThread(dialect: String, schemaDigest: String) async throws -> String {
        var req = request("v1/agent/threads")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "dialect": dialect, "schema_digest": schemaDigest,
        ])
        let (data, http) = try await fetchDataWithReauth(&req)
        if http.statusCode == 401 {
            throw AITransportError.notAuthorized
        }
        if http.statusCode != 200 {
            let msg = parseErrorMessage(from: data)
            throw AITransportError.badResponse(statusCode: http.statusCode, message: msg)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["thread_id"] as? String else {
            throw AITransportError.badResponse(statusCode: http.statusCode, message: "Missing thread_id in response")
        }
        return id
    }

    public func postMessage(threadID: String, text: String, tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(threadID: threadID, text: text, tools: tools, context: nil, dialect: "")
    }

    public func postMessage(threadID: String, text: String, tools: [AIToolSpec], context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(threadID: threadID, text: text, tools: tools, capabilities: nil, context: context, dialect: dialect)
    }

    public func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String) -> AsyncThrowingStream<AIStreamEvent, Error> {
        postMessage(
            threadID: threadID, text: text, tools: tools,
            capabilities: capabilities, context: context, dialect: dialect,
            resume: nil
        )
    }

    public func postMessage(threadID: String, text: String, tools: [AIToolSpec], capabilities: AICapabilityAdvertisement?, context: AITurnContext?, dialect: String, resume: AIInteractionResume?) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request("v1/agent/threads/\(threadID)/messages")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    var body: [String: Any] = ["text": text]
                    if !tools.isEmpty {
                        body["tools"] = tools.map { spec -> [String: Any] in
                            let params = (try? JSONSerialization.jsonObject(with: Data(spec.parametersJSON.utf8))) as? [String: Any] ?? [:]
                            return [
                                "name": spec.name, "version": spec.version,
                                "handler_version": spec.handlerVersion,
                                "description": spec.description, "parameters": params,
                            ]
                        }
                    }
                    if let capabilities {
                        var capabilityBody: [String: Any] = [
                            "protocol_version": capabilities.protocolVersion,
                            "handlers": capabilities.handlers.map {
                                ["id": $0.id, "handler_version": $0.handlerVersion]
                            },
                        ]
                        capabilityBody["dynamic_tools"] = try capabilities.dynamicTools.map { spec -> [String: Any] in
                            guard let parameters = try JSONSerialization.jsonObject(
                                with: Data(spec.parametersJSON.utf8)
                            ) as? [String: Any] else {
                                throw LocalCapabilityError.invalidDynamicSchema(spec.name)
                            }
                            return [
                                "name": spec.name, "version": spec.version,
                                "handler_version": spec.handlerVersion,
                                "description": spec.description, "parameters": parameters,
                            ]
                        }
                        body["capabilities"] = capabilityBody
                    }
                    if let context {
                        body["context"] = [
                            "summary": context.summary,
                            "recent_messages": context.recentMessages.map { ["role": $0.role, "content": $0.content] },
                        ]
                    }
                    if !dialect.isEmpty { body["dialect"] = dialect }
                    if let level = detailLevelProvider(), !level.isEmpty { body["detail_level"] = level }
                    if let model = modelProvider(), !model.isEmpty { body["model"] = model }
                    if let resume {
                        guard !resume.clientRequestID.isEmpty,
                              resume.clientRequestID.utf8.count <= 128,
                              resume.requestDigest.count == 64,
                              resume.requestDigest.utf8.allSatisfy({
                                  (48...57).contains($0) || (97...102).contains($0)
                              }) else {
                            throw AITransportError.protocolViolation(
                                code: "invalid_interaction_resume_integrity"
                            )
                        }
                        var resumeBody: [String: Any] = [
                            "token": resume.token,
                            "action": resume.action.rawValue,
                            "client_request_id": resume.clientRequestID,
                            "request_digest": resume.requestDigest,
                        ]
                        if let report = resume.report {
                            var reportBody: [String: Any] = [
                                "draft_digest": report.draftDigest,
                                "include_context": report.includeContext,
                            ]
                            if let contextDigest = report.contextDigest {
                                reportBody["context_digest"] = contextDigest
                            }
                            resumeBody["report"] = reportBody
                        }
                        body["resume"] = resumeBody
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, http) = try await fetchBytesWithReauth(
                        &req, retryStaleConnection: resume == nil
                    )
                    if http.statusCode == 401 {
                        throw AITransportError.notAuthorized
                    }
                    if http.statusCode == 426 {
                        throw AITransportError.clientUpdateRequired
                    }
                    if http.statusCode != 200 {
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        if let code = parseCapabilityProtocolCode(from: errorData) {
                            throw AITransportError.capabilityRejected(code: code)
                        }
                        let msg = parseErrorMessage(from: errorData)
                        throw AITransportError.badResponse(statusCode: http.statusCode, message: msg)
                    }
                    if capabilities != nil {
                        let mode = http.value(forHTTPHeaderField: "X-BerryDB-Capability-Mode")
                        switch mode?.lowercased() {
                        case "negotiated":
                            continuation.yield(AIStreamEvent(
                                threadID: threadID, event: .capabilityMode(.negotiated)
                            ))
                        case "legacy" where capabilityCompatibility != .requireNegotiation:
                            continuation.yield(AIStreamEvent(
                                threadID: threadID, event: .capabilityMode(.legacy)
                            ))
                        case nil where capabilityCompatibility == .allowHeaderlessLegacy:
                            continuation.yield(AIStreamEvent(
                                threadID: threadID, event: .capabilityMode(.legacy)
                            ))
                        default:
                            throw AITransportError.capabilityNegotiationFailed
                        }
                    }
                    // Feed raw bytes, not `bytes.lines`: AsyncLineSequence drops the
                    // blank lines that delimit SSE events, so no event would ever
                    // dispatch (the empty-bubble bug). See sseEvents(from:).
                    DiagnosticLog.default.event("producer: SSE loop open", detail: "thread=\(threadID)")
                    for try await raw in sseEvents(from: bytes) {
                        // Coalesced, not one line each: this fires per token
                        // (681 times in one turn, docs/tests/crash.md).
                        DiagnosticLog.default.tick("producer: \(raw.event)")
                        let data = Data(raw.data.utf8)
                        if let event = AIEvent.decode(event: raw.event, data: data) {
                            let threadID = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["thread_id"] as? String
                            continuation.yield(AIStreamEvent(threadID: threadID, event: event))
                        }
                    }
                    DiagnosticLog.default.event("producer: SSE loop EOF", detail: "thread=\(threadID)")
                    DiagnosticLog.default.flush()
                    continuation.finish()
                } catch {
                    DiagnosticLog.default.event(
                        "producer: SSE loop threw",
                        detail: "thread=\(threadID) error=\(error)"
                    )
                    DiagnosticLog.default.flush()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func rankSkills(skills: [SkillRankInput], query: String) async -> [String] {
        var req = request("v1/ai/skills/rank")
        let body: [String: Any] = [
            "query": query,
            "skills": skills.map { ["name": $0.name, "description": $0.description, "content_hash": $0.contentHash] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        req.httpBody = data
        guard let (respData, http) = try? await fetchDataWithReauth(&req), http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let names = object["names"] as? [String] else { return [] }
        return names
    }

    public func embed(text: String) async -> [Float] {
        var req = request("v1/ai/embed")
        guard let data = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return [] }
        req.httpBody = data
        guard let (respData, http) = try? await fetchDataWithReauth(&req), http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let vector = object["vector"] as? [Double] else { return [] }
        return vector.map { Float($0) }
    }

    /// Uses `fetchDataWithReauth` (not plain `fetchData`) so a stale token
    /// transparently refreshes and retries instead of surfacing as "couldn't
    /// prepare the conversation summary" — this call sits on the /report
    /// attach-context path (`AISession.prepareReportContextSummary`), where a
    /// swallowed 401 shows up as a confusing user-facing error rather than
    /// silently degrading like `rankSkills`/`embed`/`listThreads` do.
    public func summarize(previous: String, messages: [AIContextMessage]) async -> String {
        var req = request("v1/ai/summarize")
        let body: [String: Any] = [
            "previous": previous,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return "" }
        req.httpBody = data
        guard let (respData, http) = try? await fetchDataWithReauth(&req), http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let summary = object["summary"] as? String else { return "" }
        return summary
    }

    public func listThreads(dialect: String? = nil, limit: Int = 50, beforeUpdatedAt: Int? = nil, beforeID: String? = nil) async -> [AIThreadSummary] {
        var path = "v1/agent/threads?limit=\(limit)"
        // Keyset cursor (AI-21): only meaningful with both halves of (updated_at, id).
        if let beforeUpdatedAt, let beforeID {
            let encodedID = beforeID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? beforeID
            path += "&before_updated_at=\(beforeUpdatedAt)&before_id=\(encodedID)"
        }
        if let dialect, !dialect.isEmpty {
            let encoded = dialect.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dialect
            path += "&dialect=\(encoded)"
        }
        var req = request(path, method: "GET")
        guard let (data, http) = try? await fetchDataWithReauth(&req), http.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let title = (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let updated = (row["updated_at"] as? Double) ?? Double(row["updated_at"] as? Int ?? 0)
            return AIThreadSummary(id: id, title: title, updatedAt: updated)
        }
    }

    public func loadThread(id: String) async throws -> [AITurn] {
        var req = request("v1/agent/threads/\(id)/messages", method: "GET")
        let (data, http) = try await fetchDataWithReauth(&req)
        if http.statusCode == 401 {
            throw AITransportError.notAuthorized
        }
        if http.statusCode != 200 {
            let msg = parseErrorMessage(from: data)
            throw AITransportError.badResponse(statusCode: http.statusCode, message: msg)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]] ?? []
        return conversationTurns(from: messages)
    }

    public func deleteThread(id: String) async throws {
        var req = request("v1/agent/threads/\(id)", method: "DELETE")
        let (data, http) = try await fetchDataWithReauth(&req)
        guard (200..<300).contains(http.statusCode) else {
            let msg = parseErrorMessage(from: data)
            throw AITransportError.badResponse(statusCode: http.statusCode, message: msg)
        }
    }

    public func postToolResult(
        threadID: String,
        callID: String,
        dispatchNonce: String,
        capabilitySetDigest: String,
        status: String,
        resultJSON: String?
    ) async throws {
        var req = request("v1/agent/threads/\(threadID)/tool-results")
        let result: Any
        if let resultJSON {
            guard let parsed = try? JSONSerialization.jsonObject(
                with: Data(resultJSON.utf8)
            ) else {
                throw AITransportError.protocolViolation(
                    code: "invalid_tool_result_json"
                )
            }
            result = parsed
        } else {
            result = NSNull()
        }
        let clientRequestID = UUID().uuidString.lowercased()
        let requestDigest = try AIRequestIntegrity.digest([
            "call_id": callID,
            "capability_set_digest": capabilitySetDigest,
            "dispatch_nonce": dispatchNonce,
            "result": result,
            "status": status,
            "thread_id": threadID,
        ])
        var body: [String: Any] = [
            "call_id": callID,
            "dispatch_nonce": dispatchNonce,
            "capability_set_digest": capabilitySetDigest,
            "status": status,
            "client_request_id": clientRequestID,
            "request_digest": requestDigest,
        ]
        if !(result is NSNull) {
            body["result"] = result
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        DiagnosticLog.default.event("postToolResult begin", detail: "call=\(callID)")
        let (data, http) = try await fetchDataWithReauth(&req, retryStaleConnection: false)
        DiagnosticLog.default.event(
            "postToolResult done", detail: "call=\(callID) http=\(http.statusCode)"
        )
        if http.statusCode == 401 {
            throw AITransportError.notAuthorized
        }
        if !(200..<300).contains(http.statusCode) {
            let msg = parseErrorMessage(from: data)
            throw AITransportError.badResponse(statusCode: http.statusCode, message: msg)
        }
        guard let receipt = try? JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              Set(receipt.keys) == ["delivered", "receipt_id", "duplicate"],
              receipt["delivered"] as? Bool == true,
              let receiptID = receipt["receipt_id"] as? String,
              !receiptID.isEmpty, receiptID.utf8.count <= 128,
              let duplicate = receipt["duplicate"],
              CFGetTypeID(duplicate as CFTypeRef) == CFBooleanGetTypeID()
        else {
            throw AITransportError.protocolViolation(
                code: "invalid_tool_result_receipt"
            )
        }
    }
}
