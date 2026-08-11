import BerryDriverKit
import Foundation
import Testing

@testable import BerryGraph

/// Deterministic analyzers over the DSG (docs/architecture/11 §7, DI-05/07).
@Suite("Schema Analyzer (DI-07)")
struct SchemaAnalyzerTests {
    private func table(_ name: String, attrs: [String: String] = [:]) -> GraphNode {
        GraphNode(id: "tbl:\(name)", kind: .table, name: name, attrs: attrs)
    }

    private func column(_ table: String, _ name: String, pk: Bool = false, nullable: Bool = true) -> GraphNode {
        GraphNode(id: "col:\(table).\(name)", kind: .column, name: name,
                  attrs: ["primaryKey": String(pk), "nullable": String(nullable), "type": "int"])
    }

    private func withColumns(_ table: GraphNode, _ cols: [GraphNode], into graph: inout SchemaGraph) {
        graph.addNode(table)
        for col in cols {
            graph.addNode(col)
            graph.addEdge(GraphEdge(src: table.id, dst: col.id, kind: .hasColumn))
        }
    }

    private func ids(_ insights: [Insight]) -> Set<String> { Set(insights.map(\.id)) }

    @Test func flagsCircularDependency() {
        var g = SchemaGraph()
        g.addNode(table("a"))
        g.addNode(table("b"))
        g.addEdge(GraphEdge(src: "tbl:a", dst: "tbl:b", kind: .references))
        g.addEdge(GraphEdge(src: "tbl:b", dst: "tbl:a", kind: .references))
        let cycle = SchemaAnalyzer.analyze(g).first { $0.id.hasPrefix("schema.cycle") }
        #expect(cycle?.severity == .warning)
        #expect(cycle?.detail.contains("a → b") == true)
    }

    @Test func flagsTableWithoutPrimaryKey() {
        var g = SchemaGraph()
        withColumns(table("logs"), [column("logs", "msg"), column("logs", "at")], into: &g)
        withColumns(table("users"), [column("users", "id", pk: true, nullable: false)], into: &g)
        let insights = SchemaAnalyzer.analyze(g)
        #expect(ids(insights).contains("schema.missing_pk.logs"))
        #expect(!ids(insights).contains("schema.missing_pk.users"))
    }

    @Test func flagsHiddenForeignKeyWhenParentExists() {
        var g = SchemaGraph()
        withColumns(table("orders"), [
            column("orders", "id", pk: true, nullable: false),
            column("orders", "customer_id"),
        ], into: &g)
        withColumns(table("customers"), [column("customers", "id", pk: true, nullable: false)], into: &g)
        #expect(ids(SchemaAnalyzer.analyze(g)).contains("schema.hidden_fk.orders.customer_id"))
    }

    @Test func skipsHiddenForeignKeyWhenConstrainedOrNoParent() {
        var g = SchemaGraph()
        withColumns(table("orders"), [column("orders", "customer_id"), column("orders", "widget_id")], into: &g)
        withColumns(table("customers"), [column("customers", "id", pk: true, nullable: false)], into: &g)
        // orders.customer_id is already an enforced FK → not flagged.
        g.addEdge(GraphEdge(src: "tbl:orders", dst: "tbl:customers", kind: .references,
                            attrs: ["column": "customer_id"]))
        let flagged = ids(SchemaAnalyzer.analyze(g))
        #expect(!flagged.contains("schema.hidden_fk.orders.customer_id"))
        // widget_id has no matching parent table → not flagged either.
        #expect(!flagged.contains("schema.hidden_fk.orders.widget_id"))
    }

