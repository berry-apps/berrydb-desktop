import BerryCore
import Foundation

/// Approval for one MCP tool call (docs/agents/architecture/08 §6). MCP tools are
/// black boxes — no DangerGuard classification is possible — so unless the user
/// has trusted the server, every call prompts. Distinct from the SQL AIApprovalGate.
@MainActor
public protocol MCPApprovalGate {
    func approveMCP(serverID: String, toolName: String, argumentsJSON: String, forcePrompt: Bool) async -> Bool
}

/// Routes `mcp:<server>:<tool>` calls to the right connected MCP server and
/// advertises those servers' tools (docs/agents/architecture/08 §5). Namespacing
/// keeps MCP tools from colliding with the built-in SQL/graph/skill tools.
///
/// Tools are fetched once (via `tools/list`) when a server is enabled and passed
/// in here, so `toolSpecs` stays synchronous — the async work is the one-time
/// discovery the caller does, plus `callTool` at execution time.
@MainActor
public final class MCPToolExecutor: AIToolExecutor {
    public struct ConnectedServer {
        public let connection: any MCPServerConnection
        public let tools: [MCPToolSpec]
        public init(connection: any MCPServerConnection, tools: [MCPToolSpec]) {
            self.connection = connection
            self.tools = tools
        }
    }

    private var servers: [String: ConnectedServer]
    private let gate: (any MCPApprovalGate)?
    private var generation: UInt64 = 0

    public init(servers: [ConnectedServer] = [], gate: (any MCPApprovalGate)? = nil) {
        var map: [String: ConnectedServer] = [:]
        for server in servers { map[server.connection.serverID] = server }
        self.servers = map
        self.gate = gate
    }

    /// Spawns each enabled allowlisted server and caches its `tools/list` (§5).
    /// A server that fails to launch/handshake is skipped, not fatal.
    public func connect(_ manifests: [MCPServerManifest], enabled: Set<String>) async {
        for manifest in manifests where enabled.contains(manifest.id) && servers[manifest.id] == nil {
            let connection = ProcessMCPServerConnection(manifest: manifest)
            if let tools = try? await connection.start() {
                servers[manifest.id] = ConnectedServer(connection: connection, tools: tools)
                generation &+= 1
            }
        }
    }

    /// Tears down every connected server (on rebind / disable).
    public func disconnectAll() async {
        let hadServers = !servers.isEmpty
        for server in servers.values {
            if let process = server.connection as? ProcessMCPServerConnection {
                await process.shutdown()
            }
        }
        servers.removeAll()
        if hadServers { generation &+= 1 }
    }

    public var capabilityGeneration: String {
        let identities = servers.values
            .flatMap { server in
                server.tools.map { "\(server.connection.serverID):\($0.name)" }
            }
            .sorted()
            .joined(separator: ",")
        return "mcp:\(generation):\(identities)"
    }

    public var toolSpecs: [AIToolSpec] {
        servers.values.flatMap { server in
            server.tools.map { tool in
                AIToolSpec(
                    name: "mcp:\(server.connection.serverID):\(tool.name)",
                    description: tool.description,
                    parametersJSON: tool.inputSchemaJSON
                )
            }
        }
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await execute(call, lease: .alwaysValid())
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let expectedGeneration = capabilityGeneration
        guard let (serverID, toolName) = Self.parseToolName(call.name) else {
            return .failed("Not an MCP tool: '\(call.name)'")
        }
        guard let server = servers[serverID] else {
            return .failed("No enabled MCP server '\(serverID)'")
        }
        let argumentsJSON = Self.argumentsJSON(call.args)
        // MCP tools are black boxes — always ask unless the server is trusted (§6).
        if call.approval == "always", gate == nil {
            return .denied
        }
        DiagnosticLog.default.event(
            "mcp awaiting approval", detail: "server=\(serverID) tool=\(toolName)"
        )
        if let gate, await gate.approveMCP(
            serverID: serverID,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            forcePrompt: call.approval == "always"
        ) == false {
            return .denied
        }
        DiagnosticLog.default.event(
            "mcp approval granted", detail: "server=\(serverID) tool=\(toolName)"
        )
        guard lease.isValid,
              capabilityGeneration == expectedGeneration,
              servers[serverID] != nil else {
            return .denied
        }
        do {
            guard lease.isValid else { return .denied }
            DiagnosticLog.default.event(
                "mcp callTool begin", detail: "server=\(serverID) tool=\(toolName)"
            )
            let result = try await server.connection.callTool(name: toolName, argumentsJSON: argumentsJSON)
            DiagnosticLog.default.event(
                "mcp callTool end", detail: "server=\(serverID) tool=\(toolName)"
            )
            guard lease.isValid,
                  capabilityGeneration == expectedGeneration else {
                return .denied
            }
            return .ok(#"{"result":\#(Self.jsonString(result))}"#)
        } catch {
            guard lease.isValid,
                  capabilityGeneration == expectedGeneration else {
                return .denied
            }
            return .failed(error.localizedDescription)
        }
    }

    /// Splits `mcp:<server>:<tool>`. Negotiated dynamic IDs use exactly these
    /// three safe segments; additional colons are rejected by the host.
    nonisolated static func parseToolName(_ name: String) -> (server: String, tool: String)? {
        guard name.hasPrefix("mcp:") else { return nil }
        let rest = name.dropFirst("mcp:".count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let server = String(rest[..<colon])
        let tool = String(rest[rest.index(after: colon)...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// Flat string tool args → a JSON object string, parsing each value as JSON
    /// when it looks like it (numbers/objects/arrays), else keeping the string.
    private static func argumentsJSON(_ args: [String: String]) -> String {
        var out: [String: Any] = [:]
        for (key, value) in args {
            if let data = value.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                out[key] = parsed
            } else {
                out[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func jsonString(_ string: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [string], options: [])) ?? Data("[\"\"]".utf8)
        // Strip the wrapping [ ] to get a single JSON string literal.
        let wrapped = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(wrapped.dropFirst().dropLast())
    }
}
