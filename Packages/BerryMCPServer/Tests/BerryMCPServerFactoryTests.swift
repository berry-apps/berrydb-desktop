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

    /// The projects the resolver reads, and whether reading them fails.
    struct Store: Sendable {
        var projects: [MCPProject]
        var unreadable = false
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
                return current.projects.first { $0.id == id }.map {
                    MCPVerifiedProject(project: $0, liveReadProfileIDs: [])
                }
            },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
    }

    func metadata() -> MCPMetadataService {
        let profiles = [shop, billing]
        let load: @Sendable (UUID) throws -> SchemaGraph = { _ in SchemaGraph() }
        return MCPMetadataService(
            profiles: { profiles },
            graph: BerryGraphQueryService(loadGraph: load, harvestedAt: { _ in nil }),
            harvestedAt: { _ in nil },
            loadGraph: load
        )
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
        _ body: @escaping @Sendable (Client) async throws -> Void
    ) async throws {
        let dependencies = BerryMCPServerFactory.Dependencies(
            resolver: resolver(store), metadata: metadata(),
            explicitProject: explicitProject, workingDirectory: workingDirectory, version: "test",
            diagnostics: { line in diagnostics.update { $0.append(line) } }
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
            #expect(tools.count == 6)
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
            #expect(try await client.listTools().tools.count == 6)

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
            #expect(try await client.listTools().tools.count == 6)
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
}
