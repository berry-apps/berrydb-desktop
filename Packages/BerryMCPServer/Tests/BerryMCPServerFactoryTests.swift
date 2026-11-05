import BerryDriverKit
import BerryGraph
@testable import BerryCredentials
@testable import BerryMCP
import BerryStore
import CryptoKit
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
    let orders = ConnectionProfile(driverID: "dynamodb", name: "Orders")
    /// Assigned to project C but no longer saved.
    let removed = UUID(uuidString: "00000000-0000-0000-0000-0000000000DE")!

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

    /// The DynamoDB `orders`, the SQLite `billing` and a profile deleted
    /// since it was assigned.
    var projectC: MCPProject {
        MCPProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!, name: "C", isEnabled: true,
            workspaceRoots: ["/work/c"],
            profiles: [
                MCPProfileAccess(profileID: orders.id, liveRead: true), MCPProfileAccess(profileID: billing.id, liveRead: true),
                MCPProfileAccess(profileID: removed, liveRead: true),
            ]
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
        let profiles = [shop, billing, orders]
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
        audit: MCPAudit? = nil,
        _ body: @escaping @Sendable (Client) async throws -> Void
    ) async throws {
        let dependencies = BerryMCPServerFactory.Dependencies(
            resolver: resolver(store), metadata: try metadata(),
            explicitProject: explicitProject, workingDirectory: workingDirectory, version: "test",
            liveReads: liveReads,
            diagnostics: { line in diagnostics.update { $0.append(line) } },
            onRequest: { requests.update { $0 += 1 } },
            audit: audit
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

    /// Every tool but the two live ones, which need a live-read connection.
    static let metadataToolCount = MCPToolName.allCases.count - 2

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

    // MARK: DynamoDB queries

    /// Project C with live reads on for `orders`, `billing` and the deleted
    /// `removed`, as the session's roots select it.
    fileprivate func partitionStore() -> Locked<Store> {
        Locked(Store(projects: [projectA, projectB, projectC], liveReads: [orders.id, billing.id, removed]))
    }

    static func dynamoCall(_ connectionID: UUID, _ arguments: [String: Value] = [:]) -> Request<CallTool> {
        CallTool.request(.init(
            name: MCPToolName.dynamodbQuery.rawValue,
            arguments: ["connection_id": .string(connectionID.uuidString), "table": "orders", "partition_key": "c1"]
                .merging(arguments) { $1 }
        ))
    }

    static func text(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _)? = result.content.first else { return "" }
        return text
    }

    /// The JSON of `structuredContent` as the text block must carry it.
    static func reencoded(_ result: CallTool.Result) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(try #require(result.structuredContent)), as: UTF8.self)
    }

    @Test func dynamodbQueryReturnsItemsWithVerbatimAttributeNamesAndACursor() async throws {
        let first: [String: DynamoDBAttributeValue] = [
            "customer": .string("c1"), "placed": .string("2026-11-01"), "createdAt": .string("2026/11/01"),
            "total": .number("12345678901234567890.5"), "blob": .binary(Data([0, 255])), "gone": .null,
            "flag": .bool(false), "tags": .stringSet(["a", "b"]), "sizes": .numberSet(["1", "2.5"]),
            "chunks": .binarySet([Data([1])]), "lines": .list([.map(["skuCode": .string("x"), "qty": .number("2")])]),
        ]
        let second: [String: DynamoDBAttributeValue] = ["customer": .string("c1"), "placed": .string("2026-11-02")]
        let lastKey: [String: DynamoDBAttributeValue] = ["customer": .string("c1"), "placed": .string("2026-11-01")]
        let connection = ScriptedPartitionConnection(pages: [
            DynamoDBQueryPage(items: [first], lastEvaluatedKey: lastKey, consumedCapacityUnits: 0.5, scannedCount: 1),
            DynamoDBQueryPage(items: [second], lastEvaluatedKey: nil, consumedCapacityUnits: nil, scannedCount: 1),
        ])
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let ordersID = orders.id
        let expectedFirst = Value.object([
            "customer": ["S": "c1"], "placed": ["S": "2026-11-01"], "createdAt": ["S": "2026/11/01"],
            "total": ["N": "12345678901234567890.5"], "blob": ["B": "AP8="], "gone": ["NULL": true],
            "flag": ["BOOL": false], "tags": ["SS": ["a", "b"]], "sizes": ["NS": ["1", "2.5"]],
            "chunks": ["BS": ["AQ=="]], "lines": ["L": [["M": ["skuCode": ["S": "x"], "qty": ["N": "2"]]]]],
        ])
        try await withSession(store: partitionStore(), roots: .declared(["file:///work/c"]), liveReads: live.liveReads) { client in
            let tools = try await client.listTools().tools.map(\.name)
            #expect(tools.contains(MCPToolName.dynamodbQuery.rawValue))
            #expect(tools.contains(MCPToolName.executeReadQuery.rawValue))

            let result = try await client.send(Self.dynamoCall(ordersID, ["limit": 1])).value
            #expect(result.isError != true, "\(Self.text(result))")
            let structured = try #require(result.structuredContent?.objectValue)
            #expect(structured["items"] == .array([expectedFirst]))
            #expect(structured["item_count"] == 1)
            #expect(structured["truncated"] == .bool(true))
            #expect(structured["consumed_capacity_units"] == .double(0.5))
            #expect(structured["key_schema"]?.objectValue?["partition_key"] == ["name": "customer", "type": "S"])
            let cursor = try #require(structured["next_cursor"]?.stringValue)
            let text = Self.text(result)
            #expect(text == (try Self.reencoded(result)))
            #expect(text.contains(#""createdAt":{"S":"2026/11/01"}"#))
            #expect(text.contains(#""skuCode""#))
            #expect(!text.contains("created_at") && !text.contains("sku_code"))

            let next = try await client.send(Self.dynamoCall(ordersID, ["limit": 1, "cursor": .string(cursor)])).value
            #expect(next.isError != true, "\(Self.text(next))")
            #expect(next.structuredContent?.objectValue?["items"] == [["customer": ["S": "c1"], "placed": ["S": "2026-11-02"]]])
            #expect(next.structuredContent?.objectValue?["next_cursor"] == nil)
        }
        let queries = await connection.queries
        #expect(queries.map(\.partitionKey) == [.string("c1"), .string("c1")])
        #expect(queries.map(\.limit) == [1, 1])
        #expect(queries.map(\.exclusiveStartKey) == [nil, lastKey])

        // The text block is exactly the object whose size the service held
        // to the byte ceiling.
        let result = MCPPartitionQueryResult(
            items: [first, second], itemCount: 2,
            keySchema: MCPKeySchemaDescription(schema: ScriptedPartitionConnection.orders, index: nil),
            nextCursor: "abc/def+==", consumedCapacityUnits: 1.5, redactedAttributes: ["secretNote"],
            omittedAttributes: [MCPOmittedAttribute(item: 0, name: "bigBlob", bytes: 70_000)],
            skippedItems: [MCPSkippedItem(index: 3, bytes: 2_000_000)], truncated: true, elapsedMs: 12
        )
        let response = try MCPDynamoDBQueryTool.respond(result)
        #expect(Self.text(response).utf8.count == (try MCPPartitionQueryService.encodedSize(of: result)))
        #expect(Self.text(response) == (try Self.reencoded(response)))
    }

    /// A project whose only live connection is DynamoDB reports live reads
    /// as available, in agreement with the tool it lists.
    @Test func aDynamoDBOnlyProjectReportsLiveReadsAvailable() async throws {
        let projectD = MCPProject(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!, name: "D", isEnabled: true,
            workspaceRoots: ["/work/d"], profiles: [MCPProfileAccess(profileID: orders.id, liveRead: true)]
        )
        let store = Locked(Store(projects: [projectA, projectD], liveReads: [orders.id]))
        try await withSession(store: store, roots: .declared(["file:///work/d"])) { client in
            let tools = try await client.listTools().tools.map(\.name)
            #expect(tools.contains(MCPToolName.dynamodbQuery.rawValue))
            #expect(!tools.contains(MCPToolName.executeReadQuery.rawValue))
            let status = try await Self.status(client)
            #expect(Self.projectID(status) == projectD.id.uuidString)
            #expect(status["live_reads"] == "available")
        }
    }

    @Test func executeReadQueryOnADynamoDBConnectionPointsToTheDynamoDBTool() async throws {
        let connection = ScriptedPartitionConnection(pages: [])
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let ordersID = orders.id
        try await withSession(store: partitionStore(), roots: .declared(["file:///work/c"]), liveReads: live.liveReads) { client in
            let result = try await client.send(Self.readCall(ordersID, sql: "SELECT 1")).value
            #expect(result.isError == true)
            #expect(Self.text(result) == "This is a DynamoDB connection; use berrydb_dynamodb_query.")
        }
        #expect(await connection.queries.isEmpty)
        #expect(await live.tracker.opens == 0)
    }

    @Test func dynamodbQueryOnASQLConnectionPointsToTheSQLTool() async throws {
        let connection = ScriptedPartitionConnection(pages: [])
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let billingID = billing.id
        let unassignedID = shop.id
        let removedID = removed
        try await withSession(store: partitionStore(), roots: .declared(["file:///work/c"]), liveReads: live.liveReads) { client in
            let sql = try await client.send(Self.dynamoCall(billingID)).value
            #expect(sql.isError == true)
            #expect(Self.text(sql) == MCPPartitionQueryError.unsupportedDatabase.description)
            // An unassigned and a deleted profile read the same.
            for id in [unassignedID, removedID] {
                let unknown = try await client.send(Self.dynamoCall(id)).value
                #expect(unknown.isError == true)
                #expect(Self.text(unknown) == "Unknown connection for this project")
            }
        }
        #expect(await connection.queries.isEmpty)
        #expect(await live.tracker.opens == 0)
    }

    @Test func malformedDynamoDBArgumentsAreInvalidParamsWithoutEchoingValues() async throws {
        let connection = ScriptedPartitionConnection(pages: [])
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let context = MCPProjectContext.selected(
            MCPVerifiedProject(project: projectC, liveReadProfileIDs: [orders.id]), source: .explicit, workspace: nil
        )
        live.liveReads.projectSource.bind { context }
        let tool = MCPDynamoDBQueryTool(service: try #require(live.liveReads.partition))
        let metadata = try metadata()
        let base: [String: Value] = ["connection_id": .string(orders.id.uuidString), "table": "orders", "partition_key": "c1"]
        let cases: [(arguments: [String: Value], message: String, value: String)] = [
            (["partition_key": .double(1.5)], "partition_key must be a string or an integer", "1.5"),
            (["partition_key": .double(1.25e21)], "partition_key must be a string or an integer", "1250000000000000000000"),
            (["sort_key": ["op": "like", "value": "x"]], "sort_key.op must be one of eq, lt, le, gt, ge, between, begins_with", "like"),
            (["sort_key": ["op": "between", "value": 1, "value2": .double(2.75)]], "sort_key.value2 must be a string or an integer", "2.75"),
            (["projection": .array((0 ..< 51).map { .string("secretName\($0)") })], "projection accepts at most 50 names", "secretName"),
            (["smuggled": "s3cr3t-value"], "Unexpected argument: smuggled", "s3cr3t-value"),
            (["cursor": .string(String(repeating: "Q", count: 16_385))], "cursor must be at most 16384 characters", "QQQQ"),
            // One past `Int64.max`, which the SDK decodes as a double.
            (["partition_key": .double(9_223_372_036_854_775_808)], "partition_key must be a string or an integer", "9223372036854775808"),
            (["sort_key": "eq-7731"], "sort_key must be an object", "7731"),
            (["projection": ["name", 4242]], "projection must be an array of strings", "4242"),
            (["partition_key": .data(mimeType: "text/plain", Data("k9z".utf8))], "partition_key cannot hold a data: URL string", "k9z"),
            (["sort_key": ["op": "between"]], "sort_key.value is required", "between"),
        ]
        for (arguments, expected, value) in cases {
            do {
                let result = try await tool.call(base.merging(arguments) { $1 }, context: context, metadata: metadata)
                Issue.record("expected invalid params for \(arguments.keys.sorted()), got \(result)")
            } catch let MCPError.invalidParams(message) {
                #expect(message == expected)
                #expect(message?.contains(value) == false)
            }
        }
        #expect(await connection.queries.isEmpty)
        #expect(await live.tracker.opens == 0)
    }

    /// As `aCancelledToolCallThrowsCancellation`, for a DynamoDB query still
    /// waiting on the database.
    @Test func aCancelledDynamoDBCallGetsNoResponse() async throws {
        let connection = ScriptedPartitionConnection(pages: [], delay: .seconds(60))
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let context = MCPProjectContext.selected(
            MCPVerifiedProject(project: projectC, liveReadProfileIDs: [orders.id]), source: .explicit, workspace: nil
        )
        live.liveReads.projectSource.bind { context }
        let tool = MCPDynamoDBQueryTool(service: try #require(live.liveReads.partition))
        let metadata = try metadata()
        let arguments: [String: Value] = ["connection_id": .string(orders.id.uuidString), "table": "orders", "partition_key": "c1"]
        let task = Task { try await tool.call(arguments, context: context, metadata: metadata) }
        try await withDeadline(.seconds(10)) { await connection.waitForQuery() }
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

    // MARK: Audit log

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The UTF-8 length of every text item, as the audit record counts it.
    static func textBytes(_ result: CallTool.Result) -> Int {
        result.content.reduce(0) { total, item in
            guard case let .text(text, _, _) = item else { return total }
            return total + text.utf8.count
        }
    }

    static let auditKeyData = Data(repeating: 0x42, count: 32)
    static let auditKey = SymmetricKey(data: auditKeyData)

    /// A writer for `url` and a digester whose key store holds `key`. Never
    /// the Keychain.
    fileprivate func audit(
        at url: URL, key: Data? = BerryMCPServerFactoryTests.auditKeyData, diagnostics: Locked<[String]> = Locked([])
    ) -> MCPAudit {
        let report: @Sendable (String) -> Void = { line in diagnostics.update { $0.append(line) } }
        return MCPAudit(
            writer: MCPAuditWriter(url: url, diagnostics: report),
            digester: MCPAuditDigester(
                keyStore: MCPAuditKeyStore(read: { key }, write: { _ in false }), diagnostics: report
            )
        )
    }

    @Test func everyToolCallWritesOneRecordWithHostAndDuration() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let results = Locked<[CallTool.Result]>([])
        try await withSession(store: Locked(Store(projects: [projectA, projectB])), roots: .undeclared([]), audit: audit) { client in
            let status = try await Self.call(client, .status)
            let connections = try await Self.call(client, .listConnections)
            results.update { $0 = [status, connections] }
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.tool) == [MCPToolName.status.rawValue, MCPToolName.listConnections.rawValue])
        #expect(records.map(\.host) == ["test-host", "test-host"])
        #expect(records.map(\.outcome) == [.ok, .ok])
        #expect(records.map(\.projectID) == [projectA.id, projectA.id])
        #expect(records.map(\.bytes) == results.value.map(Self.textBytes))
        #expect(records.allSatisfy { $0.bytes > 0 && $0.durationMs >= 0 && $0.error == nil })
    }

    @Test func unknownToolAndBadArgumentsAreRecordedAsInvalidParams() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        try await withSession(store: Locked(Store(projects: [projectA, projectB])), roots: .undeclared([]), audit: audit) { client in
            await #expect(throws: MCPError.self) {
                _ = try await client.send(CallTool.request(.init(name: "no_such_tool"))).value
            }
            await #expect(throws: MCPError.self) {
                _ = try await client.send(CallTool.request(.init(
                    name: MCPToolName.getSchema.rawValue, arguments: ["connection_id": "not-a-uuid"]
                ))).value
            }
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.tool) == ["unknown", MCPToolName.getSchema.rawValue])
        #expect(records.map(\.outcome) == [.invalidParams, .invalidParams])
        #expect(records.map(\.bytes) == [0, 0])
        #expect(records.map(\.profileID) == [nil, nil])
    }

    @Test func liveReadRecordCarriesTheDetail() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let connection = ScriptedReadOnlyConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER")]),
            .rows([[.int(1)], [.int(2)]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let live = LiveReadHarness(connection: connection)
        let billingID = billing.id
        let sql = "SELECT id FROM events"
        let bytes = Locked(0)
        try await withSession(
            store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads, audit: audit
        ) { client in
            let result = try await client.send(Self.readCall(billingID, sql: sql)).value
            #expect(result.isError != true)
            bytes.update { $0 = Self.textBytes(result) }
        }
        let record = try #require(MCPAuditLog.read(from: url).first)
        #expect(record.tool == MCPToolName.executeReadQuery.rawValue)
        #expect(record.outcome == .ok)
        #expect(record.projectID == projectB.id)
        #expect(record.profileID == billing.id)
        #expect(record.digest == MCPAuditDigest(key: Self.auditKey).digest(.sql(sql)))
        #expect(record.rows == 2)
        #expect(record.truncated == false)
        #expect(record.redacted == false)
        #expect(record.bytes == bytes.value)
        #expect(MCPAuditLog.read(from: url).count == 1)
    }

    /// The host's cancel notification reaches the handler through the
    /// in-memory transport, as `cancellingTheCallCancelsTheRequest` shows,
    /// so the record is awaited from the file with a bound.
    @Test func cancelledCallIsRecordedAsCancelled() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let connection = ScriptedReadOnlyConnection(
            events: [.columns([ColumnMeta(name: "n", declaredType: "INTEGER")])], finishes: false
        )
        let live = LiveReadHarness(connection: connection)
        let billingID = billing.id
        let log = connection.log
        try await withSession(
            store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads, audit: audit
        ) { client in
            let call = try await client.send(Self.readCall(billingID, sql: "SELECT n FROM numbers"))
            try await withDeadline(.seconds(10)) { await log.waitForStatement() }
            try await client.cancelRequest(call.requestID, reason: "stopped")
            try await withDeadline(.seconds(10)) {
                while MCPAuditLog.read(from: url).isEmpty {
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.outcome) == [.cancelled])
        #expect(records.map(\.tool) == [MCPToolName.executeReadQuery.rawValue])
        #expect(records.map(\.bytes) == [0])
        #expect(records.map(\.projectID) == [projectB.id])
    }

    /// The connection the arguments name is recorded even when another
    /// argument is malformed and the tool never parses it.
    @Test func malformedCallStillRecordsTheNamedConnection() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let shopID = shop.id
        try await withSession(store: Locked(Store(projects: [projectA, projectB])), roots: .undeclared([]), audit: audit) { client in
            await #expect(throws: MCPError.self) {
                _ = try await client.send(CallTool.request(.init(
                    name: MCPToolName.getSchema.rawValue,
                    arguments: ["connection_id": .string(shopID.uuidString), "detail": "bogus"]
                ))).value
            }
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.outcome) == [.invalidParams])
        #expect(records.map(\.profileID) == [shopID])
    }

    @Test func noProjectRefusalOfALiveToolRecordsTheNamedConnection() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let live = LiveReadHarness(connection: ScriptedReadOnlyConnection(events: []))
        let billingID = billing.id
        try await withSession(
            store: liveStore(), roots: .undeclared([]), workingDirectory: "/elsewhere", liveReads: live.liveReads, audit: audit
        ) { client in
            let result = try await client.send(Self.readCall(billingID, sql: "SELECT 1")).value
            #expect(result.isError == true)
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.outcome) == [.error])
        #expect(records.map(\.error) == ["no_project"])
        #expect(records.map(\.profileID) == [billingID])
        #expect(records.map(\.projectID) == [nil])
    }

    /// The raw file, not only the decoded records, holds no statement text,
    /// no table or column name and no key value, for a served read, a
    /// refused one and a DynamoDB query. Each canary contains a letter that
    /// is not a hex digit, so a digest cannot contain it by chance.
    @Test func auditFileHoldsNoQueryTextNamesOrKeyValues() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let audit = self.audit(at: url)
        let connection = ScriptedReadOnlyConnection(events: [
            .columns([ColumnMeta(name: "ledger_note", declaredType: "TEXT")]),
            .rows([[.text("x")]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let live = LiveReadHarness(connection: connection)
        let billingID = billing.id
        let read = "SELECT ledger_note FROM vault_entries WHERE ledger_note <> 'quartz'"
        let write = "DELETE FROM vault_entries WHERE ledger_note = 'quartz'"
        try await withSession(
            store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads, audit: audit
        ) { client in
            let served = try await client.send(Self.readCall(billingID, sql: read)).value
            #expect(served.isError != true, "\(Self.text(served))")
            let refused = try await client.send(Self.readCall(billingID, sql: write)).value
            #expect(refused.isError == true)
        }

        let partition = ScriptedPartitionConnection(pages: [
            DynamoDBQueryPage(
                items: [["customer": .string("zulu-kilo"), "placed": .string("w")]], lastEvaluatedKey: nil,
                consumedCapacityUnits: 0.5, scannedCount: 1
            ),
        ])
        let dynamo = PartitionHarness(connection: partition, dynamoID: orders.id)
        let ordersID = orders.id
        let dynamoRequest = MCPPartitionQueryRequest(profileID: ordersID, table: "orders", partitionKey: .string("zulu-kilo"))
        try await withSession(
            store: partitionStore(), roots: .declared(["file:///work/c"]), liveReads: dynamo.liveReads, audit: audit
        ) { client in
            let result = try await client.send(Self.dynamoCall(ordersID, ["partition_key": "zulu-kilo"])).value
            #expect(result.isError != true, "\(Self.text(result))")
        }

        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.outcome) == [.ok, .error, .ok])
        #expect(records.map(\.error) == [nil, "policy", nil])
        let digest = MCPAuditDigest(key: Self.auditKey)
        #expect(records.map(\.digest) == [
            digest.digest(.sql(read)), digest.digest(.sql(write)), digest.digest(dynamoRequest.auditQuery),
        ])
        #expect(records.allSatisfy { $0.digest != nil })
        let dynamoRecord = try #require(records.last)
        #expect(dynamoRecord.tool == MCPToolName.dynamodbQuery.rawValue)
        #expect(dynamoRecord.rows == 1)
        #expect(dynamoRecord.consumedCapacityUnits == 0.5)
        let raw = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for canary in ["ledger_note", "vault_entries", "quartz", "SELECT", "DELETE", "orders", "customer", "zulu-kilo"] {
            #expect(!raw.contains(canary), "\(canary) reached the audit file")
        }
        // A digest computed without the key would be this value.
        for statement in [read, write] {
            let unkeyed = SHA256.hash(data: Data(("berrydb-mcp-audit/sql\n" + statement).utf8))
                .prefix(16).map { String(format: "%02x", $0) }.joined()
            #expect(!raw.contains(unkeyed), "an unkeyed digest reached the audit file")
        }
    }

    @Test func withoutAnAuditKeyEveryCallIsRecordedWithoutADigestAndWarnsOnce() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let diagnostics = Locked<[String]>([])
        let audit = self.audit(at: url, key: nil, diagnostics: diagnostics)
        let live = LiveReadHarness(connection: ScriptedReadOnlyConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER")]),
            .rows([[.int(1)]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ]))
        let billingID = billing.id
        try await withSession(
            store: liveStore(), roots: .declared(["file:///work/b"]), liveReads: live.liveReads, audit: audit
        ) { client in
            let served = try await client.send(Self.readCall(billingID, sql: "SELECT id FROM users")).value
            #expect(served.isError != true, "\(Self.text(served))")
            _ = try await Self.call(client, .status)
        }
        let records = MCPAuditLog.read(from: url)
        #expect(records.map(\.tool) == [MCPToolName.executeReadQuery.rawValue, MCPToolName.status.rawValue])
        #expect(records.map(\.digest) == [nil, nil])
        #expect(diagnostics.value.filter { $0.contains("audit digest key unavailable") }.count == 1)
    }

    /// The status result of a session that selects project A, with `audit`.
    fileprivate func statusResult(audit: MCPAudit?, diagnostics: Locked<[String]> = Locked([])) async throws -> [CallTool.Result] {
        let results = Locked<[CallTool.Result]>([])
        try await withSession(
            store: Locked(Store(projects: [projectA, projectB])), roots: .undeclared([]), diagnostics: diagnostics, audit: audit
        ) { client in
            let first = try await Self.call(client, .status)
            let second = try await Self.call(client, .status)
            results.update { $0 = [first, second] }
        }
        return results.value
    }

    @Test func unwritableAuditFileNeverChangesTheResponse() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let working = audit(at: dir.appendingPathComponent(MCPAuditLog.fileName))
        let expected = try await statusResult(audit: working)

        let diagnostics = Locked<[String]>([])
        let missing = dir.appendingPathComponent("missing").appendingPathComponent(MCPAuditLog.fileName)
        let unwritable = audit(at: missing, diagnostics: diagnostics)
        let results = try await statusResult(audit: unwritable, diagnostics: diagnostics)

        #expect(results == expected)
        #expect(results.first?.structuredContent?.objectValue?["state"] == "selected")
        #expect(diagnostics.value.count == 1)
        #expect(diagnostics.value.first?.hasPrefix("audit log unavailable") == true)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func withoutAWriterNothingIsWritten() async throws {
        let dir = try Self.makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let written = dir.appendingPathComponent("written")
        try FileManager.default.createDirectory(at: written, withIntermediateDirectories: true)
        let expected = try await statusResult(
            audit: audit(at: written.appendingPathComponent(MCPAuditLog.fileName))
        )
        #expect(MCPAuditLog.read(from: written.appendingPathComponent(MCPAuditLog.fileName)).count == 2)

        let results = try await statusResult(audit: nil)
        #expect(results == expected)
    }
}

