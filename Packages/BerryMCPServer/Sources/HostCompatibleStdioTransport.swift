import Foundation
import Logging
import MCP

/// The SDK's `StdioTransport` with one compatibility rule for a host message
/// that swift-sdk 0.12.1 cannot decode, and with outgoing messages written
/// one at a time.
///
/// The rule is `sanitizeIncomingMessage`, which keeps the `initialize`
/// request of Codex 0.154.0 decodable
/// (https://github.com/modelcontextprotocol/swift-sdk/issues/262).
///
/// A second rule used to answer the `server/discover` probe of MCP
/// 2026-07-28 with `-32601` here. The host compatibility gate needed it
/// because its fixture ran `.strict`, under which the SDK sends no response
/// to any request but `initialize` and `ping` before initialization. This
/// server runs the default configuration, under which the SDK answers a
/// method it has no handler for with `-32601` itself (`handleRequest` in
/// Server.swift), so the rule only repeated that answer and was removed.
/// `BerryMCPStdioTests.serverDiscoverFallsBackToInitialize` pins the reply
/// that lets a dual-era client such as Antigravity 1.2.11 fall back to
/// `initialize`.
///
/// Every outgoing message is written whole before the next one starts. The
/// wrapped `StdioTransport.send` writes in a loop and, whenever standard
/// output is full (EAGAIN), sleeps 10 ms with its actor free (`send` in
/// StdioTransport.swift of swift-sdk 0.12.1), and the SDK server sends each
/// response from its own task, so without this order a second message could
/// be written into the middle of a first one larger than the pipe.
public actor HostCompatibleStdioTransport: Transport {
    private let base: StdioTransport
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var receiveTask: Task<Void, Never>?
    /// The most recently queued write; the next one starts after it ends.
    private var lastWrite: Task<Void, Swift.Error>?

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

    /// Writes `data` once every earlier message has been written or has
    /// failed; a failed write never holds back the ones queued after it.
    public func send(_ data: Data) async throws {
        let previous = lastWrite
        let base = self.base
        let write = Task {
            _ = await previous?.result
            try await base.send(data)
        }
        lastWrite = write
        try await write.value
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
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
