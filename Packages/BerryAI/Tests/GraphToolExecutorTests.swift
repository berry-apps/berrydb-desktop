import BerryGraph
import BerryStore
import Foundation
import Testing

@testable import BerryAI

/// `graph_query` (docs/architecture/11 §7) over a persisted DSG — metadata only,
/// entirely local (no DBMS). Uses an in-memory GraphStore seeded with a small
/// FK graph: order_items → orders → customers, order_items → products, and a
/// view order_summary derived from orders.
@MainActor
@Suite("GraphToolExecutor (docs/architecture/11 §7)")
struct GraphToolExecutorTests {
    private let profile = UUID()

    private func seededStore() throws -> GraphStore {
        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        try store.persist(sampleGraph(), profileID: profile, now: Date(timeIntervalSince1970: 1000))
        return store
    }

    private func sampleGraph() -> SchemaGraph {
        var g = SchemaGraph()
        // ids deliberately differ from names, to exercise name resolution.
        let tables = ["customers", "orders", "order_items", "products"]
        for name in tables { g.addNode(GraphNode(id: "tbl:\(name)", kind: .table, name: name)) }
        g.addNode(GraphNode(id: "view:order_summary", kind: .view, name: "order_summary"))
        g.addEdge(GraphEdge(src: "tbl:orders", dst: "tbl:customers", kind: .references))
        g.addEdge(GraphEdge(src: "tbl:order_items", dst: "tbl:orders", kind: .references))
        g.addEdge(GraphEdge(src: "tbl:order_items", dst: "tbl:products", kind: .references))
        g.addEdge(GraphEdge(src: "view:order_summary", dst: "tbl:orders", kind: .derivesFrom))
        return g
    }

