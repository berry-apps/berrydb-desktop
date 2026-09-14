import Foundation
import Testing

@testable import BerryAI

@Suite("MCP client")
struct MCPTests {
 // MARK: - Allowlist manifest

    @Test func parsesAllowlistManifest() throws {
        let json = Data(#"""
        [
          {
            "id": "codebase-memory",
            "name": "Codebase Memory",
            "description": "Index local code.",
            "launch": { "command": "codebase-memory-mcp", "args": ["--stdio"] },
            "enabledByDefault": false
          }
        ]
        """#.utf8)
        let servers = try parseMCPAllowlist(json)
        #expect(servers.count == 1)
        #expect(servers[0].id == "codebase-memory")
        #expect(servers[0].command == "codebase-memory-mcp")
        #expect(servers[0].args == ["--stdio"])
        #expect(servers[0].enabledByDefault == false)
    }

    @Test func loadsBundledAllowlist() {
        let servers = MCPAllowlist.bundled()
        #expect(servers.contains { $0.id == "codebase-memory" })
    }

    @Test func parsesToolsListResult() {
        let result = #"{"tools":[{"name":"search_graph","description":"Search.","inputSchema":{"type":"object"}}]}"#
        let tools = ProcessMCPServerConnection.parseTools(result)
        #expect(tools.map(\.name) == ["search_graph"])
        #expect(tools.first?.inputSchemaJSON.contains("object") == true)
    }

 // MARK: - JSON-RPC codec

    @Test func encodesAndDecodesJSONRPC() throws {
        let line = JSONRPC.encodeRequest(id: 7, method: "tools/list", params: [:])
        // JSONSerialization escapes "/" as "\/" and key order/spacing vary, so
        // assert on the decoded shape, not an exact substring.
        let object = try #require((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "tools/list")
        #expect(object["id"] as? Int == 7)

        let response = JSONRPC.decodeResponse(#"{"jsonrpc":"2.0","id":7,"result":{"ok":true}}"#)
        #expect(response?.id == 7)
        #expect(response?.error == nil)
        #expect(response?.result?.contains("ok") == true)

        let errorResponse = JSONRPC.decodeResponse(#"{"jsonrpc":"2.0","id":8,"error":{"code":-32601,"message":"Method not found"}}"#)
        #expect(errorResponse?.error == "Method not found")
    }

    @Test func lineFramerEmitsCompleteLines() {
        let framer = LineFramer()
        #expect(framer.feed("{\"a\":1}\n{\"b\"").isEmpty == false)
        // First feed yields the first complete line only.
        let first = LineFramer()
        #expect(first.feed("{\"a\":1}\n{\"b\"") == ["{\"a\":1}"])
        #expect(first.feed(":2}\n") == ["{\"b\":2}"])
    }

 // MARK: - Namespacing + routing

    @Test func parsesNamespacedToolName() {
        #expect(MCPToolExecutor.parseToolName("mcp:codebase-memory:search_graph")?.server == "codebase-memory")
        #expect(MCPToolExecutor.parseToolName("mcp:codebase-memory:search_graph")?.tool == "search_graph")
        #expect(MCPToolExecutor.parseToolName("run_sql") == nil)
        #expect(MCPToolExecutor.parseToolName("mcp:only") == nil)
    }

    private struct FakeConnection: MCPServerConnection {
        let serverID: String
        let reply: String
        func callTool(name: String, argumentsJSON: String) async throws -> String { reply }
    }

    private actor CountingConnection: MCPServerConnection {
        nonisolated let serverID: String
        private(set) var calls = 0

        init(serverID: String) { self.serverID = serverID }

        func callTool(name: String, argumentsJSON: String) async throws -> String {
            calls += 1
            return "ran"
        }
    }

    @MainActor
    @Test func advertisesNamespacedTools() {
        let executor = MCPToolExecutor(servers: [
            .init(
                connection: FakeConnection(serverID: "cbm", reply: ""),
                tools: [MCPToolSpec(name: "search_graph", description: "Search.", inputSchemaJSON: #"{"type":"object"}"#)]
            ),
        ])
        #expect(executor.toolSpecs.map(\.name) == ["mcp:cbm:search_graph"])
    }

    @MainActor
    @Test func routesCallToTheNamedServer() async {
        let executor = MCPToolExecutor(servers: [
            .init(connection: FakeConnection(serverID: "cbm", reply: "hits: 3"), tools: []),
        ])
        let outcome = await executor.execute(AIToolCall(id: "c", name: "mcp:cbm:search_graph", args: ["q": "users"]))
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("hits: 3") == true)
    }

    @MainActor
    @Test func unknownServerIsAnError() async {
        let executor = MCPToolExecutor(servers: [])
        let outcome = await executor.execute(AIToolCall(id: "c", name: "mcp:ghost:tool", args: [:]))
        #expect(outcome.status == "error")
    }

    private struct FakeMCPGate: MCPApprovalGate {
        let decision: Bool
        func approveMCP(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool) async -> Bool { decision }
    }

    @MainActor
    private final class RecordingMCPGate: MCPApprovalGate {
        private(set) var forcePrompt = false

        func approveMCP(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool) async -> Bool {
            self.forcePrompt = forcePrompt
            return true
        }
    }

    @MainActor
    private final class SuspendedMCPGate: MCPApprovalGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var decisionContinuation: CheckedContinuation<Bool, Never>?
        private var entered = false

        func approveMCP(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool) async -> Bool {
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            return await withCheckedContinuation { decisionContinuation = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredContinuation = $0 }
        }

        func resume(_ decision: Bool) {
            decisionContinuation?.resume(returning: decision)
            decisionContinuation = nil
        }
    }

    @MainActor
    @Test func deniedMCPCallIsNotExecuted() async {
        let executor = MCPToolExecutor(
            servers: [.init(connection: FakeConnection(serverID: "cbm", reply: "ran"), tools: [])],
            gate: FakeMCPGate(decision: false)
        )
        let outcome = await executor.execute(AIToolCall(id: "c", name: "mcp:cbm:search_graph", args: [:]))
        #expect(outcome.status == "denied")
    }

    @MainActor
    @Test func authoritativeAlwaysApprovalForcesPromptEvenForTrustedGate() async {
        let gate = RecordingMCPGate()
        let executor = MCPToolExecutor(
            servers: [.init(connection: FakeConnection(serverID: "cbm", reply: "ran"), tools: [])],
            gate: gate
        )
        _ = await executor.execute(AIToolCall(
            id: "c", name: "mcp:cbm:search_graph", args: [:], approval: "always"
        ))
        #expect(gate.forcePrompt)
    }

    @MainActor
    @Test func authoritativeAlwaysApprovalWithoutGateFailsClosed() async {
        let executor = MCPToolExecutor(
            servers: [.init(connection: FakeConnection(serverID: "cbm", reply: "ran"), tools: [])]
        )
        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "mcp:cbm:search_graph", args: [:], approval: "always"
        ))
        #expect(outcome.status == "denied")
    }

    @MainActor
    @Test func disconnectOmitsMCPToolsAndInvalidatesGeneration() async {
        let executor = MCPToolExecutor(servers: [
            .init(
                connection: FakeConnection(serverID: "cbm", reply: ""),
                tools: [.init(
                    name: "search_graph", description: "Search",
                    inputSchemaJSON: #"{"type":"object"}"#
                )]
            ),
        ])
        let before = executor.capabilityGeneration
        #expect(executor.toolSpecs.map(\.name) == ["mcp:cbm:search_graph"])

        await executor.disconnectAll()

        #expect(executor.toolSpecs.isEmpty)
        #expect(executor.capabilityGeneration != before)
    }

    @MainActor
    @Test func disconnectDuringApprovalPreventsOldMCPDispatch() async {
        let connection = CountingConnection(serverID: "cbm")
        let gate = SuspendedMCPGate()
        let executor = MCPToolExecutor(
            servers: [.init(
                connection: connection,
                tools: [.init(
                    name: "search_graph", description: "Search",
                    inputSchemaJSON: #"{"type":"object"}"#
                )]
            )],
            gate: gate
        )
        let host = LocalCapabilityHost(executor: ToolRouter(
            routes: [:], prefixRoutes: [("mcp:", executor)]
        ))
        _ = try! host.beginTurn(with: executor.toolSpecs)
        try! host.setTransportMode(.legacy)

        let task = Task {
            await host.execute(.init(
                id: "c", name: "mcp:cbm:search_graph", args: [:],
                approval: "always"
            ))
        }
        await gate.waitUntilEntered()
        await executor.disconnectAll()
        gate.resume(true)
        let outcome = await task.value
        let callCount = await connection.calls

        #expect(outcome.status == "denied")
        #expect(callCount == 0)
    }
}
