import Foundation

/// Headless, metadata-only queries over a persisted schema graph.
///
/// The service deliberately contains no UI or AI concerns. It loads one
/// snapshot per operation and delegates traversal to `SchemaGraph`.
public struct BerryGraphQueryService: Sendable {
    /// Edge kinds that count as a dependency for neighbors, paths, blast
    /// radius, cycles and centrality; workload edges such as `.reads` are
    /// deliberately excluded so query traffic never reads as schema coupling.
    public static let dependencyKinds: Set<EdgeKind> = [.references, .derivesFrom]
    /// Entries `topCentrality` returns when the caller gives no limit.
    public static let defaultCentralityLimit = 10
    /// Cap on names listed in a `nodeNotFound` error, so a large schema
    /// cannot turn one failed lookup into an unbounded message.
    public static let maximumDiagnosticNames = 50

    /// How a node reference that matches more than one node is resolved.
    public enum ResolutionPolicy: Sendable {
        /// Reject an unqualified reference when more than one node matches.
        case strict
        /// Preserve the original AI tool behavior by selecting the matching
        /// table/view with the lexicographically smallest stable id.
        case legacyFirstStableID
    }

    private let loadGraph: @Sendable (UUID) throws -> SchemaGraph
    private let harvestedAt: @Sendable (UUID) throws -> Date?

    /// Reads snapshots and harvest times from `store`; never opens a
    /// database connection.
    public init(store: GraphStore) {
        self.loadGraph = { try store.loadGraph(profileID: $0) }
        self.harvestedAt = { try store.snapshots(profileID: $0).map(\.takenAt).max() }
    }

    /// Injectable snapshot source for adapters and deterministic tests. Every
    /// public operation invokes this closure exactly once. `harvestedAt`
    /// always reports `nil`; use `init(loadGraph:harvestedAt:)` to stub it.
    public init(loadGraph: @escaping @Sendable (UUID) throws -> SchemaGraph) {
        self.init(loadGraph: loadGraph, harvestedAt: { _ in nil })
    }

    /// Injectable snapshot and harvest-time sources for adapters and
    /// deterministic tests. Every public operation invokes `loadGraph` exactly
    /// once; `schema(...)` additionally invokes `harvestedAt` exactly once,
    /// after `loadGraph` succeeds.
    public init(
        loadGraph: @escaping @Sendable (UUID) throws -> SchemaGraph,
        harvestedAt: @escaping @Sendable (UUID) throws -> Date?
    ) {
        self.loadGraph = loadGraph
        self.harvestedAt = harvestedAt
    }

    /// Expected failures of a graph query. Messages name schema objects
    /// only, never data, and `nodeNotFound` lists at most
    /// `maximumDiagnosticNames` names.
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

    /// Direct dependencies of one node in both directions, by name, sorted.
    public struct Neighbors: Equatable, Sendable, Codable {
        public let node: String
        public let dependsOn: [String]
        public let dependedOnBy: [String]

        public init(node: String, dependsOn: [String], dependedOnBy: [String]) {
            self.node = node
            self.dependsOn = dependsOn
            self.dependedOnBy = dependedOnBy
        }
    }

    /// The shortest dependency chain from one node to another; `path` is
    /// in traversal order and empty when `reachable` is false.
    public struct Path: Equatable, Sendable, Codable {
        public let from: String
        public let to: String
        public let reachable: Bool
        public let path: [String]
    }

    /// Every node that transitively depends on one node, by name, sorted.
    public struct BlastRadius: Equatable, Sendable, Codable {
        public let node: String
        public let impacted: [String]
        public let count: Int

        public init(node: String, impacted: [String], count: Int) {
            self.node = node
            self.impacted = impacted
            self.count = count
        }
    }

    /// Dependency cycles as components of node names, in a deterministic
    /// order.
    public struct CircularDependencies: Equatable, Sendable {
        public let components: [[String]]
        public var hasCycles: Bool { !components.isEmpty }

        public init(components: [[String]]) {
            self.components = components
        }
    }

    /// One node and how many dependency edges point at it.
    public struct CentralityEntry: Equatable, Sendable, Codable {
        public let node: String
        public let inDegree: Int
    }

    /// Harvested statistics of one table or index, limited to the
    /// statistic keys (`rows`, `size_bytes`, `seq_scan`, `idx_scan`,
    /// `unused`) so other node attributes are never surfaced.
    public struct NodeStatistics: Equatable, Sendable, Codable {
        public let name: String
        public let fields: [String: String]
    }

    /// Statistics of one table and of each of its indexes.
    public struct TableStatistics: Equatable, Sendable, Codable {
        public let table: String
        public let fields: [String: String]
        public let indexes: [NodeStatistics]
    }

    /// Statistics of every table plus the names of indexes marked unused.
    public struct StatisticsSummary: Equatable, Sendable, Codable {
        public let tables: [NodeStatistics]
        public let unusedIndexes: [String]
    }

    /// Level of detail requested from `schema(...)`.
    public enum SchemaDetail: String, Sendable, Codable {
        /// Object name and kind only — no columns, indexes, or foreign keys.
        case overview
        /// Full column, index, and foreign key detail per object.
        case full
    }

