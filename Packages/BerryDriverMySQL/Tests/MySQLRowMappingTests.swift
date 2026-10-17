import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

/// Runs against a real server from `BERRYDB_TEST_MYSQL`, MySQL or MariaDB;
/// skipped when the variable is unset.
@Suite("MySQL rows read by position", .enabled(if: TestServer.mysql != nil))
struct MySQLRowMappingTests {
    private static func config() -> ConnectionConfig {
        let server = TestServer.mysql!
        return ConnectionConfig(
            driver: .mysql, name: "row-mapping", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        )
    }

    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    /// Result columns may share a name, and a table; each keeps its own
    /// value. `execute(_:)` reads rows sent with the prepared-statement
    /// protocol, `queryAll(_:)` rows sent as text, and `executeReadOnly`
    /// rows of the same prepared-statement path inside its own transaction.
    @Test func columnsThatShareANameKeepTheirOwnValues() async throws {
        let connection = try await MySQLDriverConnection(config: Self.config())
        let readOnly = try await MySQLDriverConnection(config: Self.config())
        defer { Task { await connection.close(); await readOnly.close() } }
        try await readOnly.prepareReadOnly()
        let cases: [(sql: String, rows: [[BerryValue]])] = [
            ("SELECT 1 AS n, 2 AS n", [[.int(1), .int(2)]]),
            ("SELECT d.x AS v, d.y AS v FROM (SELECT 1 AS x, 'b' AS y) d", [[.int(1), .text("b")]]),
            ("SELECT 1 AS n, NULL AS n", [[.int(1), .null]]),
        ]

        for (sql, rows) in cases {
            let executed = try await drain(connection.execute(sql))
            let asText = try await connection.queryAll(sql)
            let readOnlyRows = try await drain(readOnly.executeReadOnly(sql, timeout: .seconds(30)))

            #expect(executed == rows, "execute: \(sql)")
            #expect(asText == rows, "text protocol: \(sql)")
            #expect(readOnlyRows == rows, "read-only: \(sql)")
        }
    }

    /// The prepared-statement protocol sends an integer in its column's
    /// width with no sign of its own; MySQLNIO 1.9.1 reads it as unsigned
    /// only when the column definition's UNSIGNED flag is passed to
    /// `MySQLData` (`MySQLData.int`). Read as signed, TINYINT UNSIGNED 200
    /// is -56.
    @Test func unsignedIntegersKeepTheirValue() async throws {
        let connection = try await MySQLDriverConnection(config: Self.config())
        defer { Task { await connection.close() } }
        let table = "row_mapping_" + UUID().uuidString.prefix(8).lowercased()
        _ = try await drain(connection.execute(
            "CREATE TEMPORARY TABLE \(table) (t TINYINT UNSIGNED, s SMALLINT UNSIGNED, i INT UNSIGNED)"
        ))
        _ = try await drain(connection.execute("INSERT INTO \(table) VALUES (200, 65000, 4000000000)"))

        let rows = try await drain(connection.execute("SELECT t, s, i FROM \(table)"))

        _ = try? await drain(connection.execute("DROP TEMPORARY TABLE \(table)"))
        #expect(rows == [[.int(200), .int(65_000), .int(4_000_000_000)]])
    }
}
