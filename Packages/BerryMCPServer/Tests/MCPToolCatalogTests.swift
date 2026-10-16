import BerryDriverKit
import BerryGraph
import Foundation
import GRDB
import MCP
import Testing

@testable import BerryMCP
@testable import BerryMCPServer
@testable import BerryStore

/// A non-metadata failure whose every rendering contains a file path, the way
/// a database error can.
private struct PathLeakingError: Error, LocalizedError, CustomStringConvertible {
    static let path = "/Users/someone/Library/Application Support/BerryDB/store.sqlite"
    var errorDescription: String? { "disk I/O error at \(Self.path)" }
    var description: String { "PathLeakingError(\(Self.path))" }
}

/// A stored schema written the way a harvest pass writes it: the listing of
/// tables, views and foreign keys, the definitions of the tables whose
/// columns were read, and statistics.
struct StoredSchema {
    var objects: [SchemaListedObject] = []
    var relations: [SchemaListedRelation] = []
    var definitions: [SchemaDetailWrite] = []
    var rows: [String: Int64] = [:]

    static func column(_ name: String, _ type: String, nullable: Bool, primaryKey: Bool = false) -> SchemaDefinition.Column {
        SchemaDefinition.Column(name: name, type: type, nullable: nullable, defaultValue: nil, primaryKey: primaryKey)
    }

    /// A table, with a definition when `columns` is given and pending otherwise.
    mutating func table(_ name: String, columns: [SchemaDefinition.Column]? = nil, rows: Int64? = nil) throws {
        objects.append(SchemaListedObject(database: nil, name: name, kind: "table", fingerprint: nil))
        if let columns {
            let definition = SchemaDefinition(columns: columns, indexes: [])
            definitions.append(SchemaDetailWrite(
                database: nil, name: name, kind: "table", fingerprint: nil, definitionHash: definition.hash,
                definition: try definition.json(), columnText: definition.columnText, indexText: definition.indexText
            ))
        }
        self.rows[name] = rows
    }

    /// A view whose columns were never read.
    mutating func view(_ name: String) {
        objects.append(SchemaListedObject(database: nil, name: name, kind: "view", fingerprint: nil))
    }

    mutating func reference(_ source: String, _ column: String, _ target: String, _ targetColumn: String) {
        relations.append(SchemaListedRelation(
            srcDatabase: nil, srcName: source, srcColumn: column, dstDatabase: nil, dstName: target,
            dstColumn: targetColumn, constraintName: nil
        ))
    }

    /// Writes the schema as one pass at `at`, recorded as the last change and
    /// as the last check at `checkedAt`.
    func write(to store: BerryStore, profileID: UUID, at: Date, checkedAt: Date) throws {
        let listing = try store.applySchemaListing(profileID: profileID, objects: objects, relations: relations, now: at)
        _ = try store.applySchemaDetails(profileID: profileID, details: definitions, now: at, changeID: listing.changeID)
        try store.replaceSchemaStats(profileID: profileID, rows: rows.map {
            SchemaStatsRecord(profileID: profileID, database: nil, name: $0.key, rows: $0.value, updatedAt: at)
        })
        try store.updateSchemaGraphState(profileID: profileID) {
            $0.lastChangedAt = at
            $0.lastCheckedAt = checkedAt
        }
    }
}

@Suite("MCP tool catalog")
struct MCPToolCatalogTests {
    static let harvestTime = Date(timeIntervalSince1970: 1_700_000_000)
    static let noProjectText = "No BerryDB project is selected for this workspace. Call berrydb_status for details."

    let shop = ConnectionProfile(driverID: "postgres", name: "Shop", envColor: "production", host: "db.internal.example")
    let outsider = ConnectionProfile(driverID: "sqlite", name: "Outside", filePath: "/secret/outside.db")

    static let projectID = UUID()

    /// The shop project; `liveRead` turns live reads on for `shop` and
    /// verifies that switch.
    func project(integrity: Bool = true, roots: [String] = [], liveRead: Bool = false) -> MCPVerifiedProject {
        MCPVerifiedProject(
            project: MCPProject(
                id: Self.projectID, name: "Shop project", isEnabled: true, workspaceRoots: roots,
                profiles: [MCPProfileAccess(profileID: shop.id, liveRead: liveRead)]
            ),
            liveReadProfileIDs: liveRead ? [shop.id] : [],
            projectTagValid: integrity
        )
    }

    /// Selected by the working directory `/work/shop`.
    func selected(integrity: Bool = true, roots: [String] = [], liveRead: Bool = false) -> MCPProjectContext {
        .selected(
            project(integrity: integrity, roots: roots, liveRead: liveRead), source: .workingDirectory, workspace: "/work/shop"
        )
    }

    /// `orders` (10 rows) references `customers` (3 rows); `orders` has an
    /// `id` and a `createdAt` column and `customers` has no columns.
    func shopSchema() throws -> StoredSchema {
        var schema = StoredSchema()
        try schema.table("orders", columns: [
            StoredSchema.column("id", "int", nullable: false, primaryKey: true),
            StoredSchema.column("createdAt", "timestamp", nullable: true),
        ], rows: 10)
        try schema.table("customers", columns: [], rows: 3)
        schema.reference("orders", "customer_id", "customers", "id")
        return schema
    }

    /// A service over a store holding both profiles, with `schema` (the shop
    /// unless given) harvested for `shop` when `harvested`. A `broken` store
    /// fails every schema read with a database error.
    func service(schema: StoredSchema? = nil, harvested: Bool = true, broken: Bool = false) throws -> MCPMetadataService {
        let store = try BerryStore(path: ":memory:")
        try store.save(shop)
        try store.save(outsider)
        if harvested {
            try (schema ?? shopSchema()).write(to: store, profileID: shop.id, at: Self.harvestTime, checkedAt: Date())
        }
        if broken {
            try #require(store.dbQueue).write { try $0.execute(sql: "DROP TABLE schema_graph_state") }
        }
        return MCPMetadataService(store: store)
    }

