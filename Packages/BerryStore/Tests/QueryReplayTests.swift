import Foundation
import Testing
@testable import BerryStore

@Suite("Query Replay")
struct QueryReplayTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func hashIsStableAcrossWhitespaceAndCase() {
        let a = QueryReplayRecord.hash(of: "SELECT * FROM orders WHERE id = 1")
        let b = QueryReplayRecord.hash(of: "  select   *  from orders\nwhere id = 1  ")
        #expect(a == b)
    }

    @Test func hashDiffersForDifferentQueries() {
        let a = QueryReplayRecord.hash(of: "SELECT * FROM orders")
        let b = QueryReplayRecord.hash(of: "SELECT * FROM customers")
        #expect(a != b)
    }

    @Test func savesAndFetchesSnapshotsNewestFirst() throws {
        let store = try makeStore()
        let profileID = UUID()
        let hash = QueryReplayRecord.hash(of: "SELECT * FROM orders")
        let older = QueryReplaySnapshotRecord(
            profileID: profileID, queryHash: hash, sql: "SELECT * FROM orders",
            ts: Date(timeIntervalSince1970: 1000), durationMS: 420
        )
        let newer = QueryReplaySnapshotRecord(
            profileID: profileID, queryHash: hash, sql: "SELECT * FROM orders",
            ts: Date(timeIntervalSince1970: 2000), durationMS: 63
        )
        try store.saveQueryReplaySnapshot(older)
        try store.saveQueryReplaySnapshot(newer)

        let snapshots = try store.queryReplaySnapshots(profileID: profileID, queryHash: hash)
        #expect(snapshots.count == 2)
        #expect(snapshots[0].durationMS == 63)
        #expect(snapshots[1].durationMS == 420)
    }

    @Test func isolatesSnapshotsByProfileAndQueryHash() throws {
        let store = try makeStore()
        let profileID1 = UUID()
        let profileID2 = UUID()
        let hashOrders = QueryReplayRecord.hash(of: "SELECT * FROM orders")
        let hashCustomers = QueryReplayRecord.hash(of: "SELECT * FROM customers")

        try store.saveQueryReplaySnapshot(QueryReplaySnapshotRecord(
            profileID: profileID1, queryHash: hashOrders, sql: "SELECT * FROM orders", ts: Date(), durationMS: 100
        ))
        try store.saveQueryReplaySnapshot(QueryReplaySnapshotRecord(
            profileID: profileID1, queryHash: hashCustomers, sql: "SELECT * FROM customers", ts: Date(), durationMS: 200
        ))
        try store.saveQueryReplaySnapshot(QueryReplaySnapshotRecord(
            profileID: profileID2, queryHash: hashOrders, sql: "SELECT * FROM orders", ts: Date(), durationMS: 300
        ))

        #expect(try store.queryReplaySnapshots(profileID: profileID1, queryHash: hashOrders).count == 1)
        #expect(try store.queryReplaySnapshots(profileID: profileID1, queryHash: hashCustomers).count == 1)
        #expect(try store.queryReplaySnapshots(profileID: profileID2, queryHash: hashOrders).count == 1)
    }
}
