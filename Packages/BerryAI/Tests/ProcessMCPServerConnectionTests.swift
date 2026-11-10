import Foundation
import Testing

@testable import BerryAI

@Suite("MCP subprocess lifecycle", .serialized)
struct ProcessMCPServerConnectionTests {
    private func connection(script: String, output: Pipe, arguments: [String] = []) -> ProcessMCPServerConnection {
        ProcessMCPServerConnection(manifest: .init(
            id: "lifecycle-test", name: "Lifecycle test", description: "",
            command: "/bin/sh", args: ["-c", script, "mcp-lifecycle-test"] + arguments, enabledByDefault: false
        ), outputPipe: output)
    }

    private func waitForReaderToDetach(_ output: Pipe) async -> Bool {
        for _ in 0..<200 {
            if output.fileHandleForReading.readabilityHandler == nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    @Test func eofDuringInitializeDetachesReader() async {
        let output = Pipe()
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: gate) }
        let client = connection(
            script: #"IFS= read -r request; while [ ! -e "$1" ]; do sleep 0.01; done"#,
            output: output, arguments: [gate.path]
        )
        let start = Task { try await client.start() }
        // Keep stdout open until installation is observed, so an unstarted
        // reader cannot be mistaken for one that detached after EOF.
        var installed = false
        for _ in 0..<200 {
            installed = output.fileHandleForReading.readabilityHandler != nil
            if installed { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(installed)
        let released = FileManager.default.createFile(atPath: gate.path, contents: nil)
        #expect(released)
        let detached = await waitForReaderToDetach(output)
        #expect(detached)
        await client.shutdown()
        _ = await start.result
    }

    private let server = #"""
    IFS= read -r request
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
    IFS= read -r request
    """#

    @Test func eofDuringToolCallDetachesReader() async throws {
        let output = Pipe()
        let client = connection(script: server, output: output)
        _ = try await client.start()
        let call = Task { try await client.callTool(name: "test", argumentsJSON: "{}") }
        let detached = await waitForReaderToDetach(output)
        #expect(detached)
        await client.shutdown()
        _ = await call.result
    }

    @Test func shutdownDetachesReader() async throws {
        let output = Pipe()
        let client = connection(script: server, output: output)
        _ = try await client.start()
        #expect(output.fileHandleForReading.readabilityHandler != nil)
        await client.shutdown()
        #expect(output.fileHandleForReading.readabilityHandler == nil)
    }

    @Test func writeToServerWithClosedStdinThrowsInsteadOfTerminating() async throws {
        let output = Pipe()
        let stdinClosed = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stdinClosed) }
        // After the handshake the server closes its stdin, so the pipe has no
        // reader, and keeps running, so callTool still passes its isRunning check.
        let client = connection(script: #"""
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
        exec 0<&-
        : > "$1"
        exec sleep 10
        """#, output: output, arguments: [stdinClosed.path])
        _ = try await client.start()
        var closed = false
        for _ in 0..<200 {
            closed = FileManager.default.fileExists(atPath: stdinClosed.path)
            if closed { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(closed)
        let calledAt = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await client.callTool(name: "test", argumentsJSON: "{}")
        }
        #expect(ContinuousClock.now - calledAt < .seconds(5))
        await client.shutdown()
    }

    @Test func droppingConnectionDetachesReader() async throws {
        let output = Pipe()
        var client: ProcessMCPServerConnection? = connection(script: server, output: output)
        _ = try await client?.start()
        #expect(output.fileHandleForReading.readabilityHandler != nil)
        client = nil
        let detached = await waitForReaderToDetach(output)
        #expect(detached)
    }
}
