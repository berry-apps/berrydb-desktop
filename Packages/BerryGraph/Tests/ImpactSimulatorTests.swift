import BerryDriverKit
import Testing

@testable import BerryGraph

/// Impact Simulator.
@Suite("Impact Simulator")
struct ImpactSimulatorTests {
    /// orders -> customers (FK), plus an index on orders.
    private func sampleGraph() -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "table:orders", kind: .table, name: "orders"))
        g.addNode(GraphNode(id: "table:customers", kind: .table, name: "customers"))
        g.addEdge(GraphEdge(src: "table:orders", dst: "table:customers", kind: .references))
        g.addNode(GraphNode(id: "index:orders_customer_idx", kind: .index, name: "orders_customer_idx"))
        g.addEdge(GraphEdge(src: "table:orders", dst: "index:orders_customer_idx", kind: .hasIndex))
        return g
    }

    @Test func droppingATableAffectsItselfAndDependents() {
        let report = ImpactSimulator.simulate(changing: "table:customers", in: sampleGraph(), workload: [])
        #expect(Set(report.affectedTables) == ["customers", "orders"])
    }

    @Test func droppingAnIndexAffectsItsOwningTableNotJustTheIndex() {
        let report = ImpactSimulator.simulate(changing: "index:orders_customer_idx", in: sampleGraph(), workload: [])
        #expect(report.affectedTables == ["orders"])
    }

    @Test func ranksAffectedQueriesByCallFrequencyMostCalledFirst() {
        // customers' blast radius includes orders (orders references customers),
        // so a query touching either counts.
        let workload = [
            "SELECT * FROM orders WHERE id = 1",
            "SELECT * FROM orders WHERE id = 1", // duplicate call, same query
            "SELECT * FROM orders WHERE id = 2",
            "SELECT * FROM customers WHERE id = 1", // touches the changed table itself
            "SELECT * FROM widgets", // unrelated table — not counted
        ]
        let report = ImpactSimulator.simulate(changing: "table:customers", in: sampleGraph(), workload: workload)
        #expect(report.affectedQueries.count == 3)
        #expect(report.affectedQueries.first?.sql == "SELECT * FROM orders WHERE id = 1")
        #expect(report.affectedQueries.first?.frequency == 2)
        #expect(report.totalCallCount == 4)
    }

    @Test func matchingIsWholeWordNotSubstring() {
        // "order" must not match a query that only mentions "orders".
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "table:order", kind: .table, name: "order"))
        let workload = ["SELECT * FROM orders"]
        let report = ImpactSimulator.simulate(changing: "table:order", in: g, workload: workload)
        #expect(report.affectedQueries.isEmpty)
    }

    @Test func unknownNodeReturnsEmptyReport() {
        let report = ImpactSimulator.simulate(changing: "table:missing", in: sampleGraph(), workload: ["SELECT 1"])
        #expect(report.affectedTables.isEmpty)
        #expect(report.affectedQueries.isEmpty)
    }
}
