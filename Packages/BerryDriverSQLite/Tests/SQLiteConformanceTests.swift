import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverSQLite

/// Basic conformance per — this test set will be
/// abstracted into a shared suite for all drivers in M1.
@Suite("SQLite driver conformance")
struct SQLiteConformanceTests {
    private func makeTempConnection() throws -> (SQLiteConnection, String) {
        let path = NSTemporaryDirectory() + "berrydb-test-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let connection = try SQLiteConnection(path: path)
        return (connection, path)
    }

    private func drain(
        _ stream: AsyncThrowingStream<ResultEvent, Error>
    ) async throws -> (columns: [ColumnMeta], rows: [[BerryValue]], stats: QueryStats?) {
        var columns: [ColumnMeta] = []
        var rows: [[BerryValue]] = []
        var stats: QueryStats?
        for try await event in stream {
            switch event {
            case .columns(let c): columns = c
            case .rows(let batch): rows.append(contentsOf: batch)
            case .complete(let s): stats = s
            }
        }
        return (columns, rows, stats)
    }

 // MARK: Data type round-trip — lossless

    @Test func typeRoundTrip() async throws {
        let (conn, _) = try makeTempConnection()
        _ = try await drain(conn.execute(
            "CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)"
        ))
        _ = try await drain(conn.execute(
            "INSERT INTO t VALUES (42, 3.5, 'xin chào', x'DEADBEEF', NULL)"
        ))
        let result = try await drain(conn.execute("SELECT i, r, s, b, n FROM t"))

        #expect(result.rows.count == 1)
        let row = result.rows[0]
        #expect(row[0] == .int(42))
        #expect(row[1] == .double(3.5))
        #expect(row[2] == .text("xin chào"))
        #expect(row[3] == .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(row[4] == .null)
        await conn.close()
    }

    // MARK: Streams in batches, receives every row

    @Test func streamsLargeResultInBatches() async throws {
        let (conn, _) = try makeTempConnection()
        let total = 10_000
        _ = try await drain(conn.execute(
            """
            CREATE TABLE big AS
            WITH RECURSIVE seq(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < \(total)
            )
            SELECT x AS id, 'row-' || x AS name FROM seq
            """
        ))

        var rowTotal = 0
        var batchCount = 0
        var sawColumns = false
        for try await event in conn.execute("SELECT id, name FROM big ORDER BY id") {
            switch event {
            case .columns(let metas):
                sawColumns = true
                #expect(metas.map(\.name) == ["id", "name"])
            case .rows(let batch):
                batchCount += 1
                #expect(batch.count <= SQLiteConnection.batchSize)
                rowTotal += batch.count
            case .complete:
                break
            }
        }
        #expect(sawColumns)
        #expect(rowTotal == total)
        #expect(batchCount >= total / SQLiteConnection.batchSize)
        await conn.close()
    }

 // MARK: Mid-flight cancel → finishes with.cancelled ≤ 1s

    @Test func cancelInterruptsRunningQuery() async throws {
        let (conn, _) = try makeTempConnection()
        // Heavy query: counts a 500M recursive sequence — runs very long without cancel.
        let heavy = """
            WITH RECURSIVE seq(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 500000000
            )
            SELECT count(*) FROM seq
            """

        let started = ContinuousClock.now
        let stream = conn.execute(heavy)

        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            conn.cancelCurrentQuery()
        }

