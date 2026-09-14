import BerryDriverKit
import Foundation

/// Index analysis over the DSG + harvested stats
/// unused non-unique indexes (safe to drop) and tables scanned
/// sequentially far more than by index. Pure — reads only the graph + stats.
public enum IndexAdvisor {
    /// A table needs at least this many sequential scans over this many rows
    /// before "frequent seq scan" is worth flagging (heuristic — the real fix
 /// needs the workload).
    static let minSeqScans = 100
    static let minRows = 1000

    public static func analyze(_ graph: SchemaGraph, dialect: DriverID) -> [Insight] {
        unusedIndexes(graph, dialect: dialect) + sequentialScanHeavy(graph)
    }

    // MARK: - Rules

    private static func unusedIndexes(_ graph: SchemaGraph, dialect: DriverID) -> [Insight] {
        graph.nodes.values
            .filter { $0.kind == .index && $0.attrs["unused"] == "true" && $0.attrs["unique"] != "true" }
            .sorted { $0.name < $1.name }
            .map { index in
                let table = graph.neighbors(of: index.id, direction: .incoming, kinds: [.hasIndex])
                    .compactMap { graph.nodes[$0]?.name }.first
                return Insight(
                    id: "index.unused.\(index.name)",
                    severity: .warning, category: .index,
                    title: "Unused index \(index.name)",
                    detail: "\(index.name)\(table.map { " on \($0)" } ?? "") has 0 scans since stats were "
                        + "last reset; it only adds write overhead. Confirm it isn't reserved for a rare "
                        + "job before dropping.",
                    targetNode: index.id, targetName: table,
                    suggestedSQL: dropIndexSQL(index.name, table: table, dialect: dialect)
                )
            }
    }

    private static func sequentialScanHeavy(_ graph: SchemaGraph) -> [Insight] {
        graph.nodes.values
            .filter { $0.kind == .table }
            .sorted { $0.name < $1.name }
            .compactMap { table -> Insight? in
                let seq = Int(table.attrs["seq_scan"] ?? "") ?? 0
                let idx = Int(table.attrs["idx_scan"] ?? "") ?? 0
                let rows = Int(table.attrs["rows"] ?? "") ?? 0
                guard seq >= minSeqScans, rows >= minRows, seq > idx else { return nil }
                return Insight(
                    id: "index.seq_scan.\(table.name)",
                    severity: .info, category: .index,
                    title: "Frequent sequential scans on \(table.name)",
                    detail: "\(table.name) has \(seq) sequential scans vs \(idx) index scans over ~\(rows) "
                        + "rows; a query-driven index may help. Check the workload (EXPLAIN) before adding one.",
                    targetNode: table.id, targetName: table.name
                )
            }
    }

    // MARK: - Helpers

    private static func dropIndexSQL(_ index: String, table: String?, dialect: DriverID) -> String? {
        switch dialect {
        case .postgres, .sqlite: "DROP INDEX \(index);"
        case .mysql, .sqlserver: table.map { "DROP INDEX \(index) ON \($0);" }
        case .redis, .dynamodb, .mongodb, .qdrant, .elasticsearch: nil
        }
    }
}
