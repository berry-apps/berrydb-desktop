import BerryCore
import BerryDriverKit
import Foundation

/// Enriches the structural DSG with harvested table/index statistics
/// (the data foundation for the Index Advisor).
/// **Metadata only**: reads the engine's catalog/stats views through
/// `QueryService` (single SQL path, N1) and never touches user data (Q6).
/// Best-effort — a missing stats view or a permissions error leaves the graph
/// unchanged; stats are optional enrichment on top of the structural graph.
public enum StatsHarvester {
    /// Runs the dialect's stats queries and merges the numbers into node attrs.
    public static func enrich(_ graph: SchemaGraph, session: Session) async -> SchemaGraph {
        switch session.config.driver {
        case .postgres: return await enrichPostgres(graph, session: session)
        case .mysql: return await enrichMySQL(graph, session: session)
        default: return graph // SQLite/others: structural graph only for now.
        }
    }

    // MARK: - Postgres (pg_stat_user_*)

    private static func enrichPostgres(_ graph: SchemaGraph, session: Session) async -> SchemaGraph {
        var g = graph
        for row in await rows(of: """
            SELECT relname, n_live_tup, seq_scan, coalesce(idx_scan, 0) AS idx_scan,
                   pg_total_relation_size(relid) AS size_bytes
            FROM pg_stat_user_tables
            """, session) {
            guard let name = row["relname"] else { continue }
            merge(&g, kind: .table, name: name, [
                "rows": row["n_live_tup"], "seq_scan": row["seq_scan"],
                "idx_scan": row["idx_scan"], "size_bytes": row["size_bytes"],
            ])
        }
        for row in await rows(of: """
            SELECT indexrelname, coalesce(idx_scan, 0) AS idx_scan
            FROM pg_stat_user_indexes
            """, session) {
            guard let name = row["indexrelname"], let scan = row["idx_scan"] else { continue }
            merge(&g, kind: .index, name: name, [
                "idx_scan": scan, "unused": scan == "0" ? "true" : "false",
            ])
        }
        return g
    }

    // MARK: - MySQL (information_schema)

    private static func enrichMySQL(_ graph: SchemaGraph, session: Session) async -> SchemaGraph {
        var g = graph
        for row in await rows(of: """
            SELECT table_name AS name, table_rows AS n_rows,
                   (data_length + index_length) AS size_bytes
            FROM information_schema.tables
            WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
            """, session) {
            guard let name = row["name"] else { continue }
            merge(&g, kind: .table, name: name, [
                "rows": row["n_rows"], "size_bytes": row["size_bytes"],
            ])
        }
        return g
    }

    // MARK: - Helpers

    /// Runs a read-only stats query through the single SQL path (N1) and returns
    /// its rows as column→string maps. Best-effort — any error yields no rows.
    private static func rows(of sql: String, _ session: Session) async -> [[String: String]] {
        do {
            var columns: [String] = []
            var result: [[String: String]] = []
            // Metadata probe: no auto-LIMIT (would truncate a large catalog) and
 // no history recording (harvesters aren't user queries).
            for try await event in QueryService.execute(
                sql, on: session, autoLimit: nil, recordHistory: false
            ) {
                switch event {
                case let .columns(metas):
                    columns = metas.map(\.name)
                case let .rows(batch):
                    for row in batch {
                        var map: [String: String] = [:]
                        for (index, value) in row.enumerated() where index < columns.count {
                            if let string = value.displayString { map[columns[index]] = string }
                        }
                        result.append(map)
                    }
                case .complete:
                    break
                }
            }
            return result
        } catch {
            return []
        }
    }

    /// Merges non-nil stat attrs into the first node matching kind+name.
    private static func merge(
        _ graph: inout SchemaGraph, kind: NodeKind, name: String, _ attrs: [String: String?]
    ) {
        guard var node = graph.nodes.values.first(where: { $0.kind == kind && $0.name == name }) else { return }
        for (key, value) in attrs { if let value { node.attrs[key] = value } }
        graph.addNode(node)
    }
}
