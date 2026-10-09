import BerryGraph
import BerryMCP
import BerryStore
import Foundation
import MCP

/// The tools the server offers. Raw values use `[a-z0-9_]` only: a host hands
/// the name to its model API, and the Claude API requires
/// `^[a-zA-Z0-9_-]{1,128}$`, rejecting `.`
/// (https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools).
public enum MCPToolName: String, CaseIterable, Sendable {
    case status = "berrydb_status"
    case listConnections = "berrydb_list_connections"
    case getSchema = "berrydb_get_schema"
    case searchSchema = "berrydb_search_schema"
    case graphQuery = "berrydb_graph_query"
    case getGraphStats = "berrydb_get_graph_stats"
}

/// Tool definitions, independent of any transport.
///
/// Invariant: every tool declares a closed input schema (`additionalProperties`
/// false) and an output schema, and only `berrydb_status` is listed when no
/// project is selected, so an unconfigured session exposes no metadata tool.
public enum MCPToolCatalog {
    /// Largest serialized structured result a tool returns, in bytes.
    public static let maximumResultBytes = 1_048_576

    /// Tools listed for a context: only `berrydb_status` unless a project is selected.
    public static func tools(for context: MCPProjectContext) -> [Tool] {
        guard case .selected = context else { return [definition(.status)] }
        return MCPToolName.allCases.map(definition)
    }

    private static func definition(_ tool: MCPToolName) -> Tool {
        let input: Value
        let output: Value
        let description: String
        switch tool {
        case .status:
            description = "Reports which BerryDB project this session serves and why none is selected. Call it first."
            input = object([:])
            output = statusOutput
        case .listConnections:
            description = "Lists the connections of the selected project that expose schema and graph metadata."
            input = object([:])
            output = object(["connections": array(of: connectionItem)], required: ["connections"])
        case .getSchema:
            description = "Lists tables and views of one connection from its last harvested schema, at most 200 per call. Overview returns names; full adds columns, indexes and foreign keys."
            input = object(
                [
                    "connection_id": connectionID,
                    "object_names": ["type": "array", "items": ["type": "string"], "maxItems": 50],
                    "detail": ["type": "string", "enum": ["overview", "full"], "default": "overview"],
                ],
                required: ["connection_id"]
            )
            output = schemaOutput
        case .searchSchema:
            description = "Case-insensitive substring search over table, view, column and index names of one connection."
            input = object(
                [
                    "connection_id": connectionID,
                    "query": ["type": "string", "minLength": 1, "maxLength": 200],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
                ],
                required: ["connection_id", "query"]
            )
            output = object(["matches": array(of: matchItem)], required: ["matches"])
        case .graphQuery:
            description = "Runs a dependency-graph query on one connection: neighbors, path, blast_radius, circular_dependencies or top_centrality. neighbors and blast_radius need node; path needs from and to."
            input = object(
                [
                    "connection_id": connectionID,
                    "operation": operationSchema,
                    "node": ["type": "string"],
                    "from": ["type": "string"],
                    "to": ["type": "string"],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
                ],
                required: ["connection_id", "operation"]
            )
            output = object(
                ["operation": operationSchema, "result": ["type": ["object", "array"]]],
                required: ["operation", "result"]
            )
        case .getGraphStats:
            description = "Harvested statistics (rows, size, scans) for every table, or for one table and its indexes when object is given."
            input = object(["connection_id": connectionID, "object": ["type": "string"]], required: ["connection_id"])
            output = statsOutput
        }
        return Tool(
            name: tool.rawValue,
            description: description,
            inputSchema: input,
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
            outputSchema: output
        )
    }

    // MARK: Schemas

    private static let connectionID: Value = ["type": "string", "format": "uuid"]
    private static let text: Value = ["type": "string"]
    private static let operationSchema: Value = [
        "type": "string",
        "enum": ["neighbors", "path", "blast_radius", "circular_dependencies", "top_centrality"],
    ]

    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object", "properties": .object(properties), "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    private static func array(of item: Value) -> Value {
        ["type": "array", "items": item]
    }

    private static let connectionItem: Value = object(
        [
            "id": connectionID, "name": text, "driver": text,
            "environment": ["type": "string", "enum": ["production", "unlabeled"]],
            "capabilities": array(of: text),
            "graph_harvested_at": ["type": ["string", "null"], "format": "date-time"],
        ],
        required: ["id", "name", "driver", "environment", "capabilities", "graph_harvested_at"]
    )

    private static let matchItem: Value = object(
        ["name": text, "kind": text, "database": text, "table": text], required: ["name", "kind"]
    )

