import BerryDriverKit
import Testing

@testable import BerryGraph

@Suite("SchemaGraph algorithms")
struct SchemaGraphAlgorithmTests {
    /// Builds a small directed graph: a → b → c, and d → c.
    private func sample() -> SchemaGraph {
        var g = SchemaGraph()
        for name in ["a", "b", "c", "d"] {
            g.addNode(GraphNode(id: name, kind: .table, name: name))
        }
        g.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        g.addEdge(GraphEdge(src: "b", dst: "c", kind: .references))
        g.addEdge(GraphEdge(src: "d", dst: "c", kind: .references))
        return g
    }

    @Test func neighborsRespectDirectionAndKind() {
        let g = sample()
        #expect(g.neighbors(of: "a", direction: .outgoing) == ["b"])
        #expect(Set(g.neighbors(of: "c", direction: .incoming)) == ["b", "d"])
        #expect(g.neighbors(of: "c", direction: .incoming, kinds: [.reads]).isEmpty)
    }

    @Test func reachabilityFollowsEdges() {
        let g = sample()
        #expect(g.reachable(from: "a", direction: .outgoing) == ["b", "c"])
        #expect(g.reachable(from: "c", direction: .outgoing).isEmpty) // c is a sink
    }

    @Test func blastRadiusIsReverseReachability() {
        // Dropping c breaks a, b (via b→c) and d (d→c).
        let g = sample()
        #expect(g.blastRadius(of: "c") == ["a", "b", "d"])
        // Dropping a breaks nothing (nothing references a).
        #expect(g.blastRadius(of: "a").isEmpty)
    }

    @Test func shortestPathFindsFewestHops() {
        var g = sample()
        g.addEdge(GraphEdge(src: "a", dst: "c", kind: .references)) // shortcut
        #expect(g.shortestPath(from: "a", to: "c") == ["a", "c"])
        g = sample()
        #expect(g.shortestPath(from: "a", to: "c") == ["a", "b", "c"])
        #expect(g.shortestPath(from: "c", to: "a") == nil) // no path backwards
        #expect(g.shortestPath(from: "a", to: "a") == ["a"])
    }

    @Test func degreeCentralityAndTopK() {
        let g = sample()
        let degrees = g.degreeCentrality()
        #expect(degrees["c"]?.inDegree == 2)
        #expect(degrees["c"]?.outDegree == 0)
        #expect(degrees["a"]?.outDegree == 1)
        let top = g.topByInDegree(1)
        #expect(top.first?.id == "c")
        #expect(top.first?.inDegree == 2)
    }

    @Test func stronglyConnectedComponentsFindCycle() {
        var g = SchemaGraph()
        for name in ["x", "y", "z", "w"] {
            g.addNode(GraphNode(id: name, kind: .table, name: name))
        }
        // Cycle x → y → z → x, plus an acyclic w → x.
        g.addEdge(GraphEdge(src: "x", dst: "y", kind: .references))
        g.addEdge(GraphEdge(src: "y", dst: "z", kind: .references))
        g.addEdge(GraphEdge(src: "z", dst: "x", kind: .references))
        g.addEdge(GraphEdge(src: "w", dst: "x", kind: .references))

        let cycles = g.circularDependencies()
        #expect(cycles.count == 1)
        #expect(Set(cycles[0]) == ["x", "y", "z"])
        // w is acyclic — every node still lands in exactly one SCC.
        let all = g.stronglyConnectedComponents()
        #expect(all.reduce(0) { $0 + $1.count } == 4)
    }

    @Test func noFalseCyclesInAcyclicGraph() {
        #expect(sample().circularDependencies().isEmpty)
    }
}

@Suite("SchemaGraphBuilder from schema")
struct SchemaGraphBuilderTests {
    @Test func buildsTablesColumnsIndexesAndForeignKeys() {
        let objects = [
            SchemaObject(kind: .table, name: "orders"),
            SchemaObject(kind: .table, name: "customers"),
            SchemaObject(kind: .view, name: "recent_orders"),
        ]
        let ordersDetail = TableDetail(
            ref: TableRef(name: "orders"),
            columns: [
                ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                ColumnInfo(name: "customer_id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "orders_customer_idx", isUnique: false, columns: ["customer_id"])],
            foreignKeys: [ForeignKeyInfo(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
        )
        let graph = SchemaGraphBuilder.build(
            objects: objects,
            details: [TableRef(name: "orders"): ordersDetail]
        )

        let ordersID = GraphID.node(.table, database: nil, name: "orders")
        let customersID = GraphID.node(.table, database: nil, name: "customers")

        // Nodes: 2 tables + 1 view + 2 columns + 1 index.
        #expect(graph.nodes[ordersID]?.kind == .table)
        #expect(graph.nodes[GraphID.node(.view, database: nil, name: "recent_orders")]?.kind == .view)
        #expect(graph.nodes[GraphID.node(.column, database: nil, name: "customer_id", in: "orders")] != nil)
        #expect(graph.nodes[GraphID.node(.index, database: nil, name: "orders_customer_idx", in: "orders")] != nil)

        // FK edge orders → customers, and its blast radius.
        #expect(graph.neighbors(of: ordersID, direction: .outgoing, kinds: [.references]) == [customersID])
        #expect(graph.blastRadius(of: customersID).contains(ordersID))

        // A table's columns are reachable via hasColumn.
        let columns = graph.neighbors(of: ordersID, direction: .outgoing, kinds: [.hasColumn])
        #expect(columns.count == 2)
    }

    @Test func referencedTableMissingFromObjectsGetsStubNode() {
        let detail = TableDetail(
            ref: TableRef(name: "orders"),
            columns: [],
            indexes: [],
            foreignKeys: [ForeignKeyInfo(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
        )
        // customers is NOT in objects — the builder must still create a stub so
        // the reference edge (and blast radius) work.
        let graph = SchemaGraphBuilder.build(
            objects: [SchemaObject(kind: .table, name: "orders")],
            details: [TableRef(name: "orders"): detail]
        )
        let customersID = GraphID.node(.table, database: nil, name: "customers")
        #expect(graph.nodes[customersID]?.kind == .table)
        #expect(graph.blastRadius(of: customersID).contains(GraphID.node(.table, database: nil, name: "orders")))
    }
}
