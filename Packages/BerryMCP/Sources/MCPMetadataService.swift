import BerryGraph
import BerryStore
import Foundation

/// One connection a project exposes, as an agent sees it. Carries no
/// endpoint detail (host, user, path, region) and no secret: a profile's
/// identity and label are enough to choose it, and everything else stays in
/// the app.
public struct MCPConnectionDescriptor: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let driver: String
    /// "production" or "unlabeled": only a production label is reported, so a
    /// free-form environment name never reaches the agent.
    public let environment: String
    /// What the connection can serve without opening it: "schema" and "graph".
    public let capabilities: [String]
    /// When the persisted graph was last harvested; nil when it never was.
    public let graphHarvestedAt: Date?
}

/// One schema object found by `searchSchema`.
public struct MCPSchemaMatch: Codable, Equatable, Sendable {
    public let name: String
    public let kind: String
    public let database: String?
    /// The owning table for a column, nil for every other kind.
    public let table: String?
}

/// A traversal of the persisted dependency graph.
public enum MCPGraphOperation: Equatable, Sendable {
    case neighbors(node: String)
    case path(from: String, to: String)
    case blastRadius(node: String)
    case circularDependencies
    case topCentrality(limit: Int)
}

/// Why a metadata request failed. Descriptions are shown to the agent
/// verbatim, so they name schema objects and limits only, never a connection
/// detail; `unknownConnection` reads the same whether the id is unassigned
/// or does not exist.
public enum MCPMetadataError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownConnection
    case noSnapshot
    case notFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .unknownConnection:
            return "Unknown connection for this project"
        case .noSnapshot:
            return "No schema graph has been harvested for this connection. Open it in BerryDB to refresh."
        case let .notFound(message), let .invalidArgument(message):
            return message
        }
    }
}

/// A graph traversal result. Encodes as `{"operation": <name>, "result": <payload>}`
/// with snake_case operation names.
public enum MCPGraphResult: Equatable, Sendable, Encodable {
    case neighbors(BerryGraphQueryService.Neighbors)
    case path(BerryGraphQueryService.Path)
    case blastRadius(BerryGraphQueryService.BlastRadius)
    case circularDependencies(BerryGraphQueryService.CircularDependencies)
    case topCentrality([BerryGraphQueryService.CentralityEntry])

    private enum CodingKeys: String, CodingKey {
        case operation
        case result
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .neighbors(value):
            try container.encode("neighbors", forKey: .operation)
            try container.encode(value, forKey: .result)
        case let .path(value):
            try container.encode("path", forKey: .operation)
            try container.encode(value, forKey: .result)
        case let .blastRadius(value):
            try container.encode("blast_radius", forKey: .operation)
            try container.encode(value, forKey: .result)
        case let .circularDependencies(value):
            try container.encode("circular_dependencies", forKey: .operation)
            try container.encode(value, forKey: .result)
        case let .topCentrality(value):
            try container.encode("top_centrality", forKey: .operation)
            try container.encode(value, forKey: .result)
        }
    }
}

/// Harvested statistics, encoded as the payload itself.
public enum MCPGraphStats: Equatable, Sendable, Encodable {
    case summary(BerryGraphQueryService.StatisticsSummary)
    case table(BerryGraphQueryService.TableStatistics)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .summary(value):
            try value.encode(to: encoder)
        case let .table(value):
            try value.encode(to: encoder)
        }
    }
}

/// Serves schema and graph metadata for one project's connections,
/// independent of any wire protocol.
///
/// Invariants: it reads only persisted profiles and the persisted schema
/// graph, never opening a database connection or reading a credential; and
/// every method checks that the connection is assigned to the project before
/// any store access, so the error for an unassigned profile is identical to
/// the one for a profile that does not exist and cannot be used to probe for
/// either.
public struct MCPMetadataService: Sendable {
    /// Schema objects returned by one `schema` call.
    static let schemaObjectLimit = 200
    /// Object names one `schema` call may filter by.
    static let maximumObjectNames = 50
    /// Longest accepted search query, in characters.
    static let maximumQueryLength = 200
    /// Most matches one search returns.
    static let maximumSearchResults = 200
    /// Longest name list in a graph result.
    static let maximumGraphNames = 500
    /// Most entries a centrality query returns.
    static let maximumCentralityEntries = 50

