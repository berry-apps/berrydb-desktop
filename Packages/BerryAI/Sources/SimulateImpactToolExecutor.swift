import BerryGraph
import Foundation

/// Client-executed `simulate_impact`:
/// quantifies the blast radius of changing a table against real recent query
/// workload — reuses `WorkspaceViewModel.simulateImpact(_:)` (already backs
/// Graph Explorer's "Quantified impact" panel) rather than duplicating it.
/// Harmless: read-only, never touches the database.
@MainActor
public final class SimulateImpactToolExecutor: AIToolExecutor {
    /// nil only when the feature itself is unavailable (no Intelligence
    /// entitlement, or nothing harvested yet) — an unrecognized table name
    /// still returns a (empty) report rather than nil, same contract as
    /// `WorkspaceViewModel.simulateImpact`.
    private let simulateImpact: (String) -> ImpactSimulator.Report?

    public init(simulateImpact: @escaping (String) -> ImpactSimulator.Report?) {
        self.simulateImpact = simulateImpact
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "simulate_impact",
            description: "Estimate the impact of changing a table — quantifies blast radius (tables reachable via FK/derived dependencies) against real recent query workload (which queries touch it, how often). Never touches the database.",
            parametersJSON: #"{"type":"object","properties":{"table":{"type":"string"}},"required":["table"]}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        executeSimulate(call)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return executeSimulate(call)
    }

    private func executeSimulate(_ call: AIToolCall) -> ToolOutcome {
        guard call.name == "simulate_impact" else { return .failed("Unknown tool '\(call.name)'") }
        guard let table = call.args["table"], !table.isEmpty else { return .failed("Missing 'table'") }
        guard let report = simulateImpact(table) else {
            return .failed("Impact simulation isn't available right now (Intelligence entitlement or a harvested schema is required)")
        }
        let payload: [String: Any] = [
            "affected_tables": report.affectedTables,
            "affected_queries": report.affectedQueries.map { ["sql": $0.sql, "frequency": $0.frequency] },
            "total_call_count": report.totalCallCount,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"affected_tables":[],"affected_queries":[],"total_call_count":0}"#
        return .ok(json)
    }
}
