import BerryStore
import Foundation

/// Client-executed `get_slow_queries`: the slowest
/// recent successful queries — reuses `WorkspaceViewModel.slowestQueries(limit:)`
/// (same `query_history` the History tab already shows), no new analysis.
/// Base "ai" tier like `search_conversation`/`search_schema`, not
/// Intelligence-gated — History itself isn't gated either.
@MainActor
public final class GetSlowQueriesToolExecutor: AIToolExecutor {
    private let slowestQueries: (Int) -> [QueryHistoryEntry]

    public init(slowestQueries: @escaping (Int) -> [QueryHistoryEntry]) {
        self.slowestQueries = slowestQueries
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "get_slow_queries",
            description: "Return the slowest recent successful queries from local history, ranked by duration. Read-only, local metadata only.",
            parametersJSON: #"{"type":"object","properties":{"limit":{"type":"integer","description":"How many to return, default 10."}}}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        executeGet(call)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return executeGet(call)
    }

    private func executeGet(_ call: AIToolCall) -> ToolOutcome {
        guard call.name == "get_slow_queries" else { return .failed("Unknown tool '\(call.name)'") }
        let limit = call.args["limit"].flatMap(Int.init).map { max(1, min($0, 50)) } ?? 10
        let entries = slowestQueries(limit)
        let payload = entries.map { ["sql": $0.sql, "duration_ms": $0.durationMS, "row_count": $0.rowCount ?? 0] as [String: Any] }
        let json = (try? JSONSerialization.data(withJSONObject: ["queries": payload]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"queries":[]}"#
        return .ok(json)
    }
}
