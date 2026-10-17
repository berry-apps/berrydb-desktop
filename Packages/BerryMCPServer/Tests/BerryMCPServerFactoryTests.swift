import BerryDriverKit
import BerryGraph
import BerryMCP
import BerryStore
import Foundation
import MCP
import Synchronization
import Testing

@testable import BerryMCPServer

/// A value shared between a test and the closures it hands to the server.
private final class Locked<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    var value: Value {
        storage.withLock { $0 }
    }

    func update(_ body: @Sendable (inout Value) -> Void) {
        storage.withLock { body(&$0) }
    }
}

private struct StoreUnreadable: Error {}

/// How the test client answers `roots/list`.
private enum RootsBehavior: Sendable {
    /// The client declares no roots capability but still registers a handler,
    /// so a request the server should not send would be answered and visible.
    case undeclared([String])
    case declared([String])
    case declaredFailing
}

@Suite("MCP server factory")
struct BerryMCPServerFactoryTests {
    static let storeUnavailableLine = "berrydb-mcp: store unavailable"

    let shop = ConnectionProfile(driverID: "postgres", name: "Shop", envColor: "production")
    let billing = ConnectionProfile(driverID: "sqlite", name: "Billing", filePath: "/data/billing.db")

    var projectA: MCPProject {
        MCPProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, name: "A", isEnabled: true,
            workspaceRoots: ["/work/a"], profiles: [MCPProfileAccess(profileID: shop.id)]
        )
    }

    var projectB: MCPProject {
        MCPProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!, name: "B", isEnabled: true,
            workspaceRoots: ["/work/b"],
            profiles: [MCPProfileAccess(profileID: shop.id), MCPProfileAccess(profileID: billing.id)]
        )
    }

    /// The projects the resolver reads, whether reading them fails, and the
    /// profiles whose live-read switch verifies.
    struct Store: Sendable {
        var projects: [MCPProject]
        var unreadable = false
        var liveReads: Set<UUID> = []
    }

    fileprivate func resolver(_ store: Locked<Store>) -> MCPProjectContextResolver {
        MCPProjectContextResolver(
            loadProjects: {
                let current = store.value
                if current.unreadable { throw StoreUnreadable() }
                return current.projects
            },
            verify: { id in
                let current = store.value
                if current.unreadable { throw StoreUnreadable() }
                return current.projects.first { $0.id == id }.map { project in
                    MCPVerifiedProject(
                        project: project,
                        liveReadProfileIDs: current.liveReads.intersection(project.profiles.map(\.profileID))
                    )
                }
            },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
    }

    /// Both profiles over an empty schema store.
    func metadata() throws -> MCPMetadataService {
        let profiles = [shop, billing]
        let reader = GraphReader(store: try BerryStore(path: ":memory:"))
        return MCPMetadataService(profiles: { profiles }, reader: reader, graph: BerryGraphQueryService(reader: reader))
    }

    /// Connects an in-process client to a freshly built server, runs `body`
    /// and tears both down whether or not `body` throws. Every wait is
    /// bounded, so a request the server never answers fails the test instead
    /// of hanging the suite.
    fileprivate func withSession(
        store: Locked<Store>,
        roots: RootsBehavior,
        workingDirectory: String = "/work/a",
        explicitProject: MCPProjectReference? = nil,
        rootsRequests: Locked<Int> = Locked(0),
        diagnostics: Locked<[String]> = Locked([]),
        requests: Locked<Int> = Locked(0),
        liveReads: BerryMCPServerFactory.LiveReads? = nil,
        _ body: @escaping @Sendable (Client) async throws -> Void
    ) async throws {
        let dependencies = BerryMCPServerFactory.Dependencies(
            resolver: resolver(store), metadata: try metadata(),
            explicitProject: explicitProject, workingDirectory: workingDirectory, version: "test",
            liveReads: liveReads,
            diagnostics: { line in diagnostics.update { $0.append(line) } },
            onRequest: { requests.update { $0 += 1 } }
        )
        let (server, start) = await BerryMCPServerFactory.makeServer(dependencies)

        let declaresRoots: Bool
        let answer: [String]?
        switch roots {
        case .undeclared(let uris):
            declaresRoots = false
            answer = uris
        case .declared(let uris):
            declaresRoots = true
            answer = uris
        case .declaredFailing:
            declaresRoots = true
            answer = nil
        }
        let client = Client(
            name: "test-host", version: "1.0",
            capabilities: .init(roots: declaresRoots ? .init(listChanged: false) : nil)
        )
        await client.withRootsHandler {
            rootsRequests.update { $0 += 1 }
            guard let answer else { throw MCPError.internalError("roots unavailable") }
            return answer.map { Root(uri: $0) }
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        do {
            try await withDeadline(.seconds(30)) {
                try await start(serverTransport)
                try await client.connect(transport: clientTransport)
                try await body(client)
            }
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }

    /// Every tool but the live one, which needs a live-read connection.
    static let metadataToolCount = MCPToolName.allCases.count - 1

    static func call(_ client: Client, _ tool: MCPToolName) async throws -> CallTool.Result {
        try await client.send(CallTool.request(.init(name: tool.rawValue))).value
    }

    static func status(_ client: Client) async throws -> [String: Value] {
        try await call(client, .status).structuredContent?.objectValue ?? [:]
    }

    static func projectID(_ status: [String: Value]) -> String? {
        status["project"]?.objectValue?["id"]?.stringValue
    }

    // MARK: Selection

    @Test func clientWithRootsSelectsProjectFromRoots() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let expectedB = projectB.id.uuidString
        try await withSession(store: store, roots: .declared(["file:///work/b"])) { client in
            let tools = try await client.listTools().tools
            #expect(tools.count == Self.metadataToolCount)
            let status = try await Self.status(client)
            #expect(status["selected_by"] == "roots")
            #expect(Self.projectID(status) == expectedB)
            #expect(status["workspace"] == "/work/b")
        }
    }

    @Test func clientWithoutRootsUsesWorkingDirectory() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let expectedA = projectA.id.uuidString
        try await withSession(store: store, roots: .undeclared(["file:///work/b"]), rootsRequests: requests) { client in
            let status = try await Self.status(client)
            #expect(status["selected_by"] == "working_directory")
            #expect(Self.projectID(status) == expectedA)
            #expect(status["workspace"] == "/work/a")
        }
        #expect(requests.value == 0)
    }

    @Test func rootsRequestFailureFallsBackToWorkingDirectory() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let diagnostics = Locked<[String]>([])
        let expectedA = projectA.id.uuidString
        try await withSession(
            store: store, roots: .declaredFailing, rootsRequests: requests, diagnostics: diagnostics
        ) { client in
            let status = try await Self.status(client)
            #expect(status["selected_by"] == "working_directory")
            #expect(Self.projectID(status) == expectedA)
        }
        #expect(requests.value == 1)
        #expect(diagnostics.value.isEmpty)
    }

    @Test func explicitProjectWinsWithoutAskingForRoots() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let expectedB = projectB.id.uuidString
        try await withSession(
            store: store, roots: .declared(["file:///work/a"]), explicitProject: .id(projectB.id), rootsRequests: requests
        ) { client in
            let status = try await Self.status(client)
            #expect(status["selected_by"] == "explicit")
            #expect(Self.projectID(status) == expectedB)
            #expect(status["workspace"] == .null)
        }
        #expect(requests.value == 0)
    }

    @Test func explicitProjectNameWinsWithoutAskingForRoots() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let expectedB = projectB.id.uuidString
        try await withSession(
            store: store, roots: .declared(["file:///work/a"]), explicitProject: .name("b"), rootsRequests: requests
        ) { client in
            let status = try await Self.status(client)
            #expect(status["selected_by"] == "explicit")
            #expect(Self.projectID(status) == expectedB)
            #expect(status["workspace"] == .null)
        }
        #expect(requests.value == 0)
    }

    @Test func explicitProjectNameNoProjectHasIsReportedWithoutAskingForRoots() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        try await withSession(
            store: store, roots: .declared(["file:///work/a"]), explicitProject: .name("Ledger"), rootsRequests: requests
        ) { client in
            #expect(try await client.listTools().tools.map(\.name) == ["berrydb_status"])
            let status = try await Self.status(client)
            #expect(status["reason"] == "explicit_project_not_found")
            #expect(status["selected_by"] == .null)
            #expect(status["workspace"] == .null)
        }
        #expect(requests.value == 0)
    }

    /// A project selected by name is kept for the connection by its ID, so
    /// a rename in the app does not end the session's selection; deleting
    /// the project does, on the next request.
    @Test func explicitNameSelectionIsKeptForTheConnectionAndVerifiedOnEveryRequest() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let named = projectB.id
        try await withSession(
            store: store, roots: .declared(["file:///work/a"]), explicitProject: .name("b"), rootsRequests: requests
        ) { client in
            let first = try await Self.status(client)
            #expect(first["selected_by"] == "explicit")
            #expect(Self.projectID(first) == named.uuidString)
            #expect(try await client.listTools().tools.count == Self.metadataToolCount)

            store.update { state in
                state.projects = state.projects.map { project in
                    var copy = project
                    if copy.id == named { copy.name = "Billing" }
                    return copy
                }
            }
            let renamed = try await Self.status(client)
            #expect(renamed["selected_by"] == "explicit")
            #expect(Self.projectID(renamed) == named.uuidString)

            store.update { $0.projects.removeAll { $0.id == named } }
            let deleted = try await Self.status(client)
            #expect(deleted["reason"] == "no_matching_project")
            #expect(deleted["workspace"] == .null)
        }
        #expect(requests.value == 0)
    }

    // MARK: Tools and resources over the wire

    @Test func callToolEndToEndReturnsStructuredContent() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let expectedIDs = [shop.id.uuidString, billing.id.uuidString]
        try await withSession(store: store, roots: .declared(["file:///work/b"])) { client in
            let result = try await Self.call(client, .listConnections)
            #expect(result.isError != true)
            let ids = result.structuredContent?.objectValue?["connections"]?.arrayValue?
                .compactMap { $0.objectValue?["id"]?.stringValue }
            #expect(ids == expectedIDs)
            guard case let .text(text, _, _)? = result.content.first else {
                Issue.record("expected a text item")
                return
            }
            #expect(!text.isEmpty)
        }
    }

    @Test func resourcesAreServedForTheSelectedProject() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let expectedA = projectA.id.uuidString
        try await withSession(store: store, roots: .undeclared([])) { client in
            let resources = try await client.listResources().resources
            #expect(resources.map(\.uri) == ["berrydb://project"])
            let contents = try await client.readResource(uri: "berrydb://project")
            let body = try #require(contents.first?.text)
            #expect(body.contains(expectedA))
        }
    }

    @Test func unconfiguredSessionListsOnlyStatus() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        try await withSession(store: store, roots: .undeclared([]), workingDirectory: "/elsewhere") { client in
            let tools = try await client.listTools().tools
            #expect(tools.map(\.name) == ["berrydb_status"])
            let status = try await Self.status(client)
            #expect(status["state"] == "unconfigured")
            #expect(status["reason"] == "no_matching_project")
            #expect(status["workspace"] == "/elsewhere")
        }
    }

    /// Every request the server answers reads the store, so each one is
    /// reported as activity, and nothing else is.
    @Test func everyRequestIsReportedOnceAsActivity() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        try await withSession(store: store, roots: .undeclared([]), requests: requests) { client in
            #expect(requests.value == 0)
            _ = try await Self.call(client, .status)
            #expect(requests.value == 1)
            _ = try await Self.call(client, .listConnections)
            #expect(requests.value == 2)
            _ = try await client.listTools()
            #expect(requests.value == 3)
            _ = try await client.listResources()
            _ = try await client.readResource(uri: "berrydb://project")
            #expect(requests.value == 5)
        }
    }

    // MARK: Per-connection lifetime

    @Test func contextIsResolvedOnce() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        try await withSession(store: store, roots: .declared(["file:///work/b"]), rootsRequests: requests) { client in
            _ = try await Self.call(client, .status)
            _ = try await Self.call(client, .listConnections)
        }
        #expect(requests.value == 1)
    }

    /// The root that selected the project is still reported once the
    /// project is gone, so the status says which workspace lost it.
    @Test func deletedProjectIsUnconfiguredOnTheNextRequest() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let requests = Locked(0)
        let deleted = projectB.id
        try await withSession(store: store, roots: .declared(["file:///work/b"]), rootsRequests: requests) { client in
            let first = try await Self.status(client)
            #expect(first["state"] == "selected")
            store.update { $0.projects.removeAll { $0.id == deleted } }
            let second = try await Self.status(client)
            #expect(second["state"] == "unconfigured")
            #expect(second["reason"] == "no_matching_project")
            #expect(second["workspace"] == "/work/b")
        }
        #expect(requests.value == 1)
    }

    @Test func disabledProjectIsUnconfiguredOnTheNextRequest() async throws {
        let store = Locked(Store(projects: [projectA, projectB]))
        let disabled = projectA.id
        try await withSession(store: store, roots: .undeclared([])) { client in
            #expect(try await Self.status(client)["state"] == "selected")
            store.update { state in
                state.projects = state.projects.map { project in
                    var copy = project
                    if copy.id == disabled { copy.isEnabled = false }
                    return copy
                }
            }
            let status = try await Self.status(client)
            #expect(status["reason"] == "project_disabled")
            #expect(status["workspace"] == "/work/a")
            #expect(try await client.listTools().tools.map(\.name) == ["berrydb_status"])
        }
    }

    /// A project that is disabled when it is first selected is kept as the
    /// selection like any other, so enabling it in the app serves it from the
    /// next request without asking the host for its roots again.
    @Test func projectDisabledAtSelectionIsServedOnceEnabled() async throws {
        var disabledB = projectB
        disabledB.isEnabled = false
        let store = Locked(Store(projects: [projectA, disabledB]))
        let requests = Locked(0)
        let enabled = projectB.id
        try await withSession(store: store, roots: .declared(["file:///work/b"]), rootsRequests: requests) { client in
            let first = try await Self.status(client)
            #expect(first["reason"] == "project_disabled")
            #expect(try await client.listTools().tools.map(\.name) == ["berrydb_status"])

            store.update { state in
                state.projects = state.projects.map { project in
                    var copy = project
                    if copy.id == enabled { copy.isEnabled = true }
                    return copy
                }
            }
            let second = try await Self.status(client)
            #expect(second["state"] == "selected")
            #expect(second["selected_by"] == "roots")
            #expect(Self.projectID(second) == enabled.uuidString)
            #expect(try await client.listTools().tools.count == Self.metadataToolCount)
        }
        #expect(requests.value == 1)
    }

    // MARK: Store failures

    @Test func unreadableStoreIsReportedOnStderrAndSelectionIsRetried() async throws {
        let store = Locked(Store(projects: [projectA, projectB], unreadable: true))
        let diagnostics = Locked<[String]>([])
        let requests = Locked(0)
        try await withSession(
            store: store, roots: .declared(["file:///work/b"]), rootsRequests: requests, diagnostics: diagnostics
        ) { client in
            let status = try await Self.status(client)
            #expect(status["state"] == "unconfigured")
            #expect(status["reason"] == "integrity_unavailable")
            #expect(status["workspace"] == .null)
            store.update { $0.unreadable = false }
            #expect(try await Self.status(client)["selected_by"] == "roots")
        }
        #expect(diagnostics.value == [Self.storeUnavailableLine])
        #expect(requests.value == 1)
    }

    @Test func storeFailureAfterSelectionIsReportedPerRequestAndRecovers() async throws {
        let store = Locked(Store(projects: [projectA]))
        let diagnostics = Locked<[String]>([])
        let requests = Locked(0)
        try await withSession(
            store: store, roots: .declared([]), rootsRequests: requests, diagnostics: diagnostics
        ) { client in
            let selected = try await Self.status(client)
            #expect(selected["state"] == "selected")
            store.update { $0.unreadable = true }
            let failures = [try await Self.status(client), try await Self.status(client)]
            #expect(failures.map { $0["reason"] } == ["integrity_unavailable", "integrity_unavailable"])
            store.update { $0.unreadable = false }
            let recovered = try await Self.status(client)
            #expect(recovered["selected_by"] == "working_directory")
        }
        #expect(diagnostics.value == [Self.storeUnavailableLine, Self.storeUnavailableLine])
        #expect(requests.value == 1)
    }

    // MARK: Live reads

    /// Project B with live reads on for `billing`, a SQLite profile, as the
    /// session's roots select it.
    fileprivate func liveStore() -> Locked<Store> {
        Locked(Store(projects: [projectA, projectB], liveReads: [billing.id]))
    }

    static func readCall(_ connectionID: UUID, sql: String, parameters: [Value] = []) -> Request<CallTool> {
        CallTool.request(.init(
            name: MCPToolName.executeReadQuery.rawValue,
            arguments: [
                "connection_id": .string(connectionID.uuidString), "sql": .string(sql),
                "parameters": .array(parameters), "row_limit": .int(10),
            ]
        ))
    }

    @Test func aLiveReadOverTheWireReturnsRows() async throws {
        let connection = ScriptedReadOnlyConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER"), ColumnMeta(name: "createdAt", declaredType: "TEXT")]),
            .rows([[.int(1), .text("a/b")], [.int(2), .null]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let live = LiveReadHarness(connection: connection)
        let billingID = billing.id
        try await withSession(store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads) { client in
            let tools = try await client.listTools().tools.map(\.name)
            #expect(tools.contains(MCPToolName.executeReadQuery.rawValue))

            let result = try await client.send(Self.readCall(
                billingID, sql: "SELECT id, createdAt FROM events WHERE id > ?", parameters: [.int(0)]
            )).value
            #expect(result.isError != true)
            let structured = try #require(result.structuredContent?.objectValue)
            #expect(structured["columns"] == ["id", "createdAt"])
            #expect(structured["rows"] == [["1", "a/b"], ["2", .null]])
            #expect(structured["row_count"] == 2)
            #expect(structured["has_more_rows"] == .bool(false))
            #expect(Set(structured.keys) == [
                "columns", "rows", "row_count", "truncated", "has_more_rows", "truncated_cells",
                "byte_limit_reached", "elapsed_ms", "redacted_columns",
            ])
            guard case let .text(text, _, _)? = result.content.first else {
                Issue.record("expected a text item")
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let reencoded = try encoder.encode(try #require(result.structuredContent))
            #expect(String(decoding: reencoded, as: UTF8.self) == text)
            #expect(text.contains(#""a/b""#))
        }
        #expect(connection.log.snapshot().statements == [
            ScriptedReadOnlyConnection.Statement(sql: "SELECT id, createdAt FROM events WHERE id > ?", parameters: [.int(0)]),
        ])
        #expect(await live.tracker.closes == 1)
    }

    /// The host's cancel notification cancels the server's handler task,
    /// which ends the statement's stream and closes the connection. The
    /// statement has no end of its own and a 30 s limit, and the whole
    /// session is bounded by 30 s, so only the cancel can end it in time.
    @Test func cancellingTheCallCancelsTheRequest() async throws {
        let connection = ScriptedReadOnlyConnection(
            events: [.columns([ColumnMeta(name: "n", declaredType: "INTEGER")])], finishes: false
        )
        let live = LiveReadHarness(connection: connection)
        let billingID = billing.id
        let log = connection.log
        let tracker = live.tracker
        try await withSession(store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads) { client in
            let call = try await client.send(Self.readCall(billingID, sql: "SELECT n FROM numbers"))
            try await withDeadline(.seconds(10)) { await log.waitForStatement() }
            try await client.cancelRequest(call.requestID, reason: "stopped")
            try await withDeadline(.seconds(10)) { await log.waitForCancellations(1) }
            try await withDeadline(.seconds(10)) { await tracker.waitForCloses(1) }
            // `cancelRequest` resumes the client's own pending request with
            // `CancellationError` before it sends the notification, so this
            // shows only that the client stopped waiting, not that the
            // server sent no response. The server stays silent because the
            // tool throws `CancellationError`, which
            // `aCancelledToolCallThrowsCancellation` pins.
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        #expect(log.snapshot().statements.count == 1)
    }

    /// The SDK sends no response to a handler that throws
    /// `CancellationError` (`handleRequest` in Server.swift of swift-sdk
    /// 0.12.1), so a cancelled live read must end that way, not as a tool
    /// result.
    @Test func aCancelledToolCallThrowsCancellation() async throws {
        let connection = ScriptedReadOnlyConnection(
            events: [.columns([ColumnMeta(name: "n", declaredType: "INTEGER")])], finishes: false
        )
        let live = LiveReadHarness(connection: connection)
        let context = MCPProjectContext.selected(
            MCPVerifiedProject(project: projectB, liveReadProfileIDs: [billing.id]), source: .explicit, workspace: nil
        )
        live.liveReads.projectSource.bind { context }
        let tool = MCPLiveReadTool(service: live.liveReads.service)
        let metadata = try metadata()
        let arguments: [String: Value] = ["connection_id": .string(billing.id.uuidString), "sql": "SELECT n FROM numbers"]
        let task = Task { try await tool.call(arguments, context: context, metadata: metadata) }
        let log = connection.log
        try await withDeadline(.seconds(10)) { await log.waitForStatement() }
        task.cancel()
        let outcome = try await withDeadline(.seconds(10)) { () -> String in
            do {
                let result = try await task.value
                return "returned \(result)"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "threw \(error)"
            }
        }
        #expect(outcome == "cancelled")
        let tracker = live.tracker
        try await withDeadline(.seconds(10)) { await tracker.waitForCloses(1) }
    }
}

