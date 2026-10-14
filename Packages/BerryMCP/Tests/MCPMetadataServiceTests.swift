import BerryGraph
import Foundation
import GRDB
import Testing

@testable import BerryMCP
@testable import BerryStore

/// Counts invocations of the service's injected sources so a test can prove
/// which store reads a call did or did not make.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func bump(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[key, default: 0] += 1
    }

    func count(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.values.reduce(0, +)
    }
}

/// A stored schema written the way a harvest pass writes it: the listing of
/// tables, views and foreign keys, then the definitions of the objects whose
/// columns were read, then the statistics.
struct SchemaSeed {
    var objects: [SchemaListedObject] = []
    var relations: [SchemaListedRelation] = []
    var definitions: [SchemaDetailWrite] = []
    var stats: [(database: String?, name: String, rows: Int64?, sizeBytes: Int64?, indexStats: String?)] = []

    static func column(_ name: String, _ type: String = "int", nullable: Bool = false, primaryKey: Bool = false)
        -> SchemaDefinition.Column {
        SchemaDefinition.Column(name: name, type: type, nullable: nullable, defaultValue: nil, primaryKey: primaryKey)
    }

    static func definition(
        _ name: String, in database: String? = nil, kind: String = "table",
        columns: [SchemaDefinition.Column], indexes: [SchemaDefinition.Index] = []
    ) throws -> SchemaDetailWrite {
        let definition = SchemaDefinition(columns: columns, indexes: indexes)
        return SchemaDetailWrite(
            database: database, name: name, kind: kind, fingerprint: nil, definitionHash: definition.hash,
            definition: try definition.json(), columnText: definition.columnText, indexText: definition.indexText
        )
    }

    /// A table, with a definition when `columns` is given and pending otherwise.
    mutating func table(
        _ name: String, in database: String? = nil, columns: [SchemaDefinition.Column]? = nil,
        indexes: [SchemaDefinition.Index] = []
    ) throws {
        objects.append(SchemaListedObject(database: database, name: name, kind: "table", fingerprint: nil))
        if let columns {
            definitions.append(try Self.definition(name, in: database, columns: columns, indexes: indexes))
        }
    }

    /// A view whose columns were never read.
    mutating func view(_ name: String, in database: String? = nil) {
        objects.append(SchemaListedObject(database: database, name: name, kind: "view", fingerprint: nil))
    }

    /// `source.column` referencing `target.targetColumn`, both in `database`.
    mutating func reference(
        _ source: String, _ column: String, _ target: String, _ targetColumn: String = "id", in database: String? = nil
    ) {
        relations.append(SchemaListedRelation(
            srcDatabase: database, srcName: source, srcColumn: column,
            dstDatabase: database, dstName: target, dstColumn: targetColumn, constraintName: nil
        ))
    }

    /// Writes the seed as one pass at `at` and records that pass as the last
    /// change and, when `checkedAt` is given, the last check.
    func write(to store: BerryStore, profileID: UUID, at: Date, checkedAt: Date?) throws {
        let listing = try store.applySchemaListing(profileID: profileID, objects: objects, relations: relations, now: at)
        _ = try store.applySchemaDetails(profileID: profileID, details: definitions, now: at, changeID: listing.changeID)
        try store.replaceSchemaStats(profileID: profileID, rows: stats.map {
            SchemaStatsRecord(
                profileID: profileID, database: $0.database, name: $0.name, rows: $0.rows, sizeBytes: $0.sizeBytes,
                indexStats: $0.indexStats, updatedAt: at
            )
        })
        try store.updateSchemaGraphState(profileID: profileID) {
            $0.lastChangedAt = at
            $0.lastCheckedAt = checkedAt
        }
    }

    /// `orders` references `customers`; both have an `id` column, `customers`
    /// has a unique index on `email`, and the view `recent_orders` has never
    /// had its columns read.
    static func shop() throws -> SchemaSeed {
        var seed = SchemaSeed()
        try seed.table("orders", columns: [column("id", primaryKey: true), column("customer_id")])
        try seed.table(
            "customers", columns: [column("id", primaryKey: true), column("email", "text", nullable: true)],
            indexes: [SchemaDefinition.Index(name: "customers_email_key", unique: true, columns: ["email"])]
        )
        seed.view("recent_orders")
        seed.reference("orders", "customer_id", "customers")
        return seed
    }

    /// Tables with no columns read, named as `names` lists them.
    static func tables(_ names: [String], in database: String? = nil) throws -> SchemaSeed {
        var seed = SchemaSeed()
        for name in names { try seed.table(name, in: database) }
        return seed
    }
}

/// Removes the table every metadata read starts from, so any store access
/// fails with a database error rather than an answer.
func breakSchemaReads(of store: BerryStore) throws {
    try #require(store.dbQueue).write { try $0.execute(sql: "DROP TABLE schema_graph_state") }
}

