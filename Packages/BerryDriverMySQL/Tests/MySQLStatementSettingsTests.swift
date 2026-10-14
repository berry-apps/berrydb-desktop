import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

@Suite("MySQL settings for one statement")
struct MySQLStatementSettingsTests {
    @Test func theFormFollowsTheServerAndItsVersion() {
        #expect(MySQLDriverConnection.perStatementForm(version: "8.4.11") == .optimizerHints)
        #expect(MySQLDriverConnection.perStatementForm(version: "8.0.3") == .optimizerHints)
        #expect(MySQLDriverConnection.perStatementForm(version: "8.0.36-0ubuntu0.22.04.1") == .optimizerHints)
        #expect(MySQLDriverConnection.perStatementForm(version: "8.0.2-dmr") == .none)
        #expect(MySQLDriverConnection.perStatementForm(version: "5.7.44-log") == .none)
        #expect(MySQLDriverConnection.perStatementForm(version: "11.8.9-MariaDB-ubu2404") == .setStatement)
        #expect(MySQLDriverConnection.perStatementForm(version: "10.1.2-MariaDB") == .setStatement)
        #expect(MySQLDriverConnection.perStatementForm(version: "10.1.1-MariaDB") == .none)
        #expect(MySQLDriverConnection.perStatementForm(version: "unknown") == .none)
        #expect(MySQLDriverConnection.perStatementForm(version: nil) == .none)
    }

    @Test func mysqlGetsEveryHintInOneCommentAfterSelect() {
        #expect(MySQLDriverConnection.statement(
            "SELECT a FROM t", form: .optimizerHints, timeout: .seconds(15), groupConcatMaxLength: nil
        ) == "SELECT /*+ MAX_EXECUTION_TIME(15000) */ a FROM t")
        #expect(MySQLDriverConnection.statement(
            "\n  select a FROM t", form: .optimizerHints, timeout: .milliseconds(250), groupConcatMaxLength: 1_048_576
        ) == "SELECT /*+ MAX_EXECUTION_TIME(250) SET_VAR(group_concat_max_len = 1048576) */ a FROM t")
        // A hint applies to SELECT alone.
        #expect(MySQLDriverConnection.statement(
            "SHOW DATABASES", form: .optimizerHints, timeout: .seconds(15), groupConcatMaxLength: nil
        ) == "SHOW DATABASES")
        #expect(MySQLDriverConnection.statement(
            "SELECTED", form: .optimizerHints, timeout: .seconds(15), groupConcatMaxLength: nil
        ) == "SELECTED")
    }

    @Test func mariaDBGetsOneSetStatementBeforeSelectOrShow() {
        #expect(MySQLDriverConnection.statement(
            "SELECT a FROM t", form: .setStatement, timeout: .seconds(15), groupConcatMaxLength: 1_048_576
        ) == "SET STATEMENT max_statement_time=15, group_concat_max_len=1048576 FOR SELECT a FROM t")
        #expect(MySQLDriverConnection.statement(
            "SHOW DATABASES", form: .setStatement, timeout: .milliseconds(250), groupConcatMaxLength: nil
        ) == "SET STATEMENT max_statement_time=0.25 FOR SHOW DATABASES")
        #expect(MySQLDriverConnection.statement(
            "SET SESSION sql_mode = ''", form: .setStatement, timeout: .seconds(15), groupConcatMaxLength: nil
        ) == "SET SESSION sql_mode = ''")
    }

    @Test func anOlderServerGetsTheStatementAsItIs() {
        #expect(MySQLDriverConnection.statement(
            "SELECT 1", form: .none, timeout: .seconds(15), groupConcatMaxLength: 1_048_576
        ) == "SELECT 1")
    }
}

/// Runs against a real server from `BERRYDB_TEST_MYSQL`, MySQL or MariaDB;
/// skipped when the variable is unset.
@Suite("MySQL statements bounded one by one", .serialized, .enabled(if: TestServer.mysql != nil))
struct MySQLBoundedStatementTests {
    private func openConnection() async throws -> MySQLDriverConnection {
        let server = TestServer.mysql!
        return try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql, name: "bounded", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
    }

    private func value(_ sql: String, on connection: MySQLDriverConnection) async throws -> String? {
        switch try await connection.queryAll(sql).first?.first {
        case .text(let text)?: text
        case .int(let number)?: String(number)
        case .double(let number)?: String(number)
        default: nil
        }
    }

    private func isMariaDB(_ connection: MySQLDriverConnection) async throws -> Bool {
        try await value("SELECT VERSION()", on: connection)?.contains("MariaDB") == true
    }

    /// An interrupted `SLEEP` returns 1 on MySQL 8.4 and fails with error 1969
    /// on MariaDB 11.8 (both observed), so the test times the statement.
    @Test func aBoundedStatementLongerThanItsBoundIsInterrupted() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .milliseconds(200)))

        var started = ContinuousClock.now
        _ = try? await connection.queryAll("SELECT SLEEP(3)")
        #expect(ContinuousClock.now - started < .seconds(2))
        started = ContinuousClock.now
        do { for try await _ in connection.execute("SELECT SLEEP(3)") {} } catch {}
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try await value("SELECT 1", on: connection) == "1")
    }

    /// The bound is the statement's own; the server session's setting stays
    /// unset, so nothing follows the session if a pooler hands it on.
    /// MariaDB's SET STATEMENT sets the variable while its statement runs, so
    /// the probe starts with WITH, which the bound leaves as it is.
    @Test func boundingLeavesTheSessionSettingUnset() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        #expect(await connection.boundEachStatement(by: .seconds(15)))
        let variable = try await isMariaDB(connection) ? "max_statement_time" : "max_execution_time"

        let session = try await value("WITH probe AS (SELECT 1) SELECT @@SESSION.\(variable) FROM probe", on: connection)

        #expect(session.flatMap(Double.init) == 0)
    }

    /// The fingerprint query raises `group_concat_max_len` for itself alone,
    /// so the user's session keeps its own limit.
    @Test func listingObjectsLeavesTheSessionGroupConcatLimitAlone() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }
        let before = try await value("SELECT @@SESSION.group_concat_max_len", on: connection)

        _ = try await connection.introspector.objectSummaries(scope: .allUserSchemas)

        #expect(try await value("SELECT @@SESSION.group_concat_max_len", on: connection) == before)
    }
}
