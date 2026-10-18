import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

/// Runs against a real server from `BERRYDB_TEST_MYSQL`, MySQL or MariaDB;
/// skipped when the variable is unset.
@Suite("MySQL errors told apart by number", .serialized, .enabled(if: TestServer.mysql != nil))
struct MySQLErrorMappingTests {
    /// Runs far longer than the bounds and the cancel delay here; the cancel
    /// conformance test relies on the same join.
    private static let heavyQuery = """
        SELECT count(*)
        FROM information_schema.columns a,
             information_schema.columns b,
             information_schema.columns c
        """

    private static func open() async throws -> MySQLDriverConnection {
        let server = TestServer.mysql!
        return try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql, name: "error-mapping", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
    }

    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    private func isCancel(_ error: DriverError?) -> Bool {
        if case .cancelled? = error { return true }
        return false
    }

    private func isFailure(_ error: DriverError?) -> Bool {
        if case .queryFailed? = error { return true }
        return false
    }

    /// A syntax error quotes the statement near where parsing stopped, so its
    /// message carries the statement's own words: "near '1317'" and
    /// "near 'SELEC 'interrupted''", both error 1064 (verified against MySQL
    /// 8.4.11 and MariaDB 11.8.9).
    @Test func anErrorThatQuotesTheStatementIsAFailure() async throws {
        let connection = try await Self.open()
        defer { Task { await connection.close() } }

        for sql in ["SELECT 1317 1317", "SELEC 'interrupted'"] {
            let executed = await #expect(throws: DriverError.self, "execute: \(sql)") {
                try await drain(connection.execute(sql))
            }
            let asText = await #expect(throws: DriverError.self, "text protocol: \(sql)") {
                _ = try await connection.queryAll(sql)
            }

