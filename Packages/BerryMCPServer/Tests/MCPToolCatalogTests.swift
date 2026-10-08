import BerryGraph
import BerryMCP
import BerryStore
import Foundation
import MCP
import Testing

@testable import BerryMCPServer

/// A non-metadata failure whose every rendering contains a file path, the way
/// a database error can.
private struct PathLeakingError: Error, LocalizedError, CustomStringConvertible {
    static let path = "/Users/someone/Library/Application Support/BerryDB/store.sqlite"
    var errorDescription: String? { "disk I/O error at \(Self.path)" }
    var description: String { "PathLeakingError(\(Self.path))" }
}

@Suite("MCP tool catalog")
struct MCPToolCatalogTests {
    static let harvestTime = Date(timeIntervalSince1970: 1_700_000_000)
    static let noProjectText = "No BerryDB project is selected for this workspace. Call berrydb_status for details."

    let shop = ConnectionProfile(driverID: "postgres", name: "Shop", envColor: "production", host: "db.internal.example")
    let outsider = ConnectionProfile(driverID: "sqlite", name: "Outside", filePath: "/secret/outside.db")

    static let projectID = UUID()

    func project(integrity: Bool = true, roots: [String] = []) -> MCPVerifiedProject {
        MCPVerifiedProject(
            project: MCPProject(
                id: Self.projectID, name: "Shop project", isEnabled: true, workspaceRoots: roots,
                profiles: [MCPProfileAccess(profileID: shop.id)]
            ),
            liveReadProfileIDs: [],
            projectTagValid: integrity
        )
    }

    func selected(integrity: Bool = true, roots: [String] = []) -> MCPProjectContext {
        .selected(project(integrity: integrity, roots: roots), source: .workingDirectory)
    }

