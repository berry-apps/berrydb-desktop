import Foundation
import Testing
@testable import BerryStore

@Suite("Runtime Metrics")
struct RuntimeMetricTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndFetchesMetricsByMetricNameNewestFirst() throws {
        let store = try makeStore()
        let profileID = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        let t3 = Date(timeIntervalSince1970: 3000)

        let r1 = RuntimeMetricRecord(profileID: profileID, ts: t1, metric: "connection_count", value: 10)
        let r2 = RuntimeMetricRecord(profileID: profileID, ts: t3, metric: "connection_count", value: 25)
        let r3 = RuntimeMetricRecord(profileID: profileID, ts: t2, metric: "connection_count", value: 15)
        let rOther = RuntimeMetricRecord(profileID: profileID, ts: t3, metric: "cache_hit_ratio", value: 0.95)

        try store.saveRuntimeMetrics([r1, r2, r3, rOther])

        let results = try store.runtimeMetrics(profileID: profileID, metric: "connection_count")
        #expect(results.count == 3)
        #expect(results[0].value == 25)
        #expect(results[1].value == 15)
        #expect(results[2].value == 10)
        #expect(abs(results[0].ts.timeIntervalSince(t3)) < 0.001)
        #expect(abs(results[1].ts.timeIntervalSince(t2)) < 0.001)
        #expect(abs(results[2].ts.timeIntervalSince(t1)) < 0.001)
    }

    @Test func isolatesMetricsByProfile() throws {
        let store = try makeStore()
        let profileA = UUID()
        let profileB = UUID()
        let now = Date()

        let rA = RuntimeMetricRecord(profileID: profileA, ts: now, metric: "connection_count", value: 5)
        let rB = RuntimeMetricRecord(profileID: profileB, ts: now, metric: "connection_count", value: 42)

        try store.saveRuntimeMetrics([rA, rB])

        let resultsA = try store.runtimeMetrics(profileID: profileA, metric: "connection_count")
        #expect(resultsA.count == 1)
        #expect(resultsA[0].value == 5)

        let resultsB = try store.runtimeMetrics(profileID: profileB, metric: "connection_count")
        #expect(resultsB.count == 1)
        #expect(resultsB[0].value == 42)
    }

    @Test func respectsLimitParameter() throws {
        let store = try makeStore()
        let profileID = UUID()
        let baseTime = Date(timeIntervalSince1970: 1000)

        var records: [RuntimeMetricRecord] = []
        for i in 0..<10 {
            records.append(RuntimeMetricRecord(
                profileID: profileID,
                ts: baseTime.addingTimeInterval(TimeInterval(i * 10)),
                metric: "dead_tuple_count",
                value: Double(i)
            ))
        }
        try store.saveRuntimeMetrics(records)

        let fetched = try store.runtimeMetrics(profileID: profileID, metric: "dead_tuple_count", limit: 4)
        #expect(fetched.count == 4)
        #expect(fetched[0].value == 9)
        #expect(fetched[3].value == 6)
    }
}
