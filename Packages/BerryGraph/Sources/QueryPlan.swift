import BerryDriverKit
import Foundation

/// A normalized execution plan (docs/architecture/11 §4, DI-06). Dialect EXPLAIN
/// output differs wildly, so `QueryPlanParser` boils each down to the one signal
/// the Query Analyzer needs: which tables the plan scans, and whether each scan
/// rides an index or reads the whole table.
public struct QueryPlan: Sendable, Equatable {
    public struct Scan: Sendable, Equatable {
        public let table: String
        public let usesIndex: Bool
        /// Planner row estimate, when the plan exposes one.
        public let estimatedRows: Int?

        public init(table: String, usesIndex: Bool, estimatedRows: Int? = nil) {
            self.table = table
            self.usesIndex = usesIndex
            self.estimatedRows = estimatedRows
        }
    }

    public let scans: [Scan]

    public init(scans: [Scan]) { self.scans = scans }

    /// Scans that read the whole table with no index — the DI-06 signal.
    public var fullScans: [Scan] { scans.filter { !$0.usesIndex } }
}

/// One executed query paired with its parsed plan — the Query Analyzer's input.
public struct AnalyzedQuery: Sendable, Equatable {
    public let sql: String
    public let plan: QueryPlan

    public init(sql: String, plan: QueryPlan) {
        self.sql = sql
        self.plan = plan
    }
}

/// Parses dialect EXPLAIN output (already reduced to column→string row maps by
/// the harvester) into a `QueryPlan`. Pure and offline — deterministic given the
/// plan text, so the rules are unit-tested without a database.
public enum QueryPlanParser {
    public static func parse(rows: [[String: String]], dialect: DriverID) -> QueryPlan {
        switch dialect {
        case .postgres: parsePostgres(rows)
        case .mysql: parseMySQL(rows)
        case .sqlite: parseSQLite(rows)
        case .sqlserver, .redis, .dynamodb, .mongodb, .qdrant, .elasticsearch: QueryPlan(scans: [])
        }
    }

    // MARK: - Postgres — text plan under a single "QUERY PLAN" column.

    private static func parsePostgres(_ rows: [[String: String]]) -> QueryPlan {
        var scans: [QueryPlan.Scan] = []
        for row in rows {
            guard let line = row["QUERY PLAN"] else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "Seq Scan on users  (cost=0.00..1.10 rows=10 ...)" — full scan.
            // "Index Scan using idx on users ...", "Index Only Scan ... on users",
            // "Bitmap Index Scan ..." → index-backed.
            let isSeqScan = trimmed.hasPrefix("Seq Scan on ")
            let isIndexScan = trimmed.contains("Index Scan") || trimmed.contains("Index Only Scan")
            guard isSeqScan || isIndexScan else { continue }
            guard let table = tableAfterOn(trimmed) else { continue }
            scans.append(.init(
                table: table, usesIndex: !isSeqScan, estimatedRows: rowsEstimate(trimmed)
            ))
        }
        return QueryPlan(scans: scans)
    }

    /// The table name following the last " on " in a Postgres plan line,
    /// stripped of any schema qualifier and alias.
    private static func tableAfterOn(_ line: String) -> String? {
        guard let range = line.range(of: " on ", options: .backwards) else { return nil }
        let rest = line[range.upperBound...]
        guard let token = rest.split(separator: " ").first else { return nil }
        let name = token.split(separator: ".").last.map(String.init) ?? String(token)
        return name.isEmpty ? nil : name
    }

    private static func rowsEstimate(_ line: String) -> Int? {
        guard let range = line.range(of: "rows=") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - MySQL — tabular EXPLAIN (type/table/key/rows columns).

    private static func parseMySQL(_ rows: [[String: String]]) -> QueryPlan {
        var scans: [QueryPlan.Scan] = []
        for row in rows {
            guard let table = row["table"], !table.isEmpty else { continue }
            // access type "ALL" is a full table scan; anything else rides an
            // index (const/ref/range/index/eq_ref).
            let type = (row["type"] ?? "").lowercased()
            scans.append(.init(
                table: table,
                usesIndex: type != "all",
                estimatedRows: row["rows"].flatMap { Int($0) }
            ))
        }
        return QueryPlan(scans: scans)
    }

    // MARK: - SQLite — EXPLAIN QUERY PLAN, text under "detail".

    private static func parseSQLite(_ rows: [[String: String]]) -> QueryPlan {
        var scans: [QueryPlan.Scan] = []
        for row in rows {
            guard let detail = row["detail"] else { continue }
            // "SCAN t" / "SCAN TABLE t" → full scan;
            // "SEARCH t USING INDEX ix" / "... USING INTEGER PRIMARY KEY" → index.
            let isScan = detail.hasPrefix("SCAN ")
            let isSearch = detail.hasPrefix("SEARCH ")
            guard isScan || isSearch else { continue }
            guard let table = sqliteTable(detail) else { continue }
            scans.append(.init(table: table, usesIndex: isSearch))
        }
        return QueryPlan(scans: scans)
    }

    private static func sqliteTable(_ detail: String) -> String? {
        var tokens = detail.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        tokens.removeFirst() // SCAN | SEARCH
        if tokens.first == "TABLE" { tokens.removeFirst() } // legacy "SCAN TABLE t"
        guard let name = tokens.first, name != "USING" else { return nil }
        return name
    }
}
