import BerryStore
import Foundation
import Testing

@testable import BerryGraph

@Suite("Query Replay Comparator (DI-17)")
struct QueryReplayComparatorTests {
    private func snapshot(_ ms: Double, at ts: Date) -> QueryReplaySnapshotRecord {
        QueryReplaySnapshotRecord(
            profileID: UUID(), queryHash: "h", sql: "SELECT 1", ts: ts, durationMS: ms
        )
    }

    @Test func detectsImprovement() {
        let comparison = QueryReplayComparator.compare(
            earlier: snapshot(420, at: Date(timeIntervalSince1970: 1000)),
            later: snapshot(63, at: Date(timeIntervalSince1970: 2000))
        )
        #expect(comparison.deltaMS == -357)
        #expect(comparison.improved)
        #expect(comparison.percentChange.map { $0 < 0 } == true)
    }

    @Test func detectsRegression() {
        let comparison = QueryReplayComparator.compare(
            earlier: snapshot(100, at: Date(timeIntervalSince1970: 1000)),
            later: snapshot(150, at: Date(timeIntervalSince1970: 2000))
        )
        #expect(comparison.deltaMS == 50)
        #expect(!comparison.improved)
    }

    @Test func compareLatestTwoPicksTheTwoNewestInOrder() {
        // Newest-first, as BerryStore.queryReplaySnapshots returns them.
        let snapshots = [
            snapshot(63, at: Date(timeIntervalSince1970: 3000)),
            snapshot(80, at: Date(timeIntervalSince1970: 2000)),
            snapshot(420, at: Date(timeIntervalSince1970: 1000)),
        ]
        let comparison = QueryReplayComparator.compareLatestTwo(snapshots)
        #expect(comparison?.earlier.durationMS == 80)
        #expect(comparison?.later.durationMS == 63)
    }

    @Test func fewerThanTwoSnapshotsYieldsNoComparison() {
        #expect(QueryReplayComparator.compareLatestTwo([]) == nil)
        #expect(QueryReplayComparator.compareLatestTwo([snapshot(1, at: Date())]) == nil)
    }

    @Test func zeroEarlierDurationHasNoPercentChange() {
        let comparison = QueryReplayComparator.compare(
            earlier: snapshot(0, at: Date(timeIntervalSince1970: 1000)),
            later: snapshot(10, at: Date(timeIntervalSince1970: 2000))
        )
        #expect(comparison.percentChange == nil)
    }
}
