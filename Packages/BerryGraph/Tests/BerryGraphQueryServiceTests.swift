import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

@Suite("BerryGraphQueryService")
struct BerryGraphQueryServiceTests {
    private let profileID = UUID()

    private func service(graph: SchemaGraph) -> BerryGraphQueryService {
        BerryGraphQueryService(loadGraph: { _ in graph })
    }

    /// A service over an in-memory store seeded the way a harvest pass writes:
    /// the listing, then each table's detail.
    private func service(
        objects: [BerryDriverKit.SchemaObject], details: [TableDetail] = [],
        changedAt: Date? = nil, checkedAt: Date? = nil, stats: [SchemaStatsRecord] = []
    ) throws -> BerryGraphQueryService {
        let store = try BerryStore(path: ":memory:")
        try GraphReaderTests.seed(store, profileID: profileID, objects: objects, details: details, at: Date(timeIntervalSince1970: 1_000))
        try store.updateSchemaGraphState(profileID: profileID) {
            $0.lastChangedAt = changedAt
            $0.lastCheckedAt = checkedAt
        }
        try store.replaceSchemaStats(profileID: profileID, rows: stats)
        return BerryGraphQueryService(reader: GraphReader(store: store))
    }

    private func graph() -> SchemaGraph {
        var graph = SchemaGraph()
        for name in ["customers", "orders", "order_items", "products"] {
            graph.addNode(GraphNode(id: "table:shop.\(name)", kind: .table, name: name, database: "shop"))
        }
        graph.addNode(GraphNode(id: "view:shop.order_summary", kind: .view, name: "order_summary", database: "shop"))
        graph.addNode(GraphNode(id: "index:shop.orders.z", kind: .index, name: "z_idx", database: "shop", attrs: ["unused": "true", "idx_scan": "0"]))
        graph.addNode(GraphNode(id: "index:shop.orders.a", kind: .index, name: "a_idx", database: "shop", attrs: ["unused": "false", "idx_scan": "9"]))
        graph.addNode(GraphNode(id: "table:shop.metrics", kind: .table, name: "metrics", database: "shop", attrs: ["rows": "12", "size_bytes": "40", "type": "ignored"]))
        graph.addEdge(GraphEdge(src: "table:shop.orders", dst: "table:shop.customers", kind: .references))
        graph.addEdge(GraphEdge(src: "table:shop.order_items", dst: "table:shop.orders", kind: .references))
        graph.addEdge(GraphEdge(src: "table:shop.order_items", dst: "table:shop.products", kind: .references))
        graph.addEdge(GraphEdge(src: "view:shop.order_summary", dst: "table:shop.orders", kind: .derivesFrom))
        graph.addEdge(GraphEdge(src: "table:shop.metrics", dst: "table:shop.orders", kind: .reads))
        graph.addEdge(GraphEdge(src: "table:shop.orders", dst: "index:shop.orders.z", kind: .hasIndex))
        graph.addEdge(GraphEdge(src: "table:shop.orders", dst: "index:shop.orders.a", kind: .hasIndex))
        return graph
    }

