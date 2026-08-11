import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

/// EXPLAIN plan tree parsing (ED-09).
@Suite("ExplainTreeParser (ED-09)")
struct ExplainTreeTests {
    @Test func parsesSQLiteQueryPlanByIDParent() throws {
        let columns = ["id", "parent", "notused", "detail"].map {
            ColumnMeta(name: $0, declaredType: "")
        }
        let rows: [[BerryValue]] = [
            [.int(3), .int(0), .int(0), .text("SCAN users")],
            [.int(8), .int(3), .int(0), .text("SEARCH orders USING INDEX idx (user_id=?)")],
        ]
        let tree = try #require(ExplainTreeParser.parse(columns: columns, rows: rows))
        #expect(tree.count == 1)
        #expect(tree[0].text == "SCAN users")
        #expect(tree[0].children.count == 1)
        #expect(tree[0].children[0].text.hasPrefix("SEARCH orders"))
    }

    @Test func parsesPostgresIndentedPlan() throws {
        let columns = [ColumnMeta(name: "QUERY PLAN", declaredType: "text")]
        let rows: [[BerryValue]] = [
            [.text("Nested Loop  (cost=0.29..16.34 rows=1 width=8)")],
            [.text("  ->  Seq Scan on users  (cost=0.00..1.05 rows=1 width=4)")],
            [.text("        Filter: (active IS TRUE)")],
            [.text("  ->  Index Scan using idx on orders  (cost=0.29..15.28 rows=1 width=12)")],
        ]
        let tree = try #require(ExplainTreeParser.parse(columns: columns, rows: rows))
        #expect(tree.count == 1)
        #expect(tree[0].text.hasPrefix("Nested Loop"))
        #expect(tree[0].children.count == 2)
        #expect(tree[0].children[0].text.hasPrefix("Seq Scan on users"))
        #expect(tree[0].children[0].children.first?.text == "Filter: (active IS TRUE)")
        #expect(tree[0].children[1].text.hasPrefix("Index Scan using idx"))
    }

    @Test func flatOutputFallsBackToNil() {
        // MySQL tabular EXPLAIN (multi-column) → no tree.
        let columns = ["id", "select_type", "table"].map { ColumnMeta(name: $0, declaredType: "") }
        let rows: [[BerryValue]] = [[.int(1), .text("SIMPLE"), .text("users")]]
        #expect(ExplainTreeParser.parse(columns: columns, rows: rows) == nil)
        // A single text column without arrows (a plain message) → no tree.
        let single = [ColumnMeta(name: "msg", declaredType: "text")]
        #expect(ExplainTreeParser.parse(columns: single, rows: [[.text("hello")]]) == nil)
    }

    /// Query Replay stores this string verbatim (DI-17, docs/architecture/13
    /// §5.2) — round-trips through `JSONSerialization` back into the same
    /// id/text/children shape.
    @Test func planNodeJSONStringRoundTripsTheTree() throws {
        let tree = [PlanNode(id: 1, text: "Seq Scan on orders", children: [
            PlanNode(id: 2, text: "Filter: (active IS TRUE)"),
        ])]

        let json = try #require(PlanNode.jsonString(of: tree))
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )

        #expect(decoded.count == 1)
        #expect(decoded[0]["text"] as? String == "Seq Scan on orders")
        let children = try #require(decoded[0]["children"] as? [[String: Any]])
        #expect(children.count == 1)
        #expect(children[0]["text"] as? String == "Filter: (active IS TRUE)")
    }

    @Test func planNodeJSONStringOfEmptyTreeIsAnEmptyArray() {
        #expect(PlanNode.jsonString(of: []) == "[]")
    }
}
