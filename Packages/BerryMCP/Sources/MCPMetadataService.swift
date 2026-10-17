import BerryGraph
import BerryStore
import Foundation

/// One connection a project exposes, as an agent sees it. Carries no
/// endpoint detail (host, user, path, region) and no secret: a profile's
/// identity and label are enough to choose it, and everything else stays in
/// the app.
public struct MCPConnectionDescriptor: Codable, Equatable, Sendable {
    /// How many of the connection's stored tables and views have had their
    /// columns read.
    public struct Coverage: Codable, Equatable, Sendable {
        public let detailed: Int
        public let total: Int
    }

    public let id: UUID
    public let name: String
    public let driver: String
    /// "production" or "unlabeled": only a production label is reported, so a
    /// free-form environment name never reaches the agent.
    public let environment: String
    /// What the connection serves: "schema" and "graph" from the store, and
    /// "execute_read_query" when its live reads are on.
    public let capabilities: [String]
    /// The time of the last pass that changed the stored schema, the schema
    /// the graph tools read; nil when there is none or the stored schema
    /// holds no table or view. A pass that found the schema unchanged, or a
    /// refresh of statistics alone, does not move it.
    public let graphHarvestedAt: Date?
    /// When a pass last confirmed the stored schema against the database; nil
    /// when none has.
    public let checkedAt: Date?
    /// Whether the schema was never checked or last checked more than
    /// `GraphReader.staleAfter` ago.
    public let stale: Bool
    /// Why a stale schema was not checked again: the code of the failure
    /// that stopped the profile's last pass, such as `timeout` or
    /// `connection_failed`, one of the fixed `HarvestErrorCode` values and
    /// never text a server wrote. Nil when the schema is not stale or no
    /// failure was recorded.
    public let staleReason: String?
    public let detailCoverage: Coverage
    /// The schemas the harvest is limited to, or nil for the driver's
    /// default scope (`SchemaScope.allUserSchemas`).
    public let scope: [String]?
    /// `"selectSchemas"` when the catalog is too large to harvest whole and
    /// schemas should be selected in the app, else nil.
    public let hint: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, driver, environment, capabilities, graphHarvestedAt, checkedAt, stale, staleReason, detailCoverage
        case scope, hint
    }

    /// Writes every optional field as null when it is nil; the synthesized
    /// encoder would leave the key out, so connections would differ in their
    /// fields depending on whether a schema was harvested.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(driver, forKey: .driver)
        try container.encode(environment, forKey: .environment)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(graphHarvestedAt, forKey: .graphHarvestedAt)
        try container.encode(checkedAt, forKey: .checkedAt)
        try container.encode(stale, forKey: .stale)
        try container.encode(staleReason, forKey: .staleReason)
        try container.encode(detailCoverage, forKey: .detailCoverage)
        try container.encode(scope, forKey: .scope)
        try container.encode(hint, forKey: .hint)
    }
}

/// One schema object found by `searchSchema`.
public struct MCPSchemaMatch: Codable, Equatable, Sendable {
    public let name: String
    public let kind: String
    public let database: String?
    /// The table or view a column or index belongs to; nil for a table or
    /// view.
    public let table: String?
}

/// An answer read from the stored schema, with when that schema was last
/// confirmed against the database and whether that is too long ago to rely
/// on.
public struct MCPAnswer<Value: Sendable>: Sendable {
    public let value: Value
    public let checkedAt: Date?
    public let stale: Bool
}

extension MCPAnswer: Equatable where Value: Equatable {}

/// One page of a connection's schema change feed, oldest change first.
/// `nextSince` is passed back as `since` for the next page and is nil once
/// no entry remains; the feed lists the changes of passes completed by
/// `checkedAt`.
public struct MCPSchemaChanges: Codable, Equatable, Sendable {
    public let changes: [GraphReader.ChangeEntry]
    public let nextSince: String?
    public let checkedAt: Date?
    public let stale: Bool

    private enum CodingKeys: String, CodingKey {
        case changes, nextSince, checkedAt, stale
    }

    /// Writes `nextSince` and `checkedAt` as null when they are nil, so an
    /// agent paging by `nextSince` reads an explicit end rather than a
    /// missing key.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(changes, forKey: .changes)
        try container.encode(nextSince, forKey: .nextSince)
        try container.encode(checkedAt, forKey: .checkedAt)
        try container.encode(stale, forKey: .stale)
    }
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
/// Invariants: it reads only persisted profiles and the stored schema, never
/// opening a database connection or reading a credential; and every method
/// checks that the connection is assigned to the project before any store
/// access, so the error for an unassigned profile is identical to the one for
/// a profile that does not exist and cannot be used to probe for either.
public struct MCPMetadataService: Sendable {
    /// Schema objects returned by one `schema` call.
    static let schemaObjectLimit = 200
    /// Estimated bytes of one full `schema` page: half the 1 MiB ceiling on a
    /// tool result, so the page's own keys and an estimate that runs short
    /// still leave it below the ceiling.
    static let schemaPageBytes = 512 * 1024
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
    /// The saved driver IDs a live read runs on, with the dialect the read
    /// policy checks their statements in. MariaDB profiles use `mysql`.
    static let liveReadDialects: [String: MCPSQLDialect] = ["postgres": .postgresql, "mysql": .mysql, "sqlite": .sqlite]

