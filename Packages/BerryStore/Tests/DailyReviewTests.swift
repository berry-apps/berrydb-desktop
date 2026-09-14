import Foundation
import Testing
@testable import BerryStore

@Suite("Daily Review Store")
struct DailyReviewTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndFetchesLatestDailyReview() throws {
        let store = try makeStore()
        let profileID = UUID()
        let now = Date()

        let record = DailyReviewRecord(
            profileID: profileID,
            generatedAt: now,
            summaryJSON: "{\"criticalCount\":1}"
        )
        try store.saveDailyReview(record)

        let fetched = try store.latestDailyReview(profileID: profileID)
        #expect(fetched != nil)
        #expect(fetched?.id == record.id)
        #expect(fetched?.profileID == profileID)
        #expect(fetched?.summaryJSON == "{\"criticalCount\":1}")
        if let fetchedDate = fetched?.generatedAt {
            #expect(abs(fetchedDate.timeIntervalSince(now)) < 0.001)
        }
    }

    @Test func returnsNilWhenNoReviewExists() throws {
        let store = try makeStore()
        let profileID = UUID()

        let fetched = try store.latestDailyReview(profileID: profileID)
        #expect(fetched == nil)
    }

    @Test func returnsNewestReviewWhenMultipleExist() throws {
        let store = try makeStore()
        let profileID = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let t3 = Date(timeIntervalSince1970: 1500)

        let record1 = DailyReviewRecord(profileID: profileID, generatedAt: t1, summaryJSON: "first")
        let record2 = DailyReviewRecord(profileID: profileID, generatedAt: t2, summaryJSON: "newest")
        let record3 = DailyReviewRecord(profileID: profileID, generatedAt: t3, summaryJSON: "middle")

        try store.saveDailyReview(record1)
        try store.saveDailyReview(record2)
        try store.saveDailyReview(record3)

        let fetched = try store.latestDailyReview(profileID: profileID)
        #expect(fetched?.id == record2.id)
        #expect(fetched?.summaryJSON == "newest")
    }

    @Test func isolatesReviewsByProfile() throws {
        let store = try makeStore()
        let profileA = UUID()
        let profileB = UUID()
        let now = Date()

        let recordA = DailyReviewRecord(profileID: profileA, generatedAt: now, summaryJSON: "profileA")
        try store.saveDailyReview(recordA)

        let fetchedB = try store.latestDailyReview(profileID: profileB)
        #expect(fetchedB == nil)

        let fetchedA = try store.latestDailyReview(profileID: profileA)
        #expect(fetchedA?.summaryJSON == "profileA")
    }
}
