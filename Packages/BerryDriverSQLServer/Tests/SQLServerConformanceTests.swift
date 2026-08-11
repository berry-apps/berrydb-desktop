import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverSQLServer

/// Runs against a real SQL Server from `BERRYDB_TEST_SQLSERVER`
/// (see Tests/docker/compose.yml); skipped when the env var is unset.
///
/// `.serialized`: FreeTDS DB-Library's error/message handlers are
/// process-global C function pointers (see `SQLServerRuntime`'s doc
/// comment) — Swift Testing runs `@Test`s within a suite CONCURRENTLY by
/// default, and a first attempt at that here produced an unexplained abrupt
/// process exit partway through the run (no final summary line, no crash
/// report captured), consistent with DB-Library not tolerating truly
/// concurrent multi-connection use despite being documented as safe for
/// "one thread per DBPROCESS." Same shared-global-state reasoning this
/// project already applies elsewhere (`WorkspaceKeyValueTests`,
/// `WorkspaceGraphTests`).
@Suite("SQL Server driver conformance", .enabled(if: TestServer.sqlServer != nil), .serialized)
struct SQLServerConformanceTests {
    private var harness: DriverConformance {
        DriverConformance {
            let server = TestServer.sqlServer!
            return try await SQLServerConnection(config: ConnectionConfig(
                driver: .sqlserver,
                name: "test",
                host: server.host,
                port: server.port,
                username: server.username,
                password: server.password,
                database: server.database
            ))
        }
    }

    @Test func typeRoundTrip() async throws {
        try await harness.checkRoundTrip(
            setup: [
                """
                CREATE TABLE #berry_types (
                    b BIT, i2 SMALLINT, i8 BIGINT, f8 FLOAT,
                    num NUMERIC(12,4), t NVARCHAR(100), bin VARBINARY(16),
                    dt DATETIME, n NVARCHAR(10) NULL
                )
                """,
                """
                INSERT INTO #berry_types VALUES (
                    1, 7, 9007199254740993, 2.5,
                    12345.6789, N'xin chào', 0xdeadbeef,
                    '2026-01-02T03:04:05', NULL
                )
                """,
            ],
            select: "SELECT * FROM #berry_types",
            expectedColumnCount: 9
        ) { row in
            guard case .bool(true) = row[0] else { throw ConformanceFailure("bit: \(row[0])") }
            guard case .int(7) = row[1] else { throw ConformanceFailure("smallint: \(row[1])") }
            // Value above 2^53 — must survive without Double round-trip loss.
            guard case .int(9_007_199_254_740_993) = row[2] else {
                throw ConformanceFailure("bigint: \(row[2])")
            }
            guard case .double(2.5) = row[3] else { throw ConformanceFailure("float: \(row[3])") }
            guard case .decimal(let dec) = row[4], dec.contains("12345.6") else {
                throw ConformanceFailure("numeric must stay verbatim-ish: \(row[4])")
            }
            guard case .text("xin chào") = row[5] else { throw ConformanceFailure("nvarchar: \(row[5])") }
            guard case .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])) = row[6] else {
                throw ConformanceFailure("varbinary: \(row[6])")
            }
            guard case .timestamp = row[7] else { throw ConformanceFailure("datetime: \(row[7])") }
            guard case .null = row[8] else { throw ConformanceFailure("null: \(row[8])") }
        }
    }

    @Test func streamsInBatches() async throws {
        try await harness.checkStreaming(
            setup: [],
            select: """
            WITH nums AS (
                SELECT 1 AS n
                UNION ALL
                SELECT n + 1 FROM nums WHERE n < 10000
            )
            SELECT n AS id, 'row-' + CAST(n AS NVARCHAR(10)) AS name FROM nums OPTION (MAXRECURSION 0)
            """,
            expectedRows: 10_000
        )
    }

    // No cancel test here (unlike Postgres/SQLite's own conformance suites):
    // capabilities.cancelQuery == false for this driver — see
    // SQLServerDriver.swift's capabilities comment for the real,
    // reproduced-via-testing reason (a secondary-connection KILL attempt
    // reliably deadlocked FreeTDS DB-Library, confirmed outside the test
    // suite too, not a flaky test artifact).

    @Test func errorClassification() async throws {
        try await harness.checkErrorClassification(
            badQuery: "SELECT * FROM berry_conf_table_does_not_exist_xyz",
            probeQuery: "SELECT 1"
        )
    }

    @Test func useDatabaseSwitchesOnTheSameConnection() async throws {
        let conn = try await harness.makeConnection() as! SQLServerConnection
        defer { Task { await conn.close() } }
        // master always exists — confirms setDatabase actually took effect
        // (SQL Server can USE without reconnecting, unlike Postgres).
        try await conn.setDatabase("master")
        let result = try await harness.drain(conn.execute("SELECT DB_NAME()"))
        guard case .text("master")? = result.rows.first?.first else {
            throw ConformanceFailure("Expected DB_NAME() == master after setDatabase, got \(String(describing: result.rows.first))")
        }
    }

    @Test func introspectorListsATableItJustCreated() async throws {
        let conn = try await harness.makeConnection() as! SQLServerConnection
        defer { Task { await conn.close() } }
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(name)"]) } }

        try await harness.exec(conn, ["CREATE TABLE \(name) (id INT PRIMARY KEY, label NVARCHAR(50))"])
        let objects = try await conn.introspector.objects(in: "dbo")
        #expect(objects.contains { $0.name == name && $0.kind == .table })

        let detail = try await conn.introspector.tableDetail(TableRef(database: "dbo", name: name))
        #expect(detail.columns.map(\.name) == ["id", "label"])
        #expect(detail.columns.first?.isPrimaryKey == true)
    }
}
