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
