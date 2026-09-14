import BerryCore
import BerryDriverKit
import Foundation

/// Harvests execution plans for the recent workload
/// For each distinct recent SELECT it runs plain `EXPLAIN` — which
/// estimates the plan WITHOUT executing the query, so no user rows are read
/// (Q6) — parses the plan, and feeds the Query Analyzer.
///
/// Best-effort: statements that fail to plan (stale schema, dialect quirks) are
/// skipped. EXPLAIN goes through the single SQL path (N1) but opts out of query
/// history so plan probes never masquerade as user queries.
public enum PlanHarvester {
    /// Analyze up to `limit` distinct recent SELECTs from the workload.
    public static func analyze(
        statements: [String], session: Session, limit: Int = 30
    ) async -> [Insight] {
        var analyzed: [AnalyzedQuery] = []
        for sql in candidates(statements, limit: limit) {
            guard let plan = await explain(sql, session: session) else { continue }
            analyzed.append(AnalyzedQuery(sql: sql, plan: plan))
        }
        return QueryPlanAnalyzer.analyze(analyzed)
    }

    // MARK: - Candidate selection

    /// Distinct, EXPLAIN-able SELECTs — skips non-SELECTs, already-EXPLAIN'd
    /// statements, and the app's own catalog/stats probes.
    static func candidates(_ statements: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in statements {
            let sql = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = sql.lowercased()
            guard lower.hasPrefix("select"), !lower.hasPrefix("explain") else { continue }
            guard !isProbe(lower) else { continue }
            guard seen.insert(normalize(lower)).inserted else { continue }
            result.append(sql)
            if result.count >= limit { break }
        }
        return result
    }

    /// The harvester's own metadata reads (stats/catalog) — never worth planning.
    private static func isProbe(_ lower: String) -> Bool {
        lower.contains("pg_stat") || lower.contains("pg_catalog")
            || lower.contains("information_schema") || lower.contains("sqlite_master")
    }

    /// Collapse whitespace so trivially-different spellings dedupe to one probe.
    private static func normalize(_ lower: String) -> String {
        lower.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .joined(separator: " ")
    }

    // MARK: - EXPLAIN

    private static func explain(_ sql: String, session: Session) async -> QueryPlan? {
        let prefix = session.dialect.explainPrefix(analyze: false)
        let rows = await rows(of: "\(prefix) \(sql)", session)
        guard !rows.isEmpty else { return nil }
        return QueryPlanParser.parse(rows: rows, dialect: session.config.driver)
    }

    /// Runs a plan probe through the single SQL path (N1) with NO auto-LIMIT
    /// (it would corrupt the EXPLAIN) and NO history recording. Best-effort —
    /// any error yields no rows and the statement is skipped.
    private static func rows(of sql: String, _ session: Session) async -> [[String: String]] {
        do {
            var columns: [String] = []
            var result: [[String: String]] = []
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
}
