import Foundation
import MCP

/// Compatibility boundary for swift-sdk #262.
///
/// swift-sdk 0.12.1 decodes `Client.Capabilities.experimental` as
/// `[String: String]`, while Codex 0.154.0 sends object-valued entries. Retain
/// the string-valued entries that 0.12.1 can decode and remove only unsupported
/// values until the upstream decoder accepts arbitrary JSON objects.
actor CodexCompatibleStdioTransport: Transport {
    private let base: StdioTransport
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var receiveTask: Task<Void, Never>?

    // Transport requires a nonisolated logger. The wrapped transport keeps its
    // own no-op logger; this second no-op instance is used only for conformance.
    nonisolated let logger = StdioTransport().logger

    init(base: StdioTransport = StdioTransport()) {
        self.base = base
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        try await base.connect()
        let base = self.base
        let continuation = self.continuation
        receiveTask = Task {
            do {
                let upstream = await base.receive()
                for try await message in upstream {
                    continuation.yield(Self.sanitizeIncomingMessage(message))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        continuation.finish()
        await base.disconnect()
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }

    static func sanitizeIncomingMessage(_ data: Data) -> Data {
        guard
            var envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["method"] as? String == "initialize",
            var params = envelope["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimentalValue = capabilities["experimental"]
        else {
            return data
        }

        if let experimental = experimentalValue as? [String: Any] {
            let supported = experimental.compactMapValues { $0 as? String }
            guard supported.count != experimental.count else { return data }
            if supported.isEmpty {
                capabilities.removeValue(forKey: "experimental")
            } else {
                capabilities["experimental"] = supported
            }
        } else {
            capabilities.removeValue(forKey: "experimental")
        }
        params["capabilities"] = capabilities
        envelope["params"] = params
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? data
    }
}
