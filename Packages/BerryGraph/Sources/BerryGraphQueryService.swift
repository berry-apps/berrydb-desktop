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
    private let harvestedAt: @Sendable (UUID) throws -> Date?

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

    /// Level of detail requested from `schema(...)`.
    public enum SchemaDetail: Sendable {
        /// Object name and kind only — no columns, indexes, or foreign keys.
        case overview
        /// Full column, index, and foreign key detail per object.
        case full
    }

    /// One table or view surfaced by `schema(...)`. Under `.overview` detail,
    /// `columns`, `indexes`, and `foreignKeys` are always empty.
    public struct SchemaObject: Equatable, Sendable {
        public struct Column: Equatable, Sendable {
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

        public struct Index: Equatable, Sendable {
            public let name: String
            public let columns: [String]
            public let unique: Bool

            public init(name: String, columns: [String], unique: Bool) {
                self.name = name
                self.columns = columns
                self.unique = unique
            }
        }

        public struct ForeignKey: Equatable, Sendable {
            public let column: String
            public let referencedTable: String
            public let referencedColumn: String

            public init(column: String, referencedTable: String, referencedColumn: String) {
                self.column = column
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
    public struct SchemaListing: Equatable, Sendable {
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

    /// Lists tables and views from the persisted graph, without opening a
    /// database connection. `objectNames`, when given, filters by name
    /// case-insensitively; unmatched names are silently dropped, not
    /// reported as errors. Results are sorted by (`database ?? ""`, `name`)
    /// and cut at `limit`, with the remainder reported in `omittedCount`.
    public func schema(
        profileID: UUID, objectNames: [String]?, detail: SchemaDetail, limit: Int
    ) throws -> SchemaListing {
        let graph = try loadedGraph(profileID: profileID)
        let harvestedAt = try self.harvestedAt(profileID)
        let wanted = objectNames.map { Set($0.map { $0.lowercased() }) }
        let matches = graph.nodes.values
            .filter { $0.kind == .table || $0.kind == .view }
            .filter { wanted?.contains($0.name.lowercased()) ?? true }
            .sorted { ($0.database ?? "", $0.name) < ($1.database ?? "", $1.name) }
        let included = Array(matches.prefix(max(0, limit)))
        return SchemaListing(
            objects: included.map { schemaObject(for: $0, in: graph, detail: detail) },
            omittedCount: matches.count - included.count,
            harvestedAt: harvestedAt
        )
    }

    private func schemaObject(for node: GraphNode, in graph: SchemaGraph, detail: SchemaDetail) -> SchemaObject {
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
        let foreignKeys = graph.edges
            .filter { $0.src == node.id && $0.kind == .references }
            .sorted { ($0.attrs["column"] ?? "") < ($1.attrs["column"] ?? "") }
            .map {
                SchemaObject.ForeignKey(
                    column: $0.attrs["column"] ?? "",
                    referencedTable: graph.nodes[$0.dst]?.name ?? $0.dst,
                    referencedColumn: $0.attrs["referencedColumn"] ?? ""
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
