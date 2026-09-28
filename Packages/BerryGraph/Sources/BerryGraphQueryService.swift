import Foundation

/// Headless, metadata-only queries over a persisted schema graph.
///
/// The service deliberately contains no UI or AI concerns. It loads one
/// snapshot per operation and delegates traversal to `SchemaGraph`.
public struct BerryGraphQueryService: Sendable {
    public static let dependencyKinds: Set<EdgeKind> = [.references, .derivesFrom]
    public static let defaultCentralityLimit = 10
    public static let maximumDiagnosticNames = 50

    public enum ResolutionPolicy: Sendable {
        /// Reject an unqualified reference when more than one node matches.
        case strict
        /// Preserve the original AI tool behavior by selecting the matching
        /// table/view with the lexicographically smallest stable id.
        case legacyFirstStableID
    }

    private let loadGraph: @Sendable (UUID) throws -> SchemaGraph

    public init(store: GraphStore) {
        self.loadGraph = { try store.loadGraph(profileID: $0) }
    }

    /// Injectable snapshot source for adapters and deterministic tests. Every
    /// public operation invokes this closure exactly once.
    public init(loadGraph: @escaping @Sendable (UUID) throws -> SchemaGraph) {
        self.loadGraph = loadGraph
    }

    public enum QueryError: Error, Equatable, Sendable, LocalizedError {
        case noSnapshot
        case nodeNotFound(name: String, available: [String])
        case ambiguousNode(name: String, matches: [String])

        public var errorDescription: String? {
            switch self {
            case .noSnapshot:
                return "No schema graph has been harvested yet for this connection."
            case let .nodeNotFound(name, available):
                return "Node '\(name)' not found. Available: \(available.joined(separator: ", "))"
            case let .ambiguousNode(name, matches):
                return "Node '\(name)' is ambiguous. Use one of: \(matches.joined(separator: ", "))"
            }
        }
    }

    public struct Neighbors: Equatable, Sendable {
        public let node: String
        public let dependsOn: [String]
        public let dependedOnBy: [String]
    }

    public struct Path: Equatable, Sendable {
        public let from: String
        public let to: String
        public let reachable: Bool
        public let path: [String]
    }

    public struct BlastRadius: Equatable, Sendable {
        public let node: String
        public let impacted: [String]
        public let count: Int
    }

    public struct CircularDependencies: Equatable, Sendable {
        public let components: [[String]]
        public var hasCycles: Bool { !components.isEmpty }
    }

    public struct CentralityEntry: Equatable, Sendable {
        public let node: String
        public let inDegree: Int
    }

    public struct NodeStatistics: Equatable, Sendable {
        public let name: String
        public let fields: [String: String]
    }

    public struct TableStatistics: Equatable, Sendable {
        public let table: String
        public let fields: [String: String]
        public let indexes: [NodeStatistics]
    }

    public struct StatisticsSummary: Equatable, Sendable {
        public let tables: [NodeStatistics]
        public let unusedIndexes: [String]
    }

    /// Validates the persisted-snapshot precondition without exposing the
    /// mutable graph representation to transport adapters.
    public func validateSnapshot(profileID: UUID) throws {
        _ = try loadedGraph(profileID: profileID)
    }

    public func neighbors(
        profileID: UUID, node name: String, resolution: ResolutionPolicy = .strict
    ) throws -> Neighbors {
        let graph = try loadedGraph(profileID: profileID)
        let node = try resolve(name, in: graph, policy: resolution)
        return Neighbors(
            node: node.name,
            dependsOn: names(graph.neighbors(of: node.id, direction: .outgoing, kinds: Self.dependencyKinds), in: graph),
            dependedOnBy: names(graph.neighbors(of: node.id, direction: .incoming, kinds: Self.dependencyKinds), in: graph)
        )
    }

    public func path(
        profileID: UUID, from fromName: String, to toName: String,
        resolution: ResolutionPolicy = .strict
    ) throws -> Path {
        let graph = try loadedGraph(profileID: profileID)
        let from = try resolve(fromName, in: graph, policy: resolution)
        let to = try resolve(toName, in: graph, policy: resolution)
        let chain = graph.shortestPath(
            from: from.id, to: to.id, direction: .outgoing, kinds: Self.dependencyKinds
        )
        return Path(
            from: from.name,
            to: to.name,
            reachable: chain != nil,
            path: chain?.map { graph.nodes[$0]?.name ?? $0 } ?? []
        )
    }

    public func blastRadius(
        profileID: UUID, node name: String, resolution: ResolutionPolicy = .strict
    ) throws -> BlastRadius {
        let graph = try loadedGraph(profileID: profileID)
        let node = try resolve(name, in: graph, policy: resolution)
        let impacted = names(Array(graph.blastRadius(of: node.id)), in: graph)
        return BlastRadius(node: node.name, impacted: impacted, count: impacted.count)
    }

