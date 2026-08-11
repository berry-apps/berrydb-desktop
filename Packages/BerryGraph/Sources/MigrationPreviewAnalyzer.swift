import BerryCore
import BerryDriverKit
import Foundation

/// Runs the Schema/Index Analyzer rule engine (DI-06/07) against a
/// hypothetical version of the DSG where one table's design has been replaced
/// by an edited `TableDesign` — before any DDL runs (DI-15 "Migration Preview
/// Analyzer", docs/architecture/13 §5.2). Pure — never touches the DBMS; the
/// caller supplies the already-harvested graph (e.g. from `GraphStore`).
public enum MigrationPreviewAnalyzer {
    /// Aggregate risk for a set of findings, for a one-line "Overall Risk"
    /// summary (the `07.md #3` example) — derived straight from severity, not
    /// a separate signal.
    public enum RiskLevel: String, Sendable, Equatable {
        case low, medium, high
    }

    /// Findings the edit would introduce, compared against the current graph
    /// unchanged — so the reviewer sees only what THIS migration adds, not
    /// pre-existing schema debt. `design.name` identifies the table being
    /// edited; a design whose name doesn't match any table in `current` is
    /// treated as a new table.
    public static func preview(
        current: SchemaGraph, editing design: TableDesign, dialect: DriverID
    ) -> [Insight] {
        let baseline = Set(InsightEngine.analyze(current, dialect: dialect).map(\.id))
        let hypothetical = applying(design, to: current)
        return InsightEngine.analyze(hypothetical, dialect: dialect)
            .filter { !baseline.contains($0.id) }
    }

    public static func riskLevel(for insights: [Insight]) -> RiskLevel {
        if insights.contains(where: { $0.severity == .critical }) { return .high }
        if insights.contains(where: { $0.severity == .warning }) { return .medium }
        return .low
    }

    /// Replaces `design.name`'s columns/indexes/foreign keys in `graph` with
    /// the edited design, using the same node/edge shape `SchemaGraphBuilder`
    /// produces from a harvested `TableDetail`.
    static func applying(_ design: TableDesign, to graph: SchemaGraph) -> SchemaGraph {
        var result = graph
        let tableID = GraphID.node(.table, database: design.database, name: design.name)
        if result.nodes[tableID] == nil {
            result.addNode(GraphNode(id: tableID, kind: .table, name: design.name, database: design.database))
        }

        for child in result.neighbors(of: tableID, direction: .outgoing, kinds: [.hasColumn, .hasIndex]) {
            result.removeNode(child)
        }
        result.removeEdges(from: tableID, kind: .references)

        for column in design.columns where !column.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let columnID = GraphID.node(.column, database: design.database, name: column.name, in: design.name)
            result.addNode(GraphNode(
                id: columnID, kind: .column, name: column.name, database: design.database,
                attrs: [
                    "type": column.type,
                    "nullable": String(column.isNullable),
                    "primaryKey": String(column.isPrimaryKey),
                ]
            ))
            result.addEdge(GraphEdge(src: tableID, dst: columnID, kind: .hasColumn))
        }

        for index in design.indexes where !index.name.trimmingCharacters(in: .whitespaces).isEmpty {
            let indexID = GraphID.node(.index, database: design.database, name: index.name, in: design.name)
            result.addNode(GraphNode(
                id: indexID, kind: .index, name: index.name, database: design.database,
                attrs: ["unique": String(index.isUnique), "columns": index.columns.joined(separator: ",")]
            ))
            result.addEdge(GraphEdge(src: tableID, dst: indexID, kind: .hasIndex))
        }

        for fk in design.foreignKeys
        where !fk.column.trimmingCharacters(in: .whitespaces).isEmpty
            && !fk.referencedTable.trimmingCharacters(in: .whitespaces).isEmpty {
            let parentID = GraphID.node(.table, database: design.database, name: fk.referencedTable)
            if result.nodes[parentID] == nil {
                result.addNode(GraphNode(id: parentID, kind: .table, name: fk.referencedTable, database: design.database))
            }
            result.addEdge(GraphEdge(
                src: tableID, dst: parentID, kind: .references,
                attrs: ["column": fk.column, "referencedColumn": fk.referencedColumn]
            ))
        }

        return result
    }
}
