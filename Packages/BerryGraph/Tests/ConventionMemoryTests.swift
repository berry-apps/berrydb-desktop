import BerryDriverKit
import Foundation
import Testing

@testable import BerryGraph

@Suite("Convention Memory (DI-21)")
struct ConventionMemoryTests {
    private func table(_ name: String) -> GraphNode {
        GraphNode(id: "tbl:\(name)", kind: .table, name: name)
    }

    private func index(_ name: String, table: String, column: String) -> (GraphNode, GraphEdge) {
        let node = GraphNode(
            id: "idx:\(name)",
            kind: .index,
            name: name,
            attrs: ["columns": column]
        )
        let edge = GraphEdge(src: "tbl:\(table)", dst: "idx:\(name)", kind: .hasIndex)
        return (node, edge)
    }

    @Test func suggestedIndexNameProducesExpectedLowercaseString() {
        #expect(ConventionMemory.suggestedIndexName(table: "users", column: "email") == "idx_users_email")
        #expect(ConventionMemory.suggestedIndexName(table: "Orders", column: "CreatedAt") == "idx_orders_createdat")
    }

    @Test func hasIndexNamingConventionRequiresAtLeastTwoConformingIndexesAndMajority() {
        // >= 2 of 3 indexes follow template -> true
        var g1 = SchemaGraph()
        g1.addNode(table("users"))
        g1.addNode(table("orders"))

        let idx1 = index("idx_users_email", table: "users", column: "email")
        let idx2 = index("idx_orders_created_at", table: "orders", column: "created_at")
        let idx3 = index("custom_idx_orders_status", table: "orders", column: "status")

        for item in [idx1, idx2, idx3] {
            g1.addNode(item.0)
            g1.addEdge(item.1)
        }
        #expect(ConventionMemory.hasIndexNamingConvention(g1) == true)

        // Only 1 of 3 indexes follows template -> false
        var g2 = SchemaGraph()
        g2.addNode(table("users"))
        g2.addNode(table("orders"))

        let idx4 = index("idx_users_email", table: "users", column: "email")
        let idx5 = index("orders_created_at_idx", table: "orders", column: "created_at")
        let idx6 = index("custom_idx_orders_status", table: "orders", column: "status")

        for item in [idx4, idx5, idx6] {
            g2.addNode(item.0)
            g2.addEdge(item.1)
        }
        #expect(ConventionMemory.hasIndexNamingConvention(g2) == false)

        // Fewer than 2 indexes exist (only 1 index) -> false
        var g3 = SchemaGraph()
        g3.addNode(table("users"))
        let idx7 = index("idx_users_email", table: "users", column: "email")
        g3.addNode(idx7.0)
        g3.addEdge(idx7.1)
        #expect(ConventionMemory.hasIndexNamingConvention(g3) == false)
    }

    @Test func namingMismatchesOnlyFlagsWhenConventionIsEstablished() {
        // Convention IS established (2 conforming, 1 non-conforming)
        var gEstablished = SchemaGraph()
        gEstablished.addNode(table("users"))
        gEstablished.addNode(table("orders"))

        let idx1 = index("idx_users_email", table: "users", column: "email")
        let idx2 = index("idx_orders_created_at", table: "orders", column: "created_at")
        let idx3 = index("orders_status_custom", table: "orders", column: "status")

        for item in [idx1, idx2, idx3] {
            gEstablished.addNode(item.0)
            gEstablished.addEdge(item.1)
        }

        let mismatches = ConventionMemory.namingMismatches(gEstablished)
        #expect(mismatches.count == 1)
        let mismatch = mismatches.first
        #expect(mismatch?.id == "schema.naming_convention.orders_status_custom")
        #expect(mismatch?.severity == .info)
        #expect(mismatch?.category == .schema)
        #expect(mismatch?.targetNode == "idx:orders_status_custom")
        #expect(mismatch?.targetName == "orders")

        // Convention IS NOT established (only 1 conforming, 2 non-conforming)
        var gNotEstablished = SchemaGraph()
        gNotEstablished.addNode(table("users"))
        gNotEstablished.addNode(table("orders"))

        let idx4 = index("idx_users_email", table: "users", column: "email")
        let idx5 = index("orders_created_at_idx", table: "orders", column: "created_at")
        let idx6 = index("orders_status_custom", table: "orders", column: "status")

        for item in [idx4, idx5, idx6] {
            gNotEstablished.addNode(item.0)
            gNotEstablished.addEdge(item.1)
        }

        #expect(ConventionMemory.namingMismatches(gNotEstablished).isEmpty)
    }

    // MARK: - Database Memory (docs/feature/07 §12): history-mining

    private func establishedConventionGraph() -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(table("users"))
        g.addNode(table("orders"))
        for item in [
            index("idx_users_email", table: "users", column: "email"),
            index("idx_orders_created_at", table: "orders", column: "created_at"),
            index("orders_status_custom", table: "orders", column: "status"),
        ] {
            g.addNode(item.0)
            g.addEdge(item.1)
        }
        return g
    }

    private func notEstablishedConventionGraph() -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(table("users"))
        g.addNode(table("orders"))
        for item in [
            index("idx_users_email", table: "users", column: "email"),
            index("orders_created_at_idx", table: "orders", column: "created_at"),
            index("orders_status_custom", table: "orders", column: "status"),
        ] {
            g.addNode(item.0)
            g.addEdge(item.1)
        }
        return g
    }

    @Test func hasEstablishedIndexNamingConventionRequiresMajorityAcrossHistory() {
        let established = establishedConventionGraph()
        let notEstablished = notEstablishedConventionGraph()

        // Current + 2 prior snapshots all show the convention -> true.
        #expect(ConventionMemory.hasEstablishedIndexNamingConvention(
            current: established, history: [established, established]
        ))

        // Current shows it, but a majority of history doesn't -> false: a
        // coincidental majority in just today's snapshot isn't enough.
        #expect(!ConventionMemory.hasEstablishedIndexNamingConvention(
            current: established, history: [notEstablished, notEstablished]
        ))

        // Empty history falls back to exactly hasIndexNamingConvention.
        #expect(
            ConventionMemory.hasEstablishedIndexNamingConvention(current: established, history: [])
                == ConventionMemory.hasIndexNamingConvention(established)
        )
    }

    @Test func namingMismatchesWithHistoryRequiresConsistentConvention() {
        let established = establishedConventionGraph()
        let notEstablished = notEstablishedConventionGraph()

        // Majority of history agrees -> still flags the one mismatch.
        let consistent = ConventionMemory.namingMismatches(established, history: [established, notEstablished])
        #expect(consistent.count == 1)

        // Majority of history disagrees -> no established convention to
        // compare against, even though today's snapshot alone would show one.
        let inconsistent = ConventionMemory.namingMismatches(established, history: [notEstablished, notEstablished])
        #expect(inconsistent.isEmpty)
    }
}
