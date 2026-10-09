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
        // The default configuration, not `.strict`. Under `.strict`,
        // swift-sdk 0.12.1 sends no response at all to a request other than
        // `initialize` or `ping` that arrives before initialization:
        // `handleRequest` throws before any handler runs and the receive loop
        // discards the error (`start` and `handleRequest` in Server.swift), so
        // the client waits until its own timeout, as observed with this
        // helper and a `tools/call` sent before `initialize`. Under the
        // default configuration such a request is served, without roots (see
        // `MCPSessionContext`), and a method the server lacks, such as the
        // `server/discover` probe, gets `-32601`.
        let server = Server(
            name: serverName,
            version: dependencies.version,
            capabilities: .init(resources: .init(), tools: .init())
        )
        let rootsDeclared = Flag()
        let initialized = Flag()
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
            initialized: { initialized.isSet },
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

        // The hook runs inside the SDK's initialize handler, before the
        // initialize response is sent (`registerDefaultHandlers` in
        // Server.swift of swift-sdk 0.12.1), so a request the host sends
        // after that response always sees both flags.
        let start: @Sendable (any Transport) async throws -> Void = { transport in
            try await server.start(transport: transport) { _, capabilities in
                if capabilities.roots != nil { rootsDeclared.set() }
                initialized.set()
            }
        }
        return (server, start)
    }

    /// A fact about the connection written once by the initialize hook and
    /// read by later requests on other tasks.
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
