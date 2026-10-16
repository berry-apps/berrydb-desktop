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
    case getSchemaChanges = "berrydb_get_schema_changes"
    case executeReadQuery = "berrydb_execute_read_query"
}

/// Tool definitions, independent of any transport.
///
/// Invariant: every tool declares a closed input schema (`additionalProperties`
/// false) and an output schema, and only `berrydb_status` is listed when no
/// project is selected, so an unconfigured session exposes no metadata tool.
/// `berrydb_execute_read_query` is listed only while the selected project
/// has a connection it can run on.
public enum MCPToolCatalog {
    /// Largest serialized structured result a tool returns, in bytes.
    public static let maximumResultBytes = 1_048_576

    /// Tools listed for a context whose project has no live-read connection.
    public static func tools(for context: MCPProjectContext) -> [Tool] {
        tools(for: context, liveReadConnectionIDs: [])
    }

    /// Tools listed for a context: only `berrydb_status` unless a project is
    /// selected, and the live read tool only when `liveReadConnectionIDs`,
    /// the project's connections as `MCPMetadataService.liveReadConnectionIDs(in:)`
    /// reports them, is not empty.
    public static func tools(for context: MCPProjectContext, liveReadConnectionIDs: Set<UUID>) -> [Tool] {
        guard case .selected = context else { return [definition(.status)] }
        return MCPToolName.allCases
            .filter { $0 != .executeReadQuery || !liveReadConnectionIDs.isEmpty }
            .map(definition)
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
            description = "Lists tables and views of one connection from its last harvested schema, one page per call: at most 200, and fewer at full detail once a page reaches about 512 KB. Overview returns names; full adds columns, indexes and foreign keys. Pass next_offset as offset for the next page; detail_pending marks an object whose columns were not read yet."
            input = object(
                [
                    "connection_id": connectionID,
                    "object_names": ["type": "array", "items": ["type": "string"], "maxItems": 50],
                    "detail": ["type": "string", "enum": ["overview", "full"], "default": "overview"],
                    "offset": ["type": "integer", "minimum": 0, "default": 0],
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
            output = object(
                ["matches": array(of: matchItem), "checked_at": checkedAt, "stale": boolean],
                required: ["matches", "checked_at", "stale"]
            )
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
                [
                    "operation": operationSchema, "result": ["type": ["object", "array"]],
                    "checked_at": checkedAt, "stale": boolean,
                ],
                required: ["operation", "result", "checked_at", "stale"]
            )
        case .getGraphStats:
            description = "Harvested statistics (rows, size, scans) for every table, or for one table and its indexes when object is given."
            input = object(["connection_id": connectionID, "object": ["type": "string"]], required: ["connection_id"])
            output = statsOutput
        case .getSchemaChanges:
            description = "Lists the schema changes BerryDB recorded for one connection, oldest first: tables and views added, changed (with a column and index diff) or removed, and foreign keys added or removed. Pass next_since as since for the next page; since also takes an ISO 8601 time."
            input = object(
                [
                    "connection_id": connectionID,
                    "since": ["type": "string", "maxLength": 64],
                    "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
                ],
                required: ["connection_id"]
            )
            output = changesOutput
        case .executeReadQuery:
            description = "Runs one read-only SQL statement on a connection whose live reads the user turned on, and returns at most row_limit rows. Placeholders are $1, $2, … on PostgreSQL and ? on MySQL, MariaDB and SQLite; pass their values in parameters. The database refuses any write. Results go to this host and its model provider."
            input = object(
                [
                    "connection_id": connectionID,
                    "sql": ["type": "string", "minLength": 1, "maxLength": 65_536],
                    "parameters": [
                        "type": "array", "maxItems": 100, "items": ["type": ["string", "number", "boolean", "null"]],
                    ],
                    "row_limit": ["type": "integer", "minimum": 1, "maximum": 100],
                ],
                required: ["connection_id", "sql"]
            )
            output = liveReadOutput
        }
        // A live read leaves BerryDB's store for the user's database, an
        // open world in the terms of `Tool.Annotations` (swift-sdk 0.12.1),
        // and the same statement answers differently as that data changes.
        let live = tool == .executeReadQuery
        return Tool(
            name: tool.rawValue,
            description: description,
            inputSchema: input,
            annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: !live, openWorldHint: live),
            outputSchema: output
        )
    }

    // MARK: Schemas

    private static let connectionID: Value = ["type": "string", "format": "uuid"]
    private static let text: Value = ["type": "string"]
    private static let boolean: Value = ["type": "boolean"]
    private static let integer: Value = ["type": "integer"]
    /// When a pass last confirmed the stored schema; null when none has.
    private static let checkedAt: Value = ["type": ["string", "null"], "format": "date-time"]
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
            "checked_at": checkedAt, "stale": boolean, "stale_reason": staleReason,
            "detail_coverage": object(["detailed": integer, "total": integer], required: ["detailed", "total"]),
            "scope": ["type": ["array", "null"], "items": text],
            "hint": ["type": ["string", "null"]],
        ],
        required: [
            "id", "name", "driver", "environment", "capabilities", "graph_harvested_at",
            "checked_at", "stale", "stale_reason", "detail_coverage", "scope", "hint",
        ]
    )

    private static let staleReason: Value = [
        "type": ["string", "null"],
        "enum": ["connection_failed", "timeout", "cancelled", "store_write_failed", "introspection_failed", .null],
    ]

    private static let connectionFreshness: Value = object(
        [
            "id": connectionID, "name": text, "checked_at": checkedAt, "stale": boolean, "stale_reason": staleReason,
            "hint": ["type": ["string", "null"]],
        ],
        required: ["id", "name", "checked_at", "stale", "stale_reason", "hint"]
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
            "live_reads": ["type": "string", "enum": ["available", "not_available"]],
            "integrity": ["type": ["string", "null"], "enum": ["verified", "unavailable", .null]],
            "connections": ["type": ["array", "null"], "items": connectionFreshness],
        ],
        required: ["state", "reason", "project", "selected_by", "workspace", "live_reads", "integrity", "connections"]
    )

    /// Rows are arrays aligned with `columns`: as object keys, column names
    /// would be renamed by the snake_case key encoding and a repeated name
    /// would keep one value only.
    private static let liveReadOutput: Value = object(
        [
            "columns": array(of: text),
            "rows": array(of: array(of: ["type": ["string", "null"]])),
            "row_count": integer, "truncated": boolean, "has_more_rows": boolean, "truncated_cells": integer,
            "byte_limit_reached": boolean, "elapsed_ms": integer, "redacted_columns": array(of: text),
        ],
        required: [
            "columns", "rows", "row_count", "truncated", "has_more_rows", "truncated_cells", "byte_limit_reached",
            "elapsed_ms", "redacted_columns",
        ]
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
                "detail_pending": boolean,
            ],
            required: ["name", "kind", "columns", "indexes", "foreign_keys", "detail_pending"]
        )
        return object(
            [
                "objects": array(of: item), "omitted_count": integer,
                "harvested_at": ["type": "string", "format": "date-time"],
                "total": integer, "next_offset": ["type": ["integer", "null"]],
                "checked_at": checkedAt, "stale": boolean,
            ],
            required: ["objects", "omitted_count", "total", "next_offset", "checked_at", "stale"]
        )
    }()

    private static let changesOutput: Value = {
        let column = object(
            [
                "name": text, "type": text, "nullable": boolean, "default_value": text, "primary_key": boolean,
            ],
            required: ["name", "type", "nullable", "primary_key"]
        )
        let index = object(
            ["name": text, "unique": boolean, "columns": array(of: text)], required: ["name", "unique", "columns"]
        )
        let columnChange = object(["name": text, "from": column, "to": column], required: ["name", "from", "to"])
        let indexChange = object(["name": text, "from": index, "to": index], required: ["name", "from", "to"])
        let diff = object(
            [
                "columns_added": array(of: text), "columns_removed": array(of: text),
                "columns_changed": array(of: columnChange), "columns_reordered": boolean,
                "indexes_added": array(of: text), "indexes_removed": array(of: text),
                "indexes_changed": array(of: indexChange),
            ],
            required: [
                "columns_added", "columns_removed", "columns_changed", "columns_reordered",
                "indexes_added", "indexes_removed", "indexes_changed",
            ]
        )
        let change = object(
            [
                "at": ["type": "string", "format": "date-time"],
                "kind": ["type": "string", "enum": ["added", "changed", "removed", "relation_added", "relation_removed"]],
                "database": text, "name": text, "object_kind": ["type": "string", "enum": ["table", "view"]],
                "diff": diff, "relation": text,
            ],
            required: ["at", "kind", "name", "object_kind"]
        )
        return object(
            [
                "changes": array(of: change), "next_since": ["type": ["string", "null"]],
                "checked_at": checkedAt, "stale": boolean,
            ],
            required: ["changes", "next_since", "checked_at", "stale"]
        )
    }()

    private static let statsOutput: Value = {
        let fields: Value = ["type": "object", "additionalProperties": ["type": "string"]]
        let node = object(["name": text, "fields": fields], required: ["name", "fields"])
        return object(
            [
                "tables": array(of: node), "unused_indexes": array(of: text),
                "table": text, "fields": fields, "indexes": array(of: node),
                "checked_at": checkedAt, "stale": boolean,
            ],
            required: ["checked_at", "stale"]
        )
    }()
}

