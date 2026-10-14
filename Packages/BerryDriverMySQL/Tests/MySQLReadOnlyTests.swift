import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

@Suite("MySQL read-only statements")
struct MySQLReadOnlyStatementTests {
    /// A schema change commits the open transaction before it runs, so the
    /// read-only transaction alone does not stop it; the session's default
    /// mode, set again before every statement, does.
    @Test func eachStatementRunsInAReadOnlyTransactionOfAReadOnlySession() {
        #expect(MySQLDriverConnection.readOnlyPreamble == [
            "SET SESSION TRANSACTION READ ONLY",
            "START TRANSACTION READ ONLY",
        ])
    }
}

/// Runs against a real server from `BERRYDB_TEST_MYSQL`, MySQL or MariaDB;
/// skipped when the variable is unset. Each test makes its own table and
/// function, named after a fresh UUID, and drops them.
@Suite("MySQL read-only connection", .serialized, .enabled(if: TestServer.mysql != nil))
struct MySQLReadOnlyTests {
    private struct Opened {
        let main: MySQLDriverConnection
        let readOnly: MySQLDriverConnection
        let table: String
    }

    private func config() -> ConnectionConfig {
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

    @Test func prepareSetsTheLockWaitAndTheConnectionReads() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        let lockWait = try await readOnly("SELECT @@SESSION.lock_wait_timeout", on: opened)

        #expect(lockWait.first?.first?.displayString == "5")
        #expect(try await readOnly("SELECT count(*) FROM \(opened.table)", on: opened).first?.first?.displayString == "0")
    }

    /// The must-fail list: a plain write and a function that writes; the
    /// server refuses each with error 1792.
    @Test func writesFailOnTheServerHoweverTheyAreSpelled() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table

        for statement in [
            "INSERT INTO \(table) VALUES (1)",
            "SELECT \(table)_writer()",
        ] {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(isReadOnlyRefusal(error), "\(statement): \(String(describing: error))")
        }

        #expect(try await rowCount(opened) == "0")
    }

    /// A schema change commits the read-only transaction before it runs
    /// (https://dev.mysql.com/doc/refman/8.4/en/implicit-commit.html) and
    /// then runs under the session's default mode, which is read-only too.
    /// Verified against MySQL 8.4.11 and MariaDB 11.8.9: in a read-write
    /// session DROP TABLE runs from inside START TRANSACTION READ ONLY.
    @Test func schemaChangesFailOnTheServer() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let table = opened.table

        for statement in [
            "CREATE TABLE \(table)_made (id INT)",
            "DROP TABLE \(table)",
            "TRUNCATE TABLE \(table)",
        ] {
            let error = await #expect(throws: DriverError.self, "\(statement)") { try await readOnly(statement, on: opened) }
            #expect(isReadOnlyRefusal(error), "\(statement): \(String(describing: error))")
        }

        #expect(try await tableExists(table, opened))
        #expect(try await tableExists("\(table)_made", opened) == false)
    }

    /// SET SESSION TRANSACTION READ WRITE is allowed inside a transaction and
    /// changes the session's default; the next statement still starts its
    /// own read-only transaction in a read-only session. SET TRANSACTION
    /// without SESSION is refused inside a transaction with error 1568.
    @Test func switchingTheModeBackDoesNotReachTheNextStatement() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        try await readOnly("SET SESSION TRANSACTION READ WRITE", on: opened)
        let switched = await #expect(throws: DriverError.self) { try await readOnly("SET TRANSACTION READ WRITE", on: opened) }
        let insert = await #expect(throws: DriverError.self) { try await readOnly("INSERT INTO \(opened.table) VALUES (2)", on: opened) }
        try await readOnly("SET SESSION TRANSACTION READ WRITE", on: opened)
        let create = await #expect(throws: DriverError.self) { try await readOnly("CREATE TABLE \(opened.table)_made (id INT)", on: opened) }

        #expect(refusal(switched)?.contains("while a transaction is in progress") == true, "\(String(describing: switched))")
        #expect(isReadOnlyRefusal(insert), "\(String(describing: insert))")
        #expect(isReadOnlyRefusal(create), "\(String(describing: create))")
        #expect(try await rowCount(opened) == "0")
        #expect(try await tableExists("\(opened.table)_made", opened) == false)
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

    /// Writes sent at once all fail, in whatever order their control
    /// statements reach the server. Whether two statements shared a
    /// transaction does not show here: the session's read-only default also
    /// refuses an INSERT that another statement's COMMIT left outside its
    /// transaction. `aStatementSentWhileAnotherRunsStartsAfterItsCommit`
    /// checks the order itself.
    @Test func concurrentWritesAllFail() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let sql = index.isMultiple(of: 2) ? "SELECT SLEEP(0.05)" : "INSERT INTO \(opened.table) VALUES (\(index))"
                group.addTask { _ = try? await readOnly(sql, on: opened) }
            }
        }

        #expect(try await rowCount(opened) == "0")
    }

    /// A statement sent while another runs starts after the other's COMMIT,
    /// read from the server's general query log
    /// (https://dev.mysql.com/doc/refman/8.4/en/query-log.html). MySQLNIO
    /// sends one command at a time, in the order they were asked for, so
    /// without the turn the second statement's first command would run
    /// before the first statement's COMMIT, its START TRANSACTION would end
    /// the first statement's transaction, and that COMMIT would end its own.
    /// The log is switched on for the test alone and set back after.
    @Test func aStatementSentWhileAnotherRunsStartsAfterItsCommit() async throws {
        let opened = try await open()
        defer { Task { await close(opened) } }
        let connectionID = try #require(try await readOnly("SELECT CONNECTION_ID()", on: opened).first?.first?.displayString)
        let settings = try await drain(opened.main.execute("SELECT @@GLOBAL.general_log, @@GLOBAL.log_output, NOW(6)"))
        let (logging, output, since) = try #require(settings.first.map { ($0[0].displayString, $0[1].displayString, $0[2].displayString) })
        try await drain(opened.main.execute("SET GLOBAL log_output = 'TABLE'"))
        try await drain(opened.main.execute("SET GLOBAL general_log = 1"))

        let running = Task { try await readOnly("SELECT SLEEP(0.5), 7", on: opened) }
        try? await Task.sleep(for: .milliseconds(200))
        let sent = try? await readOnly("SELECT 8", on: opened)
        let ran = try? await running.value

        try await drain(opened.main.execute("SET GLOBAL general_log = \(logging ?? "0")"))
        try await drain(opened.main.execute("SET GLOBAL log_output = '\(output ?? "FILE")'"))
        let log = try await drain(opened.main.execute(
            "SELECT CAST(argument AS CHAR) FROM mysql.general_log WHERE thread_id = \(connectionID)"
                + " AND command_type IN ('Query', 'Execute') AND event_time >= '\(since ?? "")'"
        )).compactMap { $0.first?.displayString }
        let commands = Array(log.drop { !$0.contains("SLEEP(0.5)") }.prefix(3))

        #expect(ran?.first?.map(\.displayString) == ["0", "7"])
        #expect(sent?.first?.first?.displayString == "8")
        #expect(commands.count == 3 && commands[1] == "COMMIT" && commands[2] == MySQLDriverConnection.readOnlyPreamble[0], "\(log)")
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
}
