import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

/// Runs against a real server from `BERRYDB_TEST_MYSQL`, MySQL or MariaDB;
/// skipped when the variable is unset. Each test makes its own table and
/// routines, named after a fresh UUID, and drops them.
@Suite("MySQL read-only connection", .serialized, .enabled(if: TestServer.mysql != nil))
struct MySQLReadOnlyTests {
    private struct Opened {
        let main: MySQLDriverConnection
        let readOnly: MySQLDriverConnection
        let table: String
    }

    private func config() -> ConnectionConfig {
        Self.config()
    }

    private static func config() -> ConnectionConfig {
        let server = TestServer.mysql!
        return ConnectionConfig(
            driver: .mysql, name: "read-only", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        )
    }

    private func open() async throws -> Opened {
        let main = try await MySQLDriverConnection(config: config())
        let readOnly = try await MySQLDriverConnection(config: config())
        try await readOnly.prepareReadOnly()
        let table = "ro_probe_" + UUID().uuidString.prefix(8).lowercased()
        try await drain(main.execute("CREATE TABLE \(table) (id INT)"))
        // DETERMINISTIC lets a function be created while binary logging is on
        // without log_bin_trust_function_creators; it is not true here and
        // does not need to be.
        try await drain(main.execute(
            "CREATE FUNCTION \(table)_writer() RETURNS INT DETERMINISTIC MODIFIES SQL DATA "
                + "BEGIN INSERT INTO \(table) VALUES (99); RETURN 1; END"
        ))
        return Opened(main: main, readOnly: readOnly, table: table)
    }

    private func close(_ opened: Opened) async {
        _ = try? await drain(opened.main.execute("DROP FUNCTION IF EXISTS \(opened.table)_writer"))
        _ = try? await drain(opened.main.execute("DROP FUNCTION IF EXISTS \(opened.table)_flip"))
        _ = try? await drain(opened.main.execute("DROP PROCEDURE IF EXISTS \(opened.table)_proc"))
        _ = try? await drain(opened.main.execute("DROP TABLE IF EXISTS \(opened.table), \(opened.table)_made"))
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

    private func rowCount(_ opened: Opened) async throws -> String? {
        try await drain(opened.main.execute("SELECT count(*) FROM \(opened.table)")).first?.first?.displayString
    }

    private func tableExists(_ name: String, _ opened: Opened) async throws -> Bool {
        let rows = try await drain(opened.main.execute(
            "SELECT count(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '\(name)'"
        ))
        return rows.first?.first?.displayString == "1"
    }

    /// The message of a statement that failed; nil when it was cancelled,
    /// was not run, or did not fail.
    private func refusal(_ error: DriverError?) -> String? {
        if case .queryFailed(let message, _)? = error { return message }
        return nil
    }

    /// Error 1792, ER_CANT_EXECUTE_IN_READ_ONLY_TRANSACTION. The driver
    /// reports MySQLNIO's description of the error, which carries the
    /// server's text, "Cannot execute statement in a READ ONLY transaction"
    /// (verified against MySQL 8.4.11 and MariaDB 11.8.9).
    private func isReadOnlyRefusal(_ error: DriverError?) -> Bool {
        guard let message = refusal(error) else { return false }
        return message.contains("1792") || message.contains("READ ONLY transaction")
    }

    /// Refused before the server saw the text, by `ReadOnlyAllowlist`.
    private func isRefusedBeforeTheServer(_ error: DriverError?) -> Bool {
        refusal(error)?.hasPrefix("The read-only connection ") == true
    }

    private func isMariaDB(_ opened: Opened) async throws -> Bool {
        try await drain(opened.main.execute("SELECT VERSION()")).first?.first?.displayString?.contains("MariaDB") == true
    }

    @Test func prepareSetsTheLockWaitAndTheConnectionReads() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let lockWait = try await readOnly("SELECT @@SESSION.lock_wait_timeout", on: opened)

        #expect(lockWait.first?.first?.displayString == "5")
        #expect(try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened).first?.first?.displayString == "0")
    }

    /// The must-fail list for statements that start like a read: a function
    /// that writes and, on MySQL, a DELETE behind WITH, which MariaDB 11.8
    /// does not parse. The server refuses each with error 1792.
    @Test func writesFailOnTheServerHoweverTheyAreSpelled() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table
        try await drain(opened.main.execute("INSERT INTO \(table) VALUES (1)"))
        var statements = ["SELECT \(table)_writer()"]
        if try await !isMariaDB(opened) {
            statements.append("WITH gone AS (SELECT 1 AS id) DELETE FROM \(table) WHERE id IN (SELECT id FROM gone)")
        }

        for statement in statements {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(isReadOnlyRefusal(error), "\(statement): \(String(describing: error))")
        }