/// Runs tool calls against the metadata service.
///
/// Invariants: unknown tools and malformed arguments are protocol errors
/// (`MCPError.invalidParams`); everything else is a tool result. Only
/// `MCPMetadataError` texts, which are written for the agent, are ever shown;
/// any other failure becomes a fixed text, because a store error can carry a
/// file path. A live read is served by `MCPLiveReadTool`; the router answers
/// one only in a server built without live reads.
public struct MCPToolRouter: Sendable {
    static let noProjectText = "No BerryDB project is selected for this workspace. Call berrydb_status for details."
    static let tooLargeText = "Result too large; narrow the request"
    static let storeFailureText = "BerryDB could not read its store for this request."
    static let noLiveReadsText = "Live reads are not available in this helper."

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
            return try Self.respond(ConnectionList(connections: connections))
        case .getSchema:
            let listing = try metadata.schema(
                in: project, connectionID: try arguments.connectionID(),
                objectNames: try arguments.objectNames(), detail: try arguments.schemaDetail(),
                offset: try arguments.offset()
            )
            return try Self.respond(listing)
        case .searchSchema:
            let matches = try metadata.searchSchema(
                in: project, connectionID: try arguments.connectionID(),
                query: try arguments.query(), limit: try arguments.searchLimit()
            )
            return try Self.respond(MatchList(matches: matches.value, checkedAt: matches.checkedAt, stale: matches.stale))
        case .graphQuery:
            let result = try metadata.graphQuery(
                in: project, connectionID: try arguments.connectionID(), operation: try arguments.graphOperation()
            )
            return try Self.respond(Fresh(result))
        case .getGraphStats:
            let stats = try metadata.graphStats(
                in: project, connectionID: try arguments.connectionID(), object: try arguments.statisticsObject()
            )
            return try Self.respond(Fresh(stats))
        case .getSchemaChanges:
            let changes = try metadata.schemaChanges(
                in: project, connectionID: try arguments.connectionID(),
                since: try arguments.since(), limit: try arguments.changesLimit()
            )
            return try Self.respond(changes)
        case .executeReadQuery:
            return Self.failure(Self.noLiveReadsText)
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
                "connections": connectionFreshness(in: verified),
            ]
        case let .unconfigured(reason, workspace):
            fields = [
                "state": "unconfigured", "reason": .string(reason.rawValue), "project": .null,
                "selected_by": .null, "workspace": workspace.map { .string($0) } ?? .null,
                "integrity": reason == .integrityUnavailable ? Value.string("unavailable") : Value.null,
                "connections": .null,
            ]
        }
        fields["live_reads"] = liveReadsAvailable(context) ? "available" : "not_available"
        guard let result = try? Self.respond(Value.object(fields)) else { return Self.failure(Self.storeFailureText) }
        return result
    }

    /// Whether the selected project has a connection the live read tool runs
    /// on; false when the store cannot be read, so the status still answers.
    private func liveReadsAvailable(_ context: MCPProjectContext) -> Bool {
        guard case let .selected(project, _, _) = context,
              let ids = try? metadata.liveReadConnectionIDs(in: project)
        else { return false }
        return !ids.isEmpty
    }

    /// How current each connection's stored schema is, and why a stale one is,
    /// or null when the store cannot be read: the status must answer then
    /// too, since it is what an agent calls to learn what is wrong.
    private func connectionFreshness(in project: MCPVerifiedProject) -> Value {
        guard let connections = try? metadata.listConnections(in: project),
              let value = try? MCPStructuredEncoding.value(connections.map(ConnectionFreshness.init))
        else { return .null }
        return value
    }

    private struct ConnectionFreshness: Encodable {
        let id: UUID
        let name: String
        let checkedAt: Date?
        let stale: Bool
        let staleReason: String?
        let hint: String?

        init(_ connection: MCPConnectionDescriptor) {
            id = connection.id
            name = connection.name
            checkedAt = connection.checkedAt
            stale = connection.stale
            staleReason = connection.staleReason
            hint = connection.hint
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, checkedAt, stale, staleReason, hint
        }

        /// Writes every optional field as null when it is nil, as the
        /// connection listing does.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(checkedAt, forKey: .checkedAt)
            try container.encode(stale, forKey: .stale)
            try container.encode(staleReason, forKey: .staleReason)
            try container.encode(hint, forKey: .hint)
        }
    }

    /// Returns the payload as `structuredContent` and its serialized JSON as
    /// the text content: the protocol asks a tool that returns structured
    /// content to also return the serialized JSON in a text block, because
    /// hosts that ignore `structuredContent` would otherwise get no data at
    /// all. `structuredContent` is built from that same JSON and encodes back
    /// to the text's bytes. The size ceiling applies to that one JSON.
    static func respond<T: Encodable>(_ payload: T) throws -> CallTool.Result {
        let data = try MCPStructuredEncoding.data(payload)
        guard data.count <= MCPToolCatalog.maximumResultBytes else { return Self.failure(Self.tooLargeText) }
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: Optional.some(try MCPStructuredEncoding.value(from: data))
        )
    }

    /// An error result keeps a plain one-line text; collapsing whitespace
    /// stops a name inside a metadata error from splitting it.
    static func failure(_ message: String) -> CallTool.Result {
        let line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return CallTool.Result(content: [.text(text: line, annotations: nil, _meta: nil)], isError: true)
    }

    private struct ConnectionList: Encodable {
        let connections: [MCPConnectionDescriptor]
    }

    private struct MatchList: Encodable {
        let matches: [MCPSchemaMatch]
        let checkedAt: Date?
        let stale: Bool

        private enum CodingKeys: String, CodingKey {
            case matches, checkedAt, stale
        }

        /// `checkedAt` is written as null when nil, as in every answer.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(matches, forKey: .matches)
            try container.encode(checkedAt, forKey: .checkedAt)
            try container.encode(stale, forKey: .stale)
        }
    }

    /// A graph or statistics answer as its own JSON object plus `checkedAt`
    /// (null when nil) and `stale`. The answer writes its keys first; the
    /// keyed container asked for afterwards adds to that same object, which
    /// an `Encoder` permits as long as every container at that level is
    /// keyed (https://developer.apple.com/documentation/swift/encoder/container(keyedby:)).
    /// Both answer types encode as keyed objects.
    private struct Fresh<Answer: Encodable & Sendable>: Encodable {
        let answer: MCPAnswer<Answer>

        init(_ answer: MCPAnswer<Answer>) {
            self.answer = answer
        }

        private enum CodingKeys: String, CodingKey {
            case checkedAt, stale
        }

        func encode(to encoder: any Encoder) throws {
            try answer.value.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(answer.checkedAt, forKey: .checkedAt)
            try container.encode(answer.stale, forKey: .stale)
        }
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
