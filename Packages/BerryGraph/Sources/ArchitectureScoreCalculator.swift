import Foundation

/// A 0–100 health score computed from the Insight Panel's own findings (DI-09)
/// — no new data source, no DBMS access (docs/feature/07 §10, "Database
/// Architecture Score"). Deliberately narrower than the feature doc's mockup:
/// that pictures Performance/Security/Maintainability/Schema/Index/Storage
/// sub-scores, but only `Insight.Category` (schema/index/query) has any real
/// signal behind it today — there is no security- or storage-specific
/// analyzer. Following the same "report less rather than report wrong"
/// principle as `ImpactSimulator`'s scope note, this only scores the 3
/// categories that actually exist; it does not fabricate the others.
public struct ArchitectureScore: Codable, Sendable, Equatable {
    public let overall: Int
    public let schema: Int
    public let index: Int
    /// Labeled "Performance" in the UI — `Insight.Category.query` is exactly
    /// the analyzer that flags slow/expensive query patterns.
    public let performance: Int

    public init(overall: Int, schema: Int, index: Int, performance: Int) {
        self.overall = overall
        self.schema = schema
        self.index = index
        self.performance = performance
    }
}

public enum ArchitectureScoreCalculator {
    /// Points deducted per finding, by severity — critical findings dominate
    /// the score; a handful of info-level suggestions barely move it.
    private static let criticalPenalty = 15
    private static let warningPenalty = 5
    private static let infoPenalty = 1

    /// Scores already-computed insights (caller supplies them, e.g. from
    /// `InsightEngine.analyze`/`WorkspaceViewModel.analyzeInsights`) — pure,
    /// no ordering assumption unlike `DailyReviewBuilder.summarize`.
    public static func score(_ insights: [Insight]) -> ArchitectureScore {
        ArchitectureScore(
            overall: categoryScore(insights),
            schema: categoryScore(insights.filter { $0.category == .schema }),
            index: categoryScore(insights.filter { $0.category == .index }),
            performance: categoryScore(insights.filter { $0.category == .query })
        )
    }

    private static func categoryScore(_ insights: [Insight]) -> Int {
        let penalty = insights.reduce(0) { total, insight in
            switch insight.severity {
            case .critical: total + criticalPenalty
            case .warning: total + warningPenalty
            case .info: total + infoPenalty
            }
        }
        return max(0, 100 - penalty)
    }
}