        #expect(try await rowCount(opened) == "1")
    }

    /// Statements that change the access mode or end the read-only
    /// transaction before they write, each verified to write from inside
    /// START TRANSACTION READ ONLY on MariaDB 11.8.9, and the CALL also on
    /// MySQL 8.4.11, plus writes and schema changes that do not start like a
    /// read. None reaches the server.
    @Test func statementsThatDoNotStartLikeAReadAreRefusedBeforeTheServer() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table
        try await drain(opened.main.execute(
            "CREATE PROCEDURE \(table)_proc() BEGIN COMMIT; SET SESSION TRANSACTION READ WRITE; "
                + "INSERT INTO \(table) VALUES (4); END"
        ))

        for statement in [
            "SET STATEMENT transaction_read_only=0 FOR DROP TABLE \(table)",
            "SET STATEMENT tx_read_only=0 FOR DROP TABLE \(table)",
            "BEGIN NOT ATOMIC SET SESSION TRANSACTION READ WRITE; DROP TABLE \(table); END",
            "BEGIN NOT ATOMIC COMMIT; SET SESSION TRANSACTION READ WRITE; INSERT INTO \(table) VALUES (1); END",
            "CALL \(table)_proc()",
            "SELECT 1 /*!, (SELECT \(table)_writer()) */",
            "INSERT INTO \(table) VALUES (2)",
            "CREATE TABLE \(table)_made (id INT)",
            "DROP TABLE \(table)",
            "TRUNCATE TABLE \(table)",
            "SET SESSION TRANSACTION READ WRITE",
        ] {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(isRefusedBeforeTheServer(error), "\(statement): \(String(describing: error))")
        }

        #expect(try await rowCount(opened) == "0")
        #expect(try await tableExists("\(table)_made", opened) == false)
    }

    /// A stored function may set the session's default access mode back to
    /// READ WRITE, and a SELECT may call it; verified against MySQL 8.4.11
    /// and MariaDB 11.8.9. The next statement sets the default again, so a
    /// statement that commits the transaction before it runs still runs
    /// read-only.
    @Test func aFunctionThatSwitchesTheSessionBackDoesNotReachTheNextStatement() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table
        try await drain(opened.main.execute(
            "CREATE FUNCTION \(table)_flip() RETURNS INT DETERMINISTIC "
                + "BEGIN SET @@SESSION.transaction_read_only = 0; RETURN 1; END"
        ))

        let flipped = try await readOnly("SELECT \(table)_flip()", on: opened)
        let mode = try await readOnly("SELECT @@SESSION.transaction_read_only", on: opened)
        let error = await #expect(throws: DriverError.self) { try await readOnly("SELECT \(table)_writer()", on: opened) }

        #expect(flipped.first?.first?.displayString == "1")
        #expect(mode.first?.first?.displayString == "1")
        #expect(isReadOnlyRefusal(error), "\(String(describing: error))")
        #expect(try await rowCount(opened) == "0")
    }

    /// MySQLNIO 1.9.1 leaves CLIENT_MULTI_STATEMENTS out of the capabilities
    /// it asks for, so the server reads a second statement as a syntax error
    /// (https://dev.mysql.com/doc/c-api/8.4/en/c-api-multiple-queries.html).
    @Test func aTextWithTwoStatementsIsRefused() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let error = await #expect(throws: DriverError.self) {
            try await readOnly("SELECT 1; INSERT INTO \(opened.table) VALUES (3)", on: opened)
        }

        #expect(refusal(error)?.contains("SQL syntax") == true, "\(String(describing: error))")
        #expect(try await rowCount(opened) == "0")
    }

    @Test func aReadDoesNotSeeTheUsersUncommittedRow() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        try await drain(opened.main.execute("START TRANSACTION"))
        try await drain(opened.main.execute("INSERT INTO \(opened.table) VALUES (42)"))

        let seen = try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened)

        try await drain(opened.main.execute("ROLLBACK"))
        #expect(seen.first?.first?.displayString == "0")
    }

    /// An interrupted SLEEP returns 1 on MySQL 8.4 and fails on MariaDB 11
    /// (`MySQLBoundedStatementTests`), so the test times the statement.
    @Test func theServerBoundsTheStatementAndTheConnectionGoesOn() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let started = ContinuousClock.now
        _ = try? await readOnly("SELECT SLEEP(5)", on: opened, timeout: .milliseconds(300))

        #expect(ContinuousClock.now - started < .seconds(4))
        #expect(try await readOnly("SELECT 1", on: opened).first?.first?.displayString == "1")
    }

    @Test func parametersBindInOrder() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        try await drain(opened.main.execute("INSERT INTO \(opened.table) VALUES (2), (3)"))

        let rows = try await drain(opened.readOnly.executeReadOnly(
            "SELECT id FROM \(opened.table) WHERE id = ? OR id = ?", parameters: [.text("3"), .int(2)], timeout: .seconds(30)
        ))

        #expect(Set(rows.compactMap { $0.first?.displayString }) == ["2", "3"])
    }

    @Test func everyParameterKindBinds() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let rows = try await drain(opened.readOnly.executeReadOnly(
            "SELECT ? + 0, ? + 0.0, ? IS NULL, ?", parameters: [.int(9_000_000_000), .double(2.5), .null, .text("x")],
            timeout: .seconds(30)
        ))

        #expect(rows.first?.map(\.displayString) == ["9000000000", "2.5", "1", "x"])
    }

    @Test func aParameterCountMismatchFails() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let error = await #expect(throws: DriverError.self) {
            try await drain(opened.readOnly.executeReadOnly("SELECT ?, ?", parameters: [.int(1)], timeout: .seconds(30)))
        }
        #expect(refusal(error) != nil, "\(String(describing: error))")
    }

    /// On MariaDB the statement is wrapped in SET STATEMENT ... FOR, which
    /// must still prepare with its placeholders. An interrupted SLEEP returns
    /// 1 on MySQL and fails on MariaDB, so the test times the statement and
    /// accepts either outcome, but not a refusal of the parameters.
    @Test func theServerBoundStillAppliesWithParameters() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let started = ContinuousClock.now
        var outcome: [[BerryValue]]?
        var failure: DriverError?
        do {
            outcome = try await drain(opened.readOnly.executeReadOnly(
                "SELECT SLEEP(?)", parameters: [.int(5)], timeout: .milliseconds(300)
            ))
        } catch { failure = error as? DriverError }

        #expect(ContinuousClock.now - started < .seconds(4))
        // Interrupted: 1 on MySQL; on MariaDB the driver reports the aborted
        // statement as cancelled (verified against MariaDB 11.8.9).
        var interrupted = outcome?.first?.first?.displayString == "1"
        if case .cancelled? = failure { interrupted = true }
        #expect(interrupted, "\(String(describing: outcome)) \(String(describing: failure))")
        #expect(try await readOnly("SELECT 1", on: opened).first?.first?.displayString == "1")
    }

    /// Writes sent at once all fail, in whatever order their control
    /// statements reach the server. Whether two statements shared a
    /// transaction does not show here: the function's INSERT fails in a
    /// read-only session too.
    /// `aStatementSentWhileAnotherRunsStartsAfterItsCommit` checks the order
    /// itself.
    @Test func concurrentWritesAllFail() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let sql = index.isMultiple(of: 2) ? "SELECT SLEEP(0.05)" : "SELECT \(opened.table)_writer()"
                group.addTask { _ = try? await readOnly(sql, on: opened) }
            }
        }

        #expect(try await rowCount(opened) == "0")
    }

    /// MySQL keeps the last statements of each thread in
    /// `events_statements_history`, on by default
    /// (https://dev.mysql.com/doc/refman/8.4/en/performance-schema-events-statements-history-table.html);
    /// MariaDB 11.8.9 starts with the performance schema off
    /// (https://mariadb.com/kb/en/performance-schema-overview/).
    private static func keepsStatementHistory() async -> Bool {
        guard TestServer.mysql != nil, let connection = try? await MySQLDriverConnection(config: config()) else { return false }
        let rows = try? await connection.queryAll(
            "SELECT ENABLED FROM performance_schema.setup_consumers WHERE NAME = 'events_statements_history'"
        )
        await connection.close()
        return rows?.first?.first?.displayString == "YES"
    }

    /// A statement sent while another runs starts after the other's COMMIT,
    /// read from the read-only connection's own statement history. MySQLNIO
    /// sends one command at a time, in the order they were asked for, so
    /// without the turn the second statement's first command would run
    /// before the first statement's COMMIT, its START TRANSACTION would end
    /// the first statement's transaction, and that COMMIT would end its own.
    /// The history holds 10 statements per thread by default
    /// (`performance_schema_events_statements_history_size`, verified against
    /// MySQL 8.4.11), enough for the end of the first statement and all of
    /// the second.
    @Test(.enabled("needs the performance schema's statement history") { await keepsStatementHistory() })
    func aStatementSentWhileAnotherRunsStartsAfterItsCommit() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let connectionID = try #require(try await readOnly("SELECT CONNECTION_ID()", on: opened).first?.first?.displayString)

        let running = Task { try await readOnly("SELECT SLEEP(0.5), 7", on: opened) }
        try await Task.sleep(for: .milliseconds(200))
        let sent = try await readOnly("SELECT 8", on: opened)
        let ran = try await running.value
        let history = try await drain(opened.main.execute(
            "SELECT h.EVENT_NAME, h.SQL_TEXT FROM performance_schema.events_statements_history h "
                + "JOIN performance_schema.threads t ON t.THREAD_ID = h.THREAD_ID "
                + "WHERE t.PROCESSLIST_ID = \(connectionID) ORDER BY h.EVENT_ID"
        ))
        // A statement run with the prepared-statement protocol is logged as
        // Prepare, Execute and Close stmt with no text; the control
        // statements, sent as text, carry theirs.
        let order = history.compactMap { row in
            row.first?.displayString == "statement/com/Execute" ? "EXECUTE" : row.last?.displayString
        }
        let reads = order.indices.filter { order[$0] == "EXECUTE" }
        let lastTwo = reads.count >= 2 ? Array(order[reads[reads.count - 2]...]) : order

        #expect(ran.first?.map(\.displayString) == ["0", "7"])
        #expect(sent.first?.first?.displayString == "8")
        #expect(lastTwo == ["EXECUTE", "COMMIT"] + MySQLDriverConnection.readOnlyPreamble + ["EXECUTE", "COMMIT"], "\(order)")
    }

    /// Stop in the editor sends KILL QUERY for the session's own connection
    /// only. A SLEEP that ran to the end returns 0.
    @Test func cancellingTheSessionConnectionLeavesTheReadRunning() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let read = Task { try await readOnly("SELECT SLEEP(2), 7", on: opened) }
        let editor = Task { try? await drain(opened.main.execute("SELECT SLEEP(10)")) }
        try await Task.sleep(for: .milliseconds(500))
        opened.main.cancelCurrentQuery()
        _ = await editor.value

        #expect(try await read.value.first?.map(\.displayString) == ["0", "7"])
    }

    @Test func cancellingTheReadLeavesTheEditorsStatementRunning() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let editor = Task { try await drain(opened.main.execute("SELECT SLEEP(2), 7")) }
        let read = Task { try await readOnly("SELECT SLEEP(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        read.cancel()
        _ = await read.result

        #expect(try await editor.value.first?.map(\.displayString) == ["0", "7"])
    }

    /// The cancel reaches the statement that holds the connection's turn:
    /// the next statement runs at once instead of waiting it out.
    @Test func cancellingTheRunningReadEndsItOnTheServer() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let read = Task { try await readOnly("SELECT SLEEP(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        read.cancel()
        _ = await read.result

        let started = ContinuousClock.now
        #expect(try await readOnly("SELECT 1", on: opened).first?.first?.displayString == "1")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A statement cancelled while it waits for the connection's turn never
    /// runs, and no cancel is sent for it. KILL QUERY ends whatever the
    /// connection runs (https://dev.mysql.com/doc/refman/8.4/en/kill.html),
    /// so a cancel sent for the waiting statement would end the one ahead,
    /// whose SLEEP would then return 1.
    @Test func cancellingAQueuedReadLeavesTheRunningReadAlone() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let running = Task { try await readOnly("SELECT SLEEP(2), 7", on: opened) }
        try await Task.sleep(for: .milliseconds(500))
        let queued = Task { try await readOnly("SELECT SLEEP(10)", on: opened) }
        try await Task.sleep(for: .milliseconds(200))
        queued.cancel()
        _ = await queued.result

        #expect(try await running.value.first?.map(\.displayString) == ["0", "7"])
        let started = ContinuousClock.now
        #expect(try await readOnly("SELECT 1", on: opened).first?.first?.displayString == "1")
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A cancel that lands between the preamble and the statement reaches a
    /// connection with nothing running and ends nothing there (verified
    /// against MySQL 8.4.11 and MariaDB 11.8.9). The statement must then
    /// not run: it would hold the connection's turn until its own timeout,
    /// and every read behind it would wait.
    @Test func aCancelDuringThePreambleEndsTheReadBeforeItRuns() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let window = PreambleWindow()
        await opened.readOnly.holdAfterReadOnlyPreamble { await window.hold() }

        let read = Task { try await readOnly("SELECT SLEEP(10)", on: opened) }
        await window.waitUntilHeld()
        read.cancel()
        _ = await read.result
        // The cancel goes out on a connection of its own; a second is ample
        // for it to reach the idle connection before the statement could.
        try await Task.sleep(for: .seconds(1))
        await window.release()

        let started = ContinuousClock.now
        #expect(try await readOnly("SELECT 1", on: opened).first?.first?.displayString == "1")
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}

/// Holds a read-only statement between its preamble and the statement
/// until the test lets it go on.
private actor PreambleWindow {
    private var held = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Polls with a 60-second deadline, so a statement that never reaches
    /// the window fails the test instead of stalling it.
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now + .seconds(60)
        while !held {
            guard ContinuousClock.now < deadline, (try? await Task.sleep(for: .milliseconds(1))) != nil else {
                Issue.record("the statement did not reach the end of its preamble")
                return
            }
        }
    }
}
