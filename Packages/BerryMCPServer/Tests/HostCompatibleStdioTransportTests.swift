import Foundation
import MCP
import System
import Testing
@testable import BerryMCPServer

/// The two ends of one pipe, closed together.
private struct PipeEnds {
    let read: Int32
    let write: Int32

    init() throws {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { throw Errno(rawValue: errno) }
        read = ends[0]
        write = ends[1]
        // A write after the reader is gone fails with EPIPE instead of
        // raising SIGPIPE, which would end the whole test process
        // (F_SETNOSIGPIPE, fcntl(2) on macOS).
        _ = fcntl(write, F_SETNOSIGPIPE, 1)
    }

    func close() {
        _ = Darwin.close(write)
        _ = Darwin.close(read)
    }
}

/// The first `count` newline-terminated lines read from `descriptor`, fewer
/// if the writer closes first. Reads with blocking calls on a dedicated
/// thread, so no Swift concurrency thread waits on the pipe.
private func readLines(_ descriptor: Int32, count: Int) async -> [Data] {
    await withCheckedContinuation { continuation in
        Thread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var pending = Data()
            var lines: [Data] = []
            while lines.count < count {
                let received = Darwin.read(descriptor, &buffer, buffer.count)
                guard received > 0 else { break }
                pending.append(contentsOf: buffer[0 ..< received])
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    lines.append(Data(pending[pending.startIndex ..< newline]))
                    pending = Data(pending[(newline + 1)...])
                }
            }
            continuation.resume(returning: lines)
        }.start()
    }
}

@Suite("Host-compatible stdio transport")
struct HostCompatibleStdioTransportTests {
    /// A transport over two pipes instead of the process's standard streams.
    private static func pipedTransport() throws -> (HostCompatibleStdioTransport, input: PipeEnds, output: PipeEnds) {
        let input = try PipeEnds()
        let output = try PipeEnds()
        let base = StdioTransport(input: FileDescriptor(rawValue: input.read), output: FileDescriptor(rawValue: output.write))
        return (HostCompatibleStdioTransport(base: base), input, output)
    }

    /// A payload of `kibibytes` KiB, several times what a pipe holds (64 KiB,
    /// measured on macOS 26.6 by non-blocking writes until EAGAIN), so
    /// writing it meets a full pipe again and again while the reader drains
    /// it.
    private static func payload(_ letter: Character, kibibytes: Int = 256) -> Data {
        Data(repeating: letter.asciiValue!, count: kibibytes << 10)
    }

