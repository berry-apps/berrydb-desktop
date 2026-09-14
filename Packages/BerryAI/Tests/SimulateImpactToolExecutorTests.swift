import BerryGraph
import Testing
@testable import BerryAI

@Suite("simulate_impact client tool")
struct SimulateImpactToolExecutorTests {
    /// `ImpactSimulator.Report` has no public initializer (it's only ever
    /// meant to be produced by `simulate`, not hand-built) — construct a real
    /// one-table graph and run the real simulator to get genuine values.
    private func realReport(table: String, workload: [String]) -> ImpactSimulator.Report {
        var graph = SchemaGraph()
        let nodeID = GraphID.node(.table, database: nil, name: table)
        graph.addNode(GraphNode(id: nodeID, kind: .table, name: table))
        return ImpactSimulator.simulate(changing: nodeID, in: graph, workload: workload)
    }

    @MainActor
    @Test func returnsTheReportAsFormattedJSON() async {
        var seenTable: String?
        let report = realReport(table: "orders", workload: ["SELECT * FROM orders", "SELECT * FROM orders"])
        let executor = SimulateImpactToolExecutor(simulateImpact: { table in
            seenTable = table
            return report
        })

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "simulate_impact", args: ["table": "orders"]))

        #expect(outcome.status == "ok")
        #expect(seenTable == "orders")
        #expect(outcome.resultJSON?.contains("orders") == true)
        #expect(outcome.resultJSON?.contains("\"total_call_count\":2") == true)
    }

    @MainActor
    @Test func rejectsAMissingTableArgument() async {
        let executor = SimulateImpactToolExecutor(simulateImpact: { _ in nil })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "simulate_impact", args: [:]))
        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func reportsUnavailableWhenTheFeatureItselfIsGated() async {
        let executor = SimulateImpactToolExecutor(simulateImpact: { _ in nil })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "simulate_impact", args: ["table": "orders"]))
        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func anUnrecognizedTableStillReturnsOkWithAnEmptyReport() async {
        // Matches WorkspaceViewModel.simulateImpact's own contract: nil only
        // means the feature is unavailable, never "no matches" for a table
        // name the simulator doesn't recognize. An empty graph (no node for
        // "ghost" at all) reproduces that "unknown node" case for real.
        let executor = SimulateImpactToolExecutor(simulateImpact: { _ in
            ImpactSimulator.simulate(changing: GraphID.node(.table, database: nil, name: "ghost"), in: SchemaGraph(), workload: [])
        })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "simulate_impact", args: ["table": "ghost"]))
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("\"affected_tables\":[]") == true)
    }

    @MainActor
    @Test func aDeniedLeaseNeverInvokesTheSimulation() async {
        var invoked = false
        let executor = SimulateImpactToolExecutor(simulateImpact: { table in
            invoked = true
            return self.realReport(table: table, workload: [])
        })
        let deniedLease = AIExecutionLease(validate: { false })

        let outcome = await executor.execute(
            AIToolCall(id: "c1", name: "simulate_impact", args: ["table": "orders"]), lease: deniedLease
        )

        #expect(outcome == .denied)
        #expect(invoked == false)
    }
}
