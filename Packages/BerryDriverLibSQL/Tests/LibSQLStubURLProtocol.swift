import Foundation
import os

final class LibSQLStubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    private static let chunkSize = 256
    private static let handlers = OSAllocatedUnfairLock<[String: Handler]>(initialState: [:])
    private static let loadedBytesByHost = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
        loadedBytesByHost.withLock { $0[host] = 0 }
    }

    static func unregister(host: String) {
        handlers.withLock { $0.removeValue(forKey: host) }
        loadedBytesByHost.withLock { $0.removeValue(forKey: host) }
    }

    static func resetLoadedBytes(host: String) {
        loadedBytesByHost.withLock { $0[host] = 0 }
    }

    static func loadedBytes(host: String) -> Int {
        loadedBytesByHost.withLock { $0[host] ?? 0 }
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibSQLStubURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let currentRequest = request
        let body = Self.readBody(from: currentRequest)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                let (response, data) = try handler(currentRequest, body)
                guard !self.cancelled.withLock({ $0 }) else { return }
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    var offset = 0
                    while offset < data.count {
                        guard !self.cancelled.withLock({ $0 }) else { return }
                        let end = min(offset + Self.chunkSize, data.count)
                        let chunk = data.subdata(in: offset..<end)
                        self.client?.urlProtocol(self, didLoad: chunk)
                        Self.loadedBytesByHost.withLock { counts in
                            counts[host, default: 0] += chunk.count
                        }
                        offset = end
                        if offset < data.count {
                            Thread.sleep(forTimeInterval: 0.002)
                        }
                    }
                }
                guard !self.cancelled.withLock({ $0 }) else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            } catch {
                guard !self.cancelled.withLock({ $0 }) else { return }
                self.client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        cancelled.withLock { $0 = true }
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