    /// Reported crash/leak/perf audit: `hiddenForeignKeys` checked "already
    /// constrained?" via `graph.edges.contains { ... }` — a full linear scan
    /// of every edge, run once per `_id`-suffixed column of every table
    /// (O(tables × id-columns × edges)), unlike every sibling rule in this
    /// file which goes through `SchemaGraph`'s O(1) adjacency maps. This
    /// schema graph's own docs put edge counts up to 10^5 — a generous
    /// bound that only the fixed (indexed-once) version can plausibly meet.
    @Test func hiddenForeignKeysStaysFastOnALargeGraph() {
        var g = SchemaGraph()
        let n = 3000
        for i in 0..<n {
            g.addNode(GraphNode(id: "tbl:t\(i)", kind: .table, name: "t\(i)"))
            let col = GraphNode(id: "col:t\(i).x_id", kind: .column, name: "x_id", attrs: ["type": "int"])
            g.addNode(col)
            g.addEdge(GraphEdge(src: "tbl:t\(i)", dst: col.id, kind: .hasColumn))
            // Bulk unrelated edges so `graph.edges` is large enough for an
            // O(tables × edges) scan to be measurably slow, not just O(edges).
            g.addNode(GraphNode(id: "tbl:p\(i)", kind: .table, name: "p\(i)"))
            g.addEdge(GraphEdge(src: "tbl:t\(i)", dst: "tbl:p\(i)", kind: .references, attrs: ["column": "other_id"]))
        }
        let clock = ContinuousClock()
        let start = clock.now
        _ = SchemaAnalyzer.analyze(g)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func flagsAllNullableTable() {
        var g = SchemaGraph()
        withColumns(table("notes"), [column("notes", "a"), column("notes", "b")], into: &g)
        #expect(ids(SchemaAnalyzer.analyze(g)).contains("schema.all_nullable.notes"))
    }
}

@Suite("Index Advisor (DI-05)")
struct IndexAdvisorTests {
    private func index(_ name: String, table: String, unused: Bool, unique: Bool) -> (GraphNode, GraphEdge) {
        let node = GraphNode(id: "idx:\(name)", kind: .index, name: name,
                             attrs: ["unique": String(unique), "unused": String(unused), "idx_scan": unused ? "0" : "9"])
        return (node, GraphEdge(src: "tbl:\(table)", dst: "idx:\(name)", kind: .hasIndex))
    }

    private func base(_ table: GraphNode, _ index: (GraphNode, GraphEdge)) -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(table)
        g.addNode(index.0)
        g.addEdge(index.1)
        return g
    }

    @Test func flagsUnusedNonUniqueIndexWithDialectAwareDropSQL() {
        let g = base(GraphNode(id: "tbl:t", kind: .table, name: "t"),
                     index("dead_idx", table: "t", unused: true, unique: false))
        let pg = IndexAdvisor.analyze(g, dialect: .postgres).first { $0.id == "index.unused.dead_idx" }
        #expect(pg?.severity == .warning)
        #expect(pg?.suggestedSQL == "DROP INDEX dead_idx;")
        let mysql = IndexAdvisor.analyze(g, dialect: .mysql).first { $0.id == "index.unused.dead_idx" }
        #expect(mysql?.suggestedSQL == "DROP INDEX dead_idx ON t;")
    }

    @Test func skipsUnusedUniqueIndex() {
        let g = base(GraphNode(id: "tbl:t", kind: .table, name: "t"),
                     index("t_pkey", table: "t", unused: true, unique: true))
        #expect(IndexAdvisor.analyze(g, dialect: .postgres).isEmpty)
    }

    @Test func flagsSequentialScanHeavyTable() {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "tbl:big", kind: .table, name: "big",
                            attrs: ["seq_scan": "200", "idx_scan": "1", "rows": "5000"]))
        g.addNode(GraphNode(id: "tbl:small", kind: .table, name: "small",
                            attrs: ["seq_scan": "5", "idx_scan": "0", "rows": "10"]))
        let flagged = Set(IndexAdvisor.analyze(g, dialect: .postgres).map(\.id))
        #expect(flagged.contains("index.seq_scan.big"))
        #expect(!flagged.contains("index.seq_scan.small"))
    }
}

@Suite("InsightEngine ordering")
struct InsightEngineTests {
    @Test func sortsMostSevereFirst() {
        var g = SchemaGraph()
        // A warning (missing PK) and an info (all-nullable) from the same table.
        g.addNode(GraphNode(id: "tbl:t", kind: .table, name: "t"))
        for name in ["a", "b"] {
            let col = GraphNode(id: "col:t.\(name)", kind: .column, name: name,
                                attrs: ["primaryKey": "false", "nullable": "true", "type": "int"])
            g.addNode(col)
            g.addEdge(GraphEdge(src: "tbl:t", dst: col.id, kind: .hasColumn))
        }
        let insights = InsightEngine.analyze(g, dialect: .postgres)
        #expect(insights.count >= 2)
        #expect(insights.first?.severity == .warning) // missing_pk before all_nullable
    }
}
