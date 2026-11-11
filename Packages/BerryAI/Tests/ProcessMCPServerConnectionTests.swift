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

    // MARK: - Reading stdout

    /// Answers `initialize`, then reads the `initialized` notification and the
    /// `tools/list` request; a test appends the rest of the server's script.
    private let handshake = #"""
    IFS= read -r request
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
    IFS= read -r notification
    IFS= read -r request
    """#

    @Test func characterSplitAcrossTwoReadsIsDecodedWhole() async throws {
        // The euro sign is the three bytes E2 82 AC. The first write ends after
        // E2, and the pause makes the reader receive the two writes separately.
        let client = connection(script: handshake + "\n" + #"""
        printf '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"price","description":"5 \342'
        sleep 0.2
        printf '\202\254"}]}}\n'
        IFS= read -r request
        """#, output: Pipe())
        let tools = try await client.start()
        #expect(tools.map(\.description) == ["5 \u{20AC}"])
        await client.shutdown()
    }

    @Test func responseWrittenInManyPiecesArrivesIntact() async throws {
        // Two thousand separate writes form one tools/list line, so the reader
        // receives it as many reads that must be framed in the order they came.
        let client = connection(script: handshake + "\n" + #"""
        printf '{"jsonrpc":"2.0","id":2,"result":{"tools":['
        i=1
        while [ "$i" -lt 2000 ]; do printf '{"name":"t%d"},' "$i"; i=$((i + 1)); done
        printf '{"name":"t2000"}]}}\n'
        IFS= read -r request
        """#, output: Pipe())
        let tools = try await client.start()
        #expect(tools.map(\.name) == (1...2000).map { "t\($0)" })
        await client.shutdown()
    }

    @Test func serverExitingBeforeItAnswersFailsStartAtOnce() async {
        let client = connection(script: "IFS= read -r request; exit 0", output: Pipe())
        let calledAt = ContinuousClock.now
        await #expect(throws: ProcessMCPServerConnection.MCPError.notRunning) {
            _ = try await client.start()
        }
        #expect(ContinuousClock.now - calledAt < .seconds(5))
    }

    @Test func serverExitingDuringACallFailsTheCallAtOnce() async throws {
        let client = connection(script: server, output: Pipe())
        _ = try await client.start()
        let calledAt = ContinuousClock.now
        await #expect(throws: ProcessMCPServerConnection.MCPError.notRunning) {
            _ = try await client.callTool(name: "test", argumentsJSON: "{}")
        }
        #expect(ContinuousClock.now - calledAt < .seconds(5))
    }

    @Test func callAfterServerClosedStdoutFailsAtOnce() async throws {
        let output = Pipe()
        // The server closes stdout but keeps running and reading stdin, so only
        // the EOF on stdout shows that no response can arrive.
        let client = connection(script: handshake + "\n" + #"""
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}'
        exec 1>&-
        exec sleep 10
        """#, output: output)
        _ = try await client.start()
        let detached = await waitForReaderToDetach(output)
        #expect(detached)
        let calledAt = ContinuousClock.now
        await #expect(throws: ProcessMCPServerConnection.MCPError.notRunning) {
            _ = try await client.callTool(name: "test", argumentsJSON: "{}")
        }
        #expect(ContinuousClock.now - calledAt < .seconds(5))
        await client.shutdown()
    }

    @Test func responseWrittenJustBeforeExitIsDelivered() async throws {
        // The server exits right after writing a response long enough to reach
        // the reader as many reads. The EOF that follows must not fail the call
        // whose response came before it.
        for _ in 0..<5 {
            let client = connection(script: server + "\n" + #"""
            printf '{"jsonrpc":"2.0","id":3,"result":{"items":['
            i=1
            while [ "$i" -lt 2000 ]; do printf '%d,' "$i"; i=$((i + 1)); done
            printf '2000]}}\n'
            """#, output: Pipe())
            _ = try await client.start()
            let result = try await client.callTool(name: "test", argumentsJSON: "{}")
            let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: [Int]]
            #expect(object?["items"] == Array(1...2000))
            await client.shutdown()
        }
    }
}
