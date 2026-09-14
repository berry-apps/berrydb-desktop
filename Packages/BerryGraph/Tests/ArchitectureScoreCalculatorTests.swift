import Foundation
import Testing
@testable import BerryGraph

@Suite("Database Architecture Score")
struct ArchitectureScoreCalculatorTests {
    @Test func emptyInsightsScorePerfectAcrossTheBoard() {
        let score = ArchitectureScoreCalculator.score([])
        #expect(score == ArchitectureScore(overall: 100, schema: 100, index: 100, performance: 100))
    }

    @Test func criticalFindingsDominateOverWarningsAndInfo() {
        let insights: [Insight] = [
            Insight(id: "1", severity: .critical, category: .schema, title: "t", detail: "d"),
        ]
        let score = ArchitectureScoreCalculator.score(insights)
        #expect(score.overall == 85) // 100 - 15
        #expect(score.schema == 85)
        // Other categories are untouched by a schema-only finding.
        #expect(score.index == 100)
        #expect(score.performance == 100)
    }

    @Test func scoreNeverGoesBelowZero() {
        let insights: [Insight] = (1...10).map { index in
            Insight(id: "\(index)", severity: .critical, category: .schema, title: "t\(index)", detail: "d")
        }
        let score = ArchitectureScoreCalculator.score(insights)
        #expect(score.overall == 0)
        #expect(score.schema == 0)
    }

    @Test func categoriesAreScoredIndependentlyThenOverallCombinesAll() {
        let insights: [Insight] = [
            Insight(id: "1", severity: .critical, category: .schema, title: "t1", detail: "d"),
            Insight(id: "2", severity: .warning, category: .index, title: "t2", detail: "d"),
            Insight(id: "3", severity: .info, category: .query, title: "t3", detail: "d"),
        ]
        let score = ArchitectureScoreCalculator.score(insights)
        #expect(score.schema == 85) // 100 - 15
        #expect(score.index == 95) // 100 - 5
        #expect(score.performance == 99) // 100 - 1
        #expect(score.overall == 79) // 100 - 15 - 5 - 1, all findings together
    }
}
