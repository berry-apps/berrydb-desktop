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
        case .getSchema: return ["connection_id", "object_names", "detail"]
        case .searchSchema: return ["connection_id", "query", "limit"]
        case .graphQuery: return ["connection_id", "operation", "node", "from", "to", "limit"]
        case .getGraphStats: return ["connection_id", "object"]
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
        guard let value = values[key], !value.isNull else { return nil }
        guard let number = value.intValue else {
            throw MCPError.invalidParams("\(key) must be an integer")
        }
        guard range.contains(number) else {
            throw MCPError.invalidParams("\(key) must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return number
    }
}
