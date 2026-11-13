import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverLibSQL

/// Runs against a real self-hosted sqld / libSQL server from `BERRYDB_TEST_LIBSQL`
/// (`HOST:PORT[:TOKEN]`); skipped cleanly when unset.
@Suite("libSQL driver conformance", .enabled(if: LibSQLTestServer.libsql != nil))
struct LibSQLConformanceTests {
    private var server: LibSQLTestServer { LibSQLTestServer.libsql! }

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig.libsql(
            host: "http://\(server.host):\(server.port)",
            port: server.port,
            authToken: server.authToken,
            tlsMode: .disable
        )
    }

    private var harness: DriverConformance {
        DriverConformance {
            try await LibSQLDriver.connect(makeConfig())
        }
    }

    @Test func typeRoundTrip() async throws {
        let table = "berry_types_\(String(UUID().uuidString.prefix(8)).lowercased())"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, [
            "CREATE TABLE \(table) (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)",
            "INSERT INTO \(table) VALUES (42, 3.25, 'xin chao', X'DEADBEEF', NULL)",
        ])
        do {
            let result = try await harness.drain(conn.execute("SELECT i, r, t, b, n FROM \(table)"))
            #expect(result.rows.count == 1)
            let row = result.rows[0]
            #expect(row == [.int(42), .double(3.25), .text("xin chao"), .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])), .null])
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
    }

    @Test func streamsInBatches() async throws {
        try await harness.checkStreaming(
            setup: [],
            select: """
            WITH RECURSIVE cnt(x) AS (
                SELECT 1
                UNION ALL
                SELECT x + 1 FROM cnt WHERE x < 1500
            )
            SELECT x AS id, 'row-' || x AS label FROM cnt
            """,
            expectedRows: 1500,
            maxBatch: LibSQLConnection.batchSize
        )
    }

    @Test func classifiesSQLErrors() async throws {
        try await harness.checkErrorClassification(
            badQuery: "SELECT * FROM berry_nonexistent_table",
            probeQuery: "SELECT 1"
        )
    }

    @Test func transactionsCommitAndRollback() async throws {
        let table = "berry_tx_\(String(UUID().uuidString.prefix(8)).lowercased())"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, ["CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT)"])
        do {
            try await harness.exec(conn, [
                "BEGIN",
                "INSERT INTO \(table) VALUES (1, 'rolled-back')",
                "ROLLBACK",
            ])
            let afterRollback = try await harness.drain(conn.execute("SELECT COUNT(*) FROM \(table)"))
            #expect(afterRollback.rows == [[.int(0)]])

            try await harness.exec(conn, [
                "BEGIN",
                "INSERT INTO \(table) VALUES (2, 'committed')",
                "COMMIT",
            ])
            let afterCommit = try await harness.drain(conn.execute("SELECT id, name FROM \(table)"))
            #expect(afterCommit.rows == [[.int(2), .text("committed")]])
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
    }

    @Test func readOnlyExecution() async throws {
        let table = "berry_ro_\(String(UUID().uuidString.prefix(8)).lowercased())"
        let conn = try await LibSQLDriver.connect(makeConfig())
        defer { Task { await conn.close() } }

        try await harness.exec(conn, [
            "CREATE TABLE \(table) (id INTEGER PRIMARY KEY, label TEXT)",
            "INSERT INTO \(table) VALUES (1, 'alpha'), (2, 'beta')",
        ])
        do {
            try await conn.prepareReadOnly()
            let readResult = try await harness.drain(
                conn.executeReadOnly("SELECT label FROM \(table) WHERE id = ?", parameters: [.int(2)])
            )
            #expect(readResult.rows == [[.text("beta")]])

            await #expect(throws: DriverError.self) {
                _ = try await harness.drain(
                    conn.executeReadOnly("DELETE FROM \(table)", parameters: [])
                )
            }
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
    }

    @Test func introspectsSchema() async throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let parent = "berry_parent_\(suffix)"
        let child = "berry_child_\(suffix)"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, [
            "CREATE TABLE \(parent) (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)",
            "CREATE TABLE \(child) (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES \(parent)(id))",
            "INSERT INTO \(parent) VALUES (1, 'a@example.com')",
        ])
        do {
            let inspector = conn.introspector
            let objects = try await inspector.objects(in: nil)
            #expect(objects.contains { $0.name == parent && $0.kind == .table })
            #expect(objects.contains { $0.name == child && $0.kind == .table })

            let detail = try await inspector.tableDetail(TableRef(name: child))
            #expect(detail.columns.map(\.name) == ["id", "parent_id"])
            #expect(detail.columns[0].isPrimaryKey)
            #expect(detail.foreignKeys.contains {
                $0.column == "parent_id" && $0.referencedTable == parent && $0.referencedColumn == "id"
            })

            let stats = try await inspector.tableStats(TableRef(name: parent))
            #expect(stats.estimatedRowCount == 1)
            #expect(stats.engine == "libSQL")

            let ddl = try await inspector.ddl(of: SchemaObject(kind: .table, name: parent))
            #expect(ddl.contains("CREATE TABLE"))
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(child)", "DROP TABLE IF EXISTS \(parent)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(child)", "DROP TABLE IF EXISTS \(parent)"])
    }
}
