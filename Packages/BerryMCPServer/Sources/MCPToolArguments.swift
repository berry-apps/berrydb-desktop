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

    func query() throws -> String {
        guard let text = try string("query") else { throw MCPError.invalidParams("query is required") }
        guard (1 ... Self.maximumQueryLength).contains(text.count) else {
            throw MCPError.invalidParams("query must be 1 to \(Self.maximumQueryLength) characters")
        }
        return text
    }

    func searchLimit() throws -> Int {
        try integer("limit", in: Self.searchLimitRange) ?? Self.defaultSearchLimit
    }

    func graphOperation() throws -> MCPGraphOperation {
        guard let name = try string("operation") else { throw MCPError.invalidParams("operation is required") }
        switch name {
        case "neighbors":
            return .neighbors(node: try requiredName("node", for: name))
        case "path":
            return .path(from: try requiredName("from", for: name), to: try requiredName("to", for: name))
        case "blast_radius":
            return .blastRadius(node: try requiredName("node", for: name))
        case "circular_dependencies":
            return .circularDependencies
        case "top_centrality":
            let limit = try integer("limit", in: Self.graphLimitRange) ?? BerryGraphQueryService.defaultCentralityLimit
            return .topCentrality(limit: limit)
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

    private func requiredName(_ key: String, for operation: String) throws -> String {
        let trimmed = try string(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
