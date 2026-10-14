import Foundation

/// In-process HTTP stub — no real network, no Docker, same pattern as
/// `QdrantStubURLProtocol` (task scope: "pure unit
/// tests with a stubbed URLProtocol/URLSession"). Handlers are keyed by
/// request host so concurrently-running `@Test`s (Swift Testing parallelizes
/// by default) never share mutable state: each test uses its own unique host.
final class DynamoDBStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    /// Thrown by a handler to leave its request in flight: the protocol neither
    /// answers nor fails it, and holds no thread while it waits. `onStop` runs
    /// when the loading system stops the request, which is what cancelling the
    /// URLSession task does. A handler must not block instead, because every
    /// handler in the process runs on the one `com.apple.CFNetwork.CustomProtocols`
    /// thread (observed by logging `Thread.current` in a handler, and by a second
    /// session's handler starting only after the first one's 1 s `Thread.sleep`
    /// returned), so a blocked handler stalls every other test that uses a stub.
    struct Suspend: Error {
        let onStop: @Sendable () -> Void
    }

    /// Thrown by a handler to answer after `delay` instead of at once, without
    /// blocking the shared protocol thread (see `Suspend`). `beforeAnswer` runs
    /// right before the response is handed to the loading system, so a test can
    /// count how many requests are in flight between the handler call and the
    /// answer; it does not run when the request is stopped first. It runs
    /// before rather than after: once the request has finished loading, its
    /// caller may resume and start its next request while the answering
    /// thread has not yet run the hook, and a count dropped there would
    /// include both.
    struct Delayed: Error {
        let delay: TimeInterval
        let response: HTTPURLResponse
        let data: Data
        let beforeAnswer: @Sendable () -> Void
    }

    private var onStop: (@Sendable () -> Void)?
    private var pendingDelivery: DispatchWorkItem?
    private let deliveryLock = NSLock()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var capturedRequests: [String: [URLRequest]] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[host.lowercased()] = handler
        capturedRequests[host.lowercased()] = []
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests[host.lowercased()] ?? []
    }

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        register(host: host, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DynamoDBStubURLProtocol.self]
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
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch let suspend as Suspend {
            onStop = suspend.onStop
        } catch let delayed as Delayed {
            deliverLater(delayed)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        deliveryLock.lock()
        pendingDelivery?.cancel()
        deliveryLock.unlock()
        onStop?()
    }

    private func deliverLater(_ delayed: Delayed) {
        let delivery = DispatchWorkItem { [self] in
            delayed.beforeAnswer()
            client?.urlProtocol(self, didReceive: delayed.response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: delayed.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        deliveryLock.lock()
        pendingDelivery = delivery
        deliveryLock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delayed.delay, execute: delivery)
    }

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

func dynamoStubResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
}

func dynamoStubJSON(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func dynamoStubBody(_ data: Data?) -> [String: Any] {
    guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return json
}

/// Thread-safe mutable box for counters/captured values read or written
/// inside a `@Sendable` stub handler closure — Swift Testing runs `@Test`s
/// concurrently by default, so a plain captured `var` doesn't compile.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }

    var wrappedValue: T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }
}