    /// `orders` references `customers`; `orders` has an `id` and a `createdAt`
    /// column and `customers` has no columns.
    func shopGraph() -> SchemaGraph {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "t:orders", kind: .table, name: "orders", attrs: ["rows": "10"]))
        graph.addNode(GraphNode(id: "t:customers", kind: .table, name: "customers", attrs: ["rows": "3"]))
        graph.addNode(GraphNode(
            id: "c:orders.id", kind: .column, name: "id",
            attrs: ["type": "int", "nullable": "false", "primaryKey": "true"]
        ))
        graph.addNode(GraphNode(
            id: "c:orders.createdAt", kind: .column, name: "createdAt",
            attrs: ["type": "timestamp", "nullable": "true", "primaryKey": "false"]
        ))
        graph.addEdge(GraphEdge(src: "t:orders", dst: "c:orders.id", kind: .hasColumn))
        graph.addEdge(GraphEdge(src: "t:orders", dst: "c:orders.createdAt", kind: .hasColumn))
        graph.addEdge(GraphEdge(src: "t:orders", dst: "t:customers", kind: .references))
        return graph
    }

    func service(graph: SchemaGraph? = nil, failure: Error? = nil, harvested: Bool = true) -> MCPMetadataService {
        let built = graph ?? shopGraph()
        let profiles = [shop, outsider]
        let harvestedAt: Date? = harvested ? Self.harvestTime : nil
        let load: @Sendable (UUID) throws -> SchemaGraph = { _ in
            if let failure { throw failure }
            return built
        }
        return MCPMetadataService(
            profiles: { profiles },
            graph: BerryGraphQueryService(loadGraph: load, harvestedAt: { _ in harvestedAt }),
            harvestedAt: { _ in harvestedAt },
            loadGraph: load
        )
    }

    func router(graph: SchemaGraph? = nil, failure: Error? = nil) -> MCPToolRouter {
        MCPToolRouter(metadata: service(graph: graph, failure: failure))
    }

    func call(
        _ name: MCPToolName, _ arguments: [String: Value]? = nil, context: MCPProjectContext? = nil,
        router: MCPToolRouter? = nil
    ) throws -> CallTool.Result {
        try (router ?? self.router()).call(name.rawValue, arguments: arguments, context: context ?? selected())
    }

    /// The message of the `invalidParams` error a call throws, nil when it does not throw one.
    func invalidParamsMessage(
        _ name: String, _ arguments: [String: Value]?, context: MCPProjectContext? = nil
    ) -> String? {
        do {
            _ = try router().call(name, arguments: arguments, context: context ?? selected())
            return nil
        } catch let MCPError.invalidParams(message) {
            return message ?? ""
        } catch {
            return nil
        }
    }

    func text(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _)? = result.content.first else { return "" }
        return text
    }

    /// The text content must be the compact JSON of `structuredContent`, on one line.
    func expectJSONText(_ result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) {
        let decoded = try? JSONDecoder().decode(Value.self, from: Data(text(result).utf8))
        #expect(decoded != nil && decoded == result.structuredContent, sourceLocation: sourceLocation)
        #expect(!text(result).contains("\n") && !text(result).contains("\r"), sourceLocation: sourceLocation)
    }

    func object(_ result: CallTool.Result) -> [String: Value] {
        result.structuredContent?.objectValue ?? [:]
    }

    func jsonObject(_ contents: [Resource.Content]) throws -> [String: Any] {
        let body = try #require(contents.first?.text)
        return try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    var connectionID: Value { .string(shop.id.uuidString) }

    // MARK: Catalog

    @Test func toolNamesUseOnlyModelSafeCharacters() {
        for name in MCPToolName.allCases {
            #expect(name.rawValue.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil)
        }
        #expect(MCPToolName.allCases.map(\.rawValue) == [
            "berrydb_status", "berrydb_list_connections", "berrydb_get_schema",
            "berrydb_search_schema", "berrydb_graph_query", "berrydb_get_graph_stats",
        ])
    }

    @Test func unconfiguredContextListsOnlyStatus() {
        let tools = MCPToolCatalog.tools(for: .unconfigured(.noMatchingProject, workspace: "/work"))
        #expect(tools.map(\.name) == ["berrydb_status"])
    }

    @Test func selectedContextListsAllSixToolsWithStrictSchemas() throws {
        let tools = MCPToolCatalog.tools(for: selected())
        #expect(tools.map(\.name) == MCPToolName.allCases.map(\.rawValue))
        for tool in tools {
            let input = try #require(tool.inputSchema.objectValue)
            #expect(input["type"]?.stringValue == "object")
            #expect(input["additionalProperties"] == .bool(false))
            #expect(input["properties"]?.objectValue != nil)
            let output = try #require(tool.outputSchema?.objectValue)
            #expect(output["type"]?.stringValue == "object")
            #expect(tool.annotations.readOnlyHint == true)
            #expect(tool.annotations.openWorldHint == false)
            #expect(tool.description?.isEmpty == false)
        }
    }

    @Test func inputSchemasCarryTheDocumentedLimits() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools(for: selected()).map { ($0.name, $0) })
        func properties(_ name: MCPToolName) throws -> [String: Value] {
            try #require(tools[name.rawValue]?.inputSchema.objectValue?["properties"]?.objectValue)
        }
        func required(_ name: MCPToolName) -> [String] {
            tools[name.rawValue]?.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }
        #expect(try properties(.status).isEmpty)
        #expect(try properties(.listConnections).isEmpty)

        let schema = try properties(.getSchema)
        #expect(schema["connection_id"]?.objectValue?["format"]?.stringValue == "uuid")
        #expect(schema["object_names"]?.objectValue?["maxItems"]?.intValue == 50)
        #expect(schema["detail"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) == ["overview", "full"])
        #expect(schema["detail"]?.objectValue?["default"]?.stringValue == "overview")
        #expect(required(.getSchema) == ["connection_id"])

        let search = try properties(.searchSchema)
        #expect(search["query"]?.objectValue?["minLength"]?.intValue == 1)
        #expect(search["query"]?.objectValue?["maxLength"]?.intValue == 200)
        #expect(search["limit"]?.objectValue?["minimum"]?.intValue == 1)
        #expect(search["limit"]?.objectValue?["maximum"]?.intValue == 200)
        #expect(required(.searchSchema) == ["connection_id", "query"])

        let graph = try properties(.graphQuery)
        #expect(graph["operation"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue) == [
            "neighbors", "path", "blast_radius", "circular_dependencies", "top_centrality",
        ])
        #expect(graph["limit"]?.objectValue?["maximum"]?.intValue == 50)
        #expect(Set(graph.keys) == ["connection_id", "operation", "node", "from", "to", "limit"])
        #expect(required(.graphQuery) == ["connection_id", "operation"])

        let stats = try properties(.getGraphStats)
        #expect(Set(stats.keys) == ["connection_id", "object"])
        #expect(required(.getGraphStats) == ["connection_id"])
    }

    // MARK: Argument validation

    @Test func unexpectedArgumentIsInvalidParams() {
        #expect(invalidParamsMessage("berrydb_status", ["extra": .int(1)]) == "Unexpected argument: extra")
        #expect(invalidParamsMessage("berrydb_list_connections", ["extra": .int(1)]) == "Unexpected argument: extra")
        #expect(invalidParamsMessage(
            "berrydb_get_schema", ["connection_id": connectionID, "sql": .string("select 1")]
        ) == "Unexpected argument: sql")
        #expect(invalidParamsMessage(
            "berrydb_get_graph_stats", ["connection_id": connectionID, "connectionId": connectionID]
        ) == "Unexpected argument: connectionId")
    }

    @Test func pathWithoutToIsInvalidParams() {
        let arguments: [String: Value] = ["connection_id": connectionID, "operation": "path", "from": "orders"]
        #expect(invalidParamsMessage("berrydb_graph_query", arguments)?.contains("to") == true)
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "neighbors"]
        )?.contains("node") == true)
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "blast_radius", "node": "  "]
        )?.contains("node") == true)
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "path", "to": "orders"]
        )?.contains("from") == true)
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "teleport"]
        )?.contains("operation") == true)
    }

    @Test func badUUIDIsInvalidParams() {
        #expect(invalidParamsMessage("berrydb_get_schema", ["connection_id": "not-a-uuid"])?.contains("connection_id") == true)
        #expect(invalidParamsMessage("berrydb_get_schema", ["connection_id": .int(3)])?.contains("connection_id") == true)
        #expect(invalidParamsMessage("berrydb_get_schema", nil)?.contains("connection_id") == true)
        #expect(invalidParamsMessage("berrydb_get_schema", [:])?.contains("connection_id") == true)
    }

    @Test func wrongTypesAndOutOfRangeValuesAreInvalidParams() {
        let id = connectionID
        func schema(_ extra: [String: Value]) -> String? {
            invalidParamsMessage("berrydb_get_schema", ["connection_id": id].merging(extra) { $1 })
        }
        func search(_ extra: [String: Value]) -> String? {
            invalidParamsMessage("berrydb_search_schema", ["connection_id": id].merging(extra) { $1 })
        }
        func graph(_ extra: [String: Value]) -> String? {
            invalidParamsMessage(
                "berrydb_graph_query",
                ["connection_id": id, "operation": "top_centrality"].merging(extra) { $1 }
            )
        }
        #expect(schema(["detail": "everything"])?.contains("detail") == true)
        #expect(schema(["detail": .int(1)])?.contains("detail") == true)
        #expect(schema(["object_names": "orders"])?.contains("object_names") == true)
        #expect(schema(["object_names": [.string("a"), .int(2)]])?.contains("object_names") == true)
        #expect(schema(["object_names": .array((0 ... 50).map { .string("t\($0)") })])?.contains("object_names") == true)

        #expect(search([:])?.contains("query") == true)
        #expect(search(["query": ""])?.contains("query") == true)
        #expect(search(["query": .string(String(repeating: "a", count: 201))])?.contains("query") == true)
        #expect(search(["query": .int(4)])?.contains("query") == true)
        #expect(search(["query": "ord", "limit": .int(0)])?.contains("limit") == true)
        #expect(search(["query": "ord", "limit": .int(201)])?.contains("limit") == true)
        #expect(search(["query": "ord", "limit": "ten"])?.contains("limit") == true)
        #expect(search(["query": "ord", "limit": .double(2.5)])?.contains("limit") == true)

        #expect(graph(["limit": .int(0)])?.contains("limit") == true)
        #expect(graph(["limit": .int(51)])?.contains("limit") == true)
        #expect(graph(["operation": .int(1)])?.contains("operation") == true)
        #expect(invalidParamsMessage("berrydb_get_graph_stats", ["connection_id": id, "object": .int(1)])?.contains("object") == true)
    }

    @Test func unknownToolIsInvalidParams() {
        #expect(invalidParamsMessage("berrydb_run_query", [:]) != nil)
        #expect(invalidParamsMessage("", nil) != nil)
        #expect(invalidParamsMessage("berrydb_run_query", [:], context: .unconfigured(.noMatchingProject, workspace: nil)) != nil)
    }

    @Test func graphQueryChecksEveryPresentArgumentRegardlessOfOperation() {
        let id = connectionID
        func graph(_ extra: [String: Value]) -> String? {
            invalidParamsMessage("berrydb_graph_query", ["connection_id": id].merging(extra) { $1 })
        }
        #expect(graph(["operation": "neighbors", "node": "orders", "limit": .int(999)])?.contains("limit") == true)
        #expect(graph(["operation": "circular_dependencies", "node": .int(5)])?.contains("node") == true)
        #expect(graph(["operation": "path", "from": "a", "to": "b", "limit": "ten"])?.contains("limit") == true)
        #expect(graph(["operation": "blast_radius", "node": "a", "from": .bool(true)])?.contains("from") == true)
        #expect(graph(["operation": "top_centrality", "to": .int(1)])?.contains("to") == true)
        #expect(graph(["operation": "circular_dependencies", "limit": .int(0)])?.contains("limit") == true)
    }

    @Test func whitespaceOnlyQueryIsInvalidParams() {
        for query in ["   ", "\n\t "] {
            #expect(invalidParamsMessage(
                "berrydb_search_schema", ["connection_id": connectionID, "query": .string(query)]
            )?.contains("query") == true)
        }
    }

    // MARK: Expected failures

    @Test func metadataToolWhileUnconfiguredIsToolError() throws {
        let context = MCPProjectContext.unconfigured(.noMatchingProject, workspace: "/work")
        let arguments: [String: Value] = ["connection_id": connectionID, "query": "ord", "operation": "circular_dependencies"]
        for name in MCPToolName.allCases where name != .status {
            let result = try call(name, arguments, context: context)
            #expect(result.isError == true)
            #expect(text(result) == Self.noProjectText)
            #expect(result.structuredContent == nil)
        }
    }

    @Test func unknownConnectionIsToolErrorWithFixedText() throws {
        let unassigned = try call(.getSchema, ["connection_id": .string(outsider.id.uuidString)])
        let missing = try call(.getSchema, ["connection_id": .string(UUID().uuidString)])
        for result in [unassigned, missing] {
            #expect(result.isError == true)
            #expect(text(result) == "Unknown connection for this project")
        }
        #expect(unassigned == missing)
        let search = try call(.searchSchema, ["connection_id": .string(UUID().uuidString), "query": "ord"])
        #expect(text(search) == "Unknown connection for this project")
    }

    @Test func metadataErrorTextReachesTheAgent() throws {
        let result = try call(.graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "missing"])
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("Node 'missing' not found"))
        let empty = try call(.getSchema, ["connection_id": connectionID], router: router(graph: SchemaGraph()))
        #expect(empty.isError == true)
        #expect(text(empty) == MCPMetadataError.noSnapshot.description)
        let noGraph = try call(
            .searchSchema, ["connection_id": connectionID, "query": "x"], router: router(graph: SchemaGraph())
        )
        #expect(noGraph.isError == true)
        #expect(text(noGraph) == MCPMetadataError.noSnapshot.description)
    }

    @Test func nonMetadataErrorsNeverLeakTheirDetail() throws {
        let failing = router(failure: PathLeakingError())
        let calls: [(MCPToolName, [String: Value])] = [
            (.getSchema, ["connection_id": connectionID]),
            (.searchSchema, ["connection_id": connectionID, "query": "ord"]),
            (.graphQuery, ["connection_id": connectionID, "operation": "circular_dependencies"]),
            (.getGraphStats, ["connection_id": connectionID]),
        ]
        for (name, arguments) in calls {
            let result = try call(name, arguments, router: failing)
            #expect(result.isError == true)
            #expect(text(result) == "BerryDB could not read its store for this request.")
            #expect(!String(describing: result).contains("/Users"))
            #expect(!String(describing: result).contains("sqlite"))
        }

        let throwingProfiles = MCPMetadataService(
            profiles: { throw PathLeakingError() },
            graph: BerryGraphQueryService(loadGraph: { _ in SchemaGraph() }),
            harvestedAt: { _ in nil }, loadGraph: { _ in SchemaGraph() }
        )
        let listed = try MCPToolRouter(metadata: throwingProfiles)
            .call("berrydb_list_connections", arguments: nil, context: selected())
        #expect(listed.isError == true)
        #expect(text(listed) == "BerryDB could not read its store for this request.")
    }

    @Test func oversizedResultIsToolError() throws {
        var graph = SchemaGraph()
        for table in 0 ..< 200 {
            let tableID = "t:\(table)"
            graph.addNode(GraphNode(id: tableID, kind: .table, name: "table_\(table)"))
            for column in 0 ..< 80 {
                let columnID = "c:\(table).\(column)"
                let name = "column_with_a_deliberately_long_name_\(table)_\(column)"
                graph.addNode(GraphNode(
                    id: columnID, kind: .column, name: name,
                    attrs: ["type": "character varying", "nullable": "true", "primaryKey": "false"]
                ))
                graph.addEdge(GraphEdge(src: tableID, dst: columnID, kind: .hasColumn))
            }
        }
        let big = router(graph: graph)
        let result = try call(.getSchema, ["connection_id": connectionID, "detail": "full"], router: big)
        #expect(result.isError == true)
        #expect(text(result) == "Result too large; narrow the request")
        #expect(result.structuredContent == nil)

        // The same graph is fine at overview detail, so the ceiling is what rejected the full one.
        let overview = try call(.getSchema, ["connection_id": connectionID], router: big)
        #expect(overview.isError != true)
        #expect(object(overview)["omitted_count"]?.intValue == 0)
    }

    // MARK: Status

    @Test func statusReportsSelectedProject() throws {
        let result = try call(.status, [:])
        let status = object(result)
        #expect(result.isError != true)
        #expect(Set(status.keys) == [
            "state", "reason", "project", "selected_by", "workspace", "linked_project", "live_reads", "integrity",
        ])
        #expect(status["state"]?.stringValue == "selected")
        #expect(status["reason"]?.isNull == true)
        #expect(status["selected_by"]?.stringValue == "working_directory")
        #expect(status["workspace"]?.isNull == true)
        #expect(status["linked_project"]?.isNull == true)
        #expect(status["live_reads"]?.stringValue == "not_available")
        #expect(status["integrity"]?.stringValue == "verified")
        let project = try #require(status["project"]?.objectValue)
        #expect(Set(project.keys) == ["id", "name"])
        #expect(project["name"]?.stringValue == "Shop project")
        #expect(project["id"]?.stringValue == Self.projectID.uuidString)
    }

    @Test func statusReportsUnconfiguredReasonAndWorkspace() throws {
        let result = try call(.status, nil, context: .unconfigured(.ambiguousProjects, workspace: "/work/app"))
        let status = object(result)
        #expect(status["state"]?.stringValue == "unconfigured")
        #expect(status["reason"]?.stringValue == "ambiguous_projects")
        #expect(status["project"]?.isNull == true)
        #expect(status["selected_by"]?.isNull == true)
        #expect(status["workspace"]?.stringValue == "/work/app")
        #expect(status["linked_project"]?.isNull == true)
        #expect(status["live_reads"]?.stringValue == "not_available")
    }

    @Test func statusReportsALinkedRepositorySelection() throws {
        let status = object(try call(.status, nil, context: .selected(project(), source: .linkedRepository)))
        #expect(status["state"]?.stringValue == "selected")
        #expect(status["selected_by"]?.stringValue == "linked_repository")
        #expect(status["project"]?.objectValue?["name"]?.stringValue == "Shop project")
        #expect(status["linked_project"]?.isNull == true)
    }

    @Test func statusShowsTheNameALinkFileGaveWhenNoProjectHasIt() throws {
        let missing = try call(
            .status, nil, context: .unconfigured(.linkedProjectNotFound, workspace: "/work/app", linkedProject: "Ledger")
        )
        expectJSONText(missing)
        let status = object(missing)
        #expect(status["state"]?.stringValue == "unconfigured")
        #expect(status["reason"]?.stringValue == "linked_project_not_found")
        #expect(status["linked_project"]?.stringValue == "Ledger")
        #expect(status["project"]?.isNull == true)
        #expect(status["selected_by"]?.isNull == true)
        #expect(status["workspace"]?.stringValue == "/work/app")

        let invalid = object(try call(.status, nil, context: .unconfigured(.invalidLinkFile, workspace: "/work/repo")))
        #expect(invalid["reason"]?.stringValue == "invalid_link_file")
        #expect(invalid["workspace"]?.stringValue == "/work/repo")
        #expect(invalid["linked_project"]?.isNull == true)
    }

    @Test func statusIntegrityIsPinnedForEveryCase() throws {
        func integrity(_ context: MCPProjectContext) throws -> Value? {
            object(try call(.status, nil, context: context))["integrity"]
        }
        #expect(try integrity(selected(integrity: true))?.stringValue == "verified")
        #expect(try integrity(selected(integrity: false))?.stringValue == "unavailable")
        #expect(try integrity(.unconfigured(.integrityUnavailable, workspace: nil))?.stringValue == "unavailable")
        #expect(try integrity(.unconfigured(.noMatchingProject, workspace: nil))?.isNull == true)
        #expect(try integrity(.unconfigured(.projectDisabled, workspace: nil))?.isNull == true)

        // A project whose tag does not verify stays selected, so its metadata tools keep working.
        let degraded = try call(.listConnections, nil, context: selected(integrity: false))
        #expect(degraded.isError != true)
        #expect(object(try call(.status, nil, context: selected(integrity: false)))["state"]?.stringValue == "selected")
    }

    @Test func statusNeverNamesOtherProjects() throws {
        let secretRoot = "/Users/someone/clients/secret-client"
        let result = try call(.status, nil, context: selected(roots: [secretRoot]))
        let rendered = String(describing: result)
        #expect(!rendered.contains(secretRoot))
        #expect(!rendered.contains(shop.id.uuidString))
        #expect(!rendered.contains("db.internal.example"))

        let unconfigured = try call(.status, nil, context: .unconfigured(.noMatchingProject, workspace: "/work/app"))
        let unconfiguredText = String(describing: unconfigured)
        #expect(unconfiguredText.contains("/work/app"))
        #expect(!unconfiguredText.contains("Shop project"))
        #expect(object(unconfigured)["project"]?.isNull == true)

        let explicitFailure = try call(.status, nil, context: .unconfigured(.explicitProjectNotFound, workspace: nil))
        #expect(object(explicitFailure)["workspace"]?.isNull == true)
        #expect(object(explicitFailure)["reason"]?.stringValue == "explicit_project_not_found")
    }

    // MARK: Results

    @Test func listConnectionsReturnsDescriptors() throws {
        let result = try call(.listConnections, [:])
        expectJSONText(result)
        let connections = try #require(object(result)["connections"]?.arrayValue)
        #expect(connections.count == 1)
        let first = try #require(connections.first?.objectValue)
        #expect(first["id"]?.stringValue == shop.id.uuidString)
        #expect(first["name"]?.stringValue == "Shop")
        #expect(first["environment"]?.stringValue == "production")
        #expect(first["graph_harvested_at"]?.stringValue == "2023-11-14T22:13:20Z")
        #expect(!String(describing: result).contains("db.internal.example"))
    }

    @Test func getSchemaReturnsObjectsWithSnakeCaseKeys() throws {
        let overview = try call(.getSchema, ["connection_id": connectionID])
        expectJSONText(overview)
        #expect(object(overview)["omitted_count"]?.intValue == 0)
        #expect(object(overview)["harvested_at"]?.stringValue == "2023-11-14T22:13:20Z")

        let full = try call(.getSchema, ["connection_id": connectionID, "object_names": ["orders"], "detail": "full"])
        expectJSONText(full)
        let orders = try #require(object(full)["objects"]?.arrayValue?.first?.objectValue)
        let columns = try #require(orders["columns"]?.arrayValue)
        let created = try #require(columns.compactMap(\.objectValue).first { $0["name"]?.stringValue == "createdAt" })
        #expect(created["nullable"] == .bool(true))
        #expect(created["primary_key"] == .bool(false))
    }

    @Test func searchSchemaReturnsMatches() throws {
        let result = try call(.searchSchema, ["connection_id": connectionID, "query": "order"])
        let matches = try #require(object(result)["matches"]?.arrayValue)
        #expect(matches.compactMap { $0.objectValue?["name"]?.stringValue } == ["orders"])
        expectJSONText(result)
    }

    @Test func graphQueryReturnsOperationAndResult() throws {
        let neighbors = try call(.graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "orders"])
        expectJSONText(neighbors)
        #expect(object(neighbors)["operation"]?.stringValue == "neighbors")
        let payload = try #require(object(neighbors)["result"]?.objectValue)
        #expect(payload["depends_on"]?.arrayValue?.compactMap(\.stringValue) == ["customers"])
        #expect(payload["depended_on_by"]?.arrayValue == [])

        let path = try call(.graphQuery, [
            "connection_id": connectionID, "operation": "path", "from": "orders", "to": "customers",
        ])
        expectJSONText(path)

        let radius = try call(.graphQuery, ["connection_id": connectionID, "operation": "blast_radius", "node": "customers"])
        #expect(object(radius)["operation"]?.stringValue == "blast_radius")
        expectJSONText(radius)

        let cycles = try call(.graphQuery, ["connection_id": connectionID, "operation": "circular_dependencies"])
        expectJSONText(cycles)
        #expect(object(cycles)["result"]?.objectValue?["has_cycles"] == .bool(false))

        let central = try call(.graphQuery, ["connection_id": connectionID, "operation": "top_centrality", "limit": .int(1)])
        #expect(object(central)["operation"]?.stringValue == "top_centrality")
        expectJSONText(central)
        #expect(object(central)["result"]?.arrayValue?.first?.objectValue?["in_degree"]?.intValue == 1)
    }

    @Test func graphStatsReturnsSummaryAndTable() throws {
        let summary = try call(.getGraphStats, ["connection_id": connectionID])
        expectJSONText(summary)
        #expect(object(summary)["unused_indexes"]?.arrayValue == [])
        let table = try call(.getGraphStats, ["connection_id": connectionID, "object": "orders"])
        expectJSONText(table)
        #expect(object(table)["table"]?.stringValue == "orders")
        #expect(object(table)["fields"]?.objectValue?["rows"]?.stringValue == "10")
    }

    @Test func textContentIsTheCompactJSONOfTheStructuredResult() throws {
        var graph = shopGraph()
        graph.addNode(GraphNode(id: "t:evil", kind: .table, name: "evil\nname\r\nwith breaks"))
        let result = try call(
            .graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "evil\nname\r\nwith breaks"],
            router: router(graph: graph)
        )
        #expect(result.isError != true)
        expectJSONText(result)
        #expect(object(result)["result"]?.objectValue?["node"]?.stringValue == "evil\nname\r\nwith breaks")
        for status in [selected(), .unconfigured(.noMatchingProject, workspace: "/a\nb")] {
            expectJSONText(try call(.status, nil, context: status))
        }
        let failure = try call(.graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "x\ny"])
        #expect(failure.isError == true)
        #expect(!text(failure).contains("\n"))
    }

    // MARK: Output schemas

    /// Checks `value` against the subset of JSON Schema the catalog uses
    /// (`type`, `properties`, `required`, `additionalProperties`, `items`, `enum`),
    /// returning the first violation.
    func violation(_ value: Value, against schema: Value, path: String = "$") -> String? {
        guard let schema = schema.objectValue else { return nil }
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) { return "\(path): not in enum" }
        let types = schema["type"]?.stringValue.map { [$0] } ?? schema["type"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !types.isEmpty {
            let actual: String
            switch value {
            case .null: actual = "null"
            case .bool: actual = "boolean"
            case .int: actual = "integer"
            case .double: actual = "number"
            case .string: actual = "string"
            case .array: actual = "array"
            case .object: actual = "object"
            case .data: actual = "data"
            }
            guard types.contains(actual) else { return "\(path): expected \(types), got \(actual)" }
        }
        if let items = value.arrayValue, let itemSchema = schema["items"] {
            for (index, item) in items.enumerated() {
                if let problem = violation(item, against: itemSchema, path: "\(path)[\(index)]") { return problem }
            }
        }
        if let members = value.objectValue {
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where members[key] == nil {
                return "\(path): missing \(key)"
            }
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                if let propertySchema = properties[key] {
                    if let problem = violation(member, against: propertySchema, path: "\(path).\(key)") { return problem }
                } else if schema["additionalProperties"] == .bool(false) {
                    return "\(path): unexpected \(key)"
                } else if let extra = schema["additionalProperties"], extra.objectValue != nil {
                    if let problem = violation(member, against: extra, path: "\(path).\(key)") { return problem }
                }
            }
        }
        return nil
    }

    @Test func structuredResultsConformToTheirOutputSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools(for: selected()).map { ($0.name, $0) })
        let id = connectionID
        let graph: (String, [String: Value]) -> [String: Value] = { operation, extra in
            ["connection_id": id, "operation": .string(operation)].merging(extra) { $1 }
        }
        let calls: [(MCPToolName, [String: Value])] = [
            (.status, [:]),
            (.listConnections, [:]),
            (.getSchema, ["connection_id": id]),
            (.getSchema, ["connection_id": id, "detail": "full"]),
            (.searchSchema, ["connection_id": id, "query": "id"]),
            (.graphQuery, graph("neighbors", ["node": "orders"])),
            (.graphQuery, graph("path", ["from": "orders", "to": "customers"])),
            (.graphQuery, graph("blast_radius", ["node": "customers"])),
            (.graphQuery, graph("circular_dependencies", [:])),
            (.graphQuery, graph("top_centrality", [:])),
            (.getGraphStats, ["connection_id": id]),
            (.getGraphStats, ["connection_id": id, "object": "orders"]),
        ]
        for (name, arguments) in calls {
            let result = try call(name, arguments)
            #expect(result.isError != true)
            expectJSONText(result)
            let structured = try #require(result.structuredContent)
            let schema = try #require(tools[name.rawValue]?.outputSchema)
            #expect(violation(structured, against: schema) == nil, "\(name.rawValue): \(violation(structured, against: schema) ?? "")")
        }
        let contexts: [MCPProjectContext] = [
            selected(), selected(integrity: false),
            .selected(project(), source: .linkedRepository),
            .unconfigured(.integrityUnavailable, workspace: nil),
            .unconfigured(.noMatchingProject, workspace: "/work"),
            .unconfigured(.linkedProjectNotFound, workspace: nil, linkedProject: "Ledger"),
            .unconfigured(.invalidLinkFile, workspace: "/work"),
        ]
        let statusSchema = try #require(tools["berrydb_status"]?.outputSchema)
        for context in contexts {
            let structured = try #require(try call(.status, nil, context: context).structuredContent)
            #expect(violation(structured, against: statusSchema) == nil, "\(context): \(violation(structured, against: statusSchema) ?? "")")
        }
    }

    // MARK: Encoding

    @Test func dataKeysSurviveWhileStructKeysAreSnakeCase() throws {
        let decoded = try JSONDecoder().decode(
            BerryGraphQueryService.TableStatistics.self,
            from: Data(#"{"table":"orders","fields":{"rowCount":"5","createdAt":"x"},"indexes":[{"name":"i","fields":{"idxScan":"2"}}]}"#.utf8)
        )
        let value = try MCPStructuredEncoding.value(MCPGraphStats.table(decoded))
        let fields = try #require(value.objectValue?["fields"]?.objectValue)
        #expect(Set(fields.keys) == ["rowCount", "createdAt"])
        let index = try #require(value.objectValue?["indexes"]?.arrayValue?.first?.objectValue)
        #expect(Set(try #require(index["fields"]?.objectValue).keys) == ["idxScan"])

        let summary = try JSONDecoder().decode(
            BerryGraphQueryService.StatisticsSummary.self,
            from: Data(#"{"tables":[{"name":"t","fields":{"rowCount":"1"}}],"unusedIndexes":["a"]}"#.utf8)
        )
        let summaryValue = try MCPStructuredEncoding.value(MCPGraphStats.summary(summary))
        #expect(summaryValue.objectValue?["unused_indexes"]?.arrayValue?.count == 1)
        let tableFields = summaryValue.objectValue?["tables"]?.arrayValue?.first?.objectValue?["fields"]?.objectValue
        #expect(Set(tableFields?.keys.map { $0 } ?? []) == ["rowCount"])

        let listing = BerryGraphQueryService.SchemaListing(objects: [], omittedCount: 3, harvestedAt: Self.harvestTime)
        let listingValue = try MCPStructuredEncoding.value(listing)
        #expect(Set(listingValue.objectValue?.keys.map { $0 } ?? []) == ["objects", "omitted_count", "harvested_at"])
        let neighbors = BerryGraphQueryService.Neighbors(node: "n", dependsOn: [], dependedOnBy: [])
        #expect(Set(try #require(MCPStructuredEncoding.value(neighbors).objectValue).keys) == ["node", "depends_on", "depended_on_by"])
    }

    // MARK: Resources

    @Test func unconfiguredContextHasNoResources() throws {
        let context = MCPProjectContext.unconfigured(.noMatchingProject, workspace: nil)
        #expect(try MCPResourceCatalog.resources(for: context, metadata: service()).isEmpty)
        #expect(throws: MCPError.invalidParams("Unknown resource")) {
            try MCPResourceCatalog.read(uri: "berrydb://project", context: context, metadata: service())
        }
    }

    @Test func selectedContextListsProjectAndGraphResources() throws {
        let resources = try MCPResourceCatalog.resources(for: selected(), metadata: service())
        #expect(resources.map(\.uri) == ["berrydb://project", "berrydb://connections/\(shop.id.uuidString)/graph"])
        #expect(resources.allSatisfy { $0.mimeType == "application/json" })

        let project = try MCPResourceCatalog.read(uri: "berrydb://project", context: selected(), metadata: service())
        let projectJSON = try jsonObject(project)
        #expect((projectJSON["project"] as? [String: Any])?["name"] as? String == "Shop project")
        #expect((projectJSON["connections"] as? [[String: Any]])?.count == 1)
        #expect(project.first?.uri == "berrydb://project")

        let graphURI = "berrydb://connections/\(shop.id.uuidString)/graph"
        let graph = try MCPResourceCatalog.read(uri: graphURI, context: selected(), metadata: service())
        let graphJSON = try jsonObject(graph)
        #expect(graphJSON["harvested_at"] as? String == "2023-11-14T22:13:20Z")
        #expect((graphJSON["tables"] as? [Any])?.count == 2)
        #expect(graph.first?.uri == graphURI)
        #expect(graph.first?.mimeType == "application/json")
    }

    @Test func unharvestedConnectionHasNoGraphResource() throws {
        let unharvested = service(harvested: false)
        let resources = try MCPResourceCatalog.resources(for: selected(), metadata: unharvested)
        #expect(resources.map(\.uri) == ["berrydb://project"])

        let empty = service(graph: SchemaGraph(), harvested: false)
        #expect(throws: MCPError.invalidParams(MCPMetadataError.noSnapshot.description)) {
            try MCPResourceCatalog.read(
                uri: "berrydb://connections/\(shop.id.uuidString)/graph", context: selected(), metadata: empty
            )
        }
    }

    @Test func resourceReadRejectsUnassignedConnectionLikeUnknownURI() throws {
        let unknownMessage = "Unknown resource"
        let uris = [
            "berrydb://connections/\(outsider.id.uuidString)/graph",
            "berrydb://connections/\(UUID().uuidString)/graph",
            "berrydb://connections/not-a-uuid/graph",
            "berrydb://connections/\(shop.id.uuidString)/schema",
            "berrydb://project/extra",
            "berrydb://other",
            "file:///etc/passwd",
            "",
        ]
        for uri in uris {
            do {
                _ = try MCPResourceCatalog.read(uri: uri, context: selected(), metadata: service())
                Issue.record("Expected an error for \(uri)")
            } catch let MCPError.invalidParams(message) {
                #expect(message == unknownMessage)
            }
        }
    }

    @Test func resourceStoreFailuresAreGeneric() throws {
        let failing = service(failure: PathLeakingError())
        let uri = "berrydb://connections/\(shop.id.uuidString)/graph"
        do {
            _ = try MCPResourceCatalog.read(uri: uri, context: selected(), metadata: failing)
            Issue.record("Expected an error")
        } catch let error as MCPError {
            #expect(error == MCPError.internalError("BerryDB could not read its store for this request."))
        }
    }
}
