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
    /// What a server needs to run live reads and, with `partition`, DynamoDB
    /// queries.
    public struct LiveReads: Sendable {
        let service: MCPLiveReadService
        let projectSource: MCPSessionProjectSource
        let partition: MCPPartitionQueryService?

        /// `projectSource` must be the source the service's resolver loads
        /// its project from; `makeServer` binds it to the session it
        /// creates, so the service resolves against that session's project.
        /// A source can be bound once, so one value serves one server.
        /// `partition` serves `berrydb_dynamodb_query` and must resolve
        /// through the same source; without it the server answers that tool
        /// with a fixed refusal.
        public init(
            service: MCPLiveReadService, projectSource: MCPSessionProjectSource, partition: MCPPartitionQueryService? = nil
        ) {
            self.service = service
            self.projectSource = projectSource
            self.partition = partition
        }
    }

    /// Everything a server needs; no value here is a secret.
    public struct Dependencies: Sendable {
        let resolver: MCPProjectContextResolver
        let metadata: MCPMetadataService
        let explicitProject: MCPProjectReference?
        let workingDirectory: String
        let version: String
        let liveReads: LiveReads?
        let diagnostics: @Sendable (String) -> Void
        let onRequest: @Sendable () -> Void
        let audit: MCPAudit?

        /// - Parameters:
        ///   - version: Reported to the host as the server version.
        ///   - liveReads: Serves `berrydb_execute_read_query`; without it the
        ///     server answers that tool with a fixed refusal.
        ///   - diagnostics: Receives diagnostic lines; standard error unless
        ///     replaced, never standard output.
        ///   - onRequest: Called once for every tool or resource request the
        ///     server answers, listings included, each of which reads the
        ///     store.
        ///   - audit: Receives one record per tool call, digested under its
        ///     key; without it nothing is recorded.
        public init(
            resolver: MCPProjectContextResolver,
            metadata: MCPMetadataService,
            explicitProject: MCPProjectReference?,
            workingDirectory: String,
            version: String,
            liveReads: LiveReads? = nil,
            diagnostics: @escaping @Sendable (String) -> Void = MCPSessionContext.standardError,
            onRequest: @escaping @Sendable () -> Void = {},
            audit: MCPAudit? = nil
        ) {
            self.resolver = resolver
            self.metadata = metadata
            self.explicitProject = explicitProject
            self.workingDirectory = workingDirectory
            self.version = version
            self.liveReads = liveReads
            self.diagnostics = diagnostics
            self.onRequest = onRequest
            self.audit = audit
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
        let onRequest = dependencies.onRequest
        let audit = dependencies.audit
        let host = MCPHostIdentity()
        let liveTool = dependencies.liveReads.map { liveReads in
            liveReads.projectSource.bind { await session.context() }
            return MCPLiveReadTool(service: liveReads.service)
        }
        let partitionTool = dependencies.liveReads?.partition.map(MCPDynamoDBQueryTool.init)

        // Each handler resolves the session's project, which reads the store,
        // so each counts as store activity before it starts.
        await server.withMethodHandler(ListTools.self) { _ in
            onRequest()
            let context = await session.context()
            // A store that cannot be read lists neither live tool.
            var live: (sql: Set<UUID>, partition: Set<UUID>) = ([], [])
            if case let .selected(project, _, _) = context {
                live = (try? metadata.liveConnectionIDs(in: project)) ?? ([], [])
            }
            return ListTools.Result(tools: MCPToolCatalog.tools(
                for: context, liveReadConnectionIDs: live.sql, partitionQueryConnectionIDs: live.partition
            ))
        }
        // Live reads and DynamoDB queries are the calls that await a
        // database, so they run on their own path and the metadata router
        // stays synchronous.
        //
        // The audit record is awaited before the response is returned or the
        // error rethrown, so a host that reads the file right after an answer
        // sees that call. A write failure is reported once by the writer and
        // never reaches the host. The writer makes no cancellation checks, so
        // a handler whose task was cancelled still writes its record.
        await server.withMethodHandler(CallTool.self) { params in
            onRequest()
            let started = ContinuousClock.now
            let context = await session.context()
            // Read here rather than from the tool's detail: a tool that
            // refuses before parsing (no project) or throws on another
            // argument returns no detail, and the record must still say
            // which connection the call named.
            var namedConnection: UUID?
            if case let .string(text)? = params.arguments?["connection_id"] { namedConnection = UUID(uuidString: text) }
            let record: @Sendable (MCPAuditRecord.Outcome, MCPAuditDetail, Int) async -> Void = { [namedConnection] outcome, detail, bytes in
                guard let audit else { return }
                var projectID: UUID?
                if case let .selected(project, _, _) = context { projectID = project.project.id }
                await audit.writer.record(MCPAuditRecord(
                    at: Date(), host: host.name, projectID: projectID, profileID: namedConnection ?? detail.profileID,
                    tool: MCPToolName(rawValue: params.name)?.rawValue ?? "unknown", outcome: outcome,
                    error: detail.error, digest: audit.digester.digest(detail.query),
                    durationMs: Int((ContinuousClock.now - started) / .milliseconds(1)),
                    rows: detail.rows, bytes: bytes, truncated: detail.truncated, redacted: detail.redacted,
                    consumedCapacityUnits: detail.consumedCapacityUnits
                ))
            }
            let reply: MCPToolReply
            do {
                if params.name == MCPToolName.executeReadQuery.rawValue, let liveTool {
                    reply = try await liveTool.call(params.arguments, context: context, metadata: metadata)
                } else if params.name == MCPToolName.dynamodbQuery.rawValue, let partitionTool {
                    reply = try await partitionTool.call(params.arguments, context: context, metadata: metadata)
                } else {
                    reply = try router.reply(params.name, arguments: params.arguments, context: context)
                }
            } catch let error as CancellationError {
                await record(.cancelled, MCPAuditDetail(), 0)
                throw error
            } catch let error as MCPError {
                await record(.invalidParams, MCPAuditDetail(), 0)
                throw error
            } catch {
                await record(.error, MCPAuditDetail(error: "unexpected"), 0)
                throw error
            }
            let bytes = reply.result.content.reduce(0) { total, item in
                guard case let .text(text, _, _) = item else { return total }
                return total + text.utf8.count
            }
            await record(reply.result.isError == true ? .error : .ok, reply.audit, bytes)
            return reply.result
        }
        await server.withMethodHandler(ListResources.self) { _ in
            onRequest()
            let context = await session.context()
            return ListResources.Result(resources: try MCPResourceCatalog.resources(for: context, metadata: metadata))
        }
        await server.withMethodHandler(ReadResource.self) { params in
            onRequest()
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
            try await server.start(transport: transport) { info, capabilities in
                host.set(clientName: info.name)
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
