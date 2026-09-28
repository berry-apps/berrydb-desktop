import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

@Suite("BerryGraphQueryService")
struct BerryGraphQueryServiceTests {
    private let profileID = UUID()

    private func service(graph: SchemaGraph? = nil) throws -> BerryGraphQueryService {
        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        if let graph {
            try store.persist(graph, profileID: profileID, now: Date(timeIntervalSince1970: 1_000))
        }
        return BerryGraphQueryService(store: store)
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
        let query = try service()
        #expect(throws: BerryGraphQueryService.QueryError.noSnapshot) {
            try query.circularDependencies(profileID: profileID)
        }
    }

    @Test func qualifiedNameResolvesAmbiguity() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:a.users", kind: .table, name: "users", database: "a"))
        graph.addNode(GraphNode(id: "table:b.users", kind: .table, name: "users", database: "b"))
        let query = try service(graph: graph)

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
        let query = try service(graph: graph)

        #expect(throws: BerryGraphQueryService.QueryError.ambiguousNode(
            name: "shop.orders", matches: ["shop.orders", "shop.orders"]
        )) {
            try query.neighbors(profileID: profileID, node: "shop.orders")
        }
        let legacy = try query.neighbors(profileID: profileID, node: "shop.orders", resolution: .legacyFirstStableID)
        #expect(legacy.dependsOn == ["customers"])
    }

    @Test func neighborsUseOnlyDependencyKindsAndSortNames() throws {
        let result = try service(graph: graph()).neighbors(profileID: profileID, node: "orders")
        #expect(result.dependsOn == ["customers"])
        #expect(result.dependedOnBy == ["order_items", "order_summary"])
    }

    @Test func pathPreservesTraversalOrderAndReportsUnreachable() throws {
        let query = try service(graph: graph())
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
        let query = try service(graph: graph())
        let top = try query.topCentrality(profileID: profileID, limit: 2)
        #expect(top == [
            .init(node: "orders", inDegree: 2),
            .init(node: "customers", inDegree: 1),
        ])
        #expect(try query.topCentrality(profileID: profileID, limit: 0).count == 1)
    }

    @Test func statisticsAreTypedFilteredAndSorted() throws {
        let query = try service(graph: graph())
        let summary = try query.statistics(profileID: profileID)
        #expect(summary.tables.map(\.name) == ["customers", "metrics", "order_items", "orders", "products"])
        #expect(summary.tables.first { $0.name == "metrics" }?.fields == ["rows": "12", "size_bytes": "40"])
        #expect(summary.unusedIndexes == ["z_idx"])

        let table = try query.statistics(profileID: profileID, table: "orders")
        #expect(table.indexes.map(\.name) == ["a_idx", "z_idx"])
        #expect(table.indexes[0].fields == ["idx_scan": "9", "unused": "false"])
    }

    /// Two tables (`orders` referencing `customers`), a unique index on
    /// `customers.email`, and a view derived from `orders` — the fixture
    /// `SchemaGraphBuilderTests` also builds, reused here for `schema(...)`.
    private func schemaFixture() -> SchemaGraph {
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
        return SchemaGraphBuilder.build(
            objects: objects,
            details: [ordersDetail.ref: ordersDetail, customersDetail.ref: customersDetail]
        )
    }

    @Test func fullSchemaCarriesColumnsIndexesAndForeignKeys() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let fixture = schemaFixture()
        let service = BerryGraphQueryService(loadGraph: { _ in fixture }, harvestedAt: { _ in when })
        let listing = try service.schema(profileID: UUID(), objectNames: nil, detail: .full, limit: 200)
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
        let fixture = schemaFixture()
        let service = BerryGraphQueryService(loadGraph: { _ in fixture }, harvestedAt: { _ in nil })
        let listing = try service.schema(profileID: UUID(), objectNames: nil, detail: .overview, limit: 200)
        #expect(listing.objects.allSatisfy { $0.columns.isEmpty && $0.indexes.isEmpty && $0.foreignKeys.isEmpty })
    }

    @Test func limitReportsOmittedCountAndFilterIsCaseInsensitive() throws {
        let fixture = schemaFixture()
        let service = BerryGraphQueryService(loadGraph: { _ in fixture }, harvestedAt: { _ in nil })
        let limited = try service.schema(profileID: UUID(), objectNames: nil, detail: .overview, limit: 1)
        #expect(limited.objects.map(\.name) == ["customers"])
        #expect(limited.omittedCount == 2)
        let filtered = try service.schema(profileID: UUID(), objectNames: ["ORDERS"], detail: .overview, limit: 200)
        #expect(filtered.objects.map(\.name) == ["orders"])
    }

    @Test func emptySchemaGraphIsNoSnapshot() {
        let service = BerryGraphQueryService(loadGraph: { _ in SchemaGraph() }, harvestedAt: { _ in nil })
        #expect(throws: BerryGraphQueryService.QueryError.noSnapshot) {
            try service.schema(profileID: UUID(), objectNames: nil, detail: .full, limit: 200)
        }
    }

    @Test func objectNamesFilterHandlesQualifiedAndUnqualifiedAcrossDatabases() throws {
        let objects = [
            BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "ops"),
            BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "sales"),
        ]
        let graph = SchemaGraphBuilder.build(objects: objects, details: [:])
        let service = BerryGraphQueryService(loadGraph: { _ in graph }, harvestedAt: { _ in nil })

        let unqualified = try service.schema(profileID: UUID(), objectNames: ["orders"], detail: .overview, limit: 200)
        #expect(unqualified.objects.map { ($0.database ?? "") + "." + $0.name } == ["ops.orders", "sales.orders"])

        let qualified = try service.schema(profileID: UUID(), objectNames: ["SALES.orders"], detail: .overview, limit: 200)
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
        let graph = SchemaGraphBuilder.build(objects: objects, details: [ordersDetail.ref: ordersDetail])
        let service = BerryGraphQueryService(loadGraph: { _ in graph }, harvestedAt: { _ in nil })
        let listing = try service.schema(profileID: UUID(), objectNames: nil, detail: .full, limit: 200)
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
        let graph = SchemaGraphBuilder.build(objects: objects, details: [detail.ref: detail])
        let service = BerryGraphQueryService(loadGraph: { _ in graph }, harvestedAt: { _ in nil })
        let listing = try service.schema(profileID: UUID(), objectNames: nil, detail: .full, limit: 200)
        let orders = try #require(listing.objects.first { $0.name == "orders" })
        #expect(orders.indexes == [.init(name: "orders_ab_idx", columns: ["a", "b"], unique: false)])
    }

    @Test func missingNodeDiagnosticIsSortedAndCapped() throws {
        var graph = SchemaGraph()
        for index in (0..<60).reversed() {
            let name = String(format: "table_%02d", index)
            graph.addNode(GraphNode(id: name, kind: .table, name: name))
        }
        let query = try service(graph: graph)
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
}
