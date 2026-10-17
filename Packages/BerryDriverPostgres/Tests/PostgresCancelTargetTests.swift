import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres

/// Behind a pooler in transaction mode a statement outside a transaction can
/// run on any server backend, and the backend a connection read at connect
/// can by then be running another client's statement
/// (https://www.pgbouncer.org/features.html). These tests stand that up on a
/// real server by pointing a connection's cancel at another session's
/// backend. Runs against `BERRYDB_TEST_POSTGRES`; skipped when it is unset.
@Suite("Postgres cancel target", .serialized, .enabled(if: TestServer.postgres != nil))
struct PostgresCancelTargetTests {
    private func config() -> ConnectionConfig {
        let server = TestServer.postgres!
        return ConnectionConfig(
            driver: .postgres, name: "cancel-target", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        )
    }

    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    /// How many of `statements` the server is running now.
    private func running(_ statements: [String], on watcher: PostgresDriverConnection) async throws -> Int {
        let list = statements.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ", ")
        let rows = try await drain(watcher.execute(
            "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query IN (\(list))"
        ))
        guard case .int(let count)? = rows.first?.first else { return 0 }
        return Int(count)
    }

    /// Waits, at most 30 s, until the server is running every one of `statements`.
    private func waitUntilRunning(_ statements: [String], on watcher: PostgresDriverConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while try await running(statements, on: watcher) < statements.count {
            guard ContinuousClock.now < deadline else {
                Issue.record("the statements never ran together")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits, at most 30 s, until the server is no longer running `statement`.
    private func waitUntilEnded(_ statement: String, on watcher: PostgresDriverConnection) async throws -> Duration {
        let clock = ContinuousClock()
        let started = clock.now
        while try await running([statement], on: watcher) > 0 {
            guard clock.now - started < .seconds(30) else { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        return clock.now - started
    }

    @Test func aCancelLeavesAnotherSessionsStatementRunning() async throws {
        let mine = try await PostgresDriverConnection(config: config())
        let other = try await PostgresDriverConnection(config: config())
        let watcher = try await PostgresDriverConnection(config: config())
        defer { Task { await mine.close(); await other.close(); await watcher.close() } }
        let otherPID = try #require(other.debugBackendPID)
        mine.pointCancelForTesting(at: otherPID)
        let othersStatement = "SELECT pg_sleep(2), 'other'"
        let myStatement = "SELECT pg_sleep(2), 'mine'"

        let othersRead = Task { try await drain(other.execute(othersStatement)) }
        let myRead = Task { try? await drain(mine.execute(myStatement)) }
        try await waitUntilRunning([othersStatement, myStatement], on: watcher)

        mine.cancelCurrentQuery()

        let rows = try await othersRead.value
        #expect(rows.first?.last == .text("other"))
        _ = await myRead.value
    }

    /// A read-only statement runs in a transaction of its own, which a pooler
    /// keeps on one backend until it ends, so the backend read inside the
    /// transaction is the one to cancel.
    @Test func aReadOnlyStatementIsCancelledOnItsTransactionsBackend() async throws {
        let readOnly = try await PostgresDriverConnection(config: config())
        try await readOnly.prepareReadOnly()
        let other = try await PostgresDriverConnection(config: config())
        let watcher = try await PostgresDriverConnection(config: config())
        defer { Task { await readOnly.close(); await other.close(); await watcher.close() } }
        readOnly.pointCancelForTesting(at: try #require(other.debugBackendPID))
        let othersStatement = "SELECT pg_sleep(2), 'other'"
        let myStatement = "SELECT pg_sleep(30), 'mine'"

        let othersRead = Task { try await drain(other.execute(othersStatement)) }
        let myRead = Task { try? await drain(readOnly.executeReadOnly(myStatement, timeout: .seconds(60))) }
        try await waitUntilRunning([othersStatement, myStatement], on: watcher)

        myRead.cancel()

        #expect(try await waitUntilEnded(myStatement, on: watcher) < .seconds(10))
        let rows = try await othersRead.value
        #expect(rows.first?.last == .text("other"))
        _ = await myRead.value
    }

    /// A backend with `track_activities` off reports no statement to match
    /// (https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW),
    /// and Stop must still stop the connection's own statement there.
    @Test func aCancelStillStopsAStatementTheServerDoesNotTrack() async throws {
        let mine = try await PostgresDriverConnection(config: config())
        let watcher = try await PostgresDriverConnection(config: config())
        defer { Task { await mine.close(); await watcher.close() } }
        try await drain(mine.execute("SET track_activities = off"))
        let minePID = try #require(mine.debugBackendPID)
        let myStatement = "SELECT pg_sleep(30), 'untracked'"

        let clock = ContinuousClock()
        let started = clock.now
        let myRead = Task { try? await drain(mine.execute(myStatement)) }
        // The statement cannot be seen in pg_stat_activity, so wait for the
        // backend to leave idle instead.
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            let rows = try await drain(watcher.execute(
                "SELECT count(*) FROM pg_stat_activity WHERE pid = \(minePID) AND wait_event = 'PgSleep'"
            ))
            if case .int(1)? = rows.first?.first { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        mine.cancelCurrentQuery()
        _ = await myRead.value

        #expect(clock.now - started < .seconds(10))
    }

    /// Without a pooler the backend read at connect is the connection's own,
    /// and a cancel still stops its statement.
    @Test func aCancelStopsTheConnectionsOwnStatement() async throws {
        let mine = try await PostgresDriverConnection(config: config())
        let watcher = try await PostgresDriverConnection(config: config())
        defer { Task { await mine.close(); await watcher.close() } }
        let myStatement = "SELECT pg_sleep(30), 'mine'"

        let myRead = Task { try? await drain(mine.execute(myStatement)) }
        try await waitUntilRunning([myStatement], on: watcher)

        mine.cancelCurrentQuery()

        #expect(try await waitUntilEnded(myStatement, on: watcher) < .seconds(10))
        _ = await myRead.value
    }
}
