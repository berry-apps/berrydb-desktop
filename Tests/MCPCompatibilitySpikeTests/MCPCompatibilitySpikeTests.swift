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
