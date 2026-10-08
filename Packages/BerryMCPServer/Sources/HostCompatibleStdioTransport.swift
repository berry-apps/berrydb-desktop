import CoreFoundation
import Foundation
import Logging
import MCP

/// Compatibility boundary for host messages that swift-sdk 0.12.1 cannot
/// process correctly while this server remains on legacy MCP 2025-11-25.
public actor HostCompatibleStdioTransport: Transport {
    private let base: StdioTransport
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var receiveTask: Task<Void, Never>?

    // Transport requires a nonisolated logger. The wrapped transport keeps its
    // own no-op logger; this second no-op instance is used only for conformance.
    public nonisolated let logger = StdioTransport().logger

    public init(base: StdioTransport = StdioTransport()) {
        self.base = base
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        try await base.connect()
        let base = self.base
        let continuation = self.continuation
        receiveTask = Task {
            do {
                let upstream = await base.receive()
                for try await message in upstream {
                    if let response = Self.legacyDiscoveryFallbackResponse(for: message) {
                        try await base.send(response)
                        continue
                    }
                    continuation.yield(Self.sanitizeIncomingMessage(message))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        continuation.finish()
        await base.disconnect()
    }

    public func send(_ data: Data) async throws {
        try await base.send(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }

    /// `server/discover` is a 2026-07-28 probe. The pinned SDK applies its
    /// pre-initialize state guard first and returns `-32600`, which prevents
    /// dual-era clients such as Antigravity 1.2.11 from falling back. Replying
    /// `-32601` truthfully says this legacy server does not implement discovery.
    public static func legacyDiscoveryFallbackResponse(for data: Data) -> Data? {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["jsonrpc"] as? String == "2.0",
            envelope["method"] as? String == "server/discover",
            let id = envelope["id"],
            Self.isValidRequestID(id)
        else {
            return nil
        }

        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32601, "message": "Method not found"],
        ]
        return try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }

    private static func isValidRequestID(_ value: Any) -> Bool {
        if value is String { return true }
        guard let number = value as? NSNumber else { return false }
        // JSONSerialization bridges both JSON numbers and Booleans through
        // NSNumber. JSON-RPC request IDs permit numbers, never Booleans.
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// swift-sdk 0.12.1 decodes `Client.Capabilities.experimental` as
    /// `[String: String]`, while Codex 0.154.0 sends object-valued entries.
    /// Retain decodable strings and remove only unsupported values.
    public static func sanitizeIncomingMessage(_ data: Data) -> Data {
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
