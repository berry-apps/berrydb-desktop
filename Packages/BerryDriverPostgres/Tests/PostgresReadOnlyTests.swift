import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres

@Suite("Postgres read-only statements")
struct PostgresReadOnlyStatementTests {
    /// Each statement gets its own read-only transaction and its own bounds;
    /// SET LOCAL ends with the transaction
    /// (https://www.postgresql.org/docs/current/sql-set.html).
    @Test func eachStatementRunsInAReadOnlyTransactionWithItsOwnBounds() {
        #expect(PostgresDriverConnection.readOnlyPreamble(timeout: .seconds(90)) == [
            "BEGIN READ ONLY",
            "SET LOCAL statement_timeout = '90000ms'",
            "SET LOCAL lock_timeout = '5s'",
        ])
    }

    /// statement_timeout = 0 turns the bound off, so whatever is left of the
    /// assistant's deadline, the statement keeps a bound.
    @Test func aDeadlineUnderAMillisecondStillBoundsTheStatement() {
        #expect(PostgresDriverConnection.readOnlyPreamble(timeout: .microseconds(300))[1] == "SET LOCAL statement_timeout = '1ms'")
        #expect(PostgresDriverConnection.readOnlyPreamble(timeout: .zero)[1] == "SET LOCAL statement_timeout = '1ms'")
    }

    @Test func theApplicationNameIsSentAtStartup() {
        let config = ConnectionConfig(driver: .postgres, name: "p", host: "db")

        let named = PostgresDriverConnection.startupParameters(for: config.withApplicationName("BerryDB AI (read-only)"))

        #expect(named.map { "\($0.0)=\($0.1)" } == ["application_name=BerryDB AI (read-only)"])
        #expect(PostgresDriverConnection.startupParameters(for: config).isEmpty)
    }
}

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`; skipped when
/// the variable is unset. Each test makes its own table, sequence and
/// function, named after a fresh UUID, and drops them.
@Suite("Postgres read-only connection", .serialized, .enabled(if: TestServer.postgres != nil))
struct PostgresReadOnlyLiveTests {
    private struct Opened {
        let main: PostgresDriverConnection
        let readOnly: PostgresDriverConnection
        let table: String
    }

    private func config() -> ConnectionConfig {
        let server = TestServer.postgres!
        return ConnectionConfig(
            driver: .postgres, name: "read-only", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        )
    }

    private func open() async throws -> Opened {
        let main = try await PostgresDriverConnection(config: config())
        let readOnly = try await PostgresDriverConnection(config: config().withApplicationName("BerryDB AI (read-only)"))
        try await readOnly.prepareReadOnly()
        let table = "ro_probe_" + UUID().uuidString.prefix(8).lowercased()
        try await drain(main.execute("CREATE TABLE \(table) (id int)"))
        try await drain(main.execute("CREATE SEQUENCE \(table)_seq"))
        try await drain(main.execute(
            "CREATE FUNCTION \(table)_writer() RETURNS int LANGUAGE sql AS $$ INSERT INTO \(table) VALUES (99) RETURNING id $$"
        ))
        return Opened(main: main, readOnly: readOnly, table: table)
    }

    private func close(_ opened: Opened) async {
        _ = try? await drain(opened.main.execute("DROP PROCEDURE IF EXISTS \(opened.table)_proc()"))
        _ = try? await drain(opened.main.execute("DROP FUNCTION IF EXISTS \(opened.table)_writer()"))
        _ = try? await drain(opened.main.execute("DROP SEQUENCE IF EXISTS \(opened.table)_seq"))
        _ = try? await drain(opened.main.execute("DROP TABLE IF EXISTS \(opened.table)"))
        await opened.main.close()
        await opened.readOnly.close()
    }

    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    @discardableResult
    private func readOnly(_ sql: String, on opened: Opened, timeout: Duration = .seconds(30)) async throws -> [[BerryValue]] {
        try await drain(opened.readOnly.executeReadOnly(sql, timeout: timeout))
    }

    private func rowCount(_ opened: Opened) async throws -> [[BerryValue]] {
        try await drain(opened.main.execute("SELECT count(*) FROM \(opened.table)"))
    }

    /// The message of a statement that failed; nil when it was cancelled,
    /// was not run, or did not fail.
    private func refusal(_ error: DriverError?) -> String? {
        if case .queryFailed(let message, _)? = error { return message }
        return nil
    }

    @Test func theConnectionIsNamedForTheServerAndReads() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        #expect(try await readOnly("SELECT application_name FROM pg_stat_activity WHERE pid = pg_backend_pid()", on: opened)
            == [[.text("BerryDB AI (read-only)")]])
        #expect(try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened) == [[.int(0)]])
    }

    /// The must-fail list for statements that start like a read: a write in
    /// a WITH, a sequence, a function that writes, and switching the mode
    /// off inside the statement that writes.
    /// A write fails with SQLSTATE 25006, "cannot execute … in a read-only
    /// transaction". In the SELECT that calls set_config before the writing
    /// function, the switch fails first, with SQLSTATE 25001, because the
    /// statement already holds its snapshot. Verified against PostgreSQL
    /// 16.15 (postgres:16-alpine).
    @Test func writesFailOnTheServerHoweverTheyAreSpelled() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table
        let readOnlyWrite = "in a read-only transaction"

        for (statement, refused) in [
            ("WITH made AS (INSERT INTO \(table) VALUES (1) RETURNING id) SELECT id FROM made", readOnlyWrite),
            ("SELECT nextval('\(table)_seq')", readOnlyWrite),
            ("SELECT \(table)_writer()", readOnlyWrite),
            (
                "SELECT set_config('transaction_read_only', 'off', true), \(table)_writer()",
                "transaction read-write mode must be set before any query"
            ),
            (
                "WITH flip AS (SELECT set_config('transaction_read_only', 'off', true)) INSERT INTO \(table) SELECT 1 FROM flip",
                readOnlyWrite
            ),
        ] {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(refusal(error)?.contains(refused) == true, "\(statement): \(String(describing: error))")
        }

        #expect(try await rowCount(opened) == [[.int(0)]])
        #expect(try await drain(opened.main.execute("SELECT nextval('\(table)_seq')")) == [[.int(1)]])
    }

    /// A SELECT may change the session's default access mode with
    /// set_config; the next statement still begins read-only.
    @Test func switchingTheModeBackDoesNotReachTheNextStatement() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let flipped = try await readOnly("SELECT set_config('default_transaction_read_only', 'off', false)", on: opened)
        let error = await #expect(throws: DriverError.self) {
            try await readOnly("WITH made AS (INSERT INTO \(opened.table) VALUES (2) RETURNING id) SELECT id FROM made", on: opened)
        }

        #expect(flipped == [[.text("off")]])
        #expect(refusal(error)?.contains("in a read-only transaction") == true, "\(String(describing: error))")
        #expect(try await rowCount(opened) == [[.int(0)]])
    }

    /// `DO` and `CALL` run procedural code, which can try to change the
    /// access mode or end the transaction before it writes. PostgreSQL
    /// 16.15 refuses both from inside BEGIN READ ONLY (a snapshot is
    /// already taken, and a COMMIT inside the explicit transaction is an
    /// invalid transaction termination), so the refusal before the server
    /// keeps the engines alike rather than closing a hole there.
    @Test func statementsThatDoNotStartLikeAReadAreRefusedBeforeTheServer() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table
        try await drain(opened.main.execute(
            "CREATE PROCEDURE \(table)_proc() LANGUAGE plpgsql AS $$ BEGIN COMMIT; SET TRANSACTION READ WRITE; "
                + "INSERT INTO \(table) VALUES (4); END $$"
        ))

        for statement in [
            "DO $$ BEGIN SET TRANSACTION READ WRITE; INSERT INTO \(table) VALUES (3); END $$",
            "CALL \(table)_proc()",
            "INSERT INTO \(table) VALUES (1)",
            "SET TRANSACTION READ WRITE",
            "/* /* */ SELECT 1 */ DO $$ BEGIN INSERT INTO \(table) VALUES (5); END $$",
        ] {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(refusal(error)?.hasPrefix("The read-only connection ") == true, "\(statement): \(String(describing: error))")
        }

        #expect(try await rowCount(opened) == [[.int(0)]])
    }

    /// PostgresNIO sends each statement with the extended query protocol,
    /// which refuses a text of two statements before running either
    /// (https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY).
    @Test func aTextWithTwoStatementsIsRefused() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let error = await #expect(throws: DriverError.self) {
            try await readOnly("SELECT 1; INSERT INTO \(opened.table) VALUES (3)", on: opened)
        }

        #expect(refusal(error)?.contains("cannot insert multiple commands into a prepared statement") == true)
        #expect(try await rowCount(opened) == [[.int(0)]])
    }

    @Test func aReadDoesNotSeeTheUsersUncommittedRow() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        try await drain(opened.main.execute("BEGIN"))
        try await drain(opened.main.execute("INSERT INTO \(opened.table) VALUES (42)"))

        let seen = try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened)

        try await drain(opened.main.execute("ROLLBACK"))
        #expect(seen == [[.int(0)]])
    }

    /// lock_timeout: a read gives up on the user's uncommitted lock after
    /// five seconds instead of queueing behind it, and others behind it. A
    /// read without the bound would wait for the lock until the watchdog
    /// rolls the user's transaction back.
    @Test func aReadGivesUpOnTheUsersLockAfterFiveSeconds() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        try await drain(opened.main.execute("BEGIN"))
        try await drain(opened.main.execute("LOCK TABLE \(opened.table) IN ACCESS EXCLUSIVE MODE"))
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            try await drain(opened.main.execute("ROLLBACK"))
        }

        let started = ContinuousClock.now
        let error = await #expect(throws: DriverError.self) { try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened) }
        let waited = ContinuousClock.now - started
        watchdog.cancel()

        _ = try? await drain(opened.main.execute("ROLLBACK"))
        #expect(refusal(error)?.contains("lock timeout") == true, "\(String(describing: error))")
        #expect(waited >= .seconds(4) && waited < .seconds(9))
    }

    /// The server's statement_timeout cancels the statement with SQLSTATE
    /// 57014, the code of a cancelled query, so it reports as cancelled.
    @Test func theServerBoundsTheStatementAndTheConnectionGoesOn() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let started = ContinuousClock.now
        let error = await #expect(throws: DriverError.self) {
            try await readOnly("SELECT pg_sleep(5)", on: opened, timeout: .milliseconds(300))
        }

        #expect(ContinuousClock.now - started < .seconds(4))
        #expect({ if case .cancelled? = error { true } else { false } }(), "\(String(describing: error))")
        #expect(try await readOnly("SELECT 1", on: opened) == [[.int(1)]])
    }

    /// Statements sent at once never share a transaction: if one's COMMIT
    /// ended the other's transaction, that other INSERT would run in none.
    @Test func concurrentStatementsNeverShareATransaction() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let sql = index.isMultiple(of: 2)
                    ? "SELECT pg_sleep(0.05)"
                    : "WITH made AS (INSERT INTO \(opened.table) VALUES (\(index)) RETURNING id) SELECT id FROM made"
                group.addTask { _ = try? await readOnly(sql, on: opened) }
            }
        }

        #expect(try await rowCount(opened) == [[.int(0)]])
    }

    /// A statement sent while another runs waits for the other's COMMIT.
    /// Sent at once, its BEGIN would queue behind the running statement and
    /// land inside that transaction, the COMMIT would end both, and its
    /// INSERT would run in none.
    @Test func aStatementSentWhileAnotherRunsWaitsForItsCommit() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let running = Task { try await readOnly("SELECT 7 FROM pg_sleep(0.5)", on: opened) }
        try await Task.sleep(for: .milliseconds(200))
        let error = await #expect(throws: DriverError.self) {
            try await readOnly("WITH made AS (INSERT INTO \(opened.table) VALUES (5) RETURNING id) SELECT id FROM made", on: opened)
        }

        #expect(refusal(error)?.contains("in a read-only transaction") == true, "\(String(describing: error))")
        #expect(try await running.value == [[.int(7)]])
        #expect(try await rowCount(opened) == [[.int(0)]])
    }

    /// Stop in the editor cancels the backend of the session's own
    /// connection, never the read-only connection's statement.
    @Test func cancellingTheSessionConnectionLeavesTheReadRunning() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let read = Task { try await readOnly("SELECT 7 FROM pg_sleep(2)", on: opened) }
        let editor = Task { try await drain(opened.main.execute("SELECT pg_sleep(10)")) }
        try await Task.sleep(for: .milliseconds(500))
        opened.main.cancelCurrentQuery()

        await #expect(throws: DriverError.self) { try await editor.value }
        #expect(try await read.value == [[.int(7)]])
    }

    /// The assistant's timeout ends the read's stream, which cancels the
    /// read-only connection's own backend and leaves the editor's statement.
    @Test func cancellingTheReadLeavesTheEditorsStatementRunning() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let editor = Task { try await drain(opened.main.execute("SELECT 7 FROM pg_sleep(2)")) }
        let read = Task { try await readOnly("SELECT pg_sleep(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        read.cancel()
        _ = await read.result

        #expect(try await editor.value == [[.int(7)]])
    }

    /// The cancel reaches the statement that holds the connection's turn:
    /// the next statement runs at once instead of waiting it out.
    @Test func cancellingTheRunningReadEndsItOnTheServer() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let read = Task { try await readOnly("SELECT pg_sleep(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        read.cancel()
        _ = await read.result

        let started = ContinuousClock.now
        #expect(try await readOnly("SELECT 1", on: opened) == [[.int(1)]])
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A statement cancelled while it waits for the connection's turn never
    /// runs, and no cancel is sent for it. The server cancels by backend,
    /// whatever runs there
    /// (https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL),
    /// so a cancel sent for the waiting statement would end the one ahead.
    @Test func cancellingAQueuedReadLeavesTheRunningReadAlone() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let running = Task { try await readOnly("SELECT 7 FROM pg_sleep(2)", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        let queued = Task { try await readOnly("SELECT pg_sleep(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(200))
        queued.cancel()
        _ = await queued.result

        #expect(try await running.value == [[.int(7)]])
        let started = ContinuousClock.now
        #expect(try await readOnly("SELECT 1", on: opened) == [[.int(1)]])
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