    private let profiles: @Sendable () throws -> [ConnectionProfile]
    private let reader: GraphReader
    private let graph: BerryGraphQueryService
    private let cache: TableGraphCache?

    /// - Parameters:
    ///   - profiles: Reads the saved connection profiles; called once per
    ///     `listConnections`.
    ///   - reader: Reads the stored schema: state, listings, search and the
    ///     change feed.
    ///   - graph: Runs graph queries, statistics and schema listings.
    public init(
        profiles: @escaping @Sendable () throws -> [ConnectionProfile], reader: GraphReader, graph: BerryGraphQueryService
    ) {
        self.init(profiles: profiles, reader: reader, graph: graph, cache: nil)
    }

    /// Reads `store`: its saved profiles and each profile's stored schema.
    /// The graph operations take their table-level graph from a
    /// `TableGraphCache`, so a run of graph queries on one connection builds
    /// it once.
    public init(store: BerryStore) {
        let reader = GraphReader(store: store)
        let cache = TableGraphCache(reader: reader)
        self.init(
            profiles: { try store.allProfiles() }, reader: reader,
            graph: BerryGraphQueryService(reader: reader, tableGraph: { try cache.graph(profileID: $0) }),
            cache: cache
        )
    }

    private init(
        profiles: @escaping @Sendable () throws -> [ConnectionProfile], reader: GraphReader,
        graph: BerryGraphQueryService, cache: TableGraphCache?
    ) {
        self.profiles = profiles
        self.reader = reader
        self.graph = graph
        self.cache = cache
    }

    /// Drops the cached table-level graphs, for when the system asks for
    /// memory back; the next graph query builds its graph again.
    public func dropCachedGraphs() {
        cache?.dropAll()
    }

    /// The project's connections, in the project's order, each with the
    /// state of its stored schema. A profile deleted since it was assigned is
    /// skipped.
    ///
    /// `graphHarvestedAt` is nil while the stored schema holds no table or
    /// view, because the graph tools then answer that no graph was
    /// harvested: a pass that found none must not be reported as one.
    public func listConnections(in project: MCPVerifiedProject) throws -> [MCPConnectionDescriptor] {
        let saved = try savedProfiles()
        let live = Self.liveReadConnectionIDs(in: project, saved: saved)
        return try project.project.profiles.compactMap { access in
            guard let profile = saved[access.profileID] else { return nil }
            let state = try reader.state(profileID: profile.id)
            return MCPConnectionDescriptor(
                id: profile.id,
                name: profile.name,
                driver: profile.driverID,
                environment: profile.envColor == "production" ? "production" : "unlabeled",
                capabilities: live.contains(profile.id) ? ["schema", "graph", "execute_read_query"] : ["schema", "graph"],
                graphHarvestedAt: state.objectCount > 0 ? state.changedAt : nil,
                checkedAt: state.checkedAt,
                stale: state.stale,
                staleReason: state.stale ? state.lastErrorCode.flatMap { HarvestErrorCode(rawValue: $0)?.rawValue } : nil,
                detailCoverage: .init(detailed: state.detailedCount, total: state.objectCount),
                scope: state.selectedSchemas,
                hint: state.hint
            )
        }
    }

    /// The project's connections a live read can run on: the switch
    /// verified on (`liveReadProfileIDs`), the profile assigned to the
    /// project and still saved, and its driver one with a SQL dialect.
    public func liveReadConnectionIDs(in project: MCPVerifiedProject) throws -> Set<UUID> {
        Self.liveReadConnectionIDs(in: project, saved: try savedProfiles())
    }

    /// The SQL dialect of a saved profile's driver, nil for a driver
    /// without one. Throws `unknownConnection` when no such profile is
    /// saved; callers check that the profile is assigned first.
    public func dialect(of profileID: UUID) throws -> MCPSQLDialect? {
        guard let profile = try profiles().first(where: { $0.id == profileID }) else {
            throw MCPMetadataError.unknownConnection
        }
        return Self.liveReadDialects[profile.driverID]
    }

