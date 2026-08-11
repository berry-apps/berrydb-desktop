import BerryGraph
import Foundation

/// Client-executed `get_daily_review` (DI-23, docs/architecture/13 §6): reads
/// today's Daily Review digest, generating one first if none exists yet or
/// today's is overdue — reuses `WorkspaceViewModel.maybeGenerateDailyReview`/
/// `latestDailyReview` (already back the Insight Panel's "Today's Summary"),
/// no new analysis logic. Read-only, local metadata only.
@MainActor
public final class GetDailyReviewToolExecutor: AIToolExecutor {
    private let maybeGenerateDailyReview: () async -> Void
    private let latestDailyReview: () -> DailyReviewSummary?

    public init(
        maybeGenerateDailyReview: @escaping () async -> Void,
        latestDailyReview: @escaping () -> DailyReviewSummary?
    ) {
        self.maybeGenerateDailyReview = maybeGenerateDailyReview
        self.latestDailyReview = latestDailyReview
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "get_daily_review",
            description: "Read today's Daily Review digest — critical/warning/info counts and the top findings, refreshed at most once a day. Generates one now if none exists yet or today's is overdue. Read-only, local metadata only.",
            parametersJSON: #"{"type":"object","properties":{}}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await executeGet(call)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await executeGet(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

    private func executeGet(_ call: AIToolCall) async -> ToolOutcome {
        guard call.name == "get_daily_review" else { return .failed("Unknown tool '\(call.name)'") }
        await maybeGenerateDailyReview()
        guard let summary = latestDailyReview() else {
            return .ok(#"{"available":false}"#)
        }
        let payload: [String: Any] = [
            "available": true,
            "critical_count": summary.criticalCount,
            "warning_count": summary.warningCount,
            "info_count": summary.infoCount,
            "top_insight_titles": summary.topInsightTitles,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"available":false}"#
        return .ok(json)
    }
}
