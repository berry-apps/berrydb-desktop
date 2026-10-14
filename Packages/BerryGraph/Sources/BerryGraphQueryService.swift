import BerryStore
import Foundation

/// Headless, metadata-only queries over a persisted schema graph.
///
/// The service deliberately contains no UI or AI concerns. Each graph
/// operation loads one table-level graph and delegates traversal to
/// `SchemaGraph`; a schema listing reads only the page it returns.
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
    /// Per-table statistics, the source of every index counter: the
    /// table-level graph has no index nodes to carry them. `stats` reads the
    /// rows of the tables a summary keeps; `objectStats` reads one by its key.
    private let stats: @Sendable (UUID, [(database: String?, name: String)]) throws -> [SchemaStatsValues]
    private let objectStats: @Sendable (UUID, String?, String) throws -> SchemaStatsRecord?
    /// Serves `schema(...)`; nil for a service built from closures, which
    /// answers graph operations only.
    private let reader: GraphReader?

    /// Reads everything from `reader`; never opens a database connection.
    public init(reader: GraphReader) {
        self.init(reader: reader, tableGraph: { try reader.tableGraph(profileID: $0) })
    }

    /// Reads listings and statistics from `reader` and takes the table-level
    /// graph every graph operation traverses from `tableGraph`, such as a
    /// cache of `reader.tableGraph(profileID:)`.
    public init(reader: GraphReader, tableGraph: @escaping @Sendable (UUID) throws -> SchemaGraph) {
        self.loadGraph = tableGraph
        self.stats = { try reader.stats(profileID: $0, objects: $1) }
        self.objectStats = { try reader.stats(profileID: $0, database: $1, name: $2) }
        self.reader = reader
    }

    /// Injectable graph source for adapters and deterministic tests. Every
    /// graph operation invokes this closure exactly once. The service has no
    /// schema listing and no index statistics, and its table statistics are
    /// the counters the graph's nodes carry.
    public init(loadGraph: @escaping @Sendable (UUID) throws -> SchemaGraph) {
        self.loadGraph = loadGraph
        self.stats = { _, _ in [] }
        self.objectStats = { _, _, _ in nil }
        self.reader = nil
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

        /// Creates a neighbors result from already-sorted name lists.
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

        /// Creates a blast radius result; `count` is the caller's to keep as the full count.
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

        /// Creates a result from components in their final order.
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

        /// Creates a summary from already-ordered tables and unused index names.
        public init(tables: [NodeStatistics], unusedIndexes: [String]) {
            self.tables = tables
            self.unusedIndexes = unusedIndexes
        }
    }

    /// Level of detail requested from `schema(...)`.
    public enum SchemaDetail: String, Sendable, Codable {
        /// Object name and kind only — no columns, indexes, or foreign keys.
        case overview
        /// Full column, index, and foreign key detail per object.
        case full
    }

    /// One table or view surfaced by `schema(...)`. Under `.overview` detail,
    /// `columns`, `indexes`, and `foreignKeys` are always empty. They are
    /// empty too while `detailPending` is true: the object is listed but its
    /// columns have not been read yet.
    public struct SchemaObject: Equatable, Sendable, Codable {
        /// One column of the object.
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

        /// One index on the object. `columns` preserves harvest order (the
        /// key order for a composite index), not alphabetical order.
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

        /// One outgoing foreign key column of the object. `referencedDatabase`
        /// is the parent table's database, which can differ from the child's
        /// for a cross-database reference.
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
        public let detailPending: Bool

        public init(
            name: String, database: String?, kind: NodeKind,
            columns: [Column] = [], indexes: [Index] = [], foreignKeys: [ForeignKey] = [], detailPending: Bool = false
        ) {
            self.name = name
            self.database = database
            self.kind = kind
            self.columns = columns
            self.indexes = indexes
            self.foreignKeys = foreignKeys
            self.detailPending = detailPending
        }
    }

    /// Result of `schema(...)`: one page of objects, how many objects match
    /// in all (`total`) and after this page (`omittedCount`), the offset of
    /// the next page (nil on the last one), when the schema last changed
    /// (`harvestedAt`) and was last checked, and whether that check is stale.
    ///
    /// Encodes `nextOffset` and `checkedAt` as null when they are nil, so a
    /// client paging by `nextOffset` reads an explicit end rather than a
    /// missing key; `harvestedAt` is left out when nil.
    public struct SchemaListing: Equatable, Sendable, Codable {
        public let objects: [SchemaObject]
        public let omittedCount: Int
        public let harvestedAt: Date?
        public let total: Int
        public let nextOffset: Int?
        public let checkedAt: Date?
        public let stale: Bool

        /// `total` defaults to the objects plus the omitted ones, which is
        /// the total of a first page; a listing with no `checkedAt` is stale.
        public init(
            objects: [SchemaObject], omittedCount: Int, harvestedAt: Date?,
            total: Int? = nil, nextOffset: Int? = nil, checkedAt: Date? = nil, stale: Bool = true
        ) {
            self.objects = objects
            self.omittedCount = omittedCount
            self.harvestedAt = harvestedAt
            self.total = total ?? objects.count + omittedCount
            self.nextOffset = nextOffset
            self.checkedAt = checkedAt
            self.stale = stale
        }

        private enum CodingKeys: String, CodingKey {
            case objects, omittedCount, harvestedAt, total, nextOffset, checkedAt, stale
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(objects, forKey: .objects)
            try container.encode(omittedCount, forKey: .omittedCount)
            try container.encodeIfPresent(harvestedAt, forKey: .harvestedAt)
            try container.encode(total, forKey: .total)
            try container.encode(nextOffset, forKey: .nextOffset)
            try container.encode(checkedAt, forKey: .checkedAt)
            try container.encode(stale, forKey: .stale)
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

    /// Harvested statistics of every table, sorted by name then stable id, or
    /// of the first `limit` of them, and the indexes of those tables that
    /// were never scanned, sorted by name.
    ///
    /// The tables are taken from the graph before any statistics are read,
    /// and only their rows are then read, as plain values; their index
    /// counters are decoded with one decoder. At 20,000 tables, decoding
    /// every row as a record and every row's index counters with a decoder
    /// of its own, to keep 500 tables, cost hundreds of milliseconds.
    public func statistics(profileID: UUID, limit: Int? = nil) throws -> StatisticsSummary {
        let graph = try loadedGraph(profileID: profileID)
        let tables = Self.leading(limit.map { max(0, $0) }, of: graph.nodes.values.filter { $0.kind == .table }, by: nodeOrder)
        let rows = try stats(profileID, tables.map { (database: $0.database, name: $0.name) })
        let rowsByObject = Dictionary(
            rows.map { (ObjectKey(database: $0.database, name: $0.name), $0) }, uniquingKeysWith: { first, _ in first }
        )
        let decoder = JSONDecoder()
        var unusedIndexes: [String] = []
        let entries = tables.map { node -> NodeStatistics in
            let row = rowsByObject[ObjectKey(database: node.database, name: node.name)]
            if let row {
                unusedIndexes += GraphReader.indexCounters(of: row.indexStats, decoder: decoder).filter { $0.value == 0 }.map(\.key)
            }
            return NodeStatistics(name: node.name, fields: counters(of: node, row: row.map(GraphReader.counterAttributes(of:))))
        }
        return StatisticsSummary(tables: entries, unusedIndexes: unusedIndexes.sorted())
    }

    /// The first `limit` of `nodes` in `order`, sorted, or every node when
    /// `limit` is nil. A sorted buffer of `limit` nodes is kept while the
    /// nodes are read, so a large schema is not sorted whole to keep a few
    /// hundred of its tables.
    private static func leading(
        _ limit: Int?, of nodes: [GraphNode], by order: (GraphNode, GraphNode) -> Bool
    ) -> [GraphNode] {
        guard let limit, nodes.count > limit else { return nodes.sorted(by: order) }
        var kept: [GraphNode] = []
        kept.reserveCapacity(limit + 1)
        for node in nodes {
            if kept.count == limit, let last = kept.last, !order(node, last) { continue }
            var low = 0
            var high = kept.count
            while low < high {
                let middle = (low + high) / 2
                if order(node, kept[middle]) { high = middle } else { low = middle + 1 }
            }
            kept.insert(node, at: low)
            if kept.count > limit { kept.removeLast() }
        }
        return kept
    }

    /// Harvested statistics of one table and its indexes.
    public func statistics(
        profileID: UUID, table name: String, resolution: ResolutionPolicy = .strict
    ) throws -> TableStatistics {
        let graph = try loadedGraph(profileID: profileID)
        let table = try resolve(name, in: graph, policy: resolution)
        let row = try objectStats(profileID, table.database, table.name)
        let indexes = (row.map(GraphReader.indexCounters(of:)) ?? [:])
            .sorted { $0.key < $1.key }
            .map { NodeStatistics(name: $0.key, fields: GraphReader.indexAttributes(scans: $0.value)) }
        return TableStatistics(
            table: table.name, fields: counters(of: table, row: row.map(GraphReader.counterAttributes(of:))), indexes: indexes
        )
    }

    /// A table's counters. A service that reads a store takes them from the
    /// statistics row, not from the graph: the graph can be a cached one,
    /// and a statistics refresh replaces the rows without changing the
    /// schema, so the node's copy can be out of date or belong to a row
    /// since dropped. A service built from a graph closure has no rows.
    private func counters(of node: GraphNode, row: [String: String]?) -> [String: String] {
        guard reader != nil else { return statFields(node.attrs) }
        return row ?? [:]
    }

    /// One page of tables and views from the stored schema, without opening a
    /// database connection, ordered by namespace and name.
    ///
    /// `objectNames`, when given, selects objects by name: an entry matches
    /// an object of that name in every namespace, or `namespace.name` (split
    /// at the last `.`) in one; an empty namespace, as in `.orders`, is an
    /// object without one. An entry is compared exactly first and, only when
    /// that matches nothing, again ignoring case, so `ORDERS` finds `orders`
    /// while `orders` never also lists `Orders`. Unmatched names are silently
    /// dropped, not reported as errors.
    ///
    /// A page holds `limit` objects, clamped to 1...200, and a full listing
    /// also stops before an object whose estimated size would take it past
    /// `maxBytes`, though never below one object.
    ///
    /// Throws `noSnapshot` when no object of the profile was ever stored, and
    /// for a service built from closures, which has no stored schema to list.
    public func schema(
        profileID: UUID, objectNames: [String]?, detail: SchemaDetail, offset: Int, limit: Int, maxBytes: Int
    ) throws -> SchemaListing {
        guard let reader else { throw QueryError.noSnapshot }
        let state = try reader.state(profileID: profileID)
        guard state.objectCount > 0 else { throw QueryError.noSnapshot }
        // An overview serialises no definitions, so they do not count
        // against its byte budget.
        let page = try reader.objects(
            profileID: profileID, names: objectNames, offset: offset, limit: limit,
            maxBytes: detail == .full ? maxBytes : .max, includeRelations: detail == .full
        )
        let foreignKeys = detail == .full ? foreignKeysBySource(page.relations) : [:]
        let objects = page.objects.map { schemaObject(for: $0, detail: detail, foreignKeys: foreignKeys) }
        return SchemaListing(
            objects: objects,
            omittedCount: max(0, page.total - (max(0, offset) + objects.count)),
            harvestedAt: state.changedAt,
            total: page.total, nextOffset: page.nextOffset, checkedAt: state.checkedAt, stale: state.stale
        )
    }

    /// The page's foreign keys grouped by source in one pass, not one filter
    /// per object.
    private func foreignKeysBySource(_ relations: [SchemaRelationRecord]) -> [ObjectKey: [SchemaObject.ForeignKey]] {
        var result: [ObjectKey: [SchemaObject.ForeignKey]] = [:]
        for relation in relations {
            result[ObjectKey(database: relation.srcDatabase, name: relation.srcName), default: []].append(
                SchemaObject.ForeignKey(
                    column: relation.srcColumn, referencedDatabase: relation.dstDatabase,
                    referencedTable: relation.dstName, referencedColumn: relation.dstColumn
                )
            )
        }
        return result
    }

    /// Columns are listed by name, as the listing has always ordered them;
    /// foreign keys keep the store's order, which is by column.
    private func schemaObject(
        for row: SchemaObjectRecord, detail: SchemaDetail, foreignKeys: [ObjectKey: [SchemaObject.ForeignKey]]
    ) -> SchemaObject {
        let kind: NodeKind = row.kind == "view" ? .view : .table
        // An overview shows no columns, so it needs only whether a definition
        // exists, not the decoded definition.
        guard detail == .full else {
            return SchemaObject(name: row.name, database: row.database, kind: kind, detailPending: row.definition == nil)
        }
        guard let definition = GraphReader.definition(of: row) else {
            return SchemaObject(name: row.name, database: row.database, kind: kind, detailPending: true)
        }
        return SchemaObject(
            name: row.name, database: row.database, kind: kind,
            columns: definition.columns.sorted { $0.name < $1.name }.map {
                SchemaObject.Column(name: $0.name, type: $0.type, nullable: $0.nullable, primaryKey: $0.primaryKey)
            },
            indexes: definition.indexes.map { SchemaObject.Index(name: $0.name, columns: $0.columns, unique: $0.unique) },
            foreignKeys: foreignKeys[ObjectKey(database: row.database, name: row.name)] ?? []
        )
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
        // Every step scans every node, and the graph the MCP helper keeps
        // between queries can hold tens of thousands, so the qualified step,
        // which builds and lower-cases a string per node, runs only for a key
        // it can match. A qualified name holds the scalar U+002E between
        // namespace and name, and no other scalar lower-cases to text that
        // holds it or decomposes canonically into it (checked over every
        // scalar with Swift 6.3.3), so a key whose scalars hold no dot matches
        // no qualified name. The test is on scalars: a dot followed by a
        // combining mark is one Character, which `contains(".")` misses.
        if key.unicodeScalars.contains(".") {
            let qualified = allNodes.filter {
                guard let database = $0.database else { return false }
                return "\(database).\($0.name)".lowercased() == key
            }
            if let match = try select(qualified, raw: query, policy: policy) { return match }
        }

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