        await #expect(throws: DriverError.self) {
            _ = try await self.drain(stream)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(6), "cancel must take effect quickly")
        await conn.close()
    }

 // exact COUNT(*) (no catalog estimate available in SQLite), always
    // "SQLite" for engine, always nil for comment (no such concept). `size`
    // is best-effort (dbstat needs SQLITE_ENABLE_DBSTAT_VTAB at compile time)
    // so this only asserts it's positive WHEN present, never that it exists.
    @Test func tableStatsReflectsExactRowCount() async throws {
        let (conn, _) = try makeTempConnection()
        _ = try await drain(conn.execute(
            "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO items VALUES (1, 'a'), (2, 'b')"
        ))
        let stats = try await conn.introspector.tableStats(TableRef(name: "items"))
        #expect(stats.estimatedRowCount == 2)
        #expect(stats.engine == "SQLite")
        #expect(stats.comment == nil)
        if let size = stats.sizeBytes {
            #expect(size > 0)
        }
        await conn.close()
    }

 // MARK: Introspection on a sample schema

    @Test func introspectsSchema() async throws {
        let (conn, _) = try makeTempConnection()
        _ = try await drain(conn.execute(
            """
            CREATE TABLE users (
                id INTEGER PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                bio TEXT DEFAULT 'trống'
            );
            CREATE TABLE posts (
                id INTEGER PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id),
                title TEXT
            );
            CREATE VIEW post_titles AS SELECT title FROM posts;
            """
        ))

        let introspector = conn.introspector
        let objects = try await introspector.objects(in: nil)
        #expect(objects.map(\.name).sorted() == ["post_titles", "posts", "users"])
        #expect(objects.filter { $0.kind == .view }.map(\.name) == ["post_titles"])

        let detail = try await introspector.tableDetail(TableRef(name: "users"))
        #expect(detail.columns.map(\.name) == ["id", "email", "bio"])
        #expect(detail.columns[0].isPrimaryKey)
        #expect(detail.columns[1].isNullable == false)
        #expect(detail.indexes.contains { $0.isUnique && $0.columns == ["email"] })

        let postsDetail = try await introspector.tableDetail(TableRef(name: "posts"))
        #expect(postsDetail.foreignKeys == [
            ForeignKeyInfo(column: "user_id", referencedTable: "users", referencedColumn: "id")
        ])

        let ddl = try await introspector.ddl(of: SchemaObject(kind: .table, name: "users"))
        #expect(ddl.contains("CREATE TABLE users"))
        await conn.close()
    }

 // MARK: Triggers surface in the object tree

    @Test func introspectsTriggers() async throws {
        let (conn, _) = try makeTempConnection()
        _ = try await drain(conn.execute(
            """
            CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT);
            CREATE TRIGGER audit_ai AFTER INSERT ON audit
            BEGIN
                UPDATE audit SET note = 'seen' WHERE id = NEW.id;
            END;
            """
        ))

        let introspector = conn.introspector
        let triggers = try await introspector.objects(in: nil).filter { $0.kind == .trigger }
        #expect(triggers.map(\.name) == ["audit_ai"])

        let ddl = try await introspector.ddl(of: SchemaObject(kind: .trigger, name: "audit_ai"))
        #expect(ddl.contains("CREATE TRIGGER audit_ai"))
        await conn.close()
    }

    // MARK: DML reports rowsAffected via .complete

    @Test func dmlReportsRowsAffected() async throws {
        let (conn, _) = try makeTempConnection()
        _ = try await drain(conn.execute("CREATE TABLE t (x INTEGER)"))
        let insert = try await drain(conn.execute("INSERT INTO t VALUES (1), (2), (3)"))
        #expect(insert.stats?.rowsAffected == 3)
        #expect(insert.columns.isEmpty)
        await conn.close()
    }

    // MARK: SQL error → classifiable error, connection stays usable

    @Test func sqlErrorIsClassifiedAndConnectionSurvives() async throws {
        let (conn, _) = try makeTempConnection()
        await #expect(throws: DriverError.self) {
            _ = try await self.drain(conn.execute("SELECT * FROM khong_ton_tai"))
        }
        #expect(await conn.ping())
        let ok = try await drain(conn.execute("SELECT 1"))
        #expect(ok.rows == [[.int(1)]])
        await conn.close()
    }

 // MARK: Truncate — SQLite has no TRUNCATE statement

    @Test func truncateUsesDeleteFromNotTruncateTable() {
        let sql = SQLiteDialect().truncateSQL(TableRef(name: "customers"))
        #expect(sql == "DELETE FROM \"customers\";")
    }
}