    public func circularDependencies(profileID: UUID) throws -> CircularDependencies {
        let graph = try loadedGraph(profileID: profileID)
        let components = graph.circularDependencies()
            .map { names($0, in: graph) }
            .sorted(by: lexicographicallyPrecedes)
        return CircularDependencies(components: components)
    }

    public func topCentrality(profileID: UUID, limit: Int = defaultCentralityLimit) throws -> [CentralityEntry] {
        let graph = try loadedGraph(profileID: profileID)
        return graph.topByInDegree(max(1, limit), kinds: Self.dependencyKinds).map {
            CentralityEntry(node: graph.nodes[$0.id]?.name ?? $0.id, inDegree: $0.inDegree)
        }
    }

    public func statistics(profileID: UUID) throws -> StatisticsSummary {
        let graph = try loadedGraph(profileID: profileID)
        let tables = graph.nodes.values
            .filter { $0.kind == .table }
            .sorted(by: nodeOrder)
            .map { NodeStatistics(name: $0.name, fields: statFields($0.attrs)) }
        let unusedIndexes = graph.nodes.values
            .filter { $0.kind == .index && $0.attrs["unused"] == "true" }
            .map(\.name)
            .sorted()
        return StatisticsSummary(tables: tables, unusedIndexes: unusedIndexes)
    }

    public func statistics(
        profileID: UUID, table name: String, resolution: ResolutionPolicy = .strict
    ) throws -> TableStatistics {
        let graph = try loadedGraph(profileID: profileID)
        let table = try resolve(name, in: graph, policy: resolution)
        let indexes = graph.neighbors(of: table.id, direction: .outgoing, kinds: [.hasIndex])
            .compactMap { graph.nodes[$0] }
            .sorted(by: nodeOrder)
            .map { NodeStatistics(name: $0.name, fields: statFields($0.attrs)) }
        return TableStatistics(table: table.name, fields: statFields(table.attrs), indexes: indexes)
    }

    private func loadedGraph(profileID: UUID) throws -> SchemaGraph {
        let graph = try loadGraph(profileID)
        guard graph.nodeCount > 0 else { throw QueryError.noSnapshot }
        return graph
    }

    /// Exact stable id wins. Qualified `database.name` is next, followed by an
    /// unqualified case-insensitive name. Ambiguity is reported deterministically.
    private func resolve(
        _ raw: String, in graph: SchemaGraph, policy: ResolutionPolicy
    ) throws -> GraphNode {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = graph.nodes[query] { return exact }

        let key = query.lowercased()
        let allNodes = graph.nodes.values
        let qualified = allNodes.filter {
            guard let database = $0.database else { return false }
            return "\(database).\($0.name)".lowercased() == key
        }
        if let match = try unique(qualified, raw: query) { return match }

        let preferred = allNodes.filter {
            ($0.kind == .table || $0.kind == .view) && $0.name.lowercased() == key
        }
        if let match = try select(preferred, raw: query, policy: policy) { return match }

        let any = allNodes.filter { $0.name.lowercased() == key }
        if let match = try select(any, raw: query, policy: policy) { return match }

        let available = allNodes
            .filter { $0.kind == .table || $0.kind == .view }
            .map(\.name)
            .sorted()
            .prefix(Self.maximumDiagnosticNames)
        throw QueryError.nodeNotFound(name: query, available: Array(available))
    }

    private func select(
        _ matches: [GraphNode], raw: String, policy: ResolutionPolicy
    ) throws -> GraphNode? {
        switch policy {
        case .strict:
            return try unique(matches, raw: raw)
        case .legacyFirstStableID:
            return matches.min { $0.id < $1.id }
        }
    }

    private func unique(_ matches: [GraphNode], raw: String) throws -> GraphNode? {
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1 else {
            throw QueryError.ambiguousNode(name: raw, matches: matches.map(qualifiedName).sorted())
        }
        return matches[0]
    }

    private func qualifiedName(_ node: GraphNode) -> String {
        node.database.map { "\($0).\(node.name)" } ?? node.name
    }

    private func names(_ ids: [String], in graph: SchemaGraph) -> [String] {
        ids.map { graph.nodes[$0]?.name ?? $0 }.sorted()
    }

    private func statFields(_ attrs: [String: String]) -> [String: String] {
        let keys: Set<String> = ["rows", "size_bytes", "seq_scan", "idx_scan", "unused"]
        return attrs.filter { keys.contains($0.key) }
    }

    private func nodeOrder(_ lhs: GraphNode, _ rhs: GraphNode) -> Bool {
        (lhs.name, lhs.id) < (rhs.name, rhs.id)
    }

    private func lexicographicallyPrecedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }
}
