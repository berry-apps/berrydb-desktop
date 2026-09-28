import Foundation
import Testing
@testable import MCPCompatibilitySpike

@Suite("MCP compatibility spike", .serialized)
struct MCPCompatibilitySpikeTests {
    @Test("the fixture advertises one strict no-argument tool")
    func toolContract() {
        let descriptor = CompatibilityServer.echoToolDescriptor

        #expect(descriptor.name == "berrydb_compatibility_echo")
        #expect(descriptor.description == "Returns a fixed compatibility response.")
        #expect(descriptor.acceptsArguments == false)
    }

    @Test("the fixture separates success from invalid input")
    func callValidation() throws {
        #expect(try CompatibilityServer.echo(arguments: nil) == "berrydb-mcp-compatible")
        #expect(throws: CompatibilityServer.Error.invalidArguments) {
            try CompatibilityServer.echo(arguments: ["unexpected": "value"])
        }
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

    @Test("stdio executable completes the strict lifecycle and validates calls")
    func stdioLifecycle() throws {
        let process = try SpikeProcess()
        defer { process.stopIfNeeded() }

        try process.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "berrydb-tests", "version": "1.0"],
            ],
        ])
        let initialize = try process.response(id: 1)
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")

        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try process.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ])
        let list = try process.response(id: 2)
        let listResult = try #require(list["result"] as? [String: Any])
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        let tool = try #require(tools.first)
        #expect(tool["name"] as? String == "berrydb_compatibility_echo")
        #expect(tool["description"] as? String == "Returns a fixed compatibility response.")
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect((schema["properties"] as? [String: Any])?.isEmpty == true)
        #expect(schema["additionalProperties"] as? Bool == false)
        let annotations = try #require(tool["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == true)
        #expect(annotations["destructiveHint"] as? Bool == false)
        #expect(annotations["idempotentHint"] as? Bool == true)
        #expect(annotations["openWorldHint"] as? Bool == false)

        try process.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "berrydb_compatibility_echo", "arguments": [:]],
        ])
        let call = try process.response(id: 3)
        let callResult = try #require(call["result"] as? [String: Any])
        #expect(callResult["isError"] as? Bool == false)
        let content = try #require(callResult["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "berrydb-mcp-compatible")

        try process.send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": [
                "name": "berrydb_compatibility_echo",
                "arguments": ["unexpected": true],
            ],
        ])
        let invalid = try process.response(id: 4)
        let error = try #require(invalid["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)

        try process.closeInputAndWaitForExit()
        #expect(process.hasOnlyJSONStdout)
    }

    @Test("stdio executable accepts the Codex 0.154.0 initialize payload")
    func codexInitializeCompatibility() throws {
        let process = try SpikeProcess()
        defer { process.stopIfNeeded() }

        try process.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "experimental": ["codex/auth-change": [:]],
                    "elicitation": ["form": [:], "url": [:]],
                ],
                "clientInfo": ["name": "codex-mcp-client", "version": "0.154.0"],
            ],
        ])
        let initialize = try process.response(id: 1)
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")

        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try process.send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ])
        let list = try process.response(id: 2)
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["berrydb_compatibility_echo"])

        try process.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "berrydb_compatibility_echo", "arguments": [:]],
        ])
        let call = try process.response(id: 3)
        let content = try #require((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "berrydb-mcp-compatible")

        try process.closeInputAndWaitForExit()
        #expect(process.hasOnlyJSONStdout)
    }

    @Test("stdio executable exposes the server-side legacy discovery contract")
    func legacyDiscoveryServerContract() throws {
        let process = try SpikeProcess()
        defer { process.stopIfNeeded() }

        // Captured verbatim from authenticated Antigravity CLI 1.2.11. The
        // fixture is intentionally a 2025-11-25 server, so it must reject the
        // modern discovery method with Method not found instead of claiming
        // support for the stateless 2026-07-28 protocol. The remainder drives
        // the server-side legacy lifecycle; client fallback is host evidence.
        try process.send([
            "jsonrpc": "2.0", "id": 1, "method": "server/discover",
            "params": [
                "_meta": [
                    "io.modelcontextprotocol/clientCapabilities": [
                        "elicitation": ["form": [:], "url": [:]],
                        "roots": ["listChanged": true],
                    ],
                    "io.modelcontextprotocol/clientInfo": [
                        "name": "antigravity-client", "version": "v1.0.0",
                    ],
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                ],
            ],
        ])
        let discovery = try process.response(id: 1)
        let discoveryError = try #require(discovery["error"] as? [String: Any])
        #expect(discoveryError["code"] as? Int == -32601)

        try process.send([
            "jsonrpc": "2.0", "id": 2, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "antigravity-client", "version": "v1.0.0"],
            ],
        ])
        let initialize = try process.response(id: 2)
        #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try process.send([
            "jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:],
        ])
        let list = try process.response(id: 3)
        let tools = try #require((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["berrydb_compatibility_echo"])

        try process.send([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "berrydb_compatibility_echo", "arguments": [:]],
        ])
        let call = try process.response(id: 4)
        let content = try #require((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "berrydb-mcp-compatible")

        try process.closeInputAndWaitForExit()
        #expect(process.hasOnlyJSONStdout)
    }

    @Test("stdio executable cancels a delayed request without a response")
    func stdioCancellation() throws {
        let process = try SpikeProcess(environment: [
            "BERRYDB_MCP_SPIKE_ECHO_DELAY_MS": "750",
            "BERRYDB_MCP_SPIKE_EMIT_STARTED_MARKER": "1",
        ])
        defer { process.stopIfNeeded() }

        try process.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": ["name": "berrydb-tests", "version": "1.0"],
            ],
        ])
        _ = try process.response(id: 1)
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try process.send([
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "berrydb_compatibility_echo", "arguments": [:]],
        ])
        try process.waitForStderrLine("berrydb-mcp-spike:echo-started")
        try process.send([
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": 5, "reason": "integration test"],
        ])

        // Keep the connection open longer than the uncancelled handler delay.
        // A response after this point would prove cancellation did not stop it.
        Thread.sleep(forTimeInterval: 1.0)
        #expect(process.message(id: 5) == nil)
        try process.closeInputAndWaitForExit()
        #expect(process.hasOnlyJSONStdout)
    }
}

