import BerryDriverKit
import BerryGraph
import BerryMCP
import Foundation
import MCP

/// Validated tool arguments, checked against each tool's input schema before
/// any service call.
///
/// Invariant: a value of this type only exists when every key is one the
/// tool's schema declares, so a misspelled or smuggled argument can never be
/// silently ignored. Every failure is `MCPError.invalidParams` with a message
/// that names the argument and never echoes its value.
struct MCPToolArguments {
    static let maximumObjectNames = 50
    static let maximumQueryLength = 200
    static let searchLimitRange = 1 ... 200
    static let defaultSearchLimit = 50
    static let graphLimitRange = 1 ... 50
    static let changesLimitRange = 1 ... 200
    static let defaultChangesLimit = 50
    static let maximumSinceLength = 64
    static let maximumSQLBytes = 65_536
    static let maximumParameters = 100
    static let rowLimitRange = 1 ... 100
    static let nameLengthRange = 3 ... 255
    static let maximumProjection = 50
    static let itemLimitRange = 1 ... 100
    /// A sealed cursor over an index query's last key, four keys at their
    /// maximum sizes with 255-character names plus the scope, runs to about
    /// 11,500 characters when the key text needs no JSON escaping; the bound
    /// sits above that so paging does not dead-end on a cursor the service
    /// issued. Keys made mostly of control characters, which JSON escapes
    /// to six characters each, can still exceed it.
    static let maximumCursorLength = 16_384

    private let values: [String: Value]

    /// Rejects the first key (in sorted order) that is not in `allowed`.
    init(_ arguments: [String: Value]?, allowing allowed: Set<String>) throws {
        let values = arguments ?? [:]
        if let unexpected = values.keys.filter({ !allowed.contains($0) }).min() {
            throw MCPError.invalidParams("Unexpected argument: \(unexpected)")
        }
        self.values = values
    }

    /// The argument keys each tool's input schema declares.
    static func allowedKeys(for tool: MCPToolName) -> Set<String> {
        switch tool {
        case .status, .listConnections: return []
        case .getSchema: return ["connection_id", "object_names", "detail", "offset"]
        case .searchSchema: return ["connection_id", "query", "limit"]
        case .graphQuery: return ["connection_id", "operation", "node", "from", "to", "limit"]
        case .getGraphStats: return ["connection_id", "object"]
        case .getSchemaChanges: return ["connection_id", "since", "limit"]
        case .executeReadQuery: return ["connection_id", "sql", "parameters", "row_limit"]
        case .dynamodbQuery:
            return ["connection_id", "table", "index_name", "partition_key", "sort_key", "projection", "limit", "cursor"]
        }
    }

    func connectionID() throws -> UUID {
        guard let text = try string("connection_id") else {
            throw MCPError.invalidParams("connection_id is required")
        }
        guard let id = UUID(uuidString: text) else {
            throw MCPError.invalidParams("connection_id must be a UUID")
        }
        return id
    }

    func schemaDetail() throws -> BerryGraphQueryService.SchemaDetail {
        guard let text = try string("detail") else { return .overview }
        guard let detail = BerryGraphQueryService.SchemaDetail(rawValue: text) else {
            throw MCPError.invalidParams("detail must be one of overview, full")
        }
        return detail
    }

    func objectNames() throws -> [String]? {
        guard let value = values["object_names"], !value.isNull else { return nil }
        guard let items = value.arrayValue else {
            throw MCPError.invalidParams("object_names must be an array of strings")
        }
        guard items.count <= Self.maximumObjectNames else {
            throw MCPError.invalidParams("object_names accepts at most \(Self.maximumObjectNames) names")
        }
        return try items.map { item in
            guard let name = item.stringValue else {
                throw MCPError.invalidParams("object_names must be an array of strings")
            }
            return name
        }
    }

