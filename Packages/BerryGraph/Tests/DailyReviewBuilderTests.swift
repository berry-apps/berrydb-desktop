import Foundation
import Testing
@testable import BerryGraph

@Suite("Daily Review Builder")
struct DailyReviewBuilderTests {
    @Test func isDueWhenLastGeneratedAtIsNil() {
        let now = Date()
        #expect(DailyReviewBuilder.isDue(lastGeneratedAt: nil, now: now))
    }

    @Test func isDueIsFalseWhenLessThanMinimumInterval() {
        let last = Date(timeIntervalSince1970: 10_000)
        let now = Date(timeIntervalSince1970: 10_000 + 19 * 3600)
        #expect(!DailyReviewBuilder.isDue(lastGeneratedAt: last, now: now))
    }

    @Test func isDueIsTrueWhenAtOrPastMinimumInterval() {
        let last = Date(timeIntervalSince1970: 10_000)
        let exactly20h = Date(timeIntervalSince1970: 10_000 + 20 * 3600)
        let past20h = Date(timeIntervalSince1970: 10_000 + 21 * 3600)

        #expect(DailyReviewBuilder.isDue(lastGeneratedAt: last, now: exactly20h))
        #expect(DailyReviewBuilder.isDue(lastGeneratedAt: last, now: past20h))
    }

    @Test func summarizeCountsSeveritiesCorrectly() {
        let insights: [Insight] = [
            Insight(id: "1", severity: .critical, category: .schema, title: "Crit 1", detail: "d1"),
            Insight(id: "2", severity: .critical, category: .schema, title: "Crit 2", detail: "d2"),
            Insight(id: "3", severity: .warning, category: .schema, title: "Warn 1", detail: "d3"),
            Insight(id: "4", severity: .info, category: .schema, title: "Info 1", detail: "d4"),
            Insight(id: "5", severity: .info, category: .schema, title: "Info 2", detail: "d5"),
            Insight(id: "6", severity: .info, category: .schema, title: "Info 3", detail: "d6"),
        ]

        let summary = DailyReviewBuilder.summarize(insights)
        #expect(summary.criticalCount == 2)
        #expect(summary.warningCount == 1)
        #expect(summary.infoCount == 3)
    }

    @Test func summarizeCapsTopInsightTitlesAtFive() {
        let insights: [Insight] = (1...7).map { index in
            Insight(id: "\(index)", severity: .critical, category: .schema, title: "Title \(index)", detail: "d\(index)")
        }

        let summary = DailyReviewBuilder.summarize(insights)
        #expect(summary.topInsightTitles.count == 5)
        #expect(summary.topInsightTitles == ["Title 1", "Title 2", "Title 3", "Title 4", "Title 5"])
    }

    @Test func encodeAndDecodeRoundTrips() {
        let summary = DailyReviewSummary(
            criticalCount: 2,
            warningCount: 3,
            infoCount: 5,
            topInsightTitles: ["Title A", "Title B"]
        )

        let encoded = DailyReviewBuilder.encode(summary)
        let decoded = DailyReviewBuilder.decode(encoded)

        #expect(decoded == summary)
    }
}