/// A DynamoDB query service and a SQL live-read service over one
/// coordinator: sessions for `dynamoID` run on `connection`, and every other
/// profile is SQLite with no scripted SQL connection.
struct PartitionHarness {
    let tracker = SessionTracker()
    let liveReads: BerryMCPServerFactory.LiveReads

    init(connection: ScriptedPartitionConnection, dynamoID: UUID) {
        let source = MCPSessionProjectSource()
        let resolver = MCPProjectResolver(
            loadProject: { await source.project() },
            profile: { id in
                MCPConnectionProfile(id: id, driverID: id == dynamoID ? .dynamodb : .sqlite, config: .sqlite(path: ":memory:"))
            }
        )
        let tracker = self.tracker
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            sqlFactory: { _ in throw DriverError.connectionFailed("no SQL connection scripted") },
            partitionFactory: { profile in
                await tracker.opened()
                let lifecycle = MCPConnectionLifecycle(
                    cancel: { connection.cancelCurrentQuery() },
                    closeConnection: { await tracker.closed() }
                )
                return MCPPartitionSession(reader: MCPPartitionReader(connection), lifecycle: lifecycle, profile: profile)
            }
        )
        let service = MCPLiveReadService(coordinator: coordinator)
        liveReads = BerryMCPServerFactory.LiveReads(
            service: service, projectSource: source, partition: MCPPartitionQueryService(sharing: service)
        )
    }
}