private final class SpikeProcess: @unchecked Sendable {
    enum HarnessError: Swift.Error, CustomStringConvertible {
        case executableMissing(String)
        case timeout(String)

        var description: String {
            switch self {
            case .executableMissing(let path): "Missing compatibility executable at \(path)"
            case .timeout(let operation): "Timed out waiting for \(operation)"
            }
        }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var messages: [[String: Any]] = []
    private(set) var nonJSONStdout: [String] = []
    private var pending = Data()
    private var stderrLines: [String] = []
    private var pendingStderr = Data()

    var hasOnlyJSONStdout: Bool {
        lock.withLock { nonJSONStdout.isEmpty && pending.isEmpty }
    }

    init(environment: [String: String] = [:]) throws {
        let root = FileManager.default.currentDirectoryPath
        let executable = root + "/.build/debug/MCPCompatibilitySpike"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HarnessError.executableMissing(executable)
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in
            override
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        try process.run()
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(UInt8(ascii: "\n"))
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func response(id: Int, timeout: TimeInterval = 2) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = message(id: id) { return value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HarnessError.timeout("JSON-RPC response \(id)")
    }

    func message(id: Int) -> [String: Any]? {
        lock.withLock {
            messages.first { ($0["id"] as? Int) == id }
        }
    }

    func waitForStderrLine(_ expected: String, timeout: TimeInterval = 2) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ stderrLines.contains(expected) }) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HarnessError.timeout("stderr marker \(expected)")
    }

    func closeInputAndWaitForExit(timeout: TimeInterval = 2) throws {
        try stdinPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else { throw HarnessError.timeout("EOF shutdown") }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        consumeStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        consumeStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        lock.withLock {
            if !pending.isEmpty {
                nonJSONStdout.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll()
            }
        }
        #expect(process.terminationStatus == 0)
    }

    func stopIfNeeded() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            pending.append(data)
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                do {
                    let object = try JSONSerialization.jsonObject(with: line)
                    guard let message = object as? [String: Any] else {
                        nonJSONStdout.append(String(decoding: line, as: UTF8.self))
                        continue
                    }
                    messages.append(message)
                } catch {
                    nonJSONStdout.append(String(decoding: line, as: UTF8.self))
                }
            }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            pendingStderr.append(data)
            while let newline = pendingStderr.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(pendingStderr[..<newline])
                pendingStderr.removeSubrange(...newline)
                if !line.isEmpty {
                    stderrLines.append(String(decoding: line, as: UTF8.self))
                }
            }
        }
    }
}