    private let profiles: @Sendable () throws -> [ConnectionProfile]
    private let graph: BerryGraphQueryService
    private let harvestedAt: @Sendable (UUID) throws -> Date?
    private let loadGraph: @Sendable (UUID) throws -> SchemaGraph

    /// - Parameters:
    ///   - profiles: Reads the saved connection profiles; called once per
    ///     `listConnections`.
    ///   - graph: Runs graph queries and schema listings.
    ///   - harvestedAt: When a profile's graph was last harvested.
    ///   - loadGraph: The persisted graph of a profile, read once per
    ///     `searchSchema`; an empty graph means none was harvested.
    public init(
        profiles: @escaping @Sendable () throws -> [ConnectionProfile],
        graph: BerryGraphQueryService,
        harvestedAt: @escaping @Sendable (UUID) throws -> Date?,
        loadGraph: @escaping @Sendable (UUID) throws -> SchemaGraph
    ) {
        self.profiles = profiles
        self.graph = graph
        self.harvestedAt = harvestedAt
        self.loadGraph = loadGraph
    }

    /// The project's connections, in the project's order. A profile deleted
    /// since it was assigned is skipped.
    public func listConnections(in project: MCPVerifiedProject) throws -> [MCPConnectionDescriptor] {
        let saved = Dictionary(try profiles().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try project.project.profiles.compactMap { access in
            guard let profile = saved[access.profileID] else { return nil }
            return MCPConnectionDescriptor(
                id: profile.id,
                name: profile.name,
                driver: profile.driverID,
                environment: profile.envColor == "production" ? "production" : "unlabeled",
                capabilities: ["schema", "graph"],
                graphHarvestedAt: try harvestedAt(profile.id)
            )
        }
    }

    /// Tables and views of one connection, at most 200 per call; the listing
    /// reports how many more matched. `objectNames` takes at most 50 names.
    public func schema(
        in project: MCPVerifiedProject, connectionID: UUID, objectNames: [String]?,
        detail: BerryGraphQueryService.SchemaDetail
    ) throws -> BerryGraphQueryService.SchemaListing {
        try requireAssigned(connectionID, in: project)
        if let objectNames, objectNames.count > Self.maximumObjectNames {
            throw MCPMetadataError.invalidArgument("At most \(Self.maximumObjectNames) object names")
        }
        return try mappingErrors {
            try graph.schema(
                profileID: connectionID, objectNames: objectNames, detail: detail,
                limit: Self.schemaObjectLimit
            )
        }
    }

    /// Case-insensitive substring search over table, view, column and index
    /// names. `query` is trimmed and must be 1 to 200 characters; `limit` is
    /// clamped to 1...200. Results are ordered by kind (table, view, column,
    /// index), then database, owning table and name.
    public func searchSchema(
        in project: MCPVerifiedProject, connectionID: UUID, query: String, limit: Int
    ) throws -> [MCPSchemaMatch] {
        try requireAssigned(connectionID, in: project)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... Self.maximumQueryLength).contains(needle.count) else {
            throw MCPMetadataError.invalidArgument("Query must be 1 to \(Self.maximumQueryLength) characters")
        }
        let cap = min(max(limit, 1), Self.maximumSearchResults)
        let graph = try mappingErrors { try loadGraph(connectionID) }
        guard graph.nodeCount > 0 else { throw MCPMetadataError.noSnapshot }

        var ownerByColumn: [String: String] = [:]
        for edge in graph.edges where edge.kind == .hasColumn {
            if let owner = graph.nodes[edge.src] {
                ownerByColumn[edge.dst] = owner.name
            }
        }
        let matches = graph.nodes.values.compactMap { node -> (rank: Int, match: MCPSchemaMatch)? in
            guard let rank = Self.searchRank(of: node.kind),
                  node.name.range(of: needle, options: [.caseInsensitive, .literal]) != nil
            else { return nil }
            let table = node.kind == .column ? ownerByColumn[node.id] : nil
            return (rank, MCPSchemaMatch(name: node.name, kind: node.kind.rawValue, database: node.database, table: table))
        }
        return matches
            .sorted { lhs, rhs in
                (lhs.rank, lhs.match.database ?? "", lhs.match.table ?? "", lhs.match.name)
                    < (rhs.rank, rhs.match.database ?? "", rhs.match.table ?? "", rhs.match.name)
            }
            .prefix(cap)
            .map(\.match)
    }