/// Answers `orders` queries with scripted pages in order and records each
/// query; with a `delay`, a query waits that long unless cancelled.
actor ScriptedPartitionConnection: PartitionQuerying {
    /// `orders`: customer (S) and placed (S).
    static let orders = DynamoDBKeySchema(
        table: "orders",
        partitionKey: DynamoDBKeyAttribute(name: "customer", type: .string),
        sortKey: DynamoDBKeyAttribute(name: "placed", type: .string),
        indexes: []
    )

    nonisolated let id = UUID()
    private var pages: [DynamoDBQueryPage]
    private let delay: Duration
    private nonisolated let inFlight = Mutex<Task<Void, Error>?>(nil)
    private(set) var queries: [DynamoDBPartitionQuery] = []

    init(pages: [DynamoDBQueryPage], delay: Duration = .zero) {
        self.pages = pages
        self.delay = delay
    }

    func keySchema(of table: String) async throws -> DynamoDBKeySchema {
        Self.orders
    }

    func queryPartition(_ query: DynamoDBPartitionQuery) async throws -> DynamoDBQueryPage {
        queries.append(query)
        if delay > .zero {
            let delay = self.delay
            let sleep = Task { try await Task.sleep(for: delay) }
            inFlight.withLock { $0 = sleep }
            do {
                try await withTaskCancellationHandler { try await sleep.value } onCancel: { sleep.cancel() }
            } catch {
                throw DriverError.cancelled
            }
        }
        guard !pages.isEmpty else { throw DriverError.queryFailed(message: "no scripted page", code: nil) }
        return pages.removeFirst()
    }

    func waitForQuery() async {
        while queries.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() { inFlight.withLock { $0 }?.cancel() }
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

/// A live-read service over one coordinator whose sessions run on
/// `connection`, resolving its project through the source the server binds.
struct LiveReadHarness {
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

actor SessionTracker {
    private(set) var closes = 0
    private(set) var opens = 0

    func opened() {
        opens += 1
    }

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
actor ScriptedReadOnlyConnection: ReadOnlyExecuting {
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