@Suite("MCP metadata service")
struct MCPMetadataServiceTests {
    static let harvestTime = Date(timeIntervalSince1970: 1_700_000_000)

    let production = ConnectionProfile(
        driverID: "postgres", name: "Shop", envColor: "production",
        host: "db.internal.example", username: "svc_reader_account"
    )
    let staging = ConnectionProfile(
        driverID: "mysql", name: "Staging", sortOrder: 1,
        host: "staging.internal.example", port: 3306, username: "stage_user_account"
    )
    let outsider = ConnectionProfile(driverID: "sqlite", name: "Outside", sortOrder: 2, filePath: "/secret/outside.db")

    var project: MCPVerifiedProject {
        MCPVerifiedProject(
            project: MCPProject(
                name: "P", isEnabled: true,
                profiles: [
                    MCPProfileAccess(profileID: production.id),
                    MCPProfileAccess(profileID: staging.id),
                ]
            ),
            liveReadProfileIDs: []
        )
    }

    /// A store holding all three profiles, with `seed` (the shop schema
    /// unless given) written for the production profile only, harvested at
    /// `harvestTime` and checked at `checkedAt`.
    func makeStore(seed: SchemaSeed? = nil, checkedAt: Date? = Date()) throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        for profile in [production, staging, outsider] {
            try store.save(profile)
        }
        try (seed ?? SchemaSeed.shop()).write(to: store, profileID: production.id, at: Self.harvestTime, checkedAt: checkedAt)
        return store
    }

    /// A service over `store` (a fresh `makeStore()` unless given) that
    /// counts its profile reads and the table graphs its graph operations
    /// build.
    func makeService(
        seed: SchemaSeed? = nil, store: BerryStore? = nil, counter: CallCounter = CallCounter()
    ) throws -> MCPMetadataService {
        let store = try store ?? makeStore(seed: seed)
        let reader = GraphReader(store: store)
        return MCPMetadataService(
            profiles: {
                counter.bump("profiles")
                return try store.allProfiles()
            },
            reader: reader,
            graph: BerryGraphQueryService(reader: reader, tableGraph: {
                counter.bump("graph.load")
                return try reader.tableGraph(profileID: $0)
            })
        )
    }

    @Test func listConnectionsHidesEndpointDetails() throws {
        let descriptors = try makeService().listConnections(in: project)
        #expect(descriptors.map(\.id) == [production.id, staging.id])
        #expect(descriptors.map(\.environment) == ["production", "unlabeled"])
        #expect(descriptors.map(\.name) == ["Shop", "Staging"])
        #expect(descriptors.map(\.driver) == ["postgres", "mysql"])
        #expect(descriptors.allSatisfy { $0.capabilities == ["schema", "graph"] })
        #expect(descriptors.map(\.graphHarvestedAt) == [Self.harvestTime, nil])

        let encoder = JSONEncoder()
        let json = String(decoding: try encoder.encode(descriptors), as: UTF8.self)
        for secret in ["db.internal.example", "svc_reader_account", "staging.internal.example", "stage_user_account", "/secret"] {
            #expect(!json.contains(secret))
        }
    }

    /// A pass that found no tables or views still records a change, and the
    /// graph tools then answer that no graph was harvested; the connection
    /// must not claim a harvest time the tools contradict.
    @Test func aConnectionCountsAsHarvestedOnlyWhileItsStoredSchemaHoldsObjects() throws {
        let store = try BerryStore(path: ":memory:")
        for profile in [production, staging] {
            try store.save(profile)
        }
        let emptied = Self.harvestTime.addingTimeInterval(60)
        try SchemaSeed.shop().write(to: store, profileID: production.id, at: Self.harvestTime, checkedAt: Self.harvestTime)
        try SchemaSeed().write(to: store, profileID: production.id, at: emptied, checkedAt: emptied)
        try SchemaSeed.shop().write(to: store, profileID: staging.id, at: emptied, checkedAt: emptied)
        let service = MCPMetadataService(store: store)

        let descriptors = try service.listConnections(in: project)
        #expect(descriptors.map(\.graphHarvestedAt) == [nil, emptied])
        #expect(throws: MCPMetadataError.noSnapshot) {
            try service.graphStats(in: project, connectionID: production.id, object: nil)
        }
        let listing = try service.schema(in: project, connectionID: staging.id, objectNames: nil, detail: .overview)
        #expect(listing.harvestedAt == emptied)
    }

    @Test func listConnectionsSkipsProfilesThatNoLongerExistAndReadsProfilesOnce() throws {
        let counter = CallCounter()
        let vanished = MCPProfileAccess(profileID: UUID())
        let withVanished = MCPVerifiedProject(
            project: MCPProject(
                name: "P", isEnabled: true,
                profiles: [vanished, MCPProfileAccess(profileID: staging.id), MCPProfileAccess(profileID: production.id)]
            ),
            liveReadProfileIDs: []
        )
        let descriptors = try makeService(counter: counter).listConnections(in: withVanished)
        #expect(descriptors.map(\.id) == [staging.id, production.id])
        #expect(counter.count("profiles") == 1)
    }

    /// Listing connections reads each connection's state row and nothing else
    /// of its schema: no object, relation, statistics or change row, so the
    /// listing costs a point read per connection however large the schemas.
    @Test func listConnectionsReadsOnlyEachConnectionsStateRow() throws {
        let store = try makeStore()
        let log = CallCounter()
        let queue = try #require(store.dbQueue)
        queue.inDatabase { db in
            db.trace { event in
                guard case let .statement(statement) = event else { return }
                for table in ["schema_graph_state", "schema_object", "schema_relation", "schema_stats", "schema_change"]
                where statement.sql.contains(table + "\"") || statement.sql.contains(table + " ") {
                    log.bump(table)
                }
            }
        }
        defer { queue.inDatabase { $0.trace(options: .statement, nil) } }

        _ = try makeService(store: store).listConnections(in: project)

        #expect(log.count("schema_graph_state") == project.project.profiles.count)
        for table in ["schema_object", "schema_relation", "schema_stats", "schema_change"] {
            #expect(log.count(table) == 0, "\(table) was read")
        }
    }

    @Test func listConnectionsReportsCoverageScopeAndHint() throws {
        let store = try makeStore()
        try store.updateSchemaGraphState(profileID: production.id) {
            $0.selectedSchemas = #"["public","billing"]"#
            $0.hint = "selectSchemas"
        }
        let descriptors = try makeService(store: store).listConnections(in: project)
        let shop = try #require(descriptors.first)
        #expect(shop.detailCoverage == .init(detailed: 2, total: 3))
        #expect(shop.scope == ["public", "billing"])
        #expect(shop.hint == "selectSchemas")
        #expect(shop.stale == false)
        #expect(shop.checkedAt != nil)

        let unharvested = try #require(descriptors.last)
        #expect(unharvested.detailCoverage == .init(detailed: 0, total: 0))
        #expect(unharvested.scope == nil)
        #expect(unharvested.hint == nil)
        #expect(unharvested.checkedAt == nil)
        #expect(unharvested.stale)

        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(unharvested)) as? [String: Any]
        )
        for key in ["graphHarvestedAt", "checkedAt", "scope", "hint"] {
            #expect(json[key] is NSNull, "\(key)")
        }
    }

    /// Any store access before the membership check would fail with a
    /// database error here, so getting the membership error proves there
    /// was none.
    @Test func unassignedAndNonexistentConnectionsGiveTheSameError() throws {
        let counter = CallCounter()
        let store = try makeStore()
        try breakSchemaReads(of: store)
        let service = try makeService(store: store, counter: counter)
        let project = self.project
        let expected = MCPMetadataError.unknownConnection

        for id in [outsider.id, UUID()] {
            #expect(throws: expected) {
                try service.schema(in: project, connectionID: id, objectNames: nil, detail: .overview)
            }
            #expect(throws: expected) {
                try service.searchSchema(in: project, connectionID: id, query: "id", limit: 10)
            }
            for operation in [
                MCPGraphOperation.neighbors(node: "orders"),
                .path(from: "orders", to: "customers"),
                .blastRadius(node: "customers"),
                .circularDependencies,
                .topCentrality(limit: 5),
            ] {
                #expect(throws: expected) {
                    try service.graphQuery(in: project, connectionID: id, operation: operation)
                }
            }
            #expect(throws: expected) {
                try service.graphStats(in: project, connectionID: id, object: nil)
            }
            #expect(throws: expected) {
                try service.graphStats(in: project, connectionID: id, object: "orders")
            }
            #expect(throws: expected) {
                try service.schemaChanges(in: project, connectionID: id, since: nil, limit: 50)
            }
        }
        #expect(counter.total == 0)
        #expect(MCPMetadataError.unknownConnection.description == "Unknown connection for this project")
    }

    @Test func membershipIsCheckedBeforeArgumentValidation() throws {
        let service = try makeService()
        #expect(throws: MCPMetadataError.unknownConnection) {
            try service.searchSchema(in: project, connectionID: outsider.id, query: "", limit: 10)
        }
        #expect(throws: MCPMetadataError.unknownConnection) {
            try service.schema(
                in: project, connectionID: outsider.id,
                objectNames: Array(repeating: "t", count: 51), detail: .overview
            )
        }
        #expect(throws: MCPMetadataError.unknownConnection) {
            try service.schemaChanges(in: project, connectionID: outsider.id, since: "not a cursor", limit: 50)
        }
    }

    @Test func errorTextsAreExact() {
        #expect(MCPMetadataError.noSnapshot.description
            == "No schema graph has been harvested for this connection. Open it in BerryDB to refresh.")
        #expect(MCPMetadataError.notFound("missing").description == "missing")
        #expect(MCPMetadataError.invalidArgument("bad").description == "bad")
    }

    @Test func schemaOfUnharvestedConnectionIsNoSnapshot() throws {
        let service = try makeService()
        #expect(throws: MCPMetadataError.noSnapshot) {
            try service.schema(in: project, connectionID: staging.id, objectNames: nil, detail: .full)
        }
        #expect(throws: MCPMetadataError.noSnapshot) {
            try service.searchSchema(in: project, connectionID: staging.id, query: "id", limit: 10)
        }
        #expect(throws: MCPMetadataError.noSnapshot) {
            try service.graphQuery(in: project, connectionID: staging.id, operation: .circularDependencies)
        }
        #expect(throws: MCPMetadataError.noSnapshot) {
            try service.graphStats(in: project, connectionID: staging.id, object: nil)
        }
    }

    @Test func schemaReturnsColumnsForFullDetail() throws {
        let listing = try makeService().schema(
            in: project, connectionID: production.id, objectNames: ["ORDERS"], detail: .full
        )
        #expect(listing.objects.map(\.name) == ["orders"])
        #expect(listing.omittedCount == 0)
        #expect(listing.harvestedAt == Self.harvestTime)
        #expect(listing.objects[0].columns.map(\.name) == ["customer_id", "id"])
        #expect(listing.objects[0].foreignKeys.map(\.referencedTable) == ["customers"])
    }

    @Test func schemaRejectsMoreThanFiftyObjectNames() throws {
        let service = try makeService()
        let fifty = (0 ..< 50).map { "t\($0)" }
        _ = try service.schema(in: project, connectionID: production.id, objectNames: fifty, detail: .overview)
        #expect(throws: MCPMetadataError.invalidArgument("At most 50 object names")) {
            try service.schema(in: project, connectionID: production.id, objectNames: fifty + ["extra"], detail: .overview)
        }
    }

    @Test func schemaCapsListingAtTwoHundredObjects() throws {
        let service = try makeService(seed: SchemaSeed.tables((0 ..< 230).map { "t\($0)" }, in: "db"))
        let listing = try service.schema(in: project, connectionID: production.id, objectNames: nil, detail: .overview)
        #expect(listing.objects.count == 200)
        #expect(listing.omittedCount == 30)
        #expect(listing.total == 230)
        #expect(listing.nextOffset == 200)
    }

    @Test func schemaPagesFromAnOffset() throws {
        let service = try makeService(seed: SchemaSeed.tables((0 ..< 230).map { String(format: "t%03d", $0) }, in: "db"))
        let last = try service.schema(
            in: project, connectionID: production.id, objectNames: nil, detail: .overview, offset: 200
        )
        #expect(last.objects.first?.name == "t200")
        #expect(last.objects.count == 30)
        #expect(last.total == 230)
        #expect(last.nextOffset == nil)
        #expect(last.omittedCount == 0)

        let shop = try makeService().schema(
            in: project, connectionID: production.id, objectNames: nil, detail: .overview, offset: 1
        )
        #expect(shop.objects.map(\.name) == ["orders", "recent_orders"])
        #expect(shop.objects.map(\.detailPending) == [false, true])
        #expect(shop.total == 3)
        #expect(shop.nextOffset == nil)
    }

    /// Every answer read from the stored schema says when that schema was
    /// last checked, and is stale while no pass has checked it.
    @Test func answersAreStaleUntilAPassChecksTheSchema() throws {
        let store = try makeStore(checkedAt: nil)
        let service = try makeService(store: store)
        let id = production.id
        #expect(try service.schema(in: project, connectionID: id, objectNames: nil, detail: .overview).stale)
        #expect(try service.searchSchema(in: project, connectionID: id, query: "id", limit: 10).stale)
        #expect(try service.graphQuery(in: project, connectionID: id, operation: .circularDependencies).stale)
        #expect(try service.graphStats(in: project, connectionID: id, object: nil).stale)
        #expect(try service.listConnections(in: project).first?.stale == true)
        #expect(try service.schemaChanges(in: project, connectionID: id, since: nil, limit: 50).stale)

        // Whole seconds, which the store keeps exactly.
        let checked = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try store.updateSchemaGraphState(profileID: id) { $0.lastCheckedAt = checked }
        let listing = try service.schema(in: project, connectionID: id, objectNames: nil, detail: .overview)
        #expect(!listing.stale)
        #expect(listing.checkedAt == checked)
        let search = try service.searchSchema(in: project, connectionID: id, query: "id", limit: 10)
        #expect(search.checkedAt == checked && !search.stale)
        let graph = try service.graphQuery(in: project, connectionID: id, operation: .circularDependencies)
        #expect(graph.checkedAt == checked && !graph.stale)
        let stats = try service.graphStats(in: project, connectionID: id, object: nil)
        #expect(stats.checkedAt == checked && !stats.stale)
        let changes = try service.schemaChanges(in: project, connectionID: id, since: nil, limit: 50)
        #expect(changes.checkedAt == checked && !changes.stale)
    }

    @Test func schemaChangesListTheFirstPassThenAChangedTableWithItsDiff() throws {
        let store = try makeStore(checkedAt: Self.harvestTime)
        let service = try makeService(store: store)
        let first = try service.schemaChanges(in: project, connectionID: production.id, since: nil, limit: 50)
        #expect(first.changes.map(\.kind) == [.added, .added, .added, .relationAdded])
        #expect(first.changes.map(\.name) == ["customers", "orders", "recent_orders", "orders"])
        #expect(first.nextSince == nil)
        #expect(first.checkedAt == Self.harvestTime)

        let later = Self.harvestTime.addingTimeInterval(120)
        let orders = try SchemaSeed.definition("orders", columns: [
            SchemaSeed.column("id", primaryKey: true), SchemaSeed.column("customer_id"),
            SchemaSeed.column("note", "text", nullable: true),
        ])
        _ = try store.applySchemaDetails(profileID: production.id, details: [orders], now: later, changeID: nil)
        try store.updateSchemaGraphState(profileID: production.id) { $0.lastCheckedAt = later }

        let all = try service.schemaChanges(in: project, connectionID: production.id, since: nil, limit: 50)
        let changed = try #require(all.changes.last)
        #expect(changed.kind == .changed)
        #expect(changed.name == "orders")
        #expect(changed.at == later)
        #expect(changed.diff?.columnsAdded == ["note"])
        #expect(changed.diff?.columnsRemoved == [])
    }

    @Test func schemaChangesContinueFromNextSince() throws {
        let service = try makeService()
        let first = try service.schemaChanges(in: project, connectionID: production.id, since: nil, limit: 3)
        #expect(first.changes.map(\.name) == ["customers", "orders", "recent_orders"])
        let next = try #require(first.nextSince)

        let rest = try service.schemaChanges(in: project, connectionID: production.id, since: next, limit: 3)
        #expect(rest.changes.map(\.kind) == [.relationAdded])
        #expect(rest.changes.first?.relation == "orders.customer_id -> customers.id")
        #expect(rest.nextSince == nil)
    }

    /// A cursor whose entry offset no change can reach is an argument error,
    /// not an overflow that ends the helper.
    @Test func aSinceWithAnUnreachableOffsetIsAnArgumentError() throws {
        let service = try makeService()
        let first = try service.schemaChanges(in: project, connectionID: production.id, since: nil, limit: 1)
        let next = try #require(first.nextSince)
        let change = try #require(next.split(separator: ":").dropFirst().first)
        let since = "id:\(change):o1i\(Int.max)"
        #expect(since.count <= 64)
        #expect(throws: MCPMetadataError.invalidArgument("Invalid since cursor")) {
            try service.schemaChanges(in: project, connectionID: production.id, since: since, limit: 50)
        }
    }

    @Test func anInvalidSinceIsAnArgumentErrorThatDoesNotRepeatIt() throws {
        let service = try makeService()
        // `id:1:2`, a change and an entry offset, is the form an earlier
        // build wrote.
        for since in ["yesterday", "id:x", "id:1:-2", "2026-13-45", "id:1:2"] {
            do {
                _ = try service.schemaChanges(in: project, connectionID: production.id, since: since, limit: 50)
                Issue.record("expected an argument error for \(since)")
            } catch let error as MCPMetadataError {
                #expect(error == .invalidArgument("Invalid since cursor"))
                #expect(!error.description.contains(since))
            }
        }
    }

    @Test func searchMatchesColumnsCaseInsensitivelyAndCapsLimit() throws {
        let service = try makeService()
        let matches = try service.searchSchema(in: project, connectionID: production.id, query: "ID", limit: 1000).value
        #expect(matches.count <= 200)
        let columns = matches.filter { $0.kind == "column" }
        #expect(columns.contains(MCPSchemaMatch(name: "id", kind: "column", database: nil, table: "orders")))
        #expect(columns.contains(MCPSchemaMatch(name: "id", kind: "column", database: nil, table: "customers")))
        #expect(columns.contains { $0.name == "customer_id" && $0.table == "orders" })
        // Ordered by kind (table, view, column, index), then database, table, name.
        #expect(columns.map { "\($0.table ?? "").\($0.name)" } == ["customers.id", "orders.customer_id", "orders.id"])

        let one = try service.searchSchema(in: project, connectionID: production.id, query: "id", limit: 1).value
        #expect(one.count == 1)
        let clamped = try service.searchSchema(in: project, connectionID: production.id, query: "id", limit: -5).value
        #expect(clamped.count == 1)
    }

    @Test func searchReturnsExactlyTwoHundredWhenMoreMatch() throws {
        let service = try makeService(seed: SchemaSeed.tables((0 ..< 250).map { "item\($0)" }, in: "db"))
        let matches = try service.searchSchema(in: project, connectionID: production.id, query: "item", limit: 1000).value
        #expect(matches.count == 200)
        let fewer = try service.searchSchema(in: project, connectionID: production.id, query: "item", limit: 7).value
        #expect(fewer.count == 7)
    }

    @Test func searchOrdersKindsAndNamesTheOwnerOfColumnsAndIndexesOnly() throws {
        let matches = try makeService()
            .searchSchema(in: project, connectionID: production.id, query: "o", limit: 50).value
        let kinds = matches.map(\.kind)
        let order = ["table", "view", "column", "index"]
        #expect(kinds == kinds.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        #expect(matches.filter { $0.kind == "table" || $0.kind == "view" }.allSatisfy { $0.table == nil })
        #expect(matches.filter { $0.kind == "column" || $0.kind == "index" }.allSatisfy { $0.table != nil })
        #expect(matches.contains(MCPSchemaMatch(name: "customers_email_key", kind: "index", database: nil, table: "customers")))
        #expect(matches.first?.kind == "table")
    }

    @Test func searchRejectsEmptyAndOverlongQueries() throws {
        let service = try makeService()
        for query in ["", "   \n"] {
            #expect(throws: MCPMetadataError.self) {
                try service.searchSchema(in: project, connectionID: production.id, query: query, limit: 10)
            }
        }
        #expect(throws: MCPMetadataError.invalidArgument("Query must be 1 to 200 characters")) {
            try service.searchSchema(in: project, connectionID: production.id, query: String(repeating: "a", count: 201), limit: 10)
        }
        _ = try service.searchSchema(in: project, connectionID: production.id, query: String(repeating: "a", count: 200), limit: 10)
    }

    /// A search reads names and definitions from the store; it never builds
    /// the dependency graph.
    @Test func searchBuildsNoGraph() throws {
        let counter = CallCounter()
        _ = try makeService(counter: counter).searchSchema(in: project, connectionID: production.id, query: "id", limit: 10)
        #expect(counter.count("graph.load") == 0)
    }

    @Test func graphQueryNeighborsAndUnknownNode() throws {
        let service = try makeService()
        let result = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "orders"))
        guard case let .neighbors(neighbors) = result.value else { Issue.record("\(result)"); return }
        #expect(neighbors.dependsOn == ["customers"])

        do {
            _ = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "nope"))
            Issue.record("expected notFound")
        } catch let MCPMetadataError.notFound(message) {
            #expect(message.contains("Available:"))
            #expect(message.contains("customers"))
            #expect(message.contains("orders"))
        }
    }

    @Test func graphQueryPathBlastRadiusCyclesAndCentrality() throws {
        let service = try makeService()
        let path = try service.graphQuery(in: project, connectionID: production.id, operation: .path(from: "orders", to: "customers"))
        guard case let .path(found) = path.value else { Issue.record("\(path)"); return }
        #expect(found.reachable)
        #expect(found.path == ["orders", "customers"])

        let blast = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "customers"))
        guard case let .blastRadius(radius) = blast.value else { Issue.record("\(blast)"); return }
        #expect(radius.impacted == ["orders"])
        #expect(radius.count == 1)

        let cycles = try service.graphQuery(in: project, connectionID: production.id, operation: .circularDependencies)
        guard case let .circularDependencies(found) = cycles.value else { Issue.record("\(cycles)"); return }
        #expect(!found.hasCycles)

        let top = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 1000))
        guard case let .topCentrality(entries) = top.value else { Issue.record("\(top)"); return }
        #expect(entries.first?.node == "customers")
        #expect(entries.first?.inDegree == 1)
    }

    @Test func graphQueryRejectsAmbiguousNamesStrictly() throws {
        var seed = SchemaSeed()
        try seed.table("users", in: "a")
        try seed.table("users", in: "b")
        let service = try makeService(seed: seed)
        do {
            _ = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "users"))
            Issue.record("expected notFound")
        } catch let MCPMetadataError.notFound(message) {
            #expect(message.contains("a.users"))
            #expect(message.contains("b.users"))
        }
    }

    /// The suggestions an ambiguity message offers: the comma-separated names
    /// after "Use one of: ", without a trailing "and N more".
    func suggestions(in message: String) -> [String] {
        guard let range = message.range(of: "Use one of: ") else { return [] }
        return message[range.upperBound...]
            .components(separatedBy: ", ")
            .filter { !$0.hasPrefix("and ") }
    }

    /// The message of the `notFound` error `body` throws, or nil.
    func notFoundMessage(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let MCPMetadataError.notFound(message) {
            return message
        } catch {
            return nil
        }
    }

    /// Three thousand tables in one schema, each with an `id` column. The
    /// graph the graph operations traverse holds tables and views only, so
    /// the column name finds no node, and the answer names at most fifty
    /// tables.
    @Test func aColumnNameSharedByManyTablesGetsABoundedAnswer() throws {
        var seed = SchemaSeed()
        for index in 0 ..< 3000 {
            try seed.table(String(format: "t%04d", index), in: "public", columns: [SchemaSeed.column("id")])
        }
        let service = try makeService(seed: seed)

        for name in ["id", "public.id", "ID"] {
            let messages = [
                notFoundMessage { try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: name)) },
                notFoundMessage { try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: name)) },
                notFoundMessage {
                    try service.graphQuery(in: project, connectionID: production.id, operation: .path(from: name, to: "t0001"))
                },
                notFoundMessage { try service.graphStats(in: project, connectionID: production.id, object: name) },
            ]
            for message in messages {
                let text = try #require(message)
                #expect(text.hasPrefix("Node '\(name)' not found. Available: "), "\(text.prefix(300))")
                let available = text.components(separatedBy: "Available: ").last?.components(separatedBy: ", ") ?? []
                #expect(available.count == 50)
            }
        }
    }

    /// A table name present in 120 schemas: at most fifty suggestions, each
    /// distinct, each resolving to exactly one table, and a count of the rest.
    @Test func manyTablesOfOneNameGetAtMostFiftyDistinctSuggestions() throws {
        var seed = SchemaSeed()
        for index in 0 ..< 120 {
            try seed.table("users", in: String(format: "s%03d", index))
        }
        let service = try makeService(seed: seed)

        let message = try #require(notFoundMessage {
            try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "users"))
        })
        let offered = suggestions(in: message)
        #expect(offered.count == 50)
        #expect(Set(offered).count == offered.count)
        #expect(message.hasSuffix(", and 70 more"))
        for suggestion in offered {
            #expect(throws: Never.self, "\(suggestion)") {
                try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: suggestion))
            }
        }
    }

    /// A table and a view sharing a qualified name, plus a column carrying
    /// that name in the same schema: the qualified name itself is ambiguous,
    /// so it is never offered; each table and view is offered by its stable
    /// id instead, and columns are not offered at all.
    @Test func aSuggestionThatIsItselfAmbiguousIsNeverOffered() throws {
        var seed = SchemaSeed()
        try seed.table("orders", in: "shop")
        seed.view("orders", in: "shop")
        try seed.table("audit", in: "shop", columns: [SchemaSeed.column("orders")])
        let service = try makeService(seed: seed)

        for name in ["orders", "shop.orders"] {
            let message = try #require(notFoundMessage {
                try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: name))
            })
            #expect(suggestions(in: message) == ["table:shop.orders", "view:shop.orders"], "\(message)")
            for suggestion in suggestions(in: message) {
                #expect(throws: Never.self, "\(suggestion)") {
                    try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: suggestion))
                }
            }
        }
    }

    @Test func topCentralityLimitIsClampedToFifty() throws {
        var seed = try SchemaSeed.tables((0 ..< 80).map { "t\($0)" }, in: "db")
        for index in 1 ..< 80 {
            seed.reference("t\(index)", "t0_id", "t0", in: "db")
            seed.reference("t0", "t\(index)_id", "t\(index)", in: "db")
        }
        let service = try makeService(seed: seed)
        let large = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 500))
        guard case let .topCentrality(entries) = large.value else { Issue.record("\(large)"); return }
        #expect(entries.count == 50)
        let small = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 0))
        guard case let .topCentrality(single) = small.value else { Issue.record("\(small)"); return }
        #expect(single.count == 1)
    }

    @Test func graphListsAreCappedAtFiveHundredNamesButBlastRadiusKeepsTheFullCount() throws {
        var seed = try SchemaSeed.tables(["hub"] + (0 ..< 600).map { "t\($0)" }, in: "db")
        for index in 0 ..< 600 {
            seed.reference("t\(index)", "hub_id", "hub", in: "db")
            seed.reference("hub", "t\(index)_id", "t\(index)", in: "db")
        }
        let service = try makeService(seed: seed)

        let blast = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "hub"))
        guard case let .blastRadius(radius) = blast.value else { Issue.record("\(blast)"); return }
        #expect(radius.impacted.count == 500)
        #expect(radius.count == 600)

        let neighbors = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "hub"))
        guard case let .neighbors(found) = neighbors.value else { Issue.record("\(neighbors)"); return }
        #expect(found.dependsOn.count == 500)
        #expect(found.dependedOnBy.count == 500)

        let cycles = try service.graphQuery(in: project, connectionID: production.id, operation: .circularDependencies)
        guard case let .circularDependencies(components) = cycles.value else { Issue.record("\(cycles)"); return }
        #expect(components.components.flatMap { $0 }.count == 500)
    }

    @Test func graphResultEncodesOperationAndResult() throws {
        let service = try makeService()
        let result = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "orders"))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result.value)) as? [String: Any]
        )
        #expect(object["operation"] as? String == "neighbors")
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["node"] as? String == "orders")
        #expect(payload["dependsOn"] as? [String] == ["customers"])
    }

    @Test func graphStatsSummaryAndTable() throws {
        var seed = try SchemaSeed.shop()
        try seed.table("stats")
        seed.stats = [(database: nil, name: "stats", rows: 12, sizeBytes: 40, indexStats: nil)]
        let service = try makeService(seed: seed)

        let summary = try service.graphStats(in: project, connectionID: production.id, object: nil)
        guard case let .summary(found) = summary.value else { Issue.record("\(summary)"); return }
        #expect(found.tables.map(\.name).contains("stats"))
        #expect(found.tables.first { $0.name == "stats" }?.fields == ["rows": "12", "size_bytes": "40"])

        let table = try service.graphStats(in: project, connectionID: production.id, object: "stats")
        guard case let .table(stats) = table.value else { Issue.record("\(table)"); return }
        #expect(stats.table == "stats")
        #expect(stats.fields == ["rows": "12", "size_bytes": "40"])

        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(table.value)) as? [String: Any]
        )
        #expect(encoded["table"] as? String == "stats")

        #expect(throws: MCPMetadataError.self) {
            try service.graphStats(in: project, connectionID: production.id, object: "missing_table")
        }
    }

    @Test func statisticsSummaryIsCappedAtFiveHundredTablesAndUnusedIndexes() throws {
        let names = (0 ..< 620).map { String(format: "t%04d", $0) }
        var seed = try SchemaSeed.tables(names, in: "db")
        seed.stats = names.enumerated().map { index, name in
            (database: "db", name: name, rows: 1, sizeBytes: nil, indexStats: String(format: #"{"i%04d":{"idxScan":0}}"#, index))
        }
        let service = try makeService(seed: seed)
        let summary = try service.graphStats(in: project, connectionID: production.id, object: nil)
        guard case let .summary(found) = summary.value else { Issue.record("\(summary)"); return }
        #expect(found.tables.count == 500)
        #expect(found.unusedIndexes.count == 500)
        // The cap keeps the sorted prefix, and the unused indexes are those
        // of the tables kept.
        #expect(found.tables.map(\.name) == Array(names.prefix(500)))
        #expect(found.unusedIndexes.last == "i0499")
    }

    // MARK: Served from the store with a cached graph

    /// Graph operations reuse one cached graph while the schema has not
    /// changed, and see a change once a pass records it.
    @Test func graphQueriesSeeASchemaChangeOnceAPassRecordsIt() throws {
        let store = try makeStore()
        let service = MCPMetadataService(store: store)
        let before = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "customers"))
        guard case let .blastRadius(radius) = before.value else { Issue.record("\(before)"); return }
        #expect(radius.impacted == ["orders"])

        let later = Self.harvestTime.addingTimeInterval(60)
        var seed = try SchemaSeed.shop()
        try seed.table("refunds")
        seed.reference("refunds", "customer_id", "customers")
        try seed.write(to: store, profileID: production.id, at: later, checkedAt: later)

        let after = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "customers"))
        guard case let .blastRadius(widened) = after.value else { Issue.record("\(after)"); return }
        #expect(widened.impacted == ["orders", "refunds"])
    }

    /// A statistics refresh replaces the rows without changing the schema,
    /// so the cached graph is reused, and the answer is still the new rows.
    @Test func graphStatsFollowARefreshWhileTheGraphIsCached() throws {
        var seed = try SchemaSeed.shop()
        seed.stats = [(database: nil, name: "orders", rows: 10, sizeBytes: nil, indexStats: nil)]
        let store = try makeStore(seed: seed)
        let service = MCPMetadataService(store: store)
        let first = try service.graphStats(in: project, connectionID: production.id, object: "orders")
        guard case let .table(before) = first.value else { Issue.record("\(first)"); return }
        #expect(before.fields == ["rows": "10"])

        try store.replaceSchemaStats(profileID: production.id, rows: [
            SchemaStatsRecord(profileID: production.id, database: nil, name: "orders", rows: 25, updatedAt: Date()),
        ])
        let second = try service.graphStats(in: project, connectionID: production.id, object: "orders")
        guard case let .table(after) = second.value else { Issue.record("\(second)"); return }
        #expect(after.fields == ["rows": "25"])
        let summary = try service.graphStats(in: project, connectionID: production.id, object: nil)
        guard case let .summary(tables) = summary.value else { Issue.record("\(summary)"); return }
        #expect(tables.tables.first { $0.name == "orders" }?.fields == ["rows": "25"])
    }
}
