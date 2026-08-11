import Foundation

/// Builds a Daily Review digest from the Insight Panel's findings (DI-23,
/// docs/architecture/13 §5.3) — pure, no DBMS/network access. `isDue` decides
/// whether enough time has passed to generate a new one: BerryDB defines this
/// cadence itself (fixed, not user-configurable), which is what keeps this
/// out of "automation/scheduler" territory (docs/architecture/01 §5 non-goal)
/// — see docs/architecture/13 §1's "not a 24/7 agent" principle.
public struct DailyReviewSummary: Codable, Sendable, Equatable {
    public let criticalCount: Int
    public let warningCount: Int
    public let infoCount: Int
    /// Up to 5 titles, most severe first — same ordering InsightEngine.analyze already returns.
    public let topInsightTitles: [String]

    public init(criticalCount: Int, warningCount: Int, infoCount: Int, topInsightTitles: [String]) {
        self.criticalCount = criticalCount
        self.warningCount = warningCount
        self.infoCount = infoCount
        self.topInsightTitles = topInsightTitles
    }
}

public enum DailyReviewBuilder {
    /// Default cadence: 20 hours (not exactly 24h, so a user who opens the app
    /// at a slightly different time each day still gets a fresh digest daily).
    public static let defaultMinimumInterval: TimeInterval = 20 * 3600

    /// Whether it's time to generate a new digest. `lastGeneratedAt` nil (no
    /// digest ever generated) is always due.
    public static func isDue(lastGeneratedAt: Date?, now: Date, minimumInterval: TimeInterval = defaultMinimumInterval) -> Bool {
        guard let lastGeneratedAt else { return true }
        return now.timeIntervalSince(lastGeneratedAt) >= minimumInterval
    }

    /// Summarizes already-computed insights (caller supplies them — e.g. from
    /// `InsightEngine.analyze`/`WorkspaceViewModel.analyzeInsights`). Assumes
    /// `insights` is already sorted most-severe-first (InsightEngine's
    /// convention) for `topInsightTitles`.
    public static func summarize(_ insights: [Insight]) -> DailyReviewSummary {
        DailyReviewSummary(
            criticalCount: insights.filter { $0.severity == .critical }.count,
            warningCount: insights.filter { $0.severity == .warning }.count,
            infoCount: insights.filter { $0.severity == .info }.count,
            topInsightTitles: Array(insights.prefix(5).map(\.title))
        )
    }

    public static func encode(_ summary: DailyReviewSummary) -> String {
        guard let data = try? JSONEncoder().encode(summary), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    public static func decode(_ json: String) -> DailyReviewSummary? {
        try? JSONDecoder().decode(DailyReviewSummary.self, from: Data(json.utf8))
    }
}
