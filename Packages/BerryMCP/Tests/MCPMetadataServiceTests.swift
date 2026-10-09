import BerryDriverKit
import BerryGraph
import BerryStore
import Foundation
import Testing

@testable import BerryMCP

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

    /// `orders` references `customers`; both have an `id` column.
    func shopGraph() -> SchemaGraph {
        let orders = TableRef(name: "orders")
        let customers = TableRef(name: "customers")
        return SchemaGraphBuilder.build(
            objects: [
                BerryDriverKit.SchemaObject(kind: .table, name: "orders"),
                BerryDriverKit.SchemaObject(kind: .table, name: "customers"),
                BerryDriverKit.SchemaObject(kind: .view, name: "recent_orders"),
            ],
            details: [
                orders: TableDetail(
                    ref: orders,
                    columns: [
                        ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                        ColumnInfo(name: "customer_id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
                    ],
                    indexes: [],
                    foreignKeys: [ForeignKeyInfo(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
                ),
                customers: TableDetail(
                    ref: customers,
                    columns: [
                        ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                        ColumnInfo(name: "email", declaredType: "text", isNullable: true, defaultValue: nil, isPrimaryKey: false),
                    ],
                    indexes: [IndexInfo(name: "customers_email_key", isUnique: true, columns: ["email"])],
                    foreignKeys: []
                ),
            ]
        )
    }

    /// A store holding all three profiles, with `graph` persisted for the
    /// production profile only.
    func makeService(
        graph: SchemaGraph? = nil, counter: CallCounter = CallCounter()
    ) throws -> MCPMetadataService {
        let store = try BerryStore(path: ":memory:")
        for profile in [production, staging, outsider] {
            try store.save(profile)
        }
        let graphStore = GraphStore(store: store)
        try graphStore.persist(graph ?? shopGraph(), profileID: production.id, now: Self.harvestTime)
        return MCPMetadataService(
            profiles: {
                counter.bump("profiles")
                return try store.allProfiles()
            },
            graph: BerryGraphQueryService(
                loadGraph: {
                    counter.bump("graph.load")
                    return try graphStore.loadGraph(profileID: $0)
                },
                harvestedAt: {
                    counter.bump("graph.harvestedAt")
                    return try graphStore.snapshots(profileID: $0).map(\.takenAt).max()
                }
            ),
            harvestedAt: {
                counter.bump("harvestedAt")
                return try graphStore.snapshots(profileID: $0).map(\.takenAt).max()
            },
            loadGraph: {
                counter.bump("loadGraph")
                return try graphStore.loadGraph(profileID: $0)
            }
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

    /// A harvest that found no tables or views still records a snapshot, and
    /// the graph tools then answer that no graph was harvested; the
    /// connection must not claim a harvest time the tools contradict.
    @Test func aConnectionCountsAsHarvestedOnlyWhenItsLatestSnapshotHoldsNodes() throws {
        let store = try BerryStore(path: ":memory:")
        for profile in [production, staging] {
            try store.save(profile)
        }
        let graphStore = GraphStore(store: store)
        let emptied = Self.harvestTime.addingTimeInterval(60)
        try graphStore.persist(shopGraph(), profileID: production.id, now: Self.harvestTime)
        try graphStore.persist(SchemaGraph(), profileID: production.id, now: emptied)
        try graphStore.persist(shopGraph(), profileID: staging.id, now: emptied)
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

    @Test func unassignedAndNonexistentConnectionsGiveTheSameError() throws {
        let counter = CallCounter()
        let service = try makeService(counter: counter)
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
        var graph = SchemaGraph()
        for index in 0 ..< 230 {
            graph.addNode(GraphNode(id: "table:db.t\(index)", kind: .table, name: "t\(index)", database: "db"))
        }
        let listing = try makeService(graph: graph).schema(
            in: project, connectionID: production.id, objectNames: nil, detail: .overview
        )
        #expect(listing.objects.count == 200)
        #expect(listing.omittedCount == 30)
    }

    @Test func searchMatchesColumnsCaseInsensitivelyAndCapsLimit() throws {
        let service = try makeService()
        let matches = try service.searchSchema(in: project, connectionID: production.id, query: "ID", limit: 1000)
        #expect(matches.count <= 200)
        let columns = matches.filter { $0.kind == "column" }
        #expect(columns.contains(MCPSchemaMatch(name: "id", kind: "column", database: nil, table: "orders")))
        #expect(columns.contains(MCPSchemaMatch(name: "id", kind: "column", database: nil, table: "customers")))
        #expect(columns.contains { $0.name == "customer_id" && $0.table == "orders" })
        // Ordered by kind (table, view, column, index), then database, table, name.
        #expect(columns.map { "\($0.table ?? "").\($0.name)" } == ["customers.id", "orders.customer_id", "orders.id"])

        let one = try service.searchSchema(in: project, connectionID: production.id, query: "id", limit: 1)
        #expect(one.count == 1)
        let clamped = try service.searchSchema(in: project, connectionID: production.id, query: "id", limit: -5)
        #expect(clamped.count == 1)
    }

    @Test func searchReturnsExactlyTwoHundredWhenMoreMatch() throws {
        var graph = SchemaGraph()
        for index in 0 ..< 250 {
            graph.addNode(GraphNode(id: "table:db.item\(index)", kind: .table, name: "item\(index)", database: "db"))
        }
        let service = try makeService(graph: graph)
        let matches = try service.searchSchema(in: project, connectionID: production.id, query: "item", limit: 1000)
        #expect(matches.count == 200)
        let fewer = try service.searchSchema(in: project, connectionID: production.id, query: "item", limit: 7)
        #expect(fewer.count == 7)
    }

    @Test func searchOrdersKindsAndLeavesOwningTableNilOutsideColumns() throws {
        let matches = try makeService().searchSchema(in: project, connectionID: production.id, query: "o", limit: 50)
        let kinds = matches.map(\.kind)
        let order = ["table", "view", "column", "index"]
        #expect(kinds == kinds.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
        #expect(matches.filter { $0.kind != "column" }.allSatisfy { $0.table == nil })
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

    @Test func searchLoadsTheGraphOnce() throws {
        let counter = CallCounter()
        _ = try makeService(counter: counter).searchSchema(in: project, connectionID: production.id, query: "id", limit: 10)
        #expect(counter.count("loadGraph") == 1)
        #expect(counter.count("graph.load") == 0)
        #expect(counter.count("harvestedAt") == 0)
    }

    @Test func graphQueryNeighborsAndUnknownNode() throws {
        let service = try makeService()
        let result = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "orders"))
        guard case let .neighbors(neighbors) = result else { Issue.record("\(result)"); return }
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
        guard case let .path(found) = path else { Issue.record("\(path)"); return }
        #expect(found.reachable)
        #expect(found.path == ["orders", "customers"])

        let blast = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "customers"))
        guard case let .blastRadius(radius) = blast else { Issue.record("\(blast)"); return }
        #expect(radius.impacted == ["orders"])
        #expect(radius.count == 1)

        let cycles = try service.graphQuery(in: project, connectionID: production.id, operation: .circularDependencies)
        guard case let .circularDependencies(found) = cycles else { Issue.record("\(cycles)"); return }
        #expect(!found.hasCycles)

        let top = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 1000))
        guard case let .topCentrality(entries) = top else { Issue.record("\(top)"); return }
        #expect(entries.first?.node == "customers")
        #expect(entries.first?.inDegree == 1)
    }

    @Test func graphQueryRejectsAmbiguousNamesStrictly() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:a.users", kind: .table, name: "users", database: "a"))
        graph.addNode(GraphNode(id: "table:b.users", kind: .table, name: "users", database: "b"))
        let service = try makeService(graph: graph)
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

    /// Three thousand tables in one schema, each with an `id` column, as the
    /// harvester names them.
    @Test func aColumnNameSharedByManyTablesGetsABoundedAnswer() throws {
        var graph = SchemaGraph()
        for index in 0 ..< 3000 {
            let table = String(format: "t%04d", index)
            graph.addNode(GraphNode(id: "table:public.\(table)", kind: .table, name: table, database: "public"))
            graph.addNode(GraphNode(id: "column:public.\(table).id", kind: .column, name: "id", database: "public"))
            graph.addEdge(GraphEdge(src: "table:public.\(table)", dst: "column:public.\(table).id", kind: .hasColumn))
        }
        let service = try makeService(graph: graph)

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
                #expect(text.count < 300, "\(text.prefix(300))")
                #expect(text.contains("table or view name"))
                #expect(suggestions(in: text).isEmpty)
            }
        }
    }

    /// A table name present in 120 schemas: at most fifty suggestions, each
    /// distinct, each resolving to exactly one table, and a count of the rest.
    @Test func manyTablesOfOneNameGetAtMostFiftyDistinctSuggestions() throws {
        var graph = SchemaGraph()
        for index in 0 ..< 120 {
            let schema = String(format: "s%03d", index)
            graph.addNode(GraphNode(id: "table:\(schema).users", kind: .table, name: "users", database: schema))
        }
        let service = try makeService(graph: graph)

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
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:shop.orders", kind: .table, name: "orders", database: "shop"))
        graph.addNode(GraphNode(id: "view:shop.orders", kind: .view, name: "orders", database: "shop"))
        graph.addNode(GraphNode(id: "table:shop.audit", kind: .table, name: "audit", database: "shop"))
        graph.addNode(GraphNode(id: "column:shop.audit.orders", kind: .column, name: "orders", database: "shop"))
        let service = try makeService(graph: graph)

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
        var graph = SchemaGraph()
        for index in 0 ..< 80 {
            graph.addNode(GraphNode(id: "table:db.t\(index)", kind: .table, name: "t\(index)", database: "db"))
        }
        for index in 1 ..< 80 {
            graph.addEdge(GraphEdge(src: "table:db.t\(index)", dst: "table:db.t0", kind: .references))
            graph.addEdge(GraphEdge(src: "table:db.t0", dst: "table:db.t\(index)", kind: .references))
        }
        let service = try makeService(graph: graph)
        let large = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 500))
        guard case let .topCentrality(entries) = large else { Issue.record("\(large)"); return }
        #expect(entries.count == 50)
        let small = try service.graphQuery(in: project, connectionID: production.id, operation: .topCentrality(limit: 0))
        guard case let .topCentrality(single) = small else { Issue.record("\(small)"); return }
        #expect(single.count == 1)
    }

    @Test func graphListsAreCappedAtFiveHundredNamesButBlastRadiusKeepsTheFullCount() throws {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:db.hub", kind: .table, name: "hub", database: "db"))
        for index in 0 ..< 600 {
            graph.addNode(GraphNode(id: "table:db.t\(index)", kind: .table, name: "t\(index)", database: "db"))
            graph.addEdge(GraphEdge(src: "table:db.t\(index)", dst: "table:db.hub", kind: .references))
            graph.addEdge(GraphEdge(src: "table:db.hub", dst: "table:db.t\(index)", kind: .references))
        }
        let service = try makeService(graph: graph)

        let blast = try service.graphQuery(in: project, connectionID: production.id, operation: .blastRadius(node: "hub"))
        guard case let .blastRadius(radius) = blast else { Issue.record("\(blast)"); return }
        #expect(radius.impacted.count == 500)
        #expect(radius.count == 600)

        let neighbors = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "hub"))
        guard case let .neighbors(found) = neighbors else { Issue.record("\(neighbors)"); return }
        #expect(found.dependsOn.count == 500)
        #expect(found.dependedOnBy.count == 500)

        let cycles = try service.graphQuery(in: project, connectionID: production.id, operation: .circularDependencies)
        guard case let .circularDependencies(components) = cycles else { Issue.record("\(cycles)"); return }
        #expect(components.components.flatMap { $0 }.count == 500)
    }

    @Test func graphResultEncodesOperationAndResult() throws {
        let service = try makeService()
        let result = try service.graphQuery(in: project, connectionID: production.id, operation: .neighbors(node: "orders"))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )
        #expect(object["operation"] as? String == "neighbors")
        let payload = try #require(object["result"] as? [String: Any])
        #expect(payload["node"] as? String == "orders")
        #expect(payload["dependsOn"] as? [String] == ["customers"])
    }

    @Test func graphStatsSummaryAndTable() throws {
        var graph = shopGraph()
        graph.addNode(GraphNode(
            id: "table:.stats", kind: .table, name: "stats", attrs: ["rows": "12", "size_bytes": "40", "type": "ignored"]
        ))
        let service = try makeService(graph: graph)

        let summary = try service.graphStats(in: project, connectionID: production.id, object: nil)
        guard case let .summary(found) = summary else { Issue.record("\(summary)"); return }
        #expect(found.tables.map(\.name).contains("stats"))
        #expect(found.tables.first { $0.name == "stats" }?.fields == ["rows": "12", "size_bytes": "40"])

        let table = try service.graphStats(in: project, connectionID: production.id, object: "stats")
        guard case let .table(stats) = table else { Issue.record("\(table)"); return }
        #expect(stats.table == "stats")
        #expect(stats.fields == ["rows": "12", "size_bytes": "40"])

        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(table)) as? [String: Any]
        )
        #expect(encoded["table"] as? String == "stats")

        #expect(throws: MCPMetadataError.self) {
            try service.graphStats(in: project, connectionID: production.id, object: "missing_table")
        }
    }

    @Test func statisticsSummaryIsCappedAtFiveHundredTablesAndUnusedIndexes() throws {
        var graph = SchemaGraph()
        for index in 0 ..< 620 {
            let name = String(format: "t%04d", index)
            graph.addNode(GraphNode(id: "table:db.\(name)", kind: .table, name: name, database: "db", attrs: ["rows": "1"]))
            graph.addNode(GraphNode(
                id: "index:db.\(name).i", kind: .index, name: String(format: "i%04d", index),
                database: "db", attrs: ["unused": "true"]
            ))
        }
        let service = try makeService(graph: graph)
        let summary = try service.graphStats(in: project, connectionID: production.id, object: nil)
        guard case let .summary(found) = summary else { Issue.record("\(summary)"); return }
        #expect(found.tables.count == 500)
        #expect(found.unusedIndexes.count == 500)
        // The cap keeps the sorted prefix.
        #expect(found.tables.first?.name == "t0000")
        #expect(found.tables.last?.name == "t0499")
        #expect(found.unusedIndexes.last == "i0499")
    }
}
