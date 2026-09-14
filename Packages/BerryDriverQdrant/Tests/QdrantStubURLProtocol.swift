import Foundation

/// In-process HTTP stub — no real network, no Docker
/// task scope: "pure unit tests with a stubbed URLProtocol/URLSession").
/// Handlers are keyed by request host so concurrently-running `@Test`s (Swift
/// Testing parallelizes by default) never share mutable state: each test uses
/// its own unique host.
final class QdrantStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    // Protected by `lock` (same pattern as DataSourceRegistry, BerryDataSourceKit).
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var capturedRequests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var capturedBodies: [String: [Data]] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host.lowercased()] = handler
        capturedRequests[host.lowercased()] = []
        capturedBodies[host.lowercased()] = []
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests[host.lowercased()] ?? []
    }

    /// `startLoading` reads `httpBodyStream` when `URLSession` moves the body
    /// there (common for POST/PUT) — capture decoded bodies separately so
    /// assertions do not need to know which representation was used.
    static func bodies(for host: String) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return capturedBodies[host.lowercased()] ?? []
    }

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [QdrantStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        lock.lock(); defer { lock.unlock() }
        return handlers[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host?.lowercased() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        var bodyData = request.httpBody
        if bodyData == nil, let stream = request.httpBodyStream {
            bodyData = Self.drain(stream)
        }

        Self.lock.lock()
        let handler = Self.handlers[host]
        Self.capturedRequests[host, default: []].append(request)
        if let bodyData { Self.capturedBodies[host, default: []].append(bodyData) }
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func stubResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

func stubJSONData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}