    @Test func noSnapshotIsTyped() throws {
        let query = BerryGraphQueryService(reader: GraphReader(store: try BerryStore(path: ":memory:")))
        #expect(throws: BerryGraphQueryService.QueryError.noSnapshot) {
            try query.circularDependencies(profileID: profileID)
        }
    }

    @Test func qualifiedNameResolvesAmbiguity() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:a.users", kind: .table, name: "users", database: "a"))
        graph.addNode(GraphNode(id: "table:b.users", kind: .table, name: "users", database: "b"))
        let query = service(graph: graph)

        #expect(throws: BerryGraphQueryService.QueryError.ambiguousNode(
            name: "users", matches: ["a.users", "b.users"]
        )) {
            try query.neighbors(profileID: profileID, node: "users")
        }
        #expect(try query.neighbors(profileID: profileID, node: "b.users").node == "users")
    }

    /// Two nodes can share a qualified `database.name` (here a table and a
    /// view). Strict resolution reports that; legacy resolution picks the
    /// smallest stable ID at this step too, as it does for bare names.
    @Test func legacyResolutionPicksSmallestStableIDForAQualifiedNameCollision() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:shop.orders", kind: .table, name: "orders", database: "shop"))
        graph.addNode(GraphNode(id: "view:shop.orders", kind: .view, name: "orders", database: "shop"))
        graph.addNode(GraphNode(id: "table:shop.customers", kind: .table, name: "customers", database: "shop"))
        graph.addNode(GraphNode(id: "table:shop.products", kind: .table, name: "products", database: "shop"))
        graph.addEdge(GraphEdge(src: "table:shop.orders", dst: "table:shop.customers", kind: .references))
        graph.addEdge(GraphEdge(src: "view:shop.orders", dst: "table:shop.products", kind: .derivesFrom))
        let query = service(graph: graph)

        #expect(throws: BerryGraphQueryService.QueryError.ambiguousNode(
            name: "shop.orders", matches: ["shop.orders", "shop.orders"]
        )) {
            try query.neighbors(profileID: profileID, node: "shop.orders")
        }
        let legacy = try query.neighbors(profileID: profileID, node: "shop.orders", resolution: .legacyFirstStableID)
        #expect(legacy.dependsOn == ["customers"])
    }

    /// A query with a dot is tried as `database.name`, then as a bare name,
    /// since a name such as `system.profile` holds a dot of its own.
    @Test func aDottedQueryResolvesAQualifiedNameOrADottedBareName() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:shop.orders", kind: .table, name: "orders", database: "shop"))
        graph.addNode(GraphNode(id: "table:system.profile", kind: .table, name: "system.profile"))
        // A dot followed by a combining mark is one Character, which a
        // search for the Character "." does not find.
        graph.addNode(GraphNode(id: "table:shop.\u{301}accent", kind: .table, name: "\u{301}accent", database: "shop"))
        let query = service(graph: graph)

        #expect(try query.neighbors(profileID: profileID, node: "Shop.Orders").node == "orders")
        #expect(try query.neighbors(profileID: profileID, node: "SYSTEM.PROFILE").node == "system.profile")
        #expect(try query.neighbors(profileID: profileID, node: "SHOP.\u{301}ACCENT").node == "\u{301}accent")
    }

    @Test func neighborsUseOnlyDependencyKindsAndSortNames() throws {
        let result = try service(graph: graph()).neighbors(profileID: profileID, node: "orders")
        #expect(result.dependsOn == ["customers"])
        #expect(result.dependedOnBy == ["order_items", "order_summary"])
    }

    @Test func pathPreservesTraversalOrderAndReportsUnreachable() throws {
        let query = service(graph: graph())
        let path = try query.path(profileID: profileID, from: "order_items", to: "customers")
        #expect(path.path == ["order_items", "orders", "customers"])
        #expect(path.reachable)
        let missing = try query.path(profileID: profileID, from: "customers", to: "products")
        #expect(!missing.reachable)
        #expect(missing.path.isEmpty)
    }

    @Test func blastRadiusIsTransitiveSortedAndExcludesWorkloadEdges() throws {
        let result = try service(graph: graph()).blastRadius(profileID: profileID, node: "customers")
        #expect(result.impacted == ["order_items", "order_summary", "orders"])
        #expect(result.count == 3)
    }

    @Test func circularDependenciesAreDeterministic() throws {
        var graph = SchemaGraph()
        for name in ["d", "c", "b", "a"] {
            graph.addNode(GraphNode(id: name, kind: .table, name: name))
        }
        graph.addEdge(GraphEdge(src: "b", dst: "a", kind: .references))
        graph.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        graph.addEdge(GraphEdge(src: "d", dst: "c", kind: .references))
        graph.addEdge(GraphEdge(src: "c", dst: "d", kind: .references))
        let result = try service(graph: graph).circularDependencies(profileID: profileID)
        #expect(result.components == [["a", "b"], ["c", "d"]])
        #expect(result.hasCycles)
    }

    @Test func centralityHasStableTieBreakAndHonorsLimit() throws {
        let query = service(graph: graph())
        let top = try query.topCentrality(profileID: profileID, limit: 2)
        #expect(top == [
            .init(node: "orders", inDegree: 2),
            .init(node: "customers", inDegree: 1),
        ])
        #expect(try query.topCentrality(profileID: profileID, limit: 0).count == 1)
    }

    /// The tables of `graph()` in a store, with the statistics its nodes carry:
    /// row counts on `metrics`, and one used and one unused index on `orders`.
    private func shopService() throws -> BerryGraphQueryService {
        try service(
            objects: ["customers", "orders", "order_items", "products", "metrics"].map {
                BerryDriverKit.SchemaObject(kind: .table, name: $0, database: "shop")
            } + [BerryDriverKit.SchemaObject(kind: .view, name: "order_summary", database: "shop")],
            changedAt: Date(timeIntervalSince1970: 1_000),
            stats: [
                SchemaStatsRecord(profileID: profileID, database: "shop", name: "metrics", rows: 12, sizeBytes: 40, updatedAt: Date()),
                SchemaStatsRecord(
                    profileID: profileID, database: "shop", name: "orders",
                    indexStats: #"{"z_idx":{"idxScan":0},"a_idx":{"idxScan":9}}"#, updatedAt: Date()
                ),
            ]
        )
    }

    @Test func statisticsAreTypedFilteredAndSorted() throws {
        let query = try shopService()
        let summary = try query.statistics(profileID: profileID)
        #expect(summary.tables.map(\.name) == ["customers", "metrics", "order_items", "orders", "products"])
        #expect(summary.tables.first { $0.name == "metrics" }?.fields == ["rows": "12", "size_bytes": "40"])
        #expect(summary.unusedIndexes == ["z_idx"])

        let table = try query.statistics(profileID: profileID, table: "orders")
        #expect(table.indexes.map(\.name) == ["a_idx", "z_idx"])
        #expect(table.indexes[0].fields == ["idx_scan": "9", "unused": "false"])
    }

    /// A summary held to a number of tables reads the statistics of those
    /// tables alone, by key and as plain values, and lists the unused indexes
    /// of those tables: at 20,000 tables, decoding every row and every row's
    /// index counters to keep 500 cost hundreds of milliseconds.
    @Test func aLimitedSummaryReadsTheStatisticsOfItsTablesOnly() throws {
        let store = try BerryStore(path: ":memory:")
        let names = ["a", "b", "c"]
        try GraphReaderTests.seed(
            store, profileID: profileID,
            objects: names.map { BerryDriverKit.SchemaObject(kind: .table, name: $0, database: "shop") },
            details: [], at: Date(timeIntervalSince1970: 1_000)
        )
        try store.replaceSchemaStats(profileID: profileID, rows: names.map {
            SchemaStatsRecord(
                profileID: profileID, database: "shop", name: $0, rows: 1,
                indexStats: #"{"\#($0)_idx":{"idxScan":0}}"#, updatedAt: Date()
            )
        })
        let query = BerryGraphQueryService(reader: GraphReader(store: store))

        let limited = try StatementLog.recording(store) { try query.statistics(profileID: profileID, limit: 2) }
        #expect(limited.result.tables.map(\.name) == ["a", "b"])
        #expect(limited.result.tables.map(\.fields) == [["rows": "1"], ["rows": "1"]])
        #expect(limited.result.unusedIndexes == ["a_idx", "b_idx"])
        let statisticsReads = limited.statements.filter { $0.contains("FROM schema_stats") }
        #expect(!statisticsReads.isEmpty && statisticsReads.allSatisfy { !$0.contains("SELECT *") }, "\(statisticsReads)")

        let whole = try query.statistics(profileID: profileID)
        #expect(whole.tables.map(\.name) == names)
        #expect(whole.unusedIndexes == ["a_idx", "b_idx", "c_idx"])
    }

    /// A graph that outlives a statistics refresh, as a cached one does,
    /// still answers with the current rows: a refreshed counter shows, and a
    /// table whose row the refresh dropped carries no counters.
    @Test func statisticsReadTheCurrentRowsWhenTheGraphIsReused() throws {
        let store = try BerryStore(path: ":memory:")
        try GraphReaderTests.seed(
            store, profileID: profileID,
            objects: ["orders", "metrics"].map { BerryDriverKit.SchemaObject(kind: .table, name: $0, database: "shop") },
            details: [], at: Date(timeIntervalSince1970: 1_000)
        )
        try store.replaceSchemaStats(profileID: profileID, rows: [
            SchemaStatsRecord(profileID: profileID, database: "shop", name: "orders", rows: 10, updatedAt: Date()),
            SchemaStatsRecord(profileID: profileID, database: "shop", name: "metrics", rows: 5, updatedAt: Date()),
        ])
        let reader = GraphReader(store: store)
        let reused = try reader.tableGraph(profileID: profileID)
        let query = BerryGraphQueryService(reader: reader, tableGraph: { _ in reused })
        try store.replaceSchemaStats(profileID: profileID, rows: [
            SchemaStatsRecord(profileID: profileID, database: "shop", name: "orders", rows: 20, updatedAt: Date()),
        ])

        let summary = try query.statistics(profileID: profileID)
        #expect(summary.tables.map(\.name) == ["metrics", "orders"])
        #expect(summary.tables.map(\.fields) == [[:], ["rows": "20"]])
        #expect(try query.statistics(profileID: profileID, table: "orders").fields == ["rows": "20"])
        #expect(try query.statistics(profileID: profileID, table: "metrics").fields == [:])
    }

    /// Two tables (`orders` referencing `customers`), a unique index on
    /// `customers.email`, and a view whose detail was never read — the fixture
    /// `SchemaGraphBuilderTests` also builds, reused here for `schema(...)`.
    private func schemaFixture(changedAt: Date? = nil, checkedAt: Date? = nil) throws -> BerryGraphQueryService {
        let objects = [
            BerryDriverKit.SchemaObject(kind: .table, name: "orders"),
            BerryDriverKit.SchemaObject(kind: .table, name: "customers"),
            BerryDriverKit.SchemaObject(kind: .view, name: "recent_orders"),
        ]
        let ordersDetail = TableDetail(
            ref: TableRef(name: "orders"),
            columns: [
                ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                ColumnInfo(name: "customer_id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
            ],
            indexes: [],
            foreignKeys: [ForeignKeyInfo(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
        )
        let customersDetail = TableDetail(
            ref: TableRef(name: "customers"),
            columns: [
                ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                ColumnInfo(name: "email", declaredType: "text", isNullable: true, defaultValue: nil, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "customers_email_key", isUnique: true, columns: ["email"])],
            foreignKeys: []
        )
        return try service(
            objects: objects, details: [ordersDetail, customersDetail], changedAt: changedAt, checkedAt: checkedAt
        )
    }

    private func schema(
        _ service: BerryGraphQueryService, names: [String]? = nil, detail: BerryGraphQueryService.SchemaDetail,
        offset: Int = 0, limit: Int = 200, maxBytes: Int = 512 * 1024
    ) throws -> BerryGraphQueryService.SchemaListing {
        try service.schema(
            profileID: profileID, objectNames: names, detail: detail, offset: offset, limit: limit, maxBytes: maxBytes
        )
    }

    @Test func fullSchemaCarriesColumnsIndexesAndForeignKeys() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let listing = try schema(try schemaFixture(changedAt: when), detail: .full)
        #expect(listing.harvestedAt == when)
        #expect(listing.objects.map(\.name) == ["customers", "orders", "recent_orders"])
        let orders = try #require(listing.objects.first { $0.name == "orders" })
        #expect(orders.columns == [
            .init(name: "customer_id", type: "int", nullable: false, primaryKey: false),
            .init(name: "id", type: "int", nullable: false, primaryKey: true),
        ])
        #expect(orders.foreignKeys == [.init(column: "customer_id", referencedTable: "customers", referencedColumn: "id")])
        let customers = try #require(listing.objects.first { $0.name == "customers" })
        #expect(customers.indexes == [.init(name: "customers_email_key", columns: ["email"], unique: true)])
    }

    @Test func overviewOmitsColumnDetail() throws {
        let listing = try schema(try schemaFixture(), detail: .overview)
        #expect(listing.objects.allSatisfy { $0.columns.isEmpty && $0.indexes.isEmpty && $0.foreignKeys.isEmpty })
    }

    @Test func limitReportsOmittedCountAndFilterIsCaseInsensitive() throws {
        let service = try schemaFixture()
        let limited = try schema(service, detail: .overview, limit: 1)
        #expect(limited.objects.map(\.name) == ["customers"])
        #expect(limited.omittedCount == 2)
        let filtered = try schema(service, names: ["ORDERS"], detail: .overview)
        #expect(filtered.objects.map(\.name) == ["orders"])
    }

    /// Case is ignored only for a name that matches nothing exactly, so an
    /// exact name never also lists the objects that differ from it in case.
    @Test func anExactNameWinsOverACaseInsensitiveMatch() throws {
        let service = try service(objects: [
            .init(kind: .table, name: "Orders", database: "shop"), .init(kind: .table, name: "orders", database: "shop"),
        ])
        #expect(try schema(service, names: ["orders"], detail: .overview).objects.map(\.name) == ["orders"])
        #expect(try schema(service, names: ["ORDERS"], detail: .overview).objects.map(\.name) == ["Orders", "orders"])
    }

    @Test func emptySchemaGraphIsNoSnapshot() throws {
        let service = BerryGraphQueryService(reader: GraphReader(store: try BerryStore(path: ":memory:")))
        #expect(throws: BerryGraphQueryService.QueryError.noSnapshot) {
            try schema(service, detail: .full)
        }
    }

    @Test func schemaPagesWithTotalAndNextOffset() throws {
        let service = try schemaFixture()
        let first = try schema(service, detail: .overview, limit: 2)
        #expect(first.objects.map(\.name) == ["customers", "orders"])
        #expect(first.total == 3)
        #expect(first.nextOffset == 2)
        #expect(first.omittedCount == 1)

        let last = try schema(service, detail: .overview, offset: 2, limit: 2)
        #expect(last.objects.map(\.name) == ["recent_orders"])
        #expect(last.total == 3)
        #expect(last.nextOffset == nil)
        #expect(last.omittedCount == 0)
    }

    @Test func schemaFlagsObjectsWhoseDetailIsPending() throws {
        let listing = try schema(try schemaFixture(), detail: .full)
        #expect(listing.objects.map(\.detailPending) == [false, false, true])
        let view = try #require(listing.objects.last)
        #expect(view.kind == .view)
        #expect(view.columns.isEmpty && view.indexes.isEmpty)
    }

    @Test func schemaReportsWhenTheSchemaWasLastChecked() throws {
        let checkedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let fresh = try schema(try schemaFixture(checkedAt: checkedAt), detail: .overview)
        #expect(fresh.checkedAt == checkedAt)
        #expect(!fresh.stale)

        let never = try schema(try schemaFixture(), detail: .overview)
        #expect(never.checkedAt == nil)
        #expect(never.stale)
    }

    /// Only a full listing carries definitions, so only it is cut by the byte
    /// budget; an overview of the same objects is a page of names.
    @Test func byteBudgetCutsFullDetailOnly() throws {
        let wide = TableDetail(
            ref: TableRef(name: "a_wide"),
            columns: (0..<6_500).map {
                ColumnInfo(name: String(format: "column_with_a_long_name_%05d", $0), declaredType: "varchar(255)",
                           isNullable: true, defaultValue: nil, isPrimaryKey: false)
            },
            indexes: [], foreignKeys: []
        )
        let service = try service(
            objects: [.init(kind: .table, name: "a_wide"), .init(kind: .table, name: "b_narrow")], details: [wide]
        )
        let full = try schema(service, detail: .full)
        #expect(full.objects.map(\.name) == ["a_wide"])
        #expect(full.nextOffset == 1)
        #expect(full.omittedCount == 1)

        let overview = try schema(service, detail: .overview)
        #expect(overview.objects.map(\.name) == ["a_wide", "b_narrow"])
        #expect(overview.nextOffset == nil)
    }

    @Test func graphOperationsReadTheTableGraph() throws {
        let service = try schemaFixture()
        #expect(try service.neighbors(profileID: profileID, node: "orders").dependsOn == ["customers"])
        #expect(try service.blastRadius(profileID: profileID, node: "customers").impacted == ["orders"])
    }

    @Test func objectNamesFilterHandlesQualifiedAndUnqualifiedAcrossDatabases() throws {
        let objects = [
            BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "ops"),
            BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "sales"),
        ]
        let service = try service(objects: objects)

        let unqualified = try schema(service, names: ["orders"], detail: .overview)
        #expect(unqualified.objects.map { ($0.database ?? "") + "." + $0.name } == ["ops.orders", "sales.orders"])

        let qualified = try schema(service, names: ["SALES.orders"], detail: .overview)
        #expect(qualified.objects.map { ($0.database ?? "") + "." + $0.name } == ["sales.orders"])
    }

    @Test func foreignKeyRecordsReferencedDatabase() throws {
        let objects = [
            BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "sales"),
            BerryDriverKit.SchemaObject(kind: .table, name: "customers", database: "crm"),
        ]
        let ordersDetail = TableDetail(
            ref: TableRef(database: "sales", name: "orders"),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [],
            foreignKeys: [
                ForeignKeyInfo(column: "customer_id", referencedSchema: "crm", referencedTable: "customers", referencedColumn: "id"),
            ]
        )
        let listing = try schema(try service(objects: objects, details: [ordersDetail]), detail: .full)
        let orders = try #require(listing.objects.first { $0.name == "orders" })
        #expect(orders.foreignKeys == [
            .init(column: "customer_id", referencedDatabase: "crm", referencedTable: "customers", referencedColumn: "id"),
        ])
    }

    @Test func compositeIndexRoundTripsAllColumns() throws {
        let objects = [BerryDriverKit.SchemaObject(kind: .table, name: "orders")]
        let detail = TableDetail(
            ref: TableRef(name: "orders"),
            columns: [
                ColumnInfo(name: "a", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
                ColumnInfo(name: "b", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "orders_ab_idx", isUnique: false, columns: ["a", "b"])],
            foreignKeys: []
        )
        let listing = try schema(try service(objects: objects, details: [detail]), detail: .full)
        let orders = try #require(listing.objects.first { $0.name == "orders" })
        #expect(orders.indexes == [.init(name: "orders_ab_idx", columns: ["a", "b"], unique: false)])
    }

    @Test func missingNodeDiagnosticIsSortedAndCapped() throws {
        var graph = SchemaGraph()
        for index in (0..<60).reversed() {
            let name = String(format: "table_%02d", index)
            graph.addNode(GraphNode(id: name, kind: .table, name: name))
        }
        let query = service(graph: graph)
        do {
            _ = try query.neighbors(profileID: profileID, node: "missing")
            Issue.record("Expected missing-node error")
        } catch let BerryGraphQueryService.QueryError.nodeNotFound(_, available) {
            #expect(available.count == BerryGraphQueryService.maximumDiagnosticNames)
            #expect(available == available.sorted())
            #expect(available.first == "table_00")
            #expect(available.last == "table_49")
        }
    }

    private func mcpEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    @Test func graphResultsEncodeWithStableKeys() throws {
        let encoder = mcpEncoder()
        let neighbors = BerryGraphQueryService.Neighbors(node: "orders", dependsOn: ["customers"], dependedOnBy: [])
        #expect(String(decoding: try encoder.encode(neighbors), as: UTF8.self)
            == #"{"depended_on_by":[],"depends_on":["customers"],"node":"orders"}"#)
        let listing = BerryGraphQueryService.SchemaListing(objects: [], omittedCount: 3, harvestedAt: nil)
        #expect(String(decoding: try encoder.encode(listing), as: UTF8.self)
            == #"{"checked_at":null,"next_offset":null,"objects":[],"omitted_count":3,"stale":true,"total":3}"#)
    }

    @Test func circularDependenciesEncodeDerivedFlagAndRoundTrip() throws {
        let encoder = mcpEncoder()
        let none = BerryGraphQueryService.CircularDependencies(components: [])
        #expect(String(decoding: try encoder.encode(none), as: UTF8.self) == #"{"components":[],"has_cycles":false}"#)
        let cyclic = BerryGraphQueryService.CircularDependencies(components: [["a", "b"]])
        let data = try encoder.encode(cyclic)
        #expect(String(decoding: data, as: UTF8.self) == #"{"components":[["a","b"]],"has_cycles":true}"#)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        #expect(try decoder.decode(BerryGraphQueryService.CircularDependencies.self, from: data) == cyclic)
    }

    @Test func queryResultsFromAGraphEncodeSnakeCaseKeys() throws {
        let encoder = mcpEncoder()
        let query = service(graph: graph())
        let stored = try shopService()
        func json<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        #expect(try json(query.path(profileID: profileID, from: "order_items", to: "customers"))
            == #"{"from":"order_items","path":["order_items","orders","customers"],"reachable":true,"to":"customers"}"#)
        #expect(try json(query.blastRadius(profileID: profileID, node: "customers"))
            == #"{"count":3,"impacted":["order_items","order_summary","orders"],"node":"customers"}"#)
        #expect(try json(query.topCentrality(profileID: profileID, limit: 1))
            == #"[{"in_degree":2,"node":"orders"}]"#)
        #expect(try json(stored.statistics(profileID: profileID)).contains(#""unused_indexes":["z_idx"]"#))
        #expect(try json(stored.statistics(profileID: profileID, table: "orders")).contains(#""indexes":["#))

        let detailed = try schema(stored, names: ["orders"], detail: .full)
        let text = try json(detailed)
        #expect(text.contains(#""omitted_count":0"#))
        #expect(text.contains(#""harvested_at":"#))
        #expect(text.contains(#""total":1"#))
        #expect(text.contains(#""stale":true"#))
        #expect(text.contains(#""detail_pending":true"#))
        #expect(text.contains(#""next_offset":null"#))
        #expect(text.contains(#""checked_at":null"#))
        let column = BerryGraphQueryService.SchemaObject.Column(name: "id", type: "int", nullable: false, primaryKey: true)
        #expect(try json(column) == #"{"name":"id","nullable":false,"primary_key":true,"type":"int"}"#)
        let foreignKey = BerryGraphQueryService.SchemaObject.ForeignKey(
            column: "customer_id", referencedDatabase: nil, referencedTable: "customers", referencedColumn: "id")
        #expect(try json(foreignKey)
            == #"{"column":"customer_id","referenced_column":"id","referenced_table":"customers"}"#)
        #expect(try json(BerryGraphQueryService.SchemaDetail.overview) == #""overview""#)
    }
}
