import Foundation
import Testing

@testable import BerryAI

/// In-process HTTP stub for `AIClient` (same role/pattern as
/// `ReportSubmissionWireTests.swift`'s `AIStubURLProtocol` — kept as its own
/// private copy per that file's own precedent, e.g. the driver packages'
/// `QdrantStubURLProtocol`/`DynamoDBStubURLProtocol`, rather than shared
/// across test files).
private final class ReauthStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requestCounts: [String: Int] = [:]

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        lock.lock()
        handlers[host] = handler
        requestCounts[host] = 0
        lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReauthStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func requestCount(for host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requestCounts[host] ?? 0
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
        Self.lock.lock()
        Self.requestCounts[host, default: 0] += 1
        let handler = Self.handlers[host]
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

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&value) }
}

/// `summarize`/`rankSkills`/`embed`/`listThreads`/`deleteThread` used to call
/// the transport's plain `fetchData` instead of `fetchDataWithReauth` — a
/// stale token 401'd and was swallowed silently (return "" / [] / a thrown
/// generic error) instead of transparently refreshing and retrying once, the
/// way every other endpoint already does. On the report flow this surfaced
/// as "Couldn't prepare the conversation summary" for a cause that had
/// nothing to do with the conversation itself.
@Suite("AIClient reauth-on-401 (all endpoints, not just postMessage/loadThread)")
struct AITransportReauthTests {
    @Test func summarizeReauthenticatesOnceThenSucceedsOnRetry() async throws {
        let host = "summarize-reauth.test"
        let currentToken = LockedBox("stale-token")
        let reauthCount = LockedBox(0)
        let successBody = try! JSONSerialization.data(withJSONObject: ["summary": "the fixed summary"])
        let session = ReauthStubURLProtocol.session(host: host) { request in
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

        let summary = await client.summarize(
            previous: "", messages: [AIContextMessage(role: "user", content: "hi")]
        )

        #expect(summary == "the fixed summary")
        #expect(reauthCount.get() == 1)
        #expect(ReauthStubURLProtocol.requestCount(for: host) == 2)
    }

    /// Before the fix, a 401 with no reauth attempt fell through the same
    /// `guard ... else { return "" }` as any other failure — indistinguishable
    /// from "nothing to summarize." Pinned here so a regression back to plain
    /// `fetchData` is caught even without a reauth closure configured.
    @Test func summarizeReturnsEmptyRatherThanHangingWhenReauthDoesNothing() async {
        let host = "summarize-still-401.test"
        let session = ReauthStubURLProtocol.session(host: host) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data()
            )
        }
        let client = AIClient(baseURL: URL(string: "http://\(host)/")!, token: { "stale-token" }, session: session)

        let summary = await client.summarize(
            previous: "", messages: [AIContextMessage(role: "user", content: "hi")]
        )

        #expect(summary.isEmpty)
        // One request, then one retry after the no-op reauth — never a loop.
        #expect(ReauthStubURLProtocol.requestCount(for: host) == 2)
    }
}
