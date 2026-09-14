import BerryGraph
import Testing
@testable import BerryAI

@Suite("get_daily_review client tool")
struct GetDailyReviewToolExecutorTests {
    @MainActor
    @Test func generatesBeforeReadingAndReturnsFormattedSummary() async {
        var generateCalled = false
        let summary = DailyReviewSummary(
            criticalCount: 1, warningCount: 2, infoCount: 3,
            topInsightTitles: ["Missing primary key"]
        )
        let executor = GetDailyReviewToolExecutor(
            maybeGenerateDailyReview: { generateCalled = true },
            latestDailyReview: { summary }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "get_daily_review", args: [:]))

        #expect(generateCalled == true)
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("\"available\":true") == true)
        #expect(outcome.resultJSON?.contains("\"critical_count\":1") == true)
        #expect(outcome.resultJSON?.contains("Missing primary key") == true)
    }

    @MainActor
    @Test func reportsUnavailableWhenNoDigestExistsAfterGenerating() async {
        let executor = GetDailyReviewToolExecutor(
            maybeGenerateDailyReview: {},
            latestDailyReview: { nil }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "get_daily_review", args: [:]))

        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON == #"{"available":false}"#)
    }

    @MainActor
    @Test func aDeniedLeaseNeverGeneratesOrReads() async {
        var generateCalled = false
        let executor = GetDailyReviewToolExecutor(
            maybeGenerateDailyReview: { generateCalled = true },
            latestDailyReview: { nil }
        )
        let deniedLease = AIExecutionLease(validate: { false })

        let outcome = await executor.execute(
            AIToolCall(id: "c1", name: "get_daily_review", args: [:]), lease: deniedLease
        )

        #expect(outcome == .denied)
        #expect(generateCalled == false)
    }
}