    /// Runs one dependency-graph operation with strict name resolution: a
    /// name that matches several nodes is an error listing them, not a guess.
    ///
    /// Name lists are capped at 500 entries (`dependsOn`, `dependedOnBy`,
    /// `impacted`, and the names across `components`); the result has no
    /// truncation marker, except that `BlastRadius.count` keeps the full
    /// count. Centrality takes at most 50 entries.
    public func graphQuery(
        in project: MCPVerifiedProject, connectionID: UUID, operation: MCPGraphOperation
    ) throws -> MCPGraphResult {
        try requireAssigned(connectionID, in: project)
        return try mappingErrors {
            switch operation {
            case let .neighbors(node):
                let found = try graph.neighbors(profileID: connectionID, node: node, resolution: .strict)
                return .neighbors(.init(
                    node: found.node,
                    dependsOn: Array(found.dependsOn.prefix(Self.maximumGraphNames)),
                    dependedOnBy: Array(found.dependedOnBy.prefix(Self.maximumGraphNames))
                ))
            case let .path(from, to):
                return .path(try graph.path(profileID: connectionID, from: from, to: to, resolution: .strict))
            case let .blastRadius(node):
                let found = try graph.blastRadius(profileID: connectionID, node: node, resolution: .strict)
                return .blastRadius(.init(
                    node: found.node,
                    impacted: Array(found.impacted.prefix(Self.maximumGraphNames)),
                    count: found.count
                ))
            case .circularDependencies:
                let found = try graph.circularDependencies(profileID: connectionID)
                return .circularDependencies(.init(components: Self.capped(found.components)))
            case let .topCentrality(limit):
                let clamped = min(max(limit, 1), Self.maximumCentralityEntries)
                return .topCentrality(try graph.topCentrality(profileID: connectionID, limit: clamped))
            }
        }
    }

    /// Harvested statistics: every table when `object` is nil, otherwise one
    /// table and its indexes, resolved strictly.
    ///
    /// The summary lists at most 500 tables and 500 unused index names, each
    /// keeping its sorted order; the result has no truncation marker.
    public func graphStats(
        in project: MCPVerifiedProject, connectionID: UUID, object: String?
    ) throws -> MCPGraphStats {
        try requireAssigned(connectionID, in: project)
        return try mappingErrors {
            if let object {
                return .table(try graph.statistics(profileID: connectionID, table: object, resolution: .strict))
            }
            let summary = try graph.statistics(profileID: connectionID)
            return .summary(.init(
                tables: Array(summary.tables.prefix(Self.maximumGraphNames)),
                unusedIndexes: Array(summary.unusedIndexes.prefix(Self.maximumGraphNames))
            ))
        }
    }

    private func requireAssigned(_ connectionID: UUID, in project: MCPVerifiedProject) throws {
        guard project.project.profiles.contains(where: { $0.profileID == connectionID }) else {
            throw MCPMetadataError.unknownConnection
        }
    }

    private func mappingErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as BerryGraphQueryService.QueryError {
            switch error {
            case .noSnapshot:
                throw MCPMetadataError.noSnapshot
            case .nodeNotFound, .ambiguousNode:
                throw MCPMetadataError.notFound(error.localizedDescription)
            }
        }
    }

    private static func searchRank(of kind: NodeKind) -> Int? {
        switch kind {
        case .table: return 0
        case .view: return 1
        case .column: return 2
        case .index: return 3
        default: return nil
        }
    }

    /// Keeps whole components while they fit and cuts the one that crosses
    /// the cap, so the flattened name count never exceeds the cap.
    private static func capped(_ components: [[String]]) -> [[String]] {
        var remaining = maximumGraphNames
        var result: [[String]] = []
        for component in components where remaining > 0 {
            let kept = Array(component.prefix(remaining))
            result.append(kept)
            remaining -= kept.count
        }
        return result
    }
}
