import BerryCore
import BerryDriverKit
import Testing

@testable import BerryGraph

/// Migration Preview Analyzer — runs the
/// existing Schema/Index Analyzer rules against an edited `TableDesign`
/// before any DDL executes.
@Suite("Migration Preview Analyzer")
struct MigrationPreviewAnalyzerTests {
    private func column(
        _ name: String, type: String = "int", pk: Bool = false, nullable: Bool = true
    ) -> ColumnDesign {
        ColumnDesign(name: name, type: type, isNullable: nullable, isPrimaryKey: pk)
    }

    /// `orders(id PK, customer_id)` with `customers(id PK)` already in the
    /// graph — a baseline with no findings on `orders` yet.
    private func baseGraph() -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "table:.orders", kind: .table, name: "orders"))
        g.addNode(GraphNode(id: "column:.orders.id", kind: .column, name: "id",
                            attrs: ["type": "int", "nullable": "false", "primaryKey": "true"]))
        g.addEdge(GraphEdge(src: "table:.orders", dst: "column:.orders.id", kind: .hasColumn))
        g.addNode(GraphNode(id: "table:.customers", kind: .table, name: "customers"))
        g.addNode(GraphNode(id: "column:.customers.id", kind: .column, name: "id",
                            attrs: ["type": "int", "nullable": "false", "primaryKey": "true"]))
        g.addEdge(GraphEdge(src: "table:.customers", dst: "column:.customers.id", kind: .hasColumn))
        g.addNode(GraphNode(id: "column:.customers.name", kind: .column, name: "name",
                            attrs: ["type": "text", "nullable": "true", "primaryKey": "false"]))
        g.addEdge(GraphEdge(src: "table:.customers", dst: "column:.customers.name", kind: .hasColumn))
        return g
    }

    @Test func flagsHiddenForeignKeyIntroducedByTheEdit() {
        let current = baseGraph()
        let edited = TableDesign(
            name: "orders",
            columns: [column("id", pk: true, nullable: false), column("customer_id")]
        )
        let findings = MigrationPreviewAnalyzer.preview(current: current, editing: edited, dialect: .postgres)
        #expect(Set(findings.map(\.id)).contains("schema.hidden_fk.orders.customer_id"))
    }

    @Test func omitsFindingsAlreadyPresentBeforeTheEdit() {
        // "customers" already has no primary key in the baseline — editing an
        // unrelated table ("orders") must not resurface that pre-existing debt.
        var current = baseGraph()
        current.removeNode("column:.customers.id")
        let baselineIDs = Set(InsightEngine.analyze(current, dialect: .postgres).map(\.id))
        #expect(baselineIDs.contains("schema.missing_pk.customers"))

        let edited = TableDesign(name: "orders", columns: [column("id", pk: true, nullable: false)])
        let findings = MigrationPreviewAnalyzer.preview(current: current, editing: edited, dialect: .postgres)
        #expect(!findings.map(\.id).contains("schema.missing_pk.customers"))
    }

    @Test func flagsMissingPrimaryKeyWhenTheEditDropsIt() {
        let current = baseGraph()
        // Dropping the PK column, keeping only a plain one.
        let edited = TableDesign(name: "orders", columns: [column("note", nullable: true)])
        let findings = MigrationPreviewAnalyzer.preview(current: current, editing: edited, dialect: .postgres)
        #expect(Set(findings.map(\.id)).contains("schema.missing_pk.orders"))
    }

    @Test func applyingReplacesColumnsIndexesAndForeignKeys() {
        let current = baseGraph()
        let edited = TableDesign(
            name: "orders",
            columns: [column("id", pk: true, nullable: false), column("total", type: "numeric")],
            indexes: [IndexDesign(name: "orders_total_idx", columns: ["total"], isUnique: false)],
            foreignKeys: [ForeignKeyDesign(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
        )
        let hypothetical = MigrationPreviewAnalyzer.applying(edited, to: current)

        let columns = hypothetical.neighbors(of: "table:.orders", direction: .outgoing, kinds: [.hasColumn])
            .compactMap { hypothetical.nodes[$0]?.name }
        #expect(Set(columns) == ["id", "total"])

        let indexes = hypothetical.neighbors(of: "table:.orders", direction: .outgoing, kinds: [.hasIndex])
            .compactMap { hypothetical.nodes[$0]?.name }
        #expect(indexes == ["orders_total_idx"])

        #expect(hypothetical.edges.contains {
            $0.src == "table:.orders" && $0.dst == "table:.customers" && $0.kind == .references
        })
    }

    @Test func riskLevelReflectsWorstSeverity() {
        #expect(MigrationPreviewAnalyzer.riskLevel(for: []) == .low)
        let warning = Insight(id: "x", severity: .warning, category: .schema, title: "t", detail: "d")
        #expect(MigrationPreviewAnalyzer.riskLevel(for: [warning]) == .medium)
        let critical = Insight(id: "y", severity: .critical, category: .schema, title: "t", detail: "d")
        #expect(MigrationPreviewAnalyzer.riskLevel(for: [warning, critical]) == .high)
    }
}
