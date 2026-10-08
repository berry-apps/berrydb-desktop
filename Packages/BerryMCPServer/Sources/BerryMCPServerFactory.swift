import BerryMCP
import Foundation
import MCP
import Synchronization

/// Assembles the MCP server: one session context per connection and the
/// tool and resource handlers that read through it.
///
/// Invariant: every handler obtains its context from the session, so no
/// request is served from a project that was not verified for that request.
public enum BerryMCPServerFactory {
    /// Everything a server needs; no value here is a secret.
    public struct Dependencies: Sendable {
        let resolver: MCPProjectContextResolver
        let metadata: MCPMetadataService
        let explicitProject: UUID?
        let workingDirectory: String
        let version: String
        let diagnostics: @Sendable (String) -> Void

        /// - Parameters:
        ///   - version: Reported to the host as the server version.
        ///   - diagnostics: Receives diagnostic lines; standard error unless
        ///     replaced, never standard output.
        public init(
            resolver: MCPProjectContextResolver,
            metadata: MCPMetadataService,
            explicitProject: UUID?,
            workingDirectory: String,
            version: String,
            diagnostics: @escaping @Sendable (String) -> Void = MCPSessionContext.standardError
        ) {
            self.resolver = resolver
            self.metadata = metadata
            self.explicitProject = explicitProject
            self.workingDirectory = workingDirectory
            self.version = version
            self.diagnostics = diagnostics
        }
    }

    /// The server name reported to hosts.
    public static let serverName = "berrydb-mcp"

    /// Builds a server with ListTools, CallTool, ListResources and ReadResource
    /// handlers. `start` connects it to one transport; a server serves a
    /// single connection.
    public static func makeServer(
        _ dependencies: Dependencies
    ) async -> (server: Server, start: @Sendable (any Transport) async throws -> Void) {
        let server = Server(
            name: serverName,
            version: dependencies.version,
            capabilities: .init(resources: .init(), tools: .init())
        )
        let rootsDeclared = Flag()
        // The SDK's `listRoots()` checks the client's roots capability only
        // in strict mode (`validateClientCapability` in Server.swift of
        // swift-sdk 0.12.1), so the capability recorded at initialization is
        // checked here. The weak reference keeps the session, which the
        // server's handlers retain, from retaining the server in turn.
        let session = MCPSessionContext(
            resolver: dependencies.resolver,
            explicitProject: dependencies.explicitProject,
            workingDirectory: dependencies.workingDirectory,
            listRoots: { [weak server] in
                guard rootsDeclared.isSet, let server else { return nil }
                return try await server.listRoots().map(\.uri)
            },
            diagnostics: dependencies.diagnostics
        )
        let router = MCPToolRouter(metadata: dependencies.metadata)
        let metadata = dependencies.metadata

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPToolCatalog.tools(for: await session.context()))
        }
        await server.withMethodHandler(CallTool.self) { params in
            let context = await session.context()
            return try router.call(params.name, arguments: params.arguments, context: context)
        }
        await server.withMethodHandler(ListResources.self) { _ in
            let context = await session.context()
            return ListResources.Result(resources: try MCPResourceCatalog.resources(for: context, metadata: metadata))
        }
        await server.withMethodHandler(ReadResource.self) { params in
            let context = await session.context()
            return ReadResource.Result(
                contents: try MCPResourceCatalog.read(uri: params.uri, context: context, metadata: metadata)
            )
        }

        let start: @Sendable (any Transport) async throws -> Void = { transport in
            try await server.start(transport: transport) { _, capabilities in
                if capabilities.roots != nil { rootsDeclared.set() }
            }
        }
        return (server, start)
    }

    /// Whether the client declared the roots capability; written once by the
    /// initialize hook and read by later requests on other tasks.
    private final class Flag: Sendable {
        private let value = Mutex(false)

        var isSet: Bool {
            value.withLock { $0 }
        }

        func set() {
            value.withLock { $0 = true }
        }
    }
}
