import BerryDriverKit
import Foundation
import Testing

@testable import BerryGraph

/// Query Analyzer (docs/architecture/11 §7, DI-06) — pure plan parsing +
/// aggregation, deterministic and offline (no database).
@Suite("Query plan parser (DI-06)")
struct QueryPlanParserTests {
    @Test func postgresSeqScanIsFullScan() {
        let plan = QueryPlanParser.parse(rows: [
            ["QUERY PLAN": "Seq Scan on users  (cost=0.00..18.10 rows=810 width=36)"],
            ["QUERY PLAN": "  Filter: (age > 30)"],
        ], dialect: .postgres)
        #expect(plan.scans == [.init(table: "users", usesIndex: false, estimatedRows: 810)])
        #expect(plan.fullScans.map(\.table) == ["users"])
    }

    @Test func postgresIndexScanUsesIndex() {
        let plan = QueryPlanParser.parse(rows: [
            ["QUERY PLAN": "Index Scan using users_pkey on public.users  (cost=0.29..8.30 rows=1 width=36)"],
        ], dialect: .postgres)
        #expect(plan.scans == [.init(table: "users", usesIndex: true, estimatedRows: 1)])
        #expect(plan.fullScans.isEmpty)
    }

    @Test func mysqlTypeAllIsFullScan() {
        let full = QueryPlanParser.parse(rows: [
            ["table": "orders", "type": "ALL", "key": "", "rows": "5000"],
        ], dialect: .mysql)
        #expect(full.fullScans.map(\.table) == ["orders"])
        #expect(full.scans.first?.estimatedRows == 5000)

        let indexed = QueryPlanParser.parse(rows: [
            ["table": "orders", "type": "ref", "key": "idx_customer", "rows": "3"],
        ], dialect: .mysql)
        #expect(indexed.fullScans.isEmpty)
    }

    @Test func sqliteScanVsSearch() {
        let scan = QueryPlanParser.parse(rows: [["detail": "SCAN t"]], dialect: .sqlite)
        #expect(scan.fullScans.map(\.table) == ["t"])

        let legacy = QueryPlanParser.parse(rows: [["detail": "SCAN TABLE t"]], dialect: .sqlite)
        #expect(legacy.fullScans.map(\.table) == ["t"])

        let search = QueryPlanParser.parse(
            rows: [["detail": "SEARCH t USING INDEX idx_name (name=?)"]], dialect: .sqlite
        )
        #expect(search.fullScans.isEmpty)
        #expect(search.scans.map(\.usesIndex) == [true])
    }
}

@Suite("Query analyzer aggregation (DI-06)")
struct QueryPlanAnalyzerTests {
    private func fullScan(_ table: String) -> QueryPlan {
        QueryPlan(scans: [.init(table: table, usesIndex: false)])
    }

    @Test func aggregatesFullScansPerTable() {
        let insights = QueryPlanAnalyzer.analyze([
            AnalyzedQuery(sql: "SELECT * FROM orders WHERE total > 10", plan: fullScan("orders")),
            AnalyzedQuery(sql: "SELECT id FROM orders WHERE status = 'x'", plan: fullScan("orders")),
            AnalyzedQuery(sql: "SELECT * FROM users WHERE email = 'a'", plan: fullScan("users")),
        ])
        #expect(insights.map(\.id) == ["query.full_scan.orders", "query.full_scan.users"])
        #expect(insights.allSatisfy { $0.severity == .warning && $0.category == .query })
        let orders = insights.first { $0.id == "query.full_scan.orders" }
        #expect(orders?.targetName == "orders")
        #expect(orders?.detail.contains("2 recent queries") == true)
        let users = insights.first { $0.id == "query.full_scan.users" }
        #expect(users?.detail.contains("1 recent query") == true)
    }

    @Test func indexedQueriesProduceNothing() {
        let indexed = QueryPlan(scans: [.init(table: "users", usesIndex: true)])
        let insights = QueryPlanAnalyzer.analyze([
            AnalyzedQuery(sql: "SELECT * FROM users WHERE id = 1", plan: indexed),
        ])
        #expect(insights.isEmpty)
    }
}

@Suite("Plan harvester candidate filter (DI-06)")
struct PlanHarvesterCandidateTests {
    @Test func keepsDistinctSelectsAndSkipsTheRest() {
        let result = PlanHarvester.candidates([
            "SELECT * FROM t WHERE x = 1",
            "select   *   from t where x = 1", // same statement, different spacing/case
            "INSERT INTO t VALUES (1)",        // not a SELECT
            "EXPLAIN SELECT * FROM t",         // already a plan probe
            "SELECT relname FROM pg_stat_user_tables", // harvester's own probe
            "  SELECT a FROM b  ",
        ], limit: 30)
        #expect(result == ["SELECT * FROM t WHERE x = 1", "SELECT a FROM b"])
    }

    @Test func respectsLimit() {
        let many = (1...50).map { "SELECT * FROM t\($0)" }
        #expect(PlanHarvester.candidates(many, limit: 5).count == 5)
    }
}