    /// One table or view surfaced by `schema(...)`. Under `.overview` detail,
    /// `columns`, `indexes`, and `foreignKeys` are always empty.
    public struct SchemaObject: Equatable, Sendable, Codable {
        /// One column of the object, as harvested by `SchemaGraphBuilder`
        /// from a `.hasColumn` node's attrs.
        public struct Column: Equatable, Sendable, Codable {
            public let name: String
            public let type: String
            public let nullable: Bool
            public let primaryKey: Bool

            public init(name: String, type: String, nullable: Bool, primaryKey: Bool) {
                self.name = name
                self.type = type
                self.nullable = nullable
                self.primaryKey = primaryKey
            }
        }

        /// One index on the object, as harvested by `SchemaGraphBuilder`
        /// from a `.hasIndex` node's attrs. `columns` preserves harvest order
        /// (the key order for a composite index), not alphabetical order.
        public struct Index: Equatable, Sendable, Codable {
            public let name: String
            public let columns: [String]
            public let unique: Bool

            public init(name: String, columns: [String], unique: Bool) {
                self.name = name
                self.columns = columns
                self.unique = unique
            }
        }

        /// One outgoing foreign key of the object, as harvested by
        /// `SchemaGraphBuilder` onto the `.references` edge to the parent
        /// table. `referencedDatabase` is the parent table's database, which
        /// can differ from the child's for a cross-database reference.
        public struct ForeignKey: Equatable, Sendable, Codable {
            public let column: String
            public let referencedDatabase: String?
            public let referencedTable: String
            public let referencedColumn: String

            public init(
                column: String, referencedDatabase: String? = nil,
                referencedTable: String, referencedColumn: String
            ) {
                self.column = column
                self.referencedDatabase = referencedDatabase
                self.referencedTable = referencedTable
                self.referencedColumn = referencedColumn
            }
        }

        public let name: String
        public let database: String?
        public let kind: NodeKind
        public let columns: [Column]
        public let indexes: [Index]
        public let foreignKeys: [ForeignKey]

        public init(
            name: String, database: String?, kind: NodeKind,
            columns: [Column] = [], indexes: [Index] = [], foreignKeys: [ForeignKey] = []
        ) {
            self.name = name
            self.database = database
            self.kind = kind
            self.columns = columns
            self.indexes = indexes
            self.foreignKeys = foreignKeys
        }
    }

    /// Result of `schema(...)`: the objects within `limit`, how many matching
    /// objects were cut by it, and when the underlying graph was last
    /// harvested (`nil` when the store can't report a snapshot time).
    public struct SchemaListing: Equatable, Sendable, Codable {
        public let objects: [SchemaObject]
        public let omittedCount: Int
        public let harvestedAt: Date?

        public init(objects: [SchemaObject], omittedCount: Int, harvestedAt: Date?) {
            self.objects = objects
            self.omittedCount = omittedCount
            self.harvestedAt = harvestedAt
        }
    }

    /// Validates the persisted-snapshot precondition without exposing the
    /// mutable graph representation to transport adapters.
    public func validateSnapshot(profileID: UUID) throws {
        _ = try loadedGraph(profileID: profileID)
    }

    /// Direct dependencies of the node `name` resolves to, under
    /// `resolution`, from the persisted graph of `profileID`.
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

    /// Shortest dependency path between two nodes, following outgoing
    /// dependency edges only.
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

    /// Every node that transitively depends on the node `name` resolves to.
    public func blastRadius(
        profileID: UUID, node name: String, resolution: ResolutionPolicy = .strict
    ) throws -> BlastRadius {
        let graph = try loadedGraph(profileID: profileID)
        let node = try resolve(name, in: graph, policy: resolution)
        let impacted = names(Array(graph.blastRadius(of: node.id)), in: graph)
        return BlastRadius(node: node.name, impacted: impacted, count: impacted.count)
    }

    /// Every dependency cycle in the persisted graph of `profileID`.
    public func circularDependencies(profileID: UUID) throws -> CircularDependencies {
        let graph = try loadedGraph(profileID: profileID)
        let components = graph.circularDependencies()
            .map { names($0, in: graph) }
            .sorted(by: lexicographicallyPrecedes)
        return CircularDependencies(components: components)
    }

    /// The nodes with the most incoming dependency edges; `limit` is
    /// clamped to at least 1.
    public func topCentrality(profileID: UUID, limit: Int = defaultCentralityLimit) throws -> [CentralityEntry] {
        let graph = try loadedGraph(profileID: profileID)
        return graph.topByInDegree(max(1, limit), kinds: Self.dependencyKinds).map {
            CentralityEntry(node: graph.nodes[$0.id]?.name ?? $0.id, inDegree: $0.inDegree)
        }
    }

    /// Harvested statistics of every table, sorted by name then stable id.
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

    /// Harvested statistics of one table and its indexes.
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

