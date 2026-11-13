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

    @Test func savepointRollbackToAndCommit() async throws {
        let table = "berry_sp_\(String(UUID().uuidString.prefix(8)).lowercased())"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, ["CREATE TABLE \(table) (id INTEGER PRIMARY KEY, name TEXT)"])
        do {
            try await harness.exec(conn, [
                "BEGIN",
                "INSERT INTO \(table) VALUES (1, 'kept')",
                "SAVEPOINT sp1",
                "INSERT INTO \(table) VALUES (2, 'reverted')",
                "ROLLBACK TRANSACTION TO SAVEPOINT sp1",
                "COMMIT",
            ])
            let rows = try await harness.drain(conn.execute("SELECT id, name FROM \(table)"))
            #expect(rows.rows == [[.int(1), .text("kept")]])
        } catch {
            _ = try? await harness.exec(conn, ["ROLLBACK"])
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
    }

    @Test func multiStatementScriptStopsOnFirstError() async throws {
        let table = "berry_batch_\(String(UUID().uuidString.prefix(8)).lowercased())"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, ["CREATE TABLE \(table) (id INTEGER PRIMARY KEY)"])
        do {
            await #expect(throws: DriverError.self) {
                _ = try await harness.drain(conn.execute("""
                INSERT INTO \(table) VALUES (1);
                SELECT * FROM berry_nonexistent_table_xyz;
                INSERT INTO \(table) VALUES (2);
                """))
            }
            let rows = try await harness.drain(conn.execute("SELECT id FROM \(table)"))
            #expect(rows.rows == [[.int(1)]])
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(table)"])
    }

    @Test func triggerCaseEndAndImplicitForeignKeyAndDialect() async throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let parent = "berry_p_\(suffix)"
        let child = "berry_c_\(suffix)"
        let log = "berry_log_\(suffix)"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        let ddlScript = """
        CREATE TABLE \(parent) (id INTEGER PRIMARY KEY, tag TEXT);
        CREATE TABLE \(child) (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES \(parent));
        CREATE TABLE \(log) (msg TEXT);
        CREATE TRIGGER tr_\(suffix) AFTER INSERT ON \(parent) BEGIN
            UPDATE \(parent) SET tag = CASE WHEN NEW.id > 0 THEN 'pos' ELSE 'neg' END WHERE id = NEW.id;
            INSERT INTO \(log) VALUES (NEW.tag);
        END;
        INSERT INTO \(parent) VALUES (1, 'init');
        """
        _ = try await harness.drain(conn.execute(ddlScript))
        do {
            let logRows = try await harness.drain(conn.execute("SELECT msg FROM \(log)"))
            #expect(logRows.rows == [[.text("init")]])

            let fks = try await conn.introspector.foreignKeys(scope: .allUserSchemas)
            #expect(fks.contains {
                $0.source.name == child
                    && $0.column == "parent_id"
                    && $0.target.name == parent
                    && $0.referencedColumn == "id"
            })

            let detail = try await conn.introspector.tableDetail(TableRef(name: child))
            #expect(detail.foreignKeys.contains {
                $0.column == "parent_id"
                    && $0.referencedTable == parent
                    && $0.referencedColumn == "id"
            })

            let explainSQL = "\(LibSQLDriver.dialect.explainPrefix(analyze: true)) SELECT * FROM \(parent)"
            let explainRes = try await harness.drain(conn.execute(explainSQL))
            #expect(!explainRes.rows.isEmpty)

            let truncateSQL = LibSQLDriver.dialect.truncateSQL(TableRef(name: log))
            _ = try await harness.drain(conn.execute(truncateSQL))
            let afterTruncate = try await harness.drain(conn.execute("SELECT COUNT(*) FROM \(log)"))
            #expect(afterTruncate.rows == [[.int(0)]])
        } catch {
            _ = try? await harness.exec(conn, [
                "DROP TRIGGER IF EXISTS tr_\(suffix)",
                "DROP TABLE IF EXISTS \(log)",
                "DROP TABLE IF EXISTS \(child)",
                "DROP TABLE IF EXISTS \(parent)",
            ])
            throw error
        }
        try await harness.exec(conn, [
            "DROP TRIGGER IF EXISTS tr_\(suffix)",
            "DROP TABLE IF EXISTS \(log)",
            "DROP TABLE IF EXISTS \(child)",
            "DROP TABLE IF EXISTS \(parent)",
        ])
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

            // Bulk tableDetails
            let bulkDetails = try await inspector.tableDetails([TableRef(name: parent), TableRef(name: child)])
            #expect(bulkDetails.map(\.ref.name) == [parent, child])
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE IF EXISTS \(child)", "DROP TABLE IF EXISTS \(parent)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE IF EXISTS \(child)", "DROP TABLE IF EXISTS \(parent)"])
    }

    @Test func viewFingerprintUpdatesAndConcurrentExecution() async throws {
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let baseTable = "berry_vbase_\(suffix)"
        let viewName = "berry_vview_\(suffix)"
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }

        try await harness.exec(conn, [
            "CREATE TABLE \(baseTable) (id INTEGER PRIMARY KEY, a TEXT)",
            "CREATE VIEW \(viewName) AS SELECT * FROM \(baseTable)",
        ])
        do {
            let beforeSummaries = try await conn.introspector.objectSummaries(scope: .allUserSchemas)
            let beforeFP = beforeSummaries.first { $0.ref.name == viewName }?.fingerprint

            try await harness.exec(conn, ["ALTER TABLE \(baseTable) ADD COLUMN b INTEGER"])
            let afterSummaries = try await conn.introspector.objectSummaries(scope: .allUserSchemas)
            let afterFP = afterSummaries.first { $0.ref.name == viewName }?.fingerprint
            #expect(beforeFP != nil)
            #expect(afterFP != nil)
            #expect(beforeFP != afterFP)

            // Overlapping execute calls inside an open transaction must be serialized cleanly without baton reuse errors.
            try await harness.exec(conn, ["BEGIN"])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = try await self.harness.drain(conn.execute("INSERT INTO \(baseTable) VALUES (1, 'one', 10)")) }
                group.addTask { _ = try await self.harness.drain(conn.execute("INSERT INTO \(baseTable) VALUES (2, 'two', 20)")) }
                try await group.waitForAll()
            }
            try await harness.exec(conn, ["COMMIT"])

            let rows = try await harness.drain(conn.execute("SELECT COUNT(*) FROM \(baseTable)"))
            #expect(rows.rows == [[.int(2)]])
        } catch {
            _ = try? await harness.exec(conn, ["ROLLBACK"])
            _ = try? await harness.exec(conn, ["DROP VIEW IF EXISTS \(viewName)", "DROP TABLE IF EXISTS \(baseTable)"])
            throw error
        }
        try await harness.exec(conn, ["DROP VIEW IF EXISTS \(viewName)", "DROP TABLE IF EXISTS \(baseTable)"])
    }
}