    private static let statusOutput: Value = object(
        [
            "state": ["type": "string", "enum": ["selected", "unconfigured"]],
            "reason": ["type": ["string", "null"]],
            "project": ["type": ["object", "null"], "properties": ["id": connectionID, "name": text]],
            "selected_by": ["type": ["string", "null"]],
            "workspace": ["type": ["string", "null"]],
            "live_reads": ["type": "string", "enum": ["not_available"]],
            "integrity": ["type": ["string", "null"], "enum": ["verified", "unavailable", .null]],
        ],
        required: ["state", "reason", "project", "selected_by", "workspace", "live_reads", "integrity"]
    )

    private static let schemaOutput: Value = {
        let column = object(
            ["name": text, "type": text, "nullable": ["type": "boolean"], "primary_key": ["type": "boolean"]],
            required: ["name", "type", "nullable", "primary_key"]
        )
        let index = object(
            ["name": text, "columns": array(of: text), "unique": ["type": "boolean"]],
            required: ["name", "columns", "unique"]
        )
        let foreignKey = object(
            ["column": text, "referenced_database": text, "referenced_table": text, "referenced_column": text],
            required: ["column", "referenced_table", "referenced_column"]
        )
        let item = object(
            [
                "name": text, "database": text, "kind": ["type": "string", "enum": ["table", "view"]],
                "columns": array(of: column), "indexes": array(of: index), "foreign_keys": array(of: foreignKey),
            ],
            required: ["name", "kind", "columns", "indexes", "foreign_keys"]
        )
        return object(
            [
                "objects": array(of: item), "omitted_count": ["type": "integer"],
                "harvested_at": ["type": "string", "format": "date-time"],
            ],
            required: ["objects", "omitted_count"]
        )
    }()

    private static let statsOutput: Value = {
        let fields: Value = ["type": "object", "additionalProperties": ["type": "string"]]
        let node = object(["name": text, "fields": fields], required: ["name", "fields"])
        return object([
            "tables": array(of: node), "unused_indexes": array(of: text),
            "table": text, "fields": fields, "indexes": array(of: node),
        ])
    }()
}

/// Runs tool calls against the metadata service.
///
/// Invariants: unknown tools and malformed arguments are protocol errors
/// (`MCPError.invalidParams`); everything else is a tool result. Only
/// `MCPMetadataError` texts, which are written for the agent, are ever shown;
/// any other failure becomes a fixed text, because a store error can carry a
/// file path.
public struct MCPToolRouter: Sendable {
    static let noProjectText = "No BerryDB project is selected for this workspace. Call berrydb_status for details."
    static let tooLargeText = "Result too large; narrow the request"
    static let storeFailureText = "BerryDB could not read its store for this request."

    private let metadata: MCPMetadataService

    public init(metadata: MCPMetadataService) {
        self.metadata = metadata
    }

    /// Throws `MCPError.invalidParams` for unknown tools and malformed arguments;
    /// returns `isError: true` results for expected failures.
    public func call(_ name: String, arguments: [String: Value]?, context: MCPProjectContext) throws -> CallTool.Result {
        guard let tool = MCPToolName(rawValue: name) else { throw MCPError.invalidParams("Unknown tool") }
        if tool == .status {
            _ = try MCPToolArguments(arguments, allowing: MCPToolArguments.allowedKeys(for: tool))
            return status(context)
        }
        guard case let .selected(project, _, _) = context else { return Self.failure(Self.noProjectText) }
        let arguments = try MCPToolArguments(arguments, allowing: MCPToolArguments.allowedKeys(for: tool))
        do {
            return try run(tool, arguments, in: project, context: context)
        } catch let error as MCPError {
            throw error
        } catch let error as MCPMetadataError {
            return Self.failure(error.description)
        } catch {
            return Self.failure(Self.storeFailureText)
        }
    }

    private func run(
        _ tool: MCPToolName, _ arguments: MCPToolArguments, in project: MCPVerifiedProject, context: MCPProjectContext
    ) throws -> CallTool.Result {
        switch tool {
        case .status:
            return status(context)
        case .listConnections:
            let connections = try metadata.listConnections(in: project)
            return try respond(ConnectionList(connections: connections))
        case .getSchema:
            let listing = try metadata.schema(
                in: project, connectionID: try arguments.connectionID(),
                objectNames: try arguments.objectNames(), detail: try arguments.schemaDetail()
            )
            return try respond(listing)
        case .searchSchema:
            let matches = try metadata.searchSchema(
                in: project, connectionID: try arguments.connectionID(),
                query: try arguments.query(), limit: try arguments.searchLimit()
            )
            return try respond(MatchList(matches: matches))
        case .graphQuery:
            let result = try metadata.graphQuery(
                in: project, connectionID: try arguments.connectionID(), operation: try arguments.graphOperation()
            )
            return try respond(result)
        case .getGraphStats:
            let stats = try metadata.graphStats(
                in: project, connectionID: try arguments.connectionID(), object: try arguments.statisticsObject()
            )
            return try respond(stats)
        }
    }

