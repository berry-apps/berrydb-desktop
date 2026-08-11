import BerryDriverKit
import Foundation

/// Query Analyzer (docs/architecture/11 §7, DI-06): turns parsed EXPLAIN plans
/// of the recent workload into insights. The signal is a full table scan — a
/// query that reads an entire table without an index — aggregated per table so
/// one hot table doesn't produce a wall of near-identical findings.
///
/// Pure and offline: it reasons over already-parsed `AnalyzedQuery` values, so
/// the rules are deterministic and unit-tested without a database. The fix
/// (which columns to index) needs human/AI judgement, so no `suggestedSQL` is
/// emitted — the finding points at the table and tells the user to verify with
/// EXPLAIN.
public enum QueryPlanAnalyzer {
    public static func analyze(_ queries: [AnalyzedQuery]) -> [Insight] {
        var count: [String: Int] = [:]
        var example: [String: String] = [:]

        for query in queries {
            for table in Set(query.plan.fullScans.map(\.table)) {
                count[table, default: 0] += 1
                if example[table] == nil { example[table] = query.sql }
            }
        }

        return count.keys.sorted().map { table in
            let n = count[table] ?? 0
            let plural = n == 1 ? "query" : "queries"
            return Insight(
                id: "query.full_scan.\(table)",
                severity: .warning,
                category: .query,
                title: "Full table scan on \(table)",
                detail: "\(n) recent \(plural) read all of \(table) without using an index (per EXPLAIN). "
                    + "Add an index on the WHERE/JOIN columns, then re-run EXPLAIN to confirm the plan "
                    + "switches to an index scan. Example: \(excerpt(example[table] ?? ""))",
                targetName: table
            )
        }
    }

    /// A short one-line preview of the offending statement.
    private static func excerpt(_ sql: String, limit: Int = 120) -> String {
        let flat = sql.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }
}