    /// Whether a pipe holds bytes not yet read; poll(2) with a zero timeout
    /// answers without waiting.
    private static func hasUnread(_ descriptor: Int32) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 0) == 1 && entry.revents & Int16(POLLIN) != 0
    }

    @Test("concurrent sends reach the output one whole message at a time")
    func concurrentSendsNeverInterleave() async throws {
        let (transport, input, output) = try Self.pipedTransport()
        defer {
            input.close()
            output.close()
        }
        try await transport.connect()
        let first = Self.payload("a")
        let second = Self.payload("b")

        let lines = try await withDeadline(.seconds(60)) {
            async let lines = readLines(output.read, count: 2)
            async let sentFirst: Void = transport.send(first)
            async let sentSecond: Void = transport.send(second)
            _ = try await (sentFirst, sentSecond)
            return await lines
        }
        await transport.disconnect()

        #expect(lines.count == 2)
        #expect(Set(lines) == [first, second], "a line mixes the bytes of both messages")
    }

    @Test("the discovery fallback reply waits for a message being written")
    func discoveryReplyNeverInterleaves() async throws {
        let (transport, input, output) = try Self.pipedTransport()
        defer {
            input.close()
            output.close()
        }
        try await transport.connect()
        // Once the reader starts, the reply and the large message each retry
        // a full pipe every 10 ms; sixteen pipefuls give the reply many
        // chances to land inside the message if nothing orders the two.
        let large = Self.payload("a", kibibytes: 1024)
        let discover = Data(#"{"jsonrpc":"2.0","id":7,"method":"server/discover","params":{}}"#.utf8 + [UInt8(ascii: "\n")])
        let reply = try #require(HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: discover.dropLast()))

        let lines = try await withDeadline(.seconds(60)) {
            // With no reader yet, the large message stops part-written once
            // the pipe is full, and stays so until the reader starts.
            async let sentLarge: Void = transport.send(large)
            while !Self.hasUnread(output.read) {
                try await Task.sleep(for: .milliseconds(5))
            }
            _ = discover.withUnsafeBytes { Darwin.write(input.write, $0.baseAddress, $0.count) }
            while Self.hasUnread(input.read) {
                try await Task.sleep(for: .milliseconds(5))
            }
            // The transport has read the request; the allowance covers the
            // step from there to its reply attempt, which involves no I/O.
            // Only a reply attempted after the reader has drained the large
            // message would let this test pass without checking the order.
            try await Task.sleep(for: .milliseconds(100))
            async let lines = readLines(output.read, count: 2)
            try await sentLarge
            return await lines
        }
        await transport.disconnect()

        #expect(lines.count == 2)
        #expect(Set(lines) == [large, reply], "the reply was written inside the larger message")
    }

    @Test("a failed send does not hold back the next one")
    func failedSendDoesNotBlockTheNext() async throws {
        let (transport, input, output) = try Self.pipedTransport()
        defer {
            input.close()
            output.close()
        }
        // Not yet connected, so the wrapped transport refuses the send.
        await #expect(throws: (any Error).self) { try await transport.send(Data("{}".utf8)) }
        try await transport.connect()
        let message = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)

        // Far smaller than the pipe, so the write completes before reading.
        try await withDeadline(.seconds(60)) { try await transport.send(message) }
        let lines = try await withDeadline(.seconds(60)) { await readLines(output.read, count: 1) }
        await transport.disconnect()

        #expect(lines == [message])
    }

    @Test("Codex compatibility sanitizer changes only experimental initialize capabilities")
    func codexSanitizerScope() throws {
        let nonInitialize = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"experimental":{"keep":{}}}}"#.utf8)
        #expect(HostCompatibleStdioTransport.sanitizeIncomingMessage(nonInitialize) == nonInitialize)

        let initializeWithoutExperimental = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        #expect(
            HostCompatibleStdioTransport.sanitizeIncomingMessage(initializeWithoutExperimental)
                == initializeWithoutExperimental
        )

        let codexInitialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        let sanitized = HostCompatibleStdioTransport.sanitizeIncomingMessage(codexInitialize)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        #expect(envelope["jsonrpc"] as? String == "2.0")
        #expect(envelope["id"] as? Int == 1)
        #expect(envelope["method"] as? String == "initialize")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(params["clientInfo"] as? [String: String] == [
            "name": "codex-mcp-client", "version": "0.154.0",
        ])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["experimental"] == nil)
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect((elicitation["form"] as? [String: Any])?.isEmpty == true)
        #expect((elicitation["url"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Codex compatibility sanitizer preserves supported experimental entries")
    func codexSanitizerPreservesStrings() throws {
        let stringOnly = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"berry/mode":"safe","berry/version":"1"},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        #expect(HostCompatibleStdioTransport.sanitizeIncomingMessage(stringOnly) == stringOnly)

        let mixed = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"keep":"supported","object":{},"array":[],"null":null,"number":1,"boolean":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        let sanitized = HostCompatibleStdioTransport.sanitizeIncomingMessage(mixed)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        let params = try #require(envelope["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        let experimental = try #require(capabilities["experimental"] as? [String: Any])
        #expect(experimental.count == 1)
        #expect(experimental["keep"] as? String == "supported")
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect((elicitation["form"] as? [String: Any])?.isEmpty == true)
        #expect((elicitation["url"] as? [String: Any])?.isEmpty == true)
    }

    @Test("legacy discovery fallback is narrow and preserves request identifiers")
    func legacyDiscoveryFallbackScope() throws {
        let list = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        #expect(HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: list) == nil)

        let notification = Data(#"{"jsonrpc":"2.0","method":"server/discover","params":{}}"#.utf8)
        #expect(HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: notification) == nil)

        let invalidRequests = [
            #"{"id":1,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"1.0","id":1,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":{},"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":[],"method":"server/discover","params":{}}"#,
        ]
        for invalid in invalidRequests {
            #expect(
                HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(
                    for: Data(invalid.utf8)
                ) == nil
            )
        }

        let request = Data(#"{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#.utf8)
        let responseData = try #require(
            HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: request)
        )
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? String == "discover-1")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
        #expect(error["message"] as? String == "Method not found")

        let numericRequest = Data(#"{"jsonrpc":"2.0","id":7.5,"method":"server/discover","params":{}}"#.utf8)
        let numericResponseData = try #require(
            HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: numericRequest)
        )
        let numericResponse = try #require(
            JSONSerialization.jsonObject(with: numericResponseData) as? [String: Any]
        )
        #expect(numericResponse["id"] as? Double == 7.5)
    }
}
