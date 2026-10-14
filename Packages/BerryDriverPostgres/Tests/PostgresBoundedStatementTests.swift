import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`; skipped when
/// the variable is unset.
@Suite("Postgres catalog read scopes", .enabled(if: TestServer.postgres != nil))
struct PostgresBoundedStatementTests {
    private func openConnection() async throws -> PostgresDriverConnection {
        let server = TestServer.postgres!
        return try await PostgresDriverConnection(config: ConnectionConfig(
            driver: .postgres, name: "bounded", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
    }

    private func run(_ sql: String, on connection: PostgresDriverConnection) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in connection.execute(sql) {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    /// Every read of a scope, through the introspector's path and through
    /// `execute`, runs in one read-only transaction that carries the bound;
    /// a transaction's start time is the same for all of its statements.
    @Test func aScopesReadsShareOneReadOnlyTransactionWithTheBound() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .seconds(15)))
        let sql = """
            SELECT current_setting('statement_timeout'), current_setting('transaction_read_only'),
                   transaction_timestamp()::text
            """

        let (first, second, streamed) = try await connection.withCatalogReads {
            (try await connection.queryAll(sql), try await connection.queryAll(sql), try await run(sql, on: connection))
        }

        #expect(Array(first.first?.prefix(2) ?? []) == [.text("15s"), .text("on")])
        #expect(first == second && second == streamed)
    }

    /// SET LOCAL ends with its transaction
    /// (https://www.postgresql.org/docs/current/sql-set.html), so the
    /// session's own setting is the server's after a scope.
    @Test func aScopeLeavesTheSessionsStatementTimeoutUnchanged() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .seconds(15)))
        let before = try await connection.queryAll("SELECT current_setting('statement_timeout')")

        _ = try await connection.withCatalogReads { try await connection.queryAll("SELECT 1") }

        #expect(before == [[.text("0")]])
        #expect(try await connection.queryAll("SELECT current_setting('statement_timeout')") == [[.text("0")]])
    }

    @Test func aStatementLongerThanTheBoundIsCancelledAndTheConnectionGoesOn() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .milliseconds(200)))

        let started = ContinuousClock.now
        await #expect(throws: DriverError.self) {
            _ = try await connection.withCatalogReads { try await connection.queryAll("SELECT pg_sleep(3)") }
        }
        await #expect(throws: DriverError.self) {
            _ = try await connection.withCatalogReads { try await run("SELECT pg_sleep(3)", on: connection) }
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        // The aborted transaction was rolled back, or this would fail with
        // "current transaction is aborted".
        #expect(try await connection.withCatalogReads { try await connection.queryAll("SELECT 1") } == [[.int(1)]])
    }

    /// A scope whose task is cancelled is rolled back, whatever the
    /// cancellation does to the requests the task makes, and the session is
    /// left outside any transaction for the next scope.
    @Test func aCancelledScopeRollsBackAndTheNextOneWorks() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        let observer = try await openConnection()
        defer { Task { await observer.close() } }
        #expect(await connection.boundEachStatement(by: .seconds(15)))
        guard case .int(let pid)? = try await connection.queryAll("SELECT pg_backend_pid()").first?.first else {
            Issue.record("no backend pid")
            return
        }
        func state() async throws -> String? {
            let rows = try await observer.queryAll("SELECT state FROM pg_stat_activity WHERE pid = \(pid)")
            if case .text(let text)? = rows.first?.first { return text }
            return nil
        }
        let reading = Reading()

        let scope = Task {
            try await connection.withCatalogReads {
                _ = try await connection.queryAll("SELECT 1")
                await reading.mark()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await reading.wait()
        #expect(try await state() == "idle in transaction")
        scope.cancel()
        await #expect(throws: CancellationError.self) { try await scope.value }

        #expect(try await state() == "idle")
        #expect(try await connection.withCatalogReads { try await connection.queryAll("SELECT 1") } == [[.int(1)]])
    }

    /// Scopes opened at once each get their own transaction: a scope opened
    /// inside another's would be ended by its COMMIT.
    @Test func twoScopesNeverShareATransaction() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .seconds(15)))

        let starts = try await withThrowingTaskGroup(of: [[BerryValue]].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await connection.withCatalogReads {
                        try await connection.queryAll("SELECT transaction_timestamp()::text, pg_sleep(0.02)::text")
                    }
                }
            }
            var seen: [BerryValue] = []
            for try await rows in group { seen += rows.compactMap(\.first) }
            return seen
        }

        #expect(starts.count == 8)
        #expect(Set(starts).count == 8)
    }

    /// A server can refuse the scope: PgBouncer in statement pooling mode
    /// refuses transactions of more than one statement
    /// (https://www.pgbouncer.org/features.html). The bound is a safeguard,
    /// so the reads then run unscoped. The test makes PostgreSQL refuse SET
    /// LOCAL with a bound outside its range, which it rejects with "-200 ms is
    /// outside the valid range for parameter statement_timeout" (16.15).
    @Test func aScopeTheServerRefusesLeavesTheReadsUnscoped() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .milliseconds(-200)))
        _ = try await run("CREATE TEMP TABLE refused_probe (id int)", on: connection)

        let rows = try await connection.withCatalogReads {
            _ = try await run("VACUUM refused_probe", on: connection)
            return try await connection.queryAll("SELECT current_setting('statement_timeout')")
        }

        #expect(rows == [[.text("0")]])
        #expect(try await connection.beginCatalogReads() == nil)
    }

    @Test func anUnboundedConnectionOpensNoScope() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }

        #expect(try await connection.beginCatalogReads() == nil)
        #expect(try await connection.queryAll("SELECT current_setting('statement_timeout')") == [[.text("0")]])
    }
}

/// Lets a test wait until the scope under test has read.
private actor Reading {
    private var done = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func mark() {
        done = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !done else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
