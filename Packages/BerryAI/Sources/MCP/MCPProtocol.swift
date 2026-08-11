import Foundation

// Minimal MCP (Model Context Protocol) client pieces — allowlist manifest,
// JSON-RPC 2.0 codec, line framing, and the connection abstraction. Self-written,
// no SDK (docs/agents/architecture/08 §4). The real Process/Pipe stdio transport
// is a follow-up gated on the App Sandbox feasibility check (§8).

/// One curated MCP server from the packaged allowlist (docs/agents/architecture/08 §2).
/// `command`/`args` are fixed — never user-editable; only BerryDB changes them via a release.
public struct MCPServerManifest: Equatable, Sendable, Decodable {
    public let id: String
    public let name: String
    public let description: String
    public let command: String
    public let args: [String]
    public let enabledByDefault: Bool

    public init(id: String, name: String, description: String, command: String, args: [String], enabledByDefault: Bool) {
        self.id = id
        self.name = name
        self.description = description
        self.command = command
        self.args = args
        self.enabledByDefault = enabledByDefault
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, launch, enabledByDefault }
    private enum LaunchKeys: String, CodingKey { case command, args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        let launch = try c.nestedContainer(keyedBy: LaunchKeys.self, forKey: .launch)
        command = try launch.decode(String.self, forKey: .command)
        args = try launch.decodeIfPresent([String].self, forKey: .args) ?? []
        enabledByDefault = try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? false
    }
}

/// Parses the packaged `mcp-allowlist.json` (docs/agents/architecture/08 §2).
public func parseMCPAllowlist(_ data: Data) throws -> [MCPServerManifest] {
    try JSONDecoder().decode([MCPServerManifest].self, from: data)
}

/// `Bundle.module`'s generated accessor traps if it can't find this
/// package's resource bundle in a packaged, signed `.app` — see the same
/// note on `berryModuleBundle` in BerryUI/Sources/Localization.swift, and
/// docs/tests/crash.md for the real crash this caused. Checks the correct
/// packaged-app and dev-run locations first; `.module` itself is only a last
/// resort (in practice, `swift test`, where it's already safe).
private let berryAIModuleBundle: Bundle = {
    let name = "BerryDB_BerryAI.bundle"
    if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let bundle = Bundle(url: url) {
        return bundle
    }
    if let bundle = Bundle(url: Bundle.main.bundleURL.appendingPathComponent(name)) {
        return bundle
    }
    return .module
}()

public enum MCPAllowlist {
    /// The curated server list bundled with BerryAI (docs/agents/architecture/08 §2).
    /// Returns [] if the resource is missing/unreadable rather than trapping.
    public static func bundled() -> [MCPServerManifest] {
        guard let url = berryAIModuleBundle.url(forResource: "mcp-allowlist", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let servers = try? parseMCPAllowlist(data) else { return [] }
        return servers
    }
}

/// One tool a server exposes via `tools/list` (docs/agents/architecture/08 §4).
public struct MCPToolSpec: Equatable, Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// A connected, initialized MCP server we can call tools on. The production impl
/// drives a subprocess over stdio; tests use a fake.
public protocol MCPServerConnection: Sendable {
    var serverID: String { get }
    /// `argumentsJSON` is the tool arguments as a JSON object string (Sendable).
    func callTool(name: String, argumentsJSON: String) async throws -> String
}

/// Minimal JSON-RPC 2.0 codec (docs/agents/architecture/08 §4). One message per line.
public enum JSONRPC {
    /// A single-line JSON-RPC request.
    public static func encodeRequest(id: Int, method: String, params: [String: Any]) -> String {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { object["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    public struct Response: Equatable {
        public let id: Int?
        /// `result` re-serialized as a JSON string (nil when the message is an error).
        public let result: String?
        public let error: String?
    }

    public static func decodeResponse(_ line: String) -> Response? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let id = object["id"] as? Int
        var result: String?
        if let value = object["result"],
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            result = String(data: data, encoding: .utf8)
        }
        var error: String?
        if let e = object["error"] as? [String: Any] {
            error = e["message"] as? String ?? "JSON-RPC error"
        }
        return Response(id: id, result: result, error: error)
    }
}

/// Incremental line framer for line-delimited JSON over stdio — same shape as
/// SSEParser's buffering. Emits complete lines, dropping empties.
public final class LineFramer {
    private var buffer = ""
    public init() {}

    public func feed(_ chunk: String) -> [String] {
        buffer += chunk
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