    func router(schema: StoredSchema? = nil, harvested: Bool = true, broken: Bool = false) throws -> MCPToolRouter {
        MCPToolRouter(metadata: try service(schema: schema, harvested: harvested, broken: broken))
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

    /// The text content must be the compact JSON of `structuredContent`, on
    /// one line. Compared as bytes after encoding `structuredContent`, since
    /// decoding the text into `Value` would pass through the same SDK decoder
    /// that rewrites data-URL-shaped strings.
    func expectJSONText(_ result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = result.structuredContent.flatMap { try? encoder.encode($0) }
        #expect(encoded.map { String(decoding: $0, as: UTF8.self) } == text(result), sourceLocation: sourceLocation)
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
            "berrydb_search_schema", "berrydb_graph_query", "berrydb_get_graph_stats", "berrydb_get_schema_changes",
            "berrydb_execute_read_query",
        ])
    }

    @Test func unconfiguredContextListsOnlyStatus() {
        let tools = MCPToolCatalog.tools(for: .unconfigured(.noMatchingProject, workspace: "/work"))
        #expect(tools.map(\.name) == ["berrydb_status"])
    }

    /// Without a live-read connection every tool but the live one is listed.
    @Test func selectedContextListsEveryToolWithStrictSchemas() throws {
        let tools = MCPToolCatalog.tools(for: selected())
        #expect(tools.map(\.name) == MCPToolName.allCases.filter { $0 != .executeReadQuery }.map(\.rawValue))
        #expect(MCPToolCatalog.tools(for: selected(), liveReadConnectionIDs: []).map(\.name) == tools.map(\.name))
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
        #expect(schema["offset"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(schema["offset"]?.objectValue?["minimum"]?.intValue == 0)
        #expect(schema["offset"]?.objectValue?["default"]?.intValue == 0)
        #expect(Set(schema.keys) == ["connection_id", "object_names", "detail", "offset"])
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

        let changes = try properties(.getSchemaChanges)
        #expect(Set(changes.keys) == ["connection_id", "since", "limit"])
        #expect(changes["since"]?.objectValue?["type"]?.stringValue == "string")
        #expect(changes["since"]?.objectValue?["maxLength"]?.intValue == 64)
        #expect(changes["limit"]?.objectValue?["minimum"]?.intValue == 1)
        #expect(changes["limit"]?.objectValue?["maximum"]?.intValue == 200)
        #expect(changes["limit"]?.objectValue?["default"]?.intValue == 50)
        #expect(required(.getSchemaChanges) == ["connection_id"])

        let stats = try properties(.getGraphStats)
        #expect(Set(stats.keys) == ["connection_id", "object"])
        #expect(required(.getGraphStats) == ["connection_id"])
    }

    @Test func theLiveToolIsListedOnlyWithALiveReadConnection() throws {
        let live = MCPToolName.executeReadQuery.rawValue
        #expect(!MCPToolCatalog.tools(for: selected(), liveReadConnectionIDs: []).map(\.name).contains(live))
        let unconfigured = MCPProjectContext.unconfigured(.noMatchingProject, workspace: nil)
        #expect(MCPToolCatalog.tools(for: unconfigured, liveReadConnectionIDs: [shop.id]).map(\.name) == ["berrydb_status"])

        let tools = MCPToolCatalog.tools(for: selected(liveRead: true), liveReadConnectionIDs: [shop.id])
        #expect(tools.map(\.name) == MCPToolName.allCases.map(\.rawValue))
        let tool = try #require(tools.first { $0.name == live })
        #expect(tool.description == "Runs one read-only SQL statement on a connection whose live reads the user turned on, and returns at most row_limit rows. Placeholders are $1, $2, … on PostgreSQL and ? on MySQL, MariaDB and SQLite; pass their values in parameters. The database refuses any write. Results go to this host and its model provider.")
        #expect(tool.annotations.readOnlyHint == true)
        #expect(tool.annotations.destructiveHint == false)
        #expect(tool.annotations.idempotentHint == false)
        #expect(tool.annotations.openWorldHint == true)

        let input = try #require(tool.inputSchema.objectValue)
        #expect(input["type"]?.stringValue == "object")
        #expect(input["additionalProperties"] == .bool(false))
        #expect(input["required"]?.arrayValue?.compactMap(\.stringValue) == ["connection_id", "sql"])
        let properties = try #require(input["properties"]?.objectValue)
        #expect(Set(properties.keys) == ["connection_id", "sql", "parameters", "row_limit"])
        #expect(properties["connection_id"]?.objectValue?["format"]?.stringValue == "uuid")
        let sql = try #require(properties["sql"]?.objectValue)
        #expect(sql["type"]?.stringValue == "string")
        #expect(sql["minLength"]?.intValue == 1)
        #expect(sql["maxLength"]?.intValue == 65_536)
        let parameters = try #require(properties["parameters"]?.objectValue)
        #expect(parameters["type"]?.stringValue == "array")
        #expect(parameters["maxItems"]?.intValue == 100)
        #expect(parameters["items"]?.objectValue?["type"]?.arrayValue?.compactMap(\.stringValue) == [
            "string", "number", "boolean", "null",
        ])
        let rowLimit = try #require(properties["row_limit"]?.objectValue)
        #expect(rowLimit["type"]?.stringValue == "integer")
        #expect(rowLimit["minimum"]?.intValue == 1)
        #expect(rowLimit["maximum"]?.intValue == 100)

        let output = try #require(tool.outputSchema?.objectValue)
        #expect(output["additionalProperties"] == .bool(false))
        let fields = [
            "columns", "rows", "row_count", "truncated", "has_more_rows", "truncated_cells", "byte_limit_reached",
            "elapsed_ms", "redacted_columns",
        ]
        #expect(output["required"]?.arrayValue?.compactMap(\.stringValue) == fields)
        #expect(Set(output["properties"]?.objectValue?.keys.map { $0 } ?? []) == Set(fields))
        let cell = output["properties"]?.objectValue?["rows"]?.objectValue?["items"]?.objectValue?["items"]
        #expect(cell?.objectValue?["type"]?.arrayValue?.compactMap(\.stringValue) == ["string", "null"])

        // The metadata tools keep their annotations next to the live one.
        for metadataTool in tools where metadataTool.name != live {
            #expect(metadataTool.annotations.idempotentHint == true)
            #expect(metadataTool.annotations.openWorldHint == false)
        }
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

    /// Messages are pinned exactly, so none can start echoing the value it
    /// rejects.
    @Test func pathWithoutToIsInvalidParams() {
        let arguments: [String: Value] = ["connection_id": connectionID, "operation": "path", "from": "orders"]
        #expect(invalidParamsMessage("berrydb_graph_query", arguments) == "operation 'path' requires 'to'")
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "neighbors"]
        ) == "operation 'neighbors' requires 'node'")
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "blast_radius", "node": "  "]
        ) == "operation 'blast_radius' requires 'node'")
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "path", "to": "orders"]
        ) == "operation 'path' requires 'from'")
        #expect(invalidParamsMessage(
            "berrydb_graph_query", ["connection_id": connectionID, "operation": "teleport"]
        ) == "operation must be one of neighbors, path, blast_radius, circular_dependencies, top_centrality")
    }

    @Test func badUUIDIsInvalidParams() {
        #expect(invalidParamsMessage("berrydb_get_schema", ["connection_id": "not-a-uuid"]) == "connection_id must be a UUID")
        #expect(invalidParamsMessage("berrydb_get_schema", ["connection_id": .int(3)]) == "connection_id must be a string")
        #expect(invalidParamsMessage("berrydb_get_schema", nil) == "connection_id is required")
        #expect(invalidParamsMessage("berrydb_get_schema", [:]) == "connection_id is required")
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
        #expect(schema(["detail": "everything"]) == "detail must be one of overview, full")
        #expect(schema(["detail": .int(1)]) == "detail must be a string")
        #expect(schema(["object_names": "orders"]) == "object_names must be an array of strings")
        #expect(schema(["object_names": [.string("a"), .int(2)]]) == "object_names must be an array of strings")
        #expect(schema(["object_names": .array((0 ... 50).map { .string("t\($0)") })]) == "object_names accepts at most 50 names")

        let queryLength = "query must be 1 to 200 characters"
        #expect(search([:]) == "query is required")
        #expect(search(["query": ""]) == queryLength)
        #expect(search(["query": .string(String(repeating: "a", count: 201))]) == queryLength)
        #expect(search(["query": .int(4)]) == "query must be a string")
        #expect(search(["query": "ord", "limit": .int(0)]) == "limit must be between 1 and 200")
        #expect(search(["query": "ord", "limit": .int(201)]) == "limit must be between 1 and 200")
        #expect(search(["query": "ord", "limit": "ten"]) == "limit must be an integer")
        #expect(search(["query": "ord", "limit": .double(2.5)]) == "limit must be an integer")

        #expect(graph(["limit": .int(0)]) == "limit must be between 1 and 50")
        #expect(graph(["limit": .int(51)]) == "limit must be between 1 and 50")
        #expect(graph(["operation": .int(1)]) == "operation must be a string")
        #expect(invalidParamsMessage("berrydb_get_graph_stats", ["connection_id": id, "object": .int(1)]) == "object must be a string")

        #expect(schema(["offset": .int(-1)]) == "offset must be 0 or greater")
        #expect(schema(["offset": "1"]) == "offset must be an integer")
        func changes(_ extra: [String: Value]) -> String? {
            invalidParamsMessage("berrydb_get_schema_changes", ["connection_id": id].merging(extra) { $1 })
        }
        #expect(changes(["since": .int(5)]) == "since must be a string")
        #expect(changes(["since": .string(String(repeating: "9", count: 65))]) == "since must be at most 64 characters")
        #expect(changes(["limit": .int(0)]) == "limit must be between 1 and 200")
        #expect(changes(["limit": .int(201)]) == "limit must be between 1 and 200")
        #expect(changes(["limit": "ten"]) == "limit must be an integer")
        #expect(changes(["cursor": "id:1"]) == "Unexpected argument: cursor")
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

    /// A live tool whose coordinator serves no project, so a call that passes
    /// its argument checks ends at the service without opening anything.
    func liveTool() -> MCPLiveReadTool {
        let resolver = MCPProjectResolver(loadProject: { nil }, profile: { _ in nil })
        let coordinator = MCPConnectionCoordinator(resolver: resolver, sqlFactory: { _ in throw CancellationError() })
        return MCPLiveReadTool(service: MCPLiveReadService(coordinator: coordinator))
    }

    /// The `invalidParams` message the live tool throws, nil when it throws none.
    func liveInvalidParamsMessage(_ arguments: [String: Value]?) async -> String? {
        do {
            _ = try await liveTool().call(arguments, context: selected(liveRead: true), metadata: try service())
            return nil
        } catch let MCPError.invalidParams(message) {
            return message ?? ""
        } catch {
            return nil
        }
    }

    @Test func parametersMustBeScalars() async throws {
        let id = connectionID
        func read(_ parameters: Value) async -> String? {
            await liveInvalidParamsMessage(["connection_id": id, "sql": "SELECT 1", "parameters": parameters])
        }
        let scalars = "parameters must hold only strings, numbers, booleans or null"
        #expect(await read([["a": 1]]) == scalars)
        #expect(await read([.string("ok"), .array([.int(1)])]) == scalars)
        #expect(await read("1") == "parameters must be an array")
        #expect(await read(.array(Array(repeating: .int(1), count: 101))) == "parameters accepts at most 100 values")
        // The SDK decodes a string shaped like a data URL into bytes and the
        // original text cannot be recovered, so it is refused, not rebound.
        #expect(await read([.data(mimeType: "text/plain", Data("x".utf8))]) == "parameters cannot hold a data: URL string")

        let secret = "s3cr3t-parameter-value"
        for rejected: Value in [[["k": .string(secret)]], [.array([.string(secret)])], .string(secret)] {
            let message = await read(rejected)
            #expect(message != nil)
            #expect(message?.contains(secret) == false)
        }

        let bound = try MCPToolArguments(
            ["parameters": [.string("a"), .int(2), .double(2.5), .bool(true), .null]],
            allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery)
        ).parameters()
        #expect(bound == [.text("a"), .int(2), .double(2.5), .bool(true), .null])
        let absent = try MCPToolArguments([:], allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery))
        #expect(try absent.parameters() == [])
        #expect(try absent.rowLimit() == nil)
        #expect(await read(.array(Array(repeating: .int(1), count: 100))) == nil)
    }

    /// Arguments reach the tool as the SDK's `Value` decoder reads the
    /// request's JSON, and that decoder decides whether a number binds as
    /// an integer or a double.
    @Test func numbersBindAsTheSDKDecodesThem() throws {
        let json = #"{"parameters":[2,2.5,2.0,1e3,9223372036854775808]}"#
        let arguments = try JSONDecoder().decode([String: Value].self, from: Data(json.utf8))
        let bound = try MCPToolArguments(
            arguments, allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery)
        ).parameters()
        #expect(bound == [.int(2), .double(2.5), .int(2), .int(1_000), .double(9.223372036854775808e18)])
    }

    @Test func sqlIsRequiredAndBounded() async throws {
        let id = connectionID
        func read(_ arguments: [String: Value]) async -> String? {
            await liveInvalidParamsMessage(arguments)
        }
        let length = "sql must be 1 to 65536 bytes"
        #expect(await read(["connection_id": id]) == "sql is required")
        #expect(await read(["connection_id": id, "sql": .null]) == "sql is required")
        #expect(await read(["connection_id": id, "sql": .int(1)]) == "sql must be a string")
        #expect(await read(["connection_id": id, "sql": ""]) == length)
        // The bound counts UTF-8 bytes: "é" takes two.
        #expect(await read(["connection_id": id, "sql": .string(String(repeating: "a", count: 65_536))]) == nil)
        #expect(await read(["connection_id": id, "sql": .string(String(repeating: "a", count: 65_535) + "é")]) == length)
        #expect(await read(["sql": "SELECT 1"]) == "connection_id is required")
        #expect(await read(["connection_id": "nope", "sql": "SELECT 1"]) == "connection_id must be a UUID")
        #expect(await read(["connection_id": id, "sql": "SELECT 1", "row_limit": .int(0)]) == "row_limit must be between 1 and 100")
        #expect(await read(["connection_id": id, "sql": "SELECT 1", "row_limit": .int(101)]) == "row_limit must be between 1 and 100")
        #expect(await read(["connection_id": id, "sql": "SELECT 1", "row_limit": "ten"]) == "row_limit must be an integer")
        #expect(await read(["connection_id": id, "sql": "SELECT 1", "query": "SELECT 2"]) == "Unexpected argument: query")
        let limited = try MCPToolArguments(
            ["row_limit": .int(7)], allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery)
        )
        #expect(try limited.rowLimit() == 7)
    }

    /// The live tool answers an unassigned and a deleted profile alike, and a
    /// driver without a SQL dialect with the unsupported text, all before
    /// the service resolves anything; without a project it answers like the
    /// metadata tools.
    @Test func theLiveToolRefusesWhatItCannotRunBeforeConnecting() async throws {
        let cache = ConnectionProfile(driverID: "redis", name: "Cache")
        let deleted = UUID()
        let store = try BerryStore(path: ":memory:")
        for profile in [shop, outsider, cache] {
            try store.save(profile)
        }
        let metadata = MCPMetadataService(store: store)
        let project = MCPVerifiedProject(
            project: MCPProject(
                id: Self.projectID, name: "Shop project", isEnabled: true,
                profiles: [shop.id, cache.id, deleted].map { MCPProfileAccess(profileID: $0, liveRead: true) }
            ),
            liveReadProfileIDs: [shop.id, cache.id, deleted]
        )
        let context = MCPProjectContext.selected(project, source: .workingDirectory, workspace: "/work/shop")
        func call(_ id: UUID, context: MCPProjectContext) async throws -> CallTool.Result {
            try await liveTool().call(
                ["connection_id": .string(id.uuidString), "sql": "SELECT 1"], context: context, metadata: metadata
            )
        }

        let unassigned = try await call(outsider.id, context: context)
        let missing = try await call(deleted, context: context)
        let random = try await call(UUID(), context: context)
        for result in [unassigned, missing, random] {
            #expect(result.isError == true)
            #expect(text(result) == "Unknown connection for this project")
            #expect(result.structuredContent == nil)
        }
        #expect(unassigned == missing)

        let unsupported = try await call(cache.id, context: context)
        #expect(unsupported.isError == true)
        #expect(text(unsupported) == MCPLiveReadError.unsupportedDatabase.description)

        let noProject = try await call(shop.id, context: .unconfigured(.noMatchingProject, workspace: "/work"))
        #expect(noProject.isError == true)
        #expect(text(noProject) == Self.noProjectText)

        // A call that passes every check reaches the service, whose
        // coordinator here serves no project.
        let reached = try await call(shop.id, context: context)
        #expect(text(reached) == MCPLiveReadError.noProject.description)
    }

    /// A server built without live reads never runs the tool; the router
    /// answers with a fixed text.
    @Test func aRouterWithoutLiveReadsRefusesTheLiveTool() throws {
        let result = try call(.executeReadQuery, ["connection_id": connectionID, "sql": "SELECT 1"], context: selected(liveRead: true))
        #expect(result.isError == true)
        #expect(text(result) == "Live reads are not available in this helper.")
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
        let changes = try call(.getSchemaChanges, ["connection_id": .string(outsider.id.uuidString)])
        #expect(text(changes) == "Unknown connection for this project")
    }

    @Test func metadataErrorTextReachesTheAgent() throws {
        let result = try call(.graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "missing"])
        #expect(result.isError == true)
        #expect(text(result).hasPrefix("Node 'missing' not found"))
        let empty = try call(.getSchema, ["connection_id": connectionID], router: router(harvested: false))
        #expect(empty.isError == true)
        #expect(text(empty) == MCPMetadataError.noSnapshot.description)
        let noGraph = try call(
            .searchSchema, ["connection_id": connectionID, "query": "x"], router: router(harvested: false)
        )
        #expect(noGraph.isError == true)
        #expect(text(noGraph) == MCPMetadataError.noSnapshot.description)
    }

    @Test func nonMetadataErrorsNeverLeakTheirDetail() throws {
        let failing = try router(broken: true)
        let calls: [(MCPToolName, [String: Value])] = [
            (.getSchema, ["connection_id": connectionID]),
            (.searchSchema, ["connection_id": connectionID, "query": "ord"]),
            (.graphQuery, ["connection_id": connectionID, "operation": "circular_dependencies"]),
            (.getGraphStats, ["connection_id": connectionID]),
            (.getSchemaChanges, ["connection_id": connectionID]),
        ]
        for (name, arguments) in calls {
            let result = try call(name, arguments, router: failing)
            #expect(result.isError == true)
            #expect(text(result) == "BerryDB could not read its store for this request.")
            // GRDB writes "SQLite error 1: no such table: schema_graph_state".
            let rendered = String(describing: result).lowercased()
            #expect(!rendered.contains("/users"))
            #expect(!rendered.contains("sqlite"))
            #expect(!rendered.contains("schema_graph_state"))
        }

        let reader = GraphReader(store: try BerryStore(path: ":memory:"))
        let throwingProfiles = MCPMetadataService(
            profiles: { throw PathLeakingError() }, reader: reader, graph: BerryGraphQueryService(reader: reader)
        )
        let listed = try MCPToolRouter(metadata: throwingProfiles)
            .call("berrydb_list_connections", arguments: nil, context: selected())
        #expect(listed.isError == true)
        #expect(text(listed) == "BerryDB could not read its store for this request.")
    }

    /// A page always holds at least one object, so one table whose columns
    /// alone exceed 1 MiB still reaches the result ceiling.
    @Test func oversizedResultIsToolError() throws {
        var schema = StoredSchema()
        try schema.table("table_0", columns: (0 ..< 12_000).map {
            StoredSchema.column("column_with_a_deliberately_long_name_\($0)", "character varying", nullable: true)
        })
        let big = try router(schema: schema)
        let result = try call(.getSchema, ["connection_id": connectionID, "detail": "full"], router: big)
        #expect(result.isError == true)
        #expect(text(result) == "Result too large; narrow the request")
        #expect(result.structuredContent == nil)

        // The same graph is fine at overview detail, so the ceiling is what rejected the full one.
        let overview = try call(.getSchema, ["connection_id": connectionID], router: big)
        #expect(overview.isError != true)
        #expect(object(overview)["omitted_count"]?.intValue == 0)
    }

    // MARK: Paging and changes

    @Test func getSchemaPagesFromAnOffset() throws {
        let first = try call(.getSchema, ["connection_id": connectionID])
        #expect(object(first)["total"]?.intValue == 2)
        #expect(object(first)["next_offset"] == .null)
        #expect(object(first)["stale"] == .bool(false))
        #expect(object(first)["checked_at"]?.stringValue != nil)

        let last = try call(.getSchema, ["connection_id": connectionID, "offset": .int(1)])
        expectJSONText(last)
        #expect(object(last)["objects"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } == ["orders"])
        #expect(object(last)["total"]?.intValue == 2)
        #expect(object(last)["next_offset"] == .null)
        #expect(text(last).contains(#""next_offset":null"#))

        let past = try call(.getSchema, ["connection_id": connectionID, "offset": .int(5)])
        #expect(object(past)["objects"]?.arrayValue == [])
        #expect(object(past)["next_offset"] == .null)
    }

    /// A definition of about 600 KB fills a full page on its own; the next
    /// object comes on the page `next_offset` points to.
    @Test func aFullPageStopsBeforeHalfAMebibyte() throws {
        var schema = StoredSchema()
        try schema.table("a_wide", columns: (0 ..< 6_500).map {
            StoredSchema.column(String(format: "column_with_a_long_name_%05d", $0), "varchar(255)", nullable: true)
        })
        try schema.table("b_narrow", columns: [StoredSchema.column("id", "int", nullable: false, primaryKey: true)])
        let router = try router(schema: schema)

        let first = try call(.getSchema, ["connection_id": connectionID, "detail": "full"], router: router)
        #expect(first.isError != true)
        #expect(text(first).utf8.count > 600_000)
        #expect(object(first)["objects"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } == ["a_wide"])
        #expect(object(first)["next_offset"]?.intValue == 1)
        #expect(object(first)["total"]?.intValue == 2)

        let next = try call(
            .getSchema, ["connection_id": connectionID, "detail": "full", "offset": .int(1)], router: router
        )
        #expect(object(next)["objects"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } == ["b_narrow"])
        #expect(object(next)["next_offset"] == .null)

        let overview = try call(.getSchema, ["connection_id": connectionID], router: router)
        #expect(object(overview)["objects"]?.arrayValue?.count == 2)
    }

    @Test func detailPendingMarksObjectsWhoseColumnsWereNotRead() throws {
        var schema = try shopSchema()
        schema.view("recent_orders")
        let result = try call(.getSchema, ["connection_id": connectionID, "detail": "full"], router: router(schema: schema))
        let pending = try #require(object(result)["objects"]?.arrayValue).compactMap(\.objectValue).map {
            ($0["name"]?.stringValue ?? "", $0["detail_pending"])
        }
        #expect(pending.map(\.0) == ["customers", "orders", "recent_orders"])
        #expect(pending.map(\.1) == [.bool(false), .bool(false), .bool(true)])
    }

    @Test func schemaChangesReturnTheFeedAndWhereToContinue() throws {
        let first = try call(.getSchemaChanges, ["connection_id": connectionID, "limit": .int(2)])
        expectJSONText(first)
        #expect(first.isError != true)
        let changes = try #require(object(first)["changes"]?.arrayValue).compactMap(\.objectValue)
        #expect(changes.map { $0["kind"]?.stringValue } == ["added", "added"])
        #expect(changes.map { $0["name"]?.stringValue } == ["customers", "orders"])
        #expect(changes.map { $0["object_kind"]?.stringValue } == ["table", "table"])
        #expect(changes.first?["at"]?.stringValue == "2023-11-14T22:13:20Z")
        let next = try #require(object(first)["next_since"]?.stringValue)
        #expect(object(first)["stale"] == .bool(false))

        let rest = try call(.getSchemaChanges, ["connection_id": connectionID, "since": .string(next)])
        expectJSONText(rest)
        let relation = try #require(object(rest)["changes"]?.arrayValue?.first?.objectValue)
        #expect(relation["kind"]?.stringValue == "relation_added")
        #expect(relation["relation"]?.stringValue == "orders.customer_id -> customers.id")
        #expect(object(rest)["next_since"] == .null)
        #expect(text(rest).contains(#""next_since":null"#))
    }

    /// `since` is limited to 64 characters, so `next_since` must fit in them
    /// whatever the names of the entry it resumes at: PostgreSQL keeps up to
    /// 63 bytes of an identifier by default
    /// (https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS).
    /// Paging one entry at a time passes every cursor back through the
    /// tool's own argument check.
    @Test func everyNextSinceFitsTheSinceArgument() throws {
        var schema = StoredSchema()
        let names = ["a", "b", "c"].map { String(repeating: $0, count: 63) }
        for name in names { try schema.table(name, columns: []) }
        schema.reference(names[1], String(repeating: "x", count: 63), names[0], String(repeating: "y", count: 63))
        let router = try router(schema: schema)

        var arguments: [String: Value] = ["connection_id": connectionID, "limit": .int(1)]
        var kinds: [String] = []
        while true {
            let page = try call(.getSchemaChanges, arguments, router: router)
            #expect(page.isError != true)
            kinds += try #require(object(page)["changes"]?.arrayValue).compactMap { $0.objectValue?["kind"]?.stringValue }
            guard let next = object(page)["next_since"]?.stringValue else { break }
            #expect(next.count <= 64, "\(next.count) characters")
            arguments["since"] = .string(next)
        }
        #expect(kinds == ["added", "added", "added", "relation_added"])
    }

    /// A changed table carries its diff, which the output schema describes.
    @Test func aChangedTableCarriesItsDiffInTheSchemaChangesOutput() throws {
        let store = try BerryStore(path: ":memory:")
        try store.save(shop)
        let later = Self.harvestTime.addingTimeInterval(120)
        try shopSchema().write(to: store, profileID: shop.id, at: Self.harvestTime, checkedAt: Self.harvestTime)
        var changed = StoredSchema()
        try changed.table("orders", columns: [
            StoredSchema.column("id", "bigint", nullable: false, primaryKey: true),
            StoredSchema.column("createdAt", "timestamp", nullable: true),
            StoredSchema.column("note", "text", nullable: true),
        ])
        _ = try store.applySchemaDetails(profileID: shop.id, details: changed.definitions, now: later, changeID: nil)
        try store.updateSchemaGraphState(profileID: shop.id) { $0.lastCheckedAt = later }

        let result = try call(
            .getSchemaChanges, ["connection_id": connectionID], router: MCPToolRouter(metadata: MCPMetadataService(store: store))
        )
        expectJSONText(result)
        let entry = try #require(object(result)["changes"]?.arrayValue?.last?.objectValue)
        #expect(entry["kind"]?.stringValue == "changed")
        let diff = try #require(entry["diff"]?.objectValue)
        #expect(diff["columns_added"]?.arrayValue == [.string("note")])
        let typeChange = try #require(diff["columns_changed"]?.arrayValue?.first?.objectValue)
        #expect(typeChange["name"]?.stringValue == "id")
        #expect(typeChange["to"]?.objectValue?["type"]?.stringValue == "bigint")

        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools(for: selected()).map { ($0.name, $0) })
        let schema = try #require(tools["berrydb_get_schema_changes"]?.outputSchema)
        let structured = try #require(result.structuredContent)
        #expect(violation(structured, against: schema) == nil, "\(violation(structured, against: schema) ?? "")")
    }

    @Test func aSinceCursorThatDoesNotParseIsAToolErrorNotEchoed() throws {
        let result = try call(.getSchemaChanges, ["connection_id": connectionID, "since": "last tuesday"])
        #expect(result.isError == true)
        #expect(text(result) == "Invalid since cursor")
        #expect(!String(describing: result).contains("tuesday"))
    }

    @Test func aConnectionNeverCheckedHasAnEmptyStaleFeed() throws {
        let result = try call(.getSchemaChanges, ["connection_id": connectionID], router: router(harvested: false))
        #expect(result.isError != true)
        #expect(object(result)["changes"]?.arrayValue == [])
        #expect(object(result)["next_since"] == .null)
        #expect(object(result)["checked_at"] == .null)
        #expect(object(result)["stale"] == .bool(true))
    }

    // MARK: Status

    @Test func statusReportsSelectedProject() throws {
        let result = try call(.status, [:])
        let status = object(result)
        #expect(result.isError != true)
        #expect(Set(status.keys) == [
            "state", "reason", "project", "selected_by", "workspace", "live_reads", "integrity", "connections",
        ])
        #expect(status["state"]?.stringValue == "selected")
        #expect(status["reason"]?.isNull == true)
        #expect(status["selected_by"]?.stringValue == "working_directory")
        #expect(status["workspace"]?.stringValue == "/work/shop")
        #expect(status["live_reads"]?.stringValue == "not_available")
        #expect(status["integrity"]?.stringValue == "verified")
        let project = try #require(status["project"]?.objectValue)
        #expect(Set(project.keys) == ["id", "name"])
        #expect(project["name"]?.stringValue == "Shop project")
        #expect(project["id"]?.stringValue == Self.projectID.uuidString)
    }

    /// The status reports, for each connection of the selected project, how
    /// fresh its stored schema is and the large-schema hint, and for a stale
    /// one why: the code of the failure that stopped its last pass, one of a
    /// fixed set, never text a server wrote.
    @Test func statusReportsEachConnectionsFreshnessAndWhyItIsStale() throws {
        let store = try BerryStore(path: ":memory:")
        try store.save(shop)
        try store.save(outsider)
        try shopSchema().write(to: store, profileID: shop.id, at: Self.harvestTime, checkedAt: Date())
        let router = MCPToolRouter(metadata: MCPMetadataService(store: store))
        func connections() throws -> [[String: Value]] {
            try #require(object(try call(.status, nil, router: router))["connections"]?.arrayValue).compactMap(\.objectValue)
        }

        let fresh = try #require(try connections().first)
        #expect(try connections().count == 1)
        #expect(Set(fresh.keys) == ["id", "name", "checked_at", "stale", "stale_reason", "hint"])
        #expect(fresh["id"]?.stringValue == shop.id.uuidString && fresh["name"]?.stringValue == "Shop")
        #expect(fresh["stale"]?.boolValue == false && fresh["stale_reason"]?.isNull == true && fresh["hint"]?.isNull == true)

        try store.updateSchemaGraphState(profileID: shop.id) {
            $0.lastCheckedAt = Self.harvestTime
            $0.lastErrorCode = "timeout"
            $0.hint = "selectSchemas"
        }
        let stale = try #require(try connections().first)
        #expect(stale["stale"]?.boolValue == true && stale["stale_reason"]?.stringValue == "timeout")
        #expect(stale["hint"]?.stringValue == "selectSchemas")
        let listed = try #require(object(try call(.listConnections, nil, router: router))["connections"]?.arrayValue?.first?.objectValue)
        #expect(listed["stale_reason"]?.stringValue == "timeout")

        // Only a code the harvest records is passed on.
        try store.updateSchemaGraphState(profileID: shop.id) { $0.lastErrorCode = "FATAL: password authentication failed" }
        #expect(try connections().first?["stale_reason"]?.isNull == true)
        #expect(try connections().first?["stale"]?.boolValue == true)
    }

    @Test func statusReportsLiveReads() throws {
        func liveReads(_ context: MCPProjectContext, router: MCPToolRouter? = nil) throws -> String? {
            object(try call(.status, nil, context: context, router: router))["live_reads"]?.stringValue
        }
        #expect(try liveReads(selected(liveRead: true)) == "available")
        #expect(try liveReads(selected()) == "not_available")
        #expect(try liveReads(.unconfigured(.noMatchingProject, workspace: nil)) == "not_available")

        // A store that cannot be read offers no live read, and the status still answers.
        let reader = GraphReader(store: try BerryStore(path: ":memory:"))
        let unreadable = MCPToolRouter(metadata: MCPMetadataService(
            profiles: { throw PathLeakingError() }, reader: reader, graph: BerryGraphQueryService(reader: reader)
        ))
        let status = try call(.status, nil, context: selected(liveRead: true), router: unreadable)
        #expect(status.isError != true)
        #expect(object(status)["live_reads"]?.stringValue == "not_available")
    }

    @Test func statusReportsUnconfiguredReasonAndWorkspace() throws {
        let result = try call(.status, nil, context: .unconfigured(.ambiguousProjects, workspace: "/work/app"))
        let status = object(result)
        #expect(status["state"]?.stringValue == "unconfigured")
        #expect(status["reason"]?.stringValue == "ambiguous_projects")
        #expect(status["project"]?.isNull == true)
        #expect(status["selected_by"]?.isNull == true)
        #expect(status["workspace"]?.stringValue == "/work/app")
        #expect(status["live_reads"]?.stringValue == "not_available")
    }

    @Test func statusReportsNoWorkspaceForAnExplicitProject() throws {
        let status = object(try call(.status, nil, context: .selected(project(), source: .explicit, workspace: nil)))
        #expect(status["selected_by"]?.stringValue == "explicit")
        #expect(status["workspace"]?.isNull == true)
    }

    @Test func statusReportsAnExplicitProjectNoProjectMatches() throws {
        let missing = try call(.status, nil, context: .unconfigured(.explicitProjectNotFound, workspace: nil))
        expectJSONText(missing)
        let status = object(missing)
        #expect(status["state"]?.stringValue == "unconfigured")
        #expect(status["reason"]?.stringValue == "explicit_project_not_found")
        #expect(status["project"]?.isNull == true)
        #expect(status["selected_by"]?.isNull == true)
        #expect(status["workspace"]?.isNull == true)
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
        #expect(!rendered.contains(outsider.id.uuidString))
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

    /// A connection whose graph was never harvested carries the key with a
    /// null value, so every connection has the same fields.
    @Test func unharvestedGraphIsReportedAsNull() throws {
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools(for: selected()).map { ($0.name, $0) })
        let result = try call(.listConnections, [:], router: router(harvested: false))
        expectJSONText(result)
        let first = try #require(object(result)["connections"]?.arrayValue?.first?.objectValue)
        #expect(first["graph_harvested_at"] == .null)
        let schema = try #require(tools["berrydb_list_connections"]?.outputSchema)
        let structured = try #require(result.structuredContent)
        #expect(violation(structured, against: schema) == nil)
        let required = schema.objectValue?["properties"]?.objectValue?["connections"]?.objectValue?["items"]?
            .objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(required.contains("graph_harvested_at"))
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

    /// A host that forwards the text block shows the model these bytes, so
    /// a path reads as written rather than with `\/` escapes.
    @Test func textContentLeavesSlashesUnescaped() throws {
        let result = try call(.status, [:])
        expectJSONText(result)
        #expect(text(result).contains(#""workspace":"/work/shop""#))
        #expect(!text(result).contains(#"\/"#))
    }

    @Test func textContentIsTheCompactJSONOfTheStructuredResult() throws {
        var schema = try shopSchema()
        try schema.table("evil\nname\r\nwith breaks")
        let result = try call(
            .graphQuery, ["connection_id": connectionID, "operation": "neighbors", "node": "evil\nname\r\nwith breaks"],
            router: router(schema: schema)
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

    /// The SDK's `Value` decoder reads any `data:…,…` string as binary data
    /// and writes it back as base64, so a name of that shape would differ
    /// between the structured result and the text block.
    @Test func dataURLShapedNamesStayStrings() throws {
        var schema = try shopSchema()
        try schema.table("data:,x", columns: [StoredSchema.column("data:text/plain;base64,eA==", "text", nullable: true)])

        let result = try call(
            .getSchema, ["connection_id": connectionID, "object_names": ["data:,x"], "detail": "full"],
            router: router(schema: schema)
        )

        #expect(result.isError != true)
        let table = try #require(object(result)["objects"]?.arrayValue?.first?.objectValue)
        #expect(table["name"] == .string("data:,x"))
        #expect(table["columns"]?.arrayValue?.first?.objectValue?["name"] == .string("data:text/plain;base64,eA=="))
        #expect(text(result).contains(#""name":"data:,x""#))
        expectJSONText(result)
    }

    @Test func everyJSONKindMapsToItsValueCase() throws {
        let json = #"{"a":[0,1,"x"],"d":2.5,"e":1.0,"f":false,"i":-7,"n":null,"o":{},"s":"data:,x","t":true}"#
        let value = try MCPStructuredEncoding.value(from: Data(json.utf8))
        #expect(value == .object([
            "a": .array([.int(0), .int(1), .string("x")]),
            "d": .double(2.5),
            "e": .double(1.0),
            "f": .bool(false),
            "i": .int(-7),
            "n": .null,
            "o": .object([:]),
            "s": .string("data:,x"),
            "t": .bool(true),
        ]))
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
        let tools = Dictionary(uniqueKeysWithValues: MCPToolCatalog.tools(
            for: selected(liveRead: true), liveReadConnectionIDs: [shop.id]
        ).map { ($0.name, $0) })
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
            (.getSchemaChanges, ["connection_id": id]),
            (.getSchemaChanges, ["connection_id": id, "limit": .int(1)]),
        ]
        for (name, arguments) in calls {
            let result = try call(name, arguments)
            #expect(result.isError != true)
            expectJSONText(result)
            let structured = try #require(result.structuredContent)
            let schema = try #require(tools[name.rawValue]?.outputSchema)
            #expect(violation(structured, against: schema) == nil, "\(name.rawValue): \(violation(structured, against: schema) ?? "")")
        }
        // A live read answers through the same encoding; a NULL cell is null.
        let read = MCPLiveReadResult(
            columns: ["id", "createdAt"], rows: [["1", "a/b"], ["2", nil]], rowCount: 2, truncated: true,
            hasMoreRows: true, truncatedCells: 0, byteLimitReached: false, elapsedMs: 3, redactedColumns: ["createdAt"]
        )
        let live = try MCPToolRouter.respond(read)
        expectJSONText(live)
        let liveSchema = try #require(tools["berrydb_execute_read_query"]?.outputSchema)
        let liveStructured = try #require(live.structuredContent)
        #expect(violation(liveStructured, against: liveSchema) == nil, "\(violation(liveStructured, against: liveSchema) ?? "")")
        #expect(object(live)["rows"] == [["1", "a/b"], ["2", .null]])
        #expect(object(live)["has_more_rows"] == .bool(true))

        let contexts: [MCPProjectContext] = [
            selected(), selected(integrity: false), selected(liveRead: true),
            .selected(project(), source: .roots, workspace: "/work/repo"),
            .selected(project(), source: .explicit, workspace: nil),
            .unconfigured(.integrityUnavailable, workspace: nil),
            .unconfigured(.noMatchingProject, workspace: "/work"),
            .unconfigured(.explicitProjectNotFound, workspace: nil),
            .unconfigured(.ambiguousProjects, workspace: nil),
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
        #expect(Set(listingValue.objectValue?.keys.map { $0 } ?? []) == [
            "objects", "omitted_count", "harvested_at", "total", "next_offset", "checked_at", "stale",
        ])
        let neighbors = BerryGraphQueryService.Neighbors(node: "n", dependsOn: [], dependedOnBy: [])
        #expect(Set(try #require(MCPStructuredEncoding.value(neighbors).objectValue).keys) == ["node", "depends_on", "depended_on_by"])
    }

    // MARK: Resources

    @Test func unconfiguredContextHasNoResources() throws {
        let context = MCPProjectContext.unconfigured(.noMatchingProject, workspace: nil)
        let metadata = try service()
        #expect(try MCPResourceCatalog.resources(for: context, metadata: metadata).isEmpty)
        #expect(throws: MCPError.invalidParams("Unknown resource")) {
            try MCPResourceCatalog.read(uri: "berrydb://project", context: context, metadata: metadata)
        }
    }

    @Test func selectedContextListsProjectAndGraphResources() throws {
        let service = try service()
        let resources = try MCPResourceCatalog.resources(for: selected(), metadata: service)
        #expect(resources.map(\.uri) == ["berrydb://project", "berrydb://connections/\(shop.id.uuidString)/graph"])
        #expect(resources.allSatisfy { $0.mimeType == "application/json" })

        let project = try MCPResourceCatalog.read(uri: "berrydb://project", context: selected(), metadata: service)
        let projectJSON = try jsonObject(project)
        #expect((projectJSON["project"] as? [String: Any])?["name"] as? String == "Shop project")
        #expect((projectJSON["connections"] as? [[String: Any]])?.count == 1)
        #expect(project.first?.uri == "berrydb://project")

        let graphURI = "berrydb://connections/\(shop.id.uuidString)/graph"
        let graph = try MCPResourceCatalog.read(uri: graphURI, context: selected(), metadata: service)
        let graphJSON = try jsonObject(graph)
        #expect(graphJSON["harvested_at"] as? String == "2023-11-14T22:13:20Z")
        #expect((graphJSON["tables"] as? [Any])?.count == 2)
        #expect(graph.first?.uri == graphURI)
        #expect(graph.first?.mimeType == "application/json")
    }

    /// A schema never confirmed against the database has its `checked_at`
    /// written as null, as every tool writes it, rather than left out.
    @Test func theGraphResourceWritesANullCheckWhenThereIsNone() throws {
        let store = try BerryStore(path: ":memory:")
        try store.save(shop)
        try shopSchema().write(to: store, profileID: shop.id, at: Self.harvestTime, checkedAt: Date())
        try store.updateSchemaGraphState(profileID: shop.id) { $0.lastCheckedAt = nil }
        let graph = try MCPResourceCatalog.read(
            uri: "berrydb://connections/\(shop.id.uuidString)/graph", context: selected(),
            metadata: MCPMetadataService(store: store)
        )
        let json = try jsonObject(graph)
        #expect(json.keys.contains("checked_at") && json["checked_at"] is NSNull)
        #expect(json["stale"] as? Bool == true)
    }

    @Test func unharvestedConnectionHasNoGraphResource() throws {
        let unharvested = try service(harvested: false)
        let resources = try MCPResourceCatalog.resources(for: selected(), metadata: unharvested)
        #expect(resources.map(\.uri) == ["berrydb://project"])

        let empty = unharvested
        #expect(throws: MCPError.invalidParams(MCPMetadataError.noSnapshot.description)) {
            try MCPResourceCatalog.read(
                uri: "berrydb://connections/\(shop.id.uuidString)/graph", context: selected(), metadata: empty
            )
        }
    }

    /// The latest harvest found no tables or views: the connection reports
    /// no harvest time and no graph resource, as the graph tools report no
    /// graph.
    @Test func aHarvestThatFoundNothingListsNoGraph() throws {
        let store = try BerryStore(path: ":memory:")
        try store.save(shop)
        let emptied = Self.harvestTime.addingTimeInterval(60)
        try shopSchema().write(to: store, profileID: shop.id, at: Self.harvestTime, checkedAt: Self.harvestTime)
        try StoredSchema().write(to: store, profileID: shop.id, at: emptied, checkedAt: emptied)
        let metadata = MCPMetadataService(store: store)
        let router = MCPToolRouter(metadata: metadata)

        let connections = try call(.listConnections, [:], router: router)
        let first = try #require(object(connections)["connections"]?.arrayValue?.first?.objectValue)
        #expect(first["graph_harvested_at"] == .null)
        #expect(try MCPResourceCatalog.resources(for: selected(), metadata: metadata).map(\.uri) == ["berrydb://project"])
        let stats = try call(.getGraphStats, ["connection_id": connectionID], router: router)
        #expect(text(stats) == MCPMetadataError.noSnapshot.description)
    }

    @Test func resourceReadRejectsUnassignedConnectionLikeUnknownURI() throws {
        let unknownMessage = "Unknown resource"
        let metadata = try service()
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
                _ = try MCPResourceCatalog.read(uri: uri, context: selected(), metadata: metadata)
                Issue.record("Expected an error for \(uri)")
            } catch let MCPError.invalidParams(message) {
                #expect(message == unknownMessage)
            }
        }
    }

    @Test func resourceStoreFailuresAreGeneric() throws {
        let failing = try service(broken: true)
        let uri = "berrydb://connections/\(shop.id.uuidString)/graph"
        do {
            _ = try MCPResourceCatalog.read(uri: uri, context: selected(), metadata: failing)
            Issue.record("Expected an error")
        } catch let error as MCPError {
            #expect(error == MCPError.internalError("BerryDB could not read its store for this request."))
        }
    }
}