    private func status(_ context: MCPProjectContext) -> CallTool.Result {
        var fields: [String: Value]
        switch context {
        case let .selected(verified, source, workspace):
            fields = [
                "state": "selected", "reason": .null,
                "project": ["id": .string(verified.project.id.uuidString), "name": .string(verified.project.name)],
                "selected_by": .string(source.rawValue), "workspace": workspace.map { .string($0) } ?? .null,
                "integrity": verified.projectTagValid ? "verified" : "unavailable",
            ]
        case let .unconfigured(reason, workspace):
            fields = [
                "state": "unconfigured", "reason": .string(reason.rawValue), "project": .null,
                "selected_by": .null, "workspace": workspace.map { .string($0) } ?? .null,
                "integrity": reason == .integrityUnavailable ? Value.string("unavailable") : Value.null,
            ]
        }
        fields["live_reads"] = "not_available"
        guard let result = try? respond(Value.object(fields)) else { return Self.failure(Self.storeFailureText) }
        return result
    }

    /// Returns the payload as `structuredContent` and its serialized JSON as
    /// the text content: the protocol asks a tool that returns structured
    /// content to also return the serialized JSON in a text block, because
    /// hosts that ignore `structuredContent` would otherwise get no data at
    /// all. `structuredContent` is built from that same JSON and encodes back
    /// to the text's bytes. The size ceiling applies to that one JSON.
    private func respond<T: Encodable>(_ payload: T) throws -> CallTool.Result {
        let data = try MCPStructuredEncoding.data(payload)
        guard data.count <= MCPToolCatalog.maximumResultBytes else { return Self.failure(Self.tooLargeText) }
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try MCPStructuredEncoding.value(from: data))
        )
    }

    /// An error result keeps a plain one-line text; collapsing whitespace
    /// stops a name inside a metadata error from splitting it.
    private static func failure(_ message: String) -> CallTool.Result {
        let line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return CallTool.Result(content: [.text(text: line, annotations: nil, _meta: nil)], isError: true)
    }

    private struct ConnectionList: Encodable {
        let connections: [MCPConnectionDescriptor]
    }

    private struct MatchList: Encodable {
        let matches: [MCPSchemaMatch]
    }
}

/// Encodes tool payloads as compact JSON with snake_case keys, sorted keys and
/// ISO-8601 dates. Slashes are left unescaped: a host can hand the text block
/// to the model verbatim, and `\/` in every path is noise there.
enum MCPStructuredEncoding {
    static func data<T: Encodable>(_ payload: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(payload)
    }

    static func value<T: Encodable>(_ payload: T) throws -> Value {
        try value(from: data(payload))
    }

    /// The `Value` of serialized JSON, mapping each JSON value to the
    /// matching case by hand and never producing `.data`. Decoding with
    /// `Value.init(from:)` instead would turn every string shaped like a data
    /// URL (`data:…,…`) into `.data`, which encodes back as
    /// `data:<mime>;base64,…`, so a column named `data:,x` would read
    /// differently in the structured result and the text block. That decoder
    /// also builds a new regular expression for each string it checks
    /// (`Value.init(from:)` and `Data.isDataURL` in swift-sdk 0.12.1).
    static func value(from data: Data) throws -> Value {
        try value(of: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func value(of object: Any) throws -> Value {
        switch object {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // JSONSerialization returns JSON booleans and numbers alike as
            // NSNumber (https://developer.apple.com/documentation/foundation/jsonserialization);
            // booleans are the CFBoolean singletons, and a number written
            // with a fraction or exponent is stored as a float type. Observed
            // on macOS 26.6 and pinned by `everyJSONKindMapsToItsValueCase`.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.intValue)
        case let array as [Any]:
            return .array(try array.map(value(of:)))
        case let members as [String: Any]:
            return .object(try members.mapValues(value(of:)))
        default:
            throw EncodingError.invalidValue(
                object, .init(codingPath: [], debugDescription: "Not a JSON value")
            )
        }
    }
}