    private func savedProfiles() throws -> [UUID: ConnectionProfile] {
        Dictionary(try profiles().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func liveReadConnectionIDs(
        in project: MCPVerifiedProject, saved: [UUID: ConnectionProfile]
    ) -> Set<UUID> {
        Set(project.project.profiles.map(\.profileID).filter { id in
            guard project.liveReadProfileIDs.contains(id), let profile = saved[id] else { return false }
            return liveReadDialects[profile.driverID] != nil
        })
    }

    /// One page of a connection's tables and views from `offset` on: at most
    /// 200, and for full detail as many as fit an estimated 512 KB, though
    /// never fewer than one. The listing reports how many matched in all and
    /// the offset of the next page. `objectNames` takes at most 50 names.
    public func schema(
        in project: MCPVerifiedProject, connectionID: UUID, objectNames: [String]?,
        detail: BerryGraphQueryService.SchemaDetail, offset: Int = 0
    ) throws -> BerryGraphQueryService.SchemaListing {
        try requireAssigned(connectionID, in: project)
        if let objectNames, objectNames.count > Self.maximumObjectNames {
            throw MCPMetadataError.invalidArgument("At most \(Self.maximumObjectNames) object names")
        }
        return try mappingErrors(connectionID) {
            try graph.schema(
                profileID: connectionID, objectNames: objectNames, detail: detail,
                offset: offset, limit: Self.schemaObjectLimit, maxBytes: Self.schemaPageBytes
            )
        }
    }

    /// Case-insensitive substring search over table, view, column and index
    /// names. `query` is trimmed and must be 1 to 200 characters; `limit` is
    /// clamped to 1...200. Results are ordered by kind (table, view, column,
    /// index), then database, owning table and name.
    public func searchSchema(
        in project: MCPVerifiedProject, connectionID: UUID, query: String, limit: Int
    ) throws -> MCPAnswer<[MCPSchemaMatch]> {
        try requireAssigned(connectionID, in: project)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... Self.maximumQueryLength).contains(needle.count) else {
            throw MCPMetadataError.invalidArgument("Query must be 1 to \(Self.maximumQueryLength) characters")
        }
        let state = try reader.state(profileID: connectionID)
        guard state.objectCount > 0 else { throw MCPMetadataError.noSnapshot }
        let matches = try reader.search(
            profileID: connectionID, needle: needle, limit: min(max(limit, 1), Self.maximumSearchResults)
        )
        return MCPAnswer(
            value: matches.map { MCPSchemaMatch(name: $0.name, kind: $0.kind, database: $0.database, table: $0.table) },
            checkedAt: state.checkedAt, stale: state.stale
        )
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
    ) throws -> MCPAnswer<MCPGraphResult> {
        try requireAssigned(connectionID, in: project)
        let state = try reader.state(profileID: connectionID)
        let result: MCPGraphResult = try mappingErrors(connectionID) {
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
        return MCPAnswer(value: result, checkedAt: state.checkedAt, stale: state.stale)
    }

    /// Harvested statistics: every table when `object` is nil, otherwise one
    /// table and its indexes, resolved strictly.
    ///
    /// The summary lists the first 500 tables by name and the unused indexes
    /// of those tables, at most 500 names in name order; the result has no
    /// truncation marker.
    public func graphStats(
        in project: MCPVerifiedProject, connectionID: UUID, object: String?
    ) throws -> MCPAnswer<MCPGraphStats> {
        try requireAssigned(connectionID, in: project)
        let state = try reader.state(profileID: connectionID)
        let stats: MCPGraphStats = try mappingErrors(connectionID) {
            if let object {
                return .table(try graph.statistics(profileID: connectionID, table: object, resolution: .strict))
            }
            let summary = try graph.statistics(profileID: connectionID, limit: Self.maximumGraphNames)
            return .summary(.init(
                tables: summary.tables,
                unusedIndexes: Array(summary.unusedIndexes.prefix(Self.maximumGraphNames))
            ))
        }
        return MCPAnswer(value: stats, checkedAt: state.checkedAt, stale: state.stale)
    }

    /// The schema changes recorded for a connection from `since` on, at most
    /// `limit` entries, clamped to 1...200. `since` is nil for every change,
    /// an ISO 8601 time, or the `nextSince` of an earlier page. A connection
    /// whose schema was never checked has no changes yet, which is an empty
    /// page rather than an error.
    ///
    /// A `since` that is neither is an argument error whose text does not
    /// repeat it.
    public func schemaChanges(
        in project: MCPVerifiedProject, connectionID: UUID, since: String?, limit: Int
    ) throws -> MCPSchemaChanges {
        try requireAssigned(connectionID, in: project)
        let page: GraphReader.ChangePage
        do {
            page = try reader.changes(profileID: connectionID, since: since, limit: limit)
        } catch is GraphReader.InvalidChangeCursor {
            throw MCPMetadataError.invalidArgument("Invalid since cursor")
        }
        return MCPSchemaChanges(
            changes: page.entries, nextSince: page.nextSince, checkedAt: page.checkedAt,
            stale: GraphReader.isStale(checkedAt: page.checkedAt, now: Date())
        )
    }

    private func requireAssigned(_ connectionID: UUID, in project: MCPVerifiedProject) throws {
        guard project.project.profiles.contains(where: { $0.profileID == connectionID }) else {
            throw MCPMetadataError.unknownConnection
        }
    }

    /// Maps graph query errors to agent-facing ones. An ambiguous name is
    /// answered from the graph read again, because the graph service's own
    /// message lists every match, unbounded, by a qualified name that can
    /// itself be ambiguous: a table and a view of one name in one schema
    /// share it, and a table name used in a thousand schemas gives a
    /// thousand matches.
    private func mappingErrors<T>(_ connectionID: UUID, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as BerryGraphQueryService.QueryError {
            switch error {
            case .noSnapshot:
                throw MCPMetadataError.noSnapshot
            case .nodeNotFound:
                throw MCPMetadataError.notFound(error.localizedDescription)
            case let .ambiguousNode(name, _):
                let graph = try cache?.graph(profileID: connectionID) ?? reader.tableGraph(profileID: connectionID)
                throw MCPMetadataError.notFound(Self.ambiguityMessage(for: name, in: graph))
            }
        }
    }

    /// What to tell the agent when `name` matched several nodes: the tables
    /// and views it matched, each by a name that resolves to that one node
    /// alone, at most `maximumDiagnosticNames` of them and a count of the
    /// rest. A qualified name is offered when it resolves to its node alone,
    /// otherwise the node's stable id, which always does; no two suggestions
    /// are therefore alike. Columns and indexes are never offered, since
    /// graph operations and statistics work on tables and views; a name that
    /// matched only those, which a graph service built from a whole graph
    /// can hold, is answered with that rule instead.
    static func ambiguityMessage(for name: String, in graph: SchemaGraph) -> String {
        let lookup = StrictLookup(graph)
        let candidates = lookup.matches(name)
            .filter { $0.kind == .table || $0.kind == .view }
            .sorted { (StrictLookup.qualifiedName($0), $0.id) < (StrictLookup.qualifiedName($1), $1.id) }
        guard !candidates.isEmpty else {
            return "Node '\(name)' names columns or indexes, not a table or view. Pass a table or view name."
        }
        let offered = candidates.map { node in
            let qualified = StrictLookup.qualifiedName(node)
            return lookup.matches(qualified) == [node] ? qualified : node.id
        }
        let listed = offered.prefix(BerryGraphQueryService.maximumDiagnosticNames)
        let rest = offered.count - listed.count
        let more = rest > 0 ? ", and \(rest) more" : ""
        return "Node '\(name)' is ambiguous. Use one of: \(listed.joined(separator: ", "))\(more)"
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

/// The nodes a name matches under the graph service's strict resolution,
/// indexed once so that checking every suggestion stays linear in the graph.
///
/// Mirrors the order `BerryGraphQueryService` resolves a name in: the name
/// trimmed as an exact stable id, then as a qualified `database.name`, then
/// as a table or view name, then as any node name, the last three ignoring
/// letter case. The first step with a match decides, and more than one match
/// there is ambiguous. The tests check every suggestion against the service
/// itself, so a change to that order shows up there.
private struct StrictLookup {
    private let graph: SchemaGraph
    private let byQualifiedName: [String: [GraphNode]]
    private let tablesAndViewsByName: [String: [GraphNode]]
    private let byName: [String: [GraphNode]]

    init(_ graph: SchemaGraph) {
        self.graph = graph
        var byQualifiedName: [String: [GraphNode]] = [:]
        var tablesAndViewsByName: [String: [GraphNode]] = [:]
        var byName: [String: [GraphNode]] = [:]
        for node in graph.nodes.values {
            let name = node.name.lowercased()
            if let database = node.database {
                byQualifiedName["\(database).\(node.name)".lowercased(), default: []].append(node)
            }
            if node.kind == .table || node.kind == .view {
                tablesAndViewsByName[name, default: []].append(node)
            }
            byName[name, default: []].append(node)
        }
        self.byQualifiedName = byQualifiedName
        self.tablesAndViewsByName = tablesAndViewsByName
        self.byName = byName
    }

    /// The nodes of the first resolution step that `raw` matches; empty
    /// when it matches none.
    func matches(_ raw: String) -> [GraphNode] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = graph.nodes[query] { return [exact] }
        let key = query.lowercased()
        return byQualifiedName[key] ?? tablesAndViewsByName[key] ?? byName[key] ?? []
    }

    /// `database.name`, or the bare name of a node without a database, as
    /// the graph service lists matches.
    static func qualifiedName(_ node: GraphNode) -> String {
        node.database.map { "\($0).\(node.name)" } ?? node.name
    }
}
