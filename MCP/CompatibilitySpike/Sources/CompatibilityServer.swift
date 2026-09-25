import Foundation
import MCP

enum CompatibilityServer {
    struct ToolDescriptor: Sendable, Equatable {
        let name: String
        let description: String
        let acceptsArguments: Bool
    }

    enum Error: Swift.Error, Equatable {
        case invalidArguments
    }

    static let echoToolDescriptor = ToolDescriptor(
        name: "berrydb_compatibility_echo",
        description: "Returns a fixed compatibility response.",
        acceptsArguments: false
    )

    static func echo(arguments: [String: String]?) throws -> String {
        guard arguments?.isEmpty != false else {
            throw Error.invalidArguments
        }
        return "berrydb-mcp-compatible"
    }

    static func makeServer() async -> Server {
        let server = Server(
            name: "berrydb-mcp-compatibility-spike",
            version: "0.1.0",
            instructions: "Compatibility fixture for BerryDB's local MCP server.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .strict
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(
                    name: echoToolDescriptor.name,
                    description: echoToolDescriptor.description,
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([:]),
                        "additionalProperties": .bool(false),
                    ]),
                    annotations: .init(
                        readOnlyHint: true,
                        destructiveHint: false,
                        idempotentHint: true,
                        openWorldHint: false
                    )
                )
            ])
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard params.name == echoToolDescriptor.name else {
                throw MCPError.invalidParams("Unknown tool: \(params.name)")
            }
            guard params.arguments?.isEmpty != false else {
                throw MCPError.invalidParams("This tool accepts no arguments")
            }

            if let rawDelay = ProcessInfo.processInfo.environment["BERRYDB_MCP_SPIKE_ECHO_DELAY_MS"],
               let delay = UInt64(rawDelay), delay > 0
            {
                emitStartedMarkerIfRequested()
                try await Task.sleep(for: .milliseconds(delay))
            }

            return .init(
                content: [.text(text: try echo(arguments: nil), annotations: nil, _meta: nil)],
                isError: false
            )
        }

        return server
    }

    private static func emitStartedMarkerIfRequested() {
        guard ProcessInfo.processInfo.environment["BERRYDB_MCP_SPIKE_EMIT_STARTED_MARKER"] == "1"
        else { return }
        FileHandle.standardError.write(Data("berrydb-mcp-spike:echo-started\n".utf8))
    }
}
