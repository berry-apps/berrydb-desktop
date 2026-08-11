import Foundation
import Testing

@testable import BerryAI

/// In-process HTTP stub for `AIClient` (same role as the driver packages'
/// `QdrantStubURLProtocol`/`DynamoDBStubURLProtocol`). Handlers are keyed by
/// request host so concurrently-running `@Test`s never share mutable state.
private final class AIStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var capturedBodies: [String: [Data]] = [:]

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        lock.lock()
        handlers[host] = handler
        capturedBodies[host] = []
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AIStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func bodies(for host: String) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return capturedBodies[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock(); defer { lock.unlock() }
        return handlers[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // URLSession commonly moves a POST body onto `httpBodyStream`.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        Self.lock.lock()
        let handler = Self.handlers[host]
        if let body { Self.capturedBodies[host, default: []].append(body) }
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Lock-protected mutable value for asserting on state a `@Sendable` stub
/// closure mutates (call counts, a token that changes after "reauthenticating").
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}

private func stubbedClient(
    host: String, status: Int, body: [String: Any]
) -> AIClient {
    let encoded = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    let session = AIStubURLProtocol.session(host: host) { request in
        (
            HTTPURLResponse(
                url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!,
            encoded
        )
    }
    return AIClient(
        baseURL: URL(string: "http://\(host)/")!, token: { "test-token" }, session: session
    )
}

private let wireToken = "rr1.kid.\(String(repeating: "A", count: 64))"
private let wireDraft = "Opening the history panel shows an empty list after restart."
private let wireSummary = "The user reported that the history panel is empty after restart."

private func wireSubmission(summary: String?) -> AIReportSubmission {
    AIReportSubmission(
        threadID: "thread-abc", callID: "report-1", reportReadyToken: wireToken,
        draft: wireDraft, conversationSummary: summary,
        clientRequestID: "client-request-000001"
    )
}

@Suite("POST /v1/agent/report wire contract (Task 12)")
struct ReportSubmissionWireTests {
    /// The body that actually goes on the wire, field for field — and the
    /// `submission_digest` the server recomputes, checked against a value
    /// derived outside this codebase (`printf '%s\000…' | shasum -a 256`,
    /// cross-checked with Python's `hashlib`). A digest built with a
    /// different join would fail every real submission with an opaque
    /// mismatch, so it is pinned here rather than compared to itself.
    @Test func submitReportSendsTheCanonicalBodyAndTheIndependentlyComputedProof() async throws {
        let host = "report-canonical.test"
        let client = stubbedClient(
            host: host, status: 200,
            body: ["submission_id": "sub-9", "duplicate": false]
        )

        let receipt = try await client.submitReport(wireSubmission(summary: wireSummary))

        #expect(receipt == AIReportReceipt(submissionID: "sub-9", duplicate: false))
        let data = try #require(AIStubURLProtocol.bodies(for: host).last)
        let body = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(body.keys) == [
            "thread_id", "call_id", "report_ready_token", "draft",
            "include_context", "context", "confirmation",
        ])
        #expect(body["thread_id"] as? String == "thread-abc")
        #expect(body["call_id"] as? String == "report-1")
        #expect(body["report_ready_token"] as? String == wireToken)
        #expect(body["draft"] as? String == wireDraft)
        #expect(body["include_context"] as? Bool == true)
        #expect(
            (body["context"] as? [String: Any])?["conversation_summary"] as? String
                == wireSummary
        )
        let confirmation = try #require(body["confirmation"] as? [String: Any])
        #expect(confirmation["client_request_id"] as? String == "client-request-000001")
        #expect(
            confirmation["submission_digest"] as? String
                == "b696dab9d5405fb26929b99953753b9de7875cea3c2451cc3cd5e0107ef751b5"
        )
    }

    /// Without consent there is no scope: `context` is absent entirely rather
    /// than present-and-empty, which the backend refuses as a consent/scope
    /// disagreement.
    @Test func submitReportOmitsContextEntirelyWhenNothingWasConsentedTo() async throws {
        let host = "report-noscope.test"
        let client = stubbedClient(
            host: host, status: 200,
            body: ["submission_id": "sub-1", "duplicate": true]
        )

        let receipt = try await client.submitReport(wireSubmission(summary: nil))

        #expect(receipt.duplicate)
        let data = try #require(AIStubURLProtocol.bodies(for: host).last)
        let body = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(body["context"] == nil)
        #expect(body["include_context"] as? Bool == false)
        #expect(
            (body["confirmation"] as? [String: Any])?["submission_digest"] as? String
                == "a67fec8aba41f1ada0cae7ee5b3f637c480d0b9d147e0b84e1dae423da4b4c14"
        )
    }

    /// The pre-Phase-4 raw shape is not merely unused, it is unreachable:
    /// nothing this client can assemble carries a rough `message`, raw
    /// `recent_messages`, or a client-claimed `category`/`severity` (the
    /// backend reads those from the credential and would ignore them).
    @Test func noRequestThisClientCanBuildCarriesTheLegacyRawReportFields() async throws {
        let host = "report-legacy.test"
        let client = stubbedClient(
            host: host, status: 200,
            body: ["submission_id": "sub-1", "duplicate": false]
        )

        _ = try await client.submitReport(wireSubmission(summary: wireSummary))

        let data = try #require(AIStubURLProtocol.bodies(for: host).last)
        let body = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        for legacy in ["message", "recent_messages", "category", "severity"] {
            #expect(body[legacy] == nil, "\(legacy) must not exist on a submission")
        }
    }

    /// Each documented status maps to the one failure the client acts on.
    /// Getting these wrong would either retry something unretryable or give
    /// up on something a retry would have fixed.
    @Test func everyDocumentedRefusalMapsToItsOwnClientError() async throws {
        let cases: [(Int, [String: Any], AIReportSubmissionError)] = [
            (426, ["code": "report_refinement_required", "reason": "report_ready_token_required"],
             .refinementRequired),
            (400, ["code": "invalid_report_submission", "reason": "report_binding_invalid"],
             .malformedSubmission(code: "invalid_report_submission")),
            (413, ["code": "report_too_large", "reason": "report_submission_too_large"],
             .tooLarge),
            (403, ["code": "report_not_ready", "reason": "control_token_expired"],
             .notReady(reason: "control_token_expired")),
            (409, ["code": "report_already_submitted", "reason": "report_confirmation_consumed"],
             .alreadySubmitted),
            (503, ["code": "report_submission_unavailable", "reason": "report_receipt_unavailable"],
             .unavailable(reason: "report_receipt_unavailable")),
        ]
        for (index, testCase) in cases.enumerated() {
            let (status, body, expected) = testCase
            let client = stubbedClient(
                host: "report-refusal-\(index).test", status: status, body: body
            )
            await #expect(throws: expected) {
                try await client.submitReport(wireSubmission(summary: nil))
            }
        }
    }

    /// 401 stays the transport-wide "not authorized", as everywhere else in
    /// this client — it is about the session, not about this report.
    @Test func anUnauthorizedSubmissionSurfacesAsTheTransportsOwnNotAuthorized() async {
        let client = stubbedClient(
            host: "report-401.test", status: 401, body: ["error": "Missing or unknown token"]
        )
        await #expect(throws: AITransportError.notAuthorized) {
            try await client.submitReport(wireSubmission(summary: nil))
        }
    }

    /// A 401 must not surface immediately — the client re-authenticates once
    /// (e.g. re-syncing the license/device session against the backend) and
    /// retries the exact same request with a freshly-read token before
    /// giving up, so a token merely lost to a Keychain reset or a backend
    /// restart doesn't require the user to notice and manually reactivate.
    @Test func aStaleTokenReauthenticatesOnceThenSucceedsOnRetry() async throws {
        let host = "report-reauth-retry.test"
        let currentToken = LockedBox("stale-token")
        let reauthCount = LockedBox(0)
        let successBody = try! JSONSerialization.data(withJSONObject: [
            "submission_id": "sub-retry-1", "duplicate": false,
        ])
        let session = AIStubURLProtocol.session(host: host) { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stale-token" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                successBody
            )
        }
        let client = AIClient(
            baseURL: URL(string: "http://\(host)/")!,
            token: { currentToken.get() },
            reauthenticate: {
                reauthCount.mutate { $0 += 1 }
                currentToken.set("fresh-token")
            },
            session: session
        )

        let receipt = try await client.submitReport(wireSubmission(summary: nil))

        #expect(receipt.submissionID == "sub-retry-1")
        #expect(reauthCount.get() == 1)
        #expect(AIStubURLProtocol.bodies(for: host).count == 2)
    }

    /// A `200` that is not the documented receipt is a protocol violation,
    /// not a success — the old `{"id": 42}` shape included.
    @Test func aReceiptThatIsNotTheDocumentedShapeIsRefused() async {
        for body in [
            ["id": 42] as [String: Any],
            ["submission_id": "sub-1"],
            ["submission_id": "", "duplicate": false],
            ["submission_id": "sub-1", "duplicate": "false"],
        ] {
            let client = stubbedClient(
                host: "report-receipt-\(UUID().uuidString).test", status: 200, body: body
            )
            await #expect(
                throws: AITransportError.protocolViolation(
                    code: "invalid_report_submission_receipt"
                )
            ) {
                try await client.submitReport(wireSubmission(summary: nil))
            }
        }
    }
}