            #expect(isFailure(executed), "execute: \(sql): \(String(describing: executed))")
            #expect(isFailure(asText), "text protocol: \(sql): \(String(describing: asText))")
        }
    }

    /// The statements on the server, other than the asking connection's own,
    /// whose text holds `marker`.
    private func statements(marked marker: String, on watcher: MySQLDriverConnection) async throws -> [Int64] {
        try await watcher.queryAll(
            "SELECT ID FROM information_schema.processlist WHERE ID <> CONNECTION_ID() AND INFO LIKE '%\(marker)%'"
        ).compactMap { if case .int(let id)? = $0.first { id } else { nil } }
    }

    /// Waits, at most 30 s, until the server runs a statement holding `marker`.
    private func waitUntilRunning(_ marker: String, on watcher: MySQLDriverConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while try await statements(marked: marker, on: watcher).isEmpty {
            guard ContinuousClock.now < deadline else {
                Issue.record("the statement never ran")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// KILL QUERY ends the statement with error 1317 on both servers. It
    /// ends only what the connection runs when it arrives; one that reaches
    /// the connection before the statement does is lost (verified against
    /// MySQL 8.4.11 and MariaDB 11.8.9 for a read-only statement's preamble),
    /// so the cancel waits until the server runs the statement. The drain is
    /// bounded, and the statement is ended on the server however the test
    /// goes, so a regression fails the test instead of leaving the join
    /// running for hours.
    @Test func killQueryIsACancel() async throws {
        let connection = try await Self.open()
        let watcher = try await Self.open()
        defer { Task { await connection.close(); await watcher.close() } }
        let marker = "berry-kill-probe-" + UUID().uuidString.prefix(8).lowercased()

        var failure: Error?
        do {
            let stream = connection.execute(Self.heavyQuery.replacingOccurrences(
                of: "SELECT count(*)", with: "SELECT count(*), '\(marker)'"
            ))
            try await waitUntilRunning(marker, on: watcher)
            connection.cancelCurrentQuery()
            let error = await #expect(throws: DriverError.self) {
                try await within(.seconds(10)) { try await drain(stream) }
            }
            #expect(isCancel(error), "\(String(describing: error))")
        } catch {
            failure = error
        }
        for id in (try? await statements(marked: marker, on: watcher)) ?? [] {
            _ = try? await watcher.queryAll("KILL QUERY \(id)")
        }
        if let failure { throw failure }
    }

    /// Waits, at most 10 s, until MySQLNIO has seen `connection` close.
    private func waitUntilClosed(_ connection: MySQLDriverConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !connection.connectionClosedForTesting {
            guard ContinuousClock.now < deadline else {
                Issue.record("the connection never saw the server end it")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func connectionID(of connection: MySQLDriverConnection, readOnly: Bool = false) async throws -> Int64 {
        let sql = "SELECT CONNECTION_ID()"
        let rows = try await drain(readOnly ? connection.executeReadOnly(sql, timeout: .seconds(10)) : connection.execute(sql))
        guard case .int(let id)? = rows.first?.first else {
            Issue.record("no connection ID in \(rows)")
            return -1
        }
        return id
    }

    /// KILL without QUERY ends the connection itself
    /// (https://dev.mysql.com/doc/refman/8.4/en/kill.html,
    /// https://mariadb.com/kb/en/kill/). Every way the driver sends a
    /// statement then reports a lost connection, the read-only setup and a
    /// read-only statement included: reported as `readOnlyUnavailable`, it
    /// would make the in-app assistant ask for an approval card as if the
    /// server could not run read-only. Each call is bounded, so one that
    /// waits forever fails the test.
    @Test func aKilledConnectionIsALostConnection() async throws {
        let connection = try await Self.open()
        let readOnly = try await Self.open()
        let unprepared = try await Self.open()
        let admin = try await Self.open()
        defer { Task { await connection.close(); await readOnly.close(); await unprepared.close(); await admin.close() } }
        try await readOnly.prepareReadOnly()
        let ids = [
            try await connectionID(of: connection),
            try await connectionID(of: readOnly, readOnly: true),
            try await connectionID(of: unprepared),
        ]
        for id in ids {
            _ = try await admin.queryAll("KILL \(id)")
        }
        try await waitUntilClosed(connection)
        try await waitUntilClosed(readOnly)
        try await waitUntilClosed(unprepared)

        let executed = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await drain(connection.execute("SELECT 1")) }
        }
        let listed = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await connection.queryAll("SELECT 1") }
        }
        let read = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await drain(readOnly.executeReadOnly("SELECT 1", timeout: .seconds(5))) }
        }
        let prepared = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await unprepared.prepareReadOnly() }
        }
        let answered = try await within(.seconds(10)) { await connection.ping() }

        for (path, error) in [("execute", executed), ("queryAll", listed), ("read-only", read), ("read-only setup", prepared)] {
            guard case .connectionLost? = error else {
                Issue.record("\(path): not a lost connection: \(String(describing: error))")
                continue
            }
        }
        #expect(answered == false)
    }

    /// The server's own bound ends the statement with error 3024 on MySQL
    /// (`MAX_EXECUTION_TIME`) and 1969 on MariaDB (`max_statement_time`),
    /// on a connection bounded statement by statement and on the read-only
    /// path alike.
    @Test func aStatementPastTheServersBoundIsACancel() async throws {
        let bounded = try await Self.open()
        let readOnly = try await Self.open()
        defer { Task { await bounded.close(); await readOnly.close() } }
        #expect(await bounded.boundEachStatement(by: .milliseconds(200)))
        try await readOnly.prepareReadOnly()

        let executed = await #expect(throws: DriverError.self) { try await drain(bounded.execute(Self.heavyQuery)) }
        let read = await #expect(throws: DriverError.self) {
            try await drain(readOnly.executeReadOnly(Self.heavyQuery, timeout: .milliseconds(200)))
        }

        #expect(isCancel(executed), "bounded: \(String(describing: executed))")
        #expect(isCancel(read), "read-only: \(String(describing: read))")
    }
}
