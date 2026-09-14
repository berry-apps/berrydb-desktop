import Foundation
import Testing
@testable import BerryStore

@Suite("Recommendation Feedback")
struct RecommendationFeedbackTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func recordsAndFetchesFeedback() throws {
        let store = try makeStore()
        let profileID = UUID()
        let insightID = "insight-index-missing"
        let now = Date()

        let record = RecommendationFeedbackRecord(
            profileID: profileID,
            insightID: insightID,
            action: .applied,
            ts: now
        )
        try store.recordRecommendationFeedback(record)

        let feedback = try store.recommendationFeedback(profileID: profileID, insightID: insightID)
        #expect(feedback.count == 1)
        #expect(feedback[0].id == record.id)
        #expect(feedback[0].profileID == profileID)
        #expect(feedback[0].insightID == insightID)
        #expect(feedback[0].action == RecommendationAction.applied.rawValue)
        #expect(abs(feedback[0].ts.timeIntervalSince(now)) < 0.001)
    }

    @Test func isolatesFeedbackByInsightAndProfile() throws {
        let store = try makeStore()
        let profileID1 = UUID()
        let profileID2 = UUID()
        let insightID1 = "insight-1"
        let insightID2 = "insight-2"
        let now = Date()

        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: insightID1, action: .applied, ts: now)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: insightID2, action: .dismissed, ts: now)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID2, insightID: insightID1, action: .ignored, ts: now)
        )

        let feedbackP1I1 = try store.recommendationFeedback(profileID: profileID1, insightID: insightID1)
        #expect(feedbackP1I1.count == 1)
        #expect(feedbackP1I1[0].insightID == insightID1)
        #expect(feedbackP1I1[0].action == RecommendationAction.applied.rawValue)

        let feedbackP1I2 = try store.recommendationFeedback(profileID: profileID1, insightID: insightID2)
        #expect(feedbackP1I2.count == 1)
        #expect(feedbackP1I2[0].action == RecommendationAction.dismissed.rawValue)

        let feedbackP2I1 = try store.recommendationFeedback(profileID: profileID2, insightID: insightID1)
        #expect(feedbackP2I1.count == 1)
        #expect(feedbackP2I1[0].action == RecommendationAction.ignored.rawValue)
    }

    @Test func returnsOnlyDismissedInsightIDsForGivenProfile() throws {
        let store = try makeStore()
        let profileID1 = UUID()
        let profileID2 = UUID()
        let now = Date()

        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: "insight-applied", action: .applied, ts: now)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: "insight-dismissed-1", action: .dismissed, ts: now)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: "insight-ignored", action: .ignored, ts: now)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID1, insightID: "insight-dismissed-2", action: .dismissed, ts: now)
        )
        // Profile 2 dismissed insight should not appear for Profile 1
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID2, insightID: "insight-profile2-dismissed", action: .dismissed, ts: now)
        )

        let dismissedP1 = try store.dismissedInsightIDs(profileID: profileID1)
        #expect(dismissedP1 == ["insight-dismissed-1", "insight-dismissed-2"])

        let dismissedP2 = try store.dismissedInsightIDs(profileID: profileID2)
        #expect(dismissedP2 == ["insight-profile2-dismissed"])
    }

    @Test func returnsMultipleFeedbackNewestFirst() throws {
        let store = try makeStore()
        let profileID = UUID()
        let insightID = "insight-repeated"
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let t3 = Date(timeIntervalSince1970: 3000)

        // Insert out of order
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID, insightID: insightID, action: .ignored, ts: t1)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID, insightID: insightID, action: .applied, ts: t3)
        )
        try store.recordRecommendationFeedback(
            RecommendationFeedbackRecord(profileID: profileID, insightID: insightID, action: .dismissed, ts: t2)
        )

        let feedback = try store.recommendationFeedback(profileID: profileID, insightID: insightID)
        #expect(feedback.count == 3)
        #expect(feedback[0].action == RecommendationAction.applied.rawValue)
        #expect(feedback[1].action == RecommendationAction.dismissed.rawValue)
        #expect(feedback[2].action == RecommendationAction.ignored.rawValue)
    }
}
