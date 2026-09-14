import BerryDriverKit
import BerryDriverSQLite
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// `slowestQueries` (`get_slow_queries` tool bridge)
/// re-ranks `query_history` by duration instead of recency.
/// Serialized: registers `SQLiteDriver` (shared global `DriverRegistry`
/// state), same caveat `WorkspaceGraphTests` documents.
@MainActor
@Suite("Slow queries (WorkspaceViewModel)", .serialized)
struct SlowQueriesTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    private func makeSQLiteDB() -> String {
        DriverRegistry.register(SQLiteDriver.self)
        let path = tempPath("db")
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    @Test func rankedByDurationAndExcludesFailedRuns() async throws {
        let storePath = tempPath("store")
        let vm = try WorkspaceViewModel(storePath: storePath)
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        _ = try #require(vm.session)

        // A separate connection to the same file (GRDB/SQLite is fine with
        // multiple connections) — inserts history directly rather than
        // driving it through real query execution.
        let store = try BerryStore(path: storePath)
        try store.record(QueryHistoryEntry(
            profileID: profile.id, sql: "SELECT * FROM fast", startedAt: Date(), durationMS: 5, status: "success"
        ))
        try store.record(QueryHistoryEntry(
            profileID: profile.id, sql: "SELECT * FROM slow", startedAt: Date(), durationMS: 900, status: "success"
        ))
        try store.record(QueryHistoryEntry(
            profileID: profile.id, sql: "SELECT * FROM slowest_but_failed", startedAt: Date(), durationMS: 5000, status: "failed"
        ))
        try store.record(QueryHistoryEntry(
            profileID: profile.id, sql: "SELECT * FROM medium", startedAt: Date(), durationMS: 200, status: "success"
        ))

        let slowest = vm.slowestQueries(limit: 2)

        #expect(slowest.map(\.sql) == ["SELECT * FROM slow", "SELECT * FROM medium"])
        vm.disconnect()
    }

    @Test func emptyWithoutAnActiveProfile() throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(vm.slowestQueries().isEmpty)
    }
}