    /// The trimmed query. The length limit applies to the text as sent and the
    /// query must hold at least one non-whitespace character.
    func query() throws -> String {
        guard let text = try string("query") else { throw MCPError.invalidParams("query is required") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= Self.maximumQueryLength, !trimmed.isEmpty else {
            throw MCPError.invalidParams("query must be 1 to \(Self.maximumQueryLength) characters")
        }
        return trimmed
    }

    func searchLimit() throws -> Int {
        try integer("limit", in: Self.searchLimitRange) ?? Self.defaultSearchLimit
    }

    /// Where a listing page starts; 0 when absent.
    func offset() throws -> Int {
        guard let offset = try integer("offset") else { return 0 }
        guard offset >= 0 else { throw MCPError.invalidParams("offset must be 0 or greater") }
        return offset
    }

    /// The change feed position to continue from, as the service accepts it.
    /// Only its length is checked here; text the service cannot read is a
    /// tool error, since a cursor that went stale is not a malformed call.
    func since() throws -> String? {
        guard let since = try string("since") else { return nil }
        guard since.count <= Self.maximumSinceLength else {
            throw MCPError.invalidParams("since must be at most \(Self.maximumSinceLength) characters")
        }
        return since
    }

    func changesLimit() throws -> Int {
        try integer("limit", in: Self.changesLimitRange) ?? Self.defaultChangesLimit
    }

    /// Every present key is type- and range-checked before the operation is
    /// considered, so a bad value is never ignored just because the chosen
    /// operation does not read it.
    func graphOperation() throws -> MCPGraphOperation {
        let operation = try string("operation")
        let node = try string("node")
        let from = try string("from")
        let to = try string("to")
        let limit = try integer("limit", in: Self.graphLimitRange)
        switch operation {
        case nil:
            throw MCPError.invalidParams("operation is required")
        case "neighbors":
            return .neighbors(node: try required(node, "node", for: "neighbors"))
        case "path":
            return .path(from: try required(from, "from", for: "path"), to: try required(to, "to", for: "path"))
        case "blast_radius":
            return .blastRadius(node: try required(node, "node", for: "blast_radius"))
        case "circular_dependencies":
            return .circularDependencies
        case "top_centrality":
            return .topCentrality(limit: limit ?? BerryGraphQueryService.defaultCentralityLimit)
        default:
            throw MCPError.invalidParams(
                "operation must be one of neighbors, path, blast_radius, circular_dependencies, top_centrality"
            )
        }
    }

    /// The statement as sent; the read policy, not this check, decides
    /// whether it is one read.
    func sql() throws -> String {
        guard let sql = try string("sql") else { throw MCPError.invalidParams("sql is required") }
        guard (1 ... Self.maximumSQLBytes).contains(sql.utf8.count) else {
            throw MCPError.invalidParams("sql must be 1 to \(Self.maximumSQLBytes) bytes")
        }
        return sql
    }

    /// The values bound to the statement's placeholders, in order; none when
    /// absent. A JSON number binds as an integer when the SDK decoded it as
    /// one, which it does for any integral value that fits in 64 bits, `2.0`
    /// and `1e3` included (Foundation's `JSONDecoder`, observed on macOS
    /// 26.6), and as a double otherwise.
    ///
    /// A string shaped like a data URL (`data:…,…`) reaches this point as
    /// `.data`: the SDK's `Value` decoder converts it and keeps only the
    /// decoded bytes (`Value.init(from:)` in swift-sdk 0.12.1), so the text
    /// the host sent cannot be rebuilt and binding a re-encoded one would
    /// compare against a different string. Such a value is refused.
    func parameters() throws -> [SQLParameter] {
        guard let value = values["parameters"], !value.isNull else { return [] }
        guard let items = value.arrayValue else { throw MCPError.invalidParams("parameters must be an array") }
        guard items.count <= Self.maximumParameters else {
            throw MCPError.invalidParams("parameters accepts at most \(Self.maximumParameters) values")
        }
        return try items.map { item in
            switch item {
            case .null: return .null
            case let .bool(flag): return .bool(flag)
            case let .int(number): return .int(Int64(number))
            case let .double(number): return .double(number)
            case let .string(text): return .text(text)
            case .data: throw MCPError.invalidParams("parameters cannot hold a data: URL string")
            case .array, .object:
                throw MCPError.invalidParams("parameters must hold only strings, numbers, booleans or null")
            }
        }
    }

    /// The rows the caller wants at most; nil leaves the profile's limit.
    func rowLimit() throws -> Int? {
        try integer("row_limit", in: Self.rowLimitRange)
    }

    func table() throws -> String {
        guard let table = try name("table") else { throw MCPError.invalidParams("table is required") }
        return table
    }

    func indexName() throws -> String? {
        try name("index_name")
    }

    /// Only the length is checked here; the service refuses a name outside
    /// DynamoDB's character set with its own explanation.
    private func name(_ key: String) throws -> String? {
        guard let name = try string(key) else { return nil }
        guard Self.nameLengthRange.contains(name.count) else {
            throw MCPError.invalidParams(
                "\(key) must be \(Self.nameLengthRange.lowerBound) to \(Self.nameLengthRange.upperBound) characters"
            )
        }
        return name
    }

    func partitionKeyInput() throws -> MCPKeyInput {
        guard let value = values["partition_key"], !value.isNull else {
            throw MCPError.invalidParams("partition_key is required")
        }
        return try Self.keyInput(value, "partition_key")
    }

    /// The sort key condition, nil when absent. Whether the operator takes
    /// `value2` is the service's check, since it explains the refusal.
    func sortKeyInput() throws -> MCPSortKeyInput? {
        guard let value = values["sort_key"], !value.isNull else { return nil }
        guard let members = value.objectValue else { throw MCPError.invalidParams("sort_key must be an object") }
        if let unexpected = members.keys.filter({ !["op", "value", "value2"].contains($0) }).min() {
            throw MCPError.invalidParams("Unexpected argument: sort_key.\(unexpected)")
        }
        let operators = MCPSortKeyOperator.allCases.map(\.rawValue).joined(separator: ", ")
        guard let opValue = members["op"], !opValue.isNull else { throw MCPError.invalidParams("sort_key.op is required") }
        guard let text = opValue.stringValue, let op = MCPSortKeyOperator(rawValue: text) else {
            throw MCPError.invalidParams("sort_key.op must be one of \(operators)")
        }
        guard let first = members["value"], !first.isNull else { throw MCPError.invalidParams("sort_key.value is required") }
        let second = try members["value2"].flatMap { $0.isNull ? nil : try Self.keyInput($0, "sort_key.value2") }
        return MCPSortKeyInput(op: op, value: try Self.keyInput(first, "sort_key.value"), value2: second)
    }

    /// A string, or a number that is a whole `Int64`. The SDK decodes an
    /// integral JSON number that fits 64 bits as `.int` and anything else as
    /// `.double` (`numbersBindAsTheSDKDecodesThem`), so a `.double` is
    /// accepted only when it converts exactly. A string shaped like a data
    /// URL arrives as `.data` without its original text (see `parameters()`),
    /// so it is refused rather than sent as a different key.
    private static func keyInput(_ value: Value, _ key: String) throws -> MCPKeyInput {
        switch value {
        case let .string(text): return .string(text)
        case let .int(number): return .integer(Int64(number))
        case let .double(number):
            if let whole = Int64(exactly: number) { return .integer(whole) }
        case .data: throw MCPError.invalidParams("\(key) cannot hold a data: URL string")
        default: break
        }
        throw MCPError.invalidParams("\(key) must be a string or an integer")
    }

    func projection() throws -> [String]? {
        guard let value = values["projection"], !value.isNull else { return nil }
        guard let items = value.arrayValue else { throw MCPError.invalidParams("projection must be an array of strings") }
        guard items.count <= Self.maximumProjection else {
            throw MCPError.invalidParams("projection accepts at most \(Self.maximumProjection) names")
        }
        return try items.map { item in
            guard let name = item.stringValue else { throw MCPError.invalidParams("projection must be an array of strings") }
            return name
        }
    }

    /// The items the caller wants at most; nil leaves the profile's limit.
    func itemLimit() throws -> Int? {
        try integer("limit", in: Self.itemLimitRange)
    }

    /// Only the length is checked here; a cursor the service cannot open is
    /// a tool error that says to start again.
    func cursor() throws -> String? {
        guard let cursor = try string("cursor") else { return nil }
        guard cursor.count <= Self.maximumCursorLength else {
            throw MCPError.invalidParams("cursor must be at most \(Self.maximumCursorLength) characters")
        }
        return cursor
    }

    /// The optional statistics target; a blank value means every table.
    func statisticsObject() throws -> String? {
        guard let text = try string("object") else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func required(_ value: String?, _ key: String, for operation: String) throws -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw MCPError.invalidParams("operation '\(operation)' requires '\(key)'")
        }
        return trimmed
    }

    /// A present, non-null string argument, or nil when absent.
    private func string(_ key: String) throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let text = value.stringValue else { throw MCPError.invalidParams("\(key) must be a string") }
        return text
    }

    private func integer(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let number = try integer(key) else { return nil }
        guard range.contains(number) else {
            throw MCPError.invalidParams("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return number
    }

    /// A present, non-null integer argument, or nil when absent.
    private func integer(_ key: String) throws -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let number = value.intValue else {
            throw MCPError.invalidParams("\(key) must be an integer")
        }
        return number
    }
}