/// A live-read service over one coordinator whose sessions run on
/// `connection`, resolving its project through the source the server binds.
private struct LiveReadHarness {
    let tracker = SessionTracker()
    let liveReads: BerryMCPServerFactory.LiveReads

    init(connection: ScriptedReadOnlyConnection) {
        let source = MCPSessionProjectSource()
        let resolver = MCPProjectResolver(
            loadProject: { await source.project() },
            profile: { id in MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
        )
        let tracker = self.tracker
        let coordinator = MCPConnectionCoordinator(resolver: resolver, sqlFactory: { profile in
            let lifecycle = MCPConnectionLifecycle(cancel: {}, closeConnection: { await tracker.closed() })
            return MCPSQLSession(connection: connection, lifecycle: lifecycle, profile: profile)
        })
        liveReads = BerryMCPServerFactory.LiveReads(
            service: MCPLiveReadService(coordinator: coordinator), projectSource: source
        )
    }
}

private actor SessionTracker {
    private(set) var closes = 0

    func closed() {
        closes += 1
    }

    func waitForCloses(_ count: Int) async {
        while closes < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Answers every read-only statement with `events`, then finishes the
/// stream, or leaves it open when `finishes` is false, as a statement still
/// running on the server does.
private actor ScriptedReadOnlyConnection: ReadOnlyExecuting {
    struct Statement: Equatable, Sendable {
        let sql: String
        let parameters: [SQLParameter]
    }

    /// Locked rather than actor-held, so the stream's termination handler
    /// records synchronously.
    final class Log: Sendable {
        struct Snapshot: Sendable {
            var statements: [Statement] = []
            var cancellations = 0
        }

        private let state = Mutex(Snapshot())

        func snapshot() -> Snapshot {
            state.withLock { $0 }
        }

        func received(_ statement: Statement) {
            state.withLock { $0.statements.append(statement) }
        }

        func cancelled() {
            state.withLock { $0.cancellations += 1 }
        }

        func waitForStatement() async {
            while snapshot().statements.isEmpty {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func waitForCancellations(_ count: Int) async {
            while snapshot().cancellations < count {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    nonisolated let id = UUID()
    nonisolated let log = Log()
    private nonisolated let events: [ResultEvent]
    private nonisolated let finishes: Bool

    init(events: [ResultEvent], finishes: Bool = true) {
        self.events = events
        self.finishes = finishes
    }

    func prepareReadOnly() async throws {}

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        log.received(Statement(sql: sql, parameters: parameters))
        let (stream, continuation) = AsyncThrowingStream<ResultEvent, Error>.makeStream()
        let log = self.log
        continuation.onTermination = { termination in
            if case .cancelled = termination { log.cancelled() }
        }
        for event in events {
            continuation.yield(event)
        }
        if finishes { continuation.finish() }
        return stream
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}