    /// Lists tables and views from the persisted graph, without opening a
    /// database connection. `objectNames`, when given, filters case-
    /// insensitively: an entry containing a `.` matches the qualified
    /// `database.name` (empty string for a nil database, e.g. `.orders`);
    /// an entry without a `.` matches the bare name in every database.
    /// Unmatched names are silently dropped, not reported as errors. Results
    /// are sorted by (`database ?? ""`, `name`) and cut at `limit` — `0`
    /// returns no objects and reports every match as omitted — with the
    /// remainder reported in `omittedCount`.
    public func schema(
        profileID: UUID, objectNames: [String]?, detail: SchemaDetail, limit: Int
    ) throws -> SchemaListing {
        let graph = try loadedGraph(profileID: profileID)
        let harvestedAt = try self.harvestedAt(profileID)
        let wanted = objectNames?.map { $0.lowercased() }
        let matches = graph.nodes.values
            .filter { $0.kind == .table || $0.kind == .view }
            .filter { matchesWanted($0, wanted: wanted) }
            .sorted { ($0.database ?? "", $0.name) < ($1.database ?? "", $1.name) }
        let included = Array(matches.prefix(max(0, limit)))
        // Single pass over all edges, not one filter per object: keeps
        // schema() linear in graph size instead of quadratic in object count.
        let referencesBySource = detail == .full ? referenceEdgesBySource(in: graph) : [:]
        return SchemaListing(
            objects: included.map { schemaObject(for: $0, in: graph, detail: detail, referencesBySource: referencesBySource) },
            omittedCount: matches.count - included.count,
            harvestedAt: harvestedAt
        )
    }

    private func matchesWanted(_ node: GraphNode, wanted: [String]?) -> Bool {
        guard let wanted else { return true }
        let bare = node.name.lowercased()
        let qualified = "\(node.database ?? "").\(node.name)".lowercased()
        return wanted.contains { $0.contains(".") ? $0 == qualified : $0 == bare }
    }

    private func referenceEdgesBySource(in graph: SchemaGraph) -> [String: [GraphEdge]] {
        var result: [String: [GraphEdge]] = [:]
        for edge in graph.edges where edge.kind == .references {
            result[edge.src, default: []].append(edge)
        }
        return result
    }

    private func schemaObject(
        for node: GraphNode, in graph: SchemaGraph, detail: SchemaDetail,
        referencesBySource: [String: [GraphEdge]]
    ) -> SchemaObject {
        guard detail == .full else {
            return SchemaObject(name: node.name, database: node.database, kind: node.kind)
        }
        let columns = graph.neighbors(of: node.id, direction: .outgoing, kinds: [.hasColumn])
            .compactMap { graph.nodes[$0] }
            .sorted { $0.name < $1.name }
            .map {
                SchemaObject.Column(
                    name: $0.name,
                    type: $0.attrs["type"] ?? "",
                    nullable: $0.attrs["nullable"] == "true",
                    primaryKey: $0.attrs["primaryKey"] == "true"
                )
            }
        let indexes = graph.neighbors(of: node.id, direction: .outgoing, kinds: [.hasIndex])
            .compactMap { graph.nodes[$0] }
            .sorted { $0.name < $1.name }
            .map {
                SchemaObject.Index(
                    name: $0.name,
                    columns: indexColumns($0.attrs["columns"]),
                    unique: $0.attrs["unique"] == "true"
                )
            }
        let foreignKeys = (referencesBySource[node.id] ?? [])
            .sorted { ($0.attrs["column"] ?? "") < ($1.attrs["column"] ?? "") }
            .map { edge -> SchemaObject.ForeignKey in
                let parent = graph.nodes[edge.dst]
                return SchemaObject.ForeignKey(
                    column: edge.attrs["column"] ?? "",
                    referencedDatabase: parent?.database,
                    referencedTable: parent?.name ?? edge.dst,
                    referencedColumn: edge.attrs["referencedColumn"] ?? ""
                )
            }
        return SchemaObject(
            name: node.name, database: node.database, kind: node.kind,
            columns: columns, indexes: indexes, foreignKeys: foreignKeys
        )
    }

    private func indexColumns(_ attr: String?) -> [String] {
        (attr ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func loadedGraph(profileID: UUID) throws -> SchemaGraph {
        let graph = try loadGraph(profileID)
        guard graph.nodeCount > 0 else { throw QueryError.noSnapshot }
        return graph
    }

    /// Exact stable id wins. Qualified `database.name` is next, followed by an
    /// unqualified case-insensitive name. Under `.strict`, more than one match
    /// at a step is reported deterministically as `ambiguousNode`; under
    /// `.legacyFirstStableID`, every step picks the smallest stable id instead
    /// and never reports ambiguity.
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
        if let match = try select(qualified, raw: query, policy: policy) { return match }

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

/// Wire form of `CircularDependencies`: `components` plus the derived
/// `hasCycles` flag, so a client can branch on one boolean without inspecting
/// the list. Decoding reads `components` only, because `hasCycles` is computed
/// and a stored copy could never disagree with it.
extension BerryGraphQueryService.CircularDependencies: Codable {
    private enum CodingKeys: String, CodingKey {
        case components
        case hasCycles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(components: try container.decode([[String]].self, forKey: .components))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(components, forKey: .components)
        try container.encode(hasCycles, forKey: .hasCycles)
    }
}