    private func decode(_ outcome: ToolOutcome) -> [String: Any] {
        guard let json = outcome.resultJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func call(_ args: [String: String]) -> AIToolCall {
        AIToolCall(id: "c", name: "graph_query", args: args)
    }

    @Test func blastRadiusListsEverythingThatDependsOnATable() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "blast_radius", "node": "customers"]))
        #expect(outcome.status == "ok")
        let impacted = Set(decode(outcome)["impacted"] as? [String] ?? [])
        // orders (FK), order_items (transitive FK), order_summary (derives from orders).
        #expect(impacted == ["orders", "order_items", "order_summary"])
        #expect(decode(outcome)["count"] as? Int == 3)
    }

    @Test func pathReturnsTheDependencyChain() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "path", "from": "order_items", "to": "customers"]))
        #expect(decode(outcome)["reachable"] as? Bool == true)
        #expect(decode(outcome)["path"] as? [String] == ["order_items", "orders", "customers"])
    }

    @Test func pathReportsUnreachable() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        // customers depends on nothing → cannot reach products following FKs out.
        let outcome = await executor.execute(call(["op": "path", "from": "customers", "to": "products"]))
        #expect(decode(outcome)["reachable"] as? Bool == false)
        #expect((decode(outcome)["path"] as? [String])?.isEmpty == true)
    }

    @Test func neighborsSplitsDependenciesByDirection() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "neighbors", "node": "orders"]))
        #expect(decode(outcome)["depends_on"] as? [String] == ["customers"])
        #expect(decode(outcome)["depended_on_by"] as? [String] == ["order_items", "order_summary"])
    }

    @Test func topCentralityRanksMostDependedUpon() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "top_centrality", "k": "2"]))
        let top = decode(outcome)["top_by_dependents"] as? [[String: Any]] ?? []
        #expect(top.count == 2)
        // orders has 2 dependents (order_items + order_summary) — the top.
        #expect(top.first?["node"] as? String == "orders")
        #expect(top.first?["in_degree"] as? Int == 2)
    }

    @Test func sccReportsNoCyclesForAcyclicSchema() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "scc"]))
        #expect(decode(outcome)["has_cycles"] as? Bool == false)
        #expect((decode(outcome)["circular_dependencies"] as? [[String]])?.isEmpty == true)
    }

    @Test func sccDetectsACircularDependency() async throws {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "tbl:a", kind: .table, name: "a"))
        g.addNode(GraphNode(id: "tbl:b", kind: .table, name: "b"))
        g.addEdge(GraphEdge(src: "tbl:a", dst: "tbl:b", kind: .references))
        g.addEdge(GraphEdge(src: "tbl:b", dst: "tbl:a", kind: .references))
        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        let p = UUID()
        try store.persist(g, profileID: p, now: Date(timeIntervalSince1970: 1000))

        let executor = GraphToolExecutor(store: store, profileID: p)
        let outcome = await executor.execute(call(["op": "scc"]))
        #expect(decode(outcome)["has_cycles"] as? Bool == true)
        let cycles = decode(outcome)["circular_dependencies"] as? [[String]] ?? []
        #expect(cycles.first.map(Set.init) == ["a", "b"])
    }

    @Test func unknownNodeReturnsErrorWithAvailableNames() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "blast_radius", "node": "nope"]))
        #expect(outcome.status == "error")
        #expect(outcome.resultJSON?.contains("customers") == true)
    }

    @Test func unknownOpIsRejected() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(call(["op": "louvain"]))
        #expect(outcome.status == "error")
    }

    @Test func nonGraphToolIsNotHandled() async throws {
        let executor = GraphToolExecutor(store: try seededStore(), profileID: profile)
        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_sql", args: [:]))
        #expect(outcome.status == "error")
    }

    @Test func emptyGraphReportsNothingHarvested() async throws {
        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        let executor = GraphToolExecutor(store: store, profileID: UUID())
        let outcome = await executor.execute(call(["op": "scc"]))
        #expect(outcome.status == "error")
        #expect(outcome.resultJSON?.contains("harvested") == true)
    }

    // MARK: - get_stats (§7)

    private func statsStore() throws -> GraphStore {
        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "tbl:orders", kind: .table, name: "orders",
                            attrs: ["rows": "1000", "size_bytes": "40960"]))
        g.addNode(GraphNode(id: "idx:pk", kind: .index, name: "orders_pk",
                            attrs: ["idx_scan": "50", "unused": "false"]))
        g.addNode(GraphNode(id: "idx:dead", kind: .index, name: "orders_dead_idx",
                            attrs: ["idx_scan": "0", "unused": "true"]))
        g.addEdge(GraphEdge(src: "tbl:orders", dst: "idx:pk", kind: .hasIndex))
        g.addEdge(GraphEdge(src: "tbl:orders", dst: "idx:dead", kind: .hasIndex))
        try store.persist(g, profileID: profile, now: Date(timeIntervalSince1970: 1000))
        return store
    }

    @Test func getStatsSummaryListsTablesAndUnusedIndexes() async throws {
        let executor = GraphToolExecutor(store: try statsStore(), profileID: profile)
        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_stats", args: [:]))
        #expect(outcome.status == "ok")
        let tables = decode(outcome)["tables"] as? [[String: Any]] ?? []
        #expect(tables.first?["name"] as? String == "orders")
        #expect(tables.first?["rows"] as? String == "1000")
        #expect(decode(outcome)["unused_indexes"] as? [String] == ["orders_dead_idx"])
    }

    @Test func getStatsForTableIncludesItsIndexes() async throws {
        let executor = GraphToolExecutor(store: try statsStore(), profileID: profile)
        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "get_stats", args: ["table": "orders"])
        )
        #expect(outcome.status == "ok")
        #expect(decode(outcome)["table"] as? String == "orders")
        #expect(decode(outcome)["size_bytes"] as? String == "40960")
        let indexes = decode(outcome)["indexes"] as? [[String: Any]] ?? []
        #expect(indexes.contains {
            ($0["name"] as? String) == "orders_dead_idx" && ($0["unused"] as? String) == "true"
        })
    }
}

/// The `ToolRouter` dispatches by tool name across executors.
@MainActor
@Suite("ToolRouter (docs/architecture/09 §4)")
struct ToolRouterTests {
    private final class StubExecutor: AIToolExecutor {
        let tag: String
        init(_ tag: String) { self.tag = tag }
        func execute(_ call: AIToolCall) async -> ToolOutcome { .ok("{\"by\":\"\(tag)\"}") }
    }

    @Test func routesKnownToolAndFallsBack() async throws {
        let router = ToolRouter(
            routes: ["graph_query": StubExecutor("graph")],
            fallback: StubExecutor("sql")
        )
        let graph = await router.execute(AIToolCall(id: "1", name: "graph_query", args: [:]))
        let sql = await router.execute(AIToolCall(id: "2", name: "run_sql", args: [:]))
        #expect(graph.resultJSON == "{\"by\":\"graph\"}")
        #expect(sql.resultJSON == "{\"by\":\"sql\"}")
    }

    @Test func unknownToolWithoutFallbackErrors() async throws {
        let router = ToolRouter(routes: [:])
        let outcome = await router.execute(AIToolCall(id: "1", name: "mystery", args: [:]))
        #expect(outcome.status == "error")
    }
}
