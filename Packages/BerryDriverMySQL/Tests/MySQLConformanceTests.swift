import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

/// Runs against a real MySQL 8.4 from `BERRYDB_TEST_MYSQL`
/// (see Tests/docker/compose.yml); skipped when the env var is unset.
/// MySQL 8.x defaults to caching_sha2_password, so a successful connect here
/// IS the M1 auth spike.
@Suite("MySQL driver conformance", .enabled(if: TestServer.mysql != nil))
struct MySQLConformanceTests {
    private var harness: DriverConformance {
        DriverConformance {
            let server = TestServer.mysql!
            return try await MySQLDriverConnection(config: ConnectionConfig(
                driver: .mysql,
                name: "test",
                host: server.host,
                port: server.port,
                username: server.username,
                password: server.password,
                database: server.database
            ))
        }
    }

    @Test func connectsWithCachingSHA2Password() async throws {
        // The spike itself: MySQL 8.4 + caching_sha2_password + TLS `prefer`.
        let conn = try await harness.makeConnection()
        let result = try await harness.drain(conn.execute("SELECT 1"))
        #expect(result.rows == [[.int(1)]])
        await conn.close()
    }

    @Test func typeRoundTrip() async throws {
        try await harness.checkRoundTrip(
            setup: [
                """
                CREATE TEMPORARY TABLE berry_types (
                    i int, i8 bigint, d double, num decimal(12,4),
                    t varchar(100), bin blob, dt datetime, j json, n varchar(10)
                )
                """,
                """
                INSERT INTO berry_types VALUES (
                    7, 9007199254740993, 2.5, '12345.6789',
                    'xin chào', X'DEADBEEF', '2026-01-02 03:04:05',
                    '{"k": 1}', NULL
                )
                """,
            ],
            select: "SELECT * FROM berry_types",
            expectedColumnCount: 9
        ) { row in
            guard case .int(7) = row[0] else { throw ConformanceFailure("int: \(row[0])") }
            guard case .int(9_007_199_254_740_993) = row[1] else {
                throw ConformanceFailure("bigint: \(row[1])")
            }
            guard case .double(2.5) = row[2] else { throw ConformanceFailure("double: \(row[2])") }
            guard case .decimal(let dec) = row[3], dec.contains("12345.6789") else {
                throw ConformanceFailure("decimal must stay verbatim: \(row[3])")
            }
            guard case .text("xin chào") = row[4] else { throw ConformanceFailure("varchar: \(row[4])") }
            guard case .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])) = row[5] else {
                throw ConformanceFailure("blob: \(row[5])")
            }
            guard case .timestamp = row[6] else { throw ConformanceFailure("datetime: \(row[6])") }
            guard case .json = row[7] else { throw ConformanceFailure("json: \(row[7])") }
            guard case .null = row[8] else { throw ConformanceFailure("null: \(row[8])") }
        }
    }

    @Test func streamsInBatches() async throws {
        try await harness.checkStreaming(
            setup: ["SET SESSION cte_max_recursion_depth = 20000"],
            select: """
                WITH RECURSIVE seq(x) AS (
                    SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 10000
                )
                SELECT x AS id, CONCAT('row-', x) AS name FROM seq
                """,
            expectedRows: 10_000
        )
    }

    @Test func cancelViaKillQuery() async throws {
        try await harness.checkCancel(
            // Cross join over information_schema is expensive enough to outlive
            // the cancel window; KILL QUERY raises ER_QUERY_INTERRUPTED (1317).
            heavyQuery: """
                SELECT count(*)
                FROM information_schema.columns a,
                     information_schema.columns b,
                     information_schema.columns c
                """,
            probeQuery: "SELECT 1"
        )
    }

    @Test func classifiesSQLErrors() async throws {
        try await harness.checkErrorClassification(
            badQuery: "SELECT * FROM berry_khong_ton_tai",
            probeQuery: "SELECT 1"
        )
    }

    // InnoDB's TABLE_ROWS is a persistent-statistics estimate — ANALYZE TABLE
    // refreshes it deterministically instead of racing InnoDB's background
 // stats updater (same reasoning as Postgres's ANALYZE/n_live_tup).
    @Test func tableStatsReflectsRowsEngineAndComment() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let name = "berry_conf_stats_\(String(UUID().uuidString.prefix(8)).lowercased())"

        try await harness.exec(conn, [
            "CREATE TABLE \(name) (id BIGINT PRIMARY KEY, name TEXT) COMMENT = 'quick-info test table'",
            "INSERT INTO \(name) VALUES (1, 'a'), (2, 'b'), (3, 'c')",
            "ANALYZE TABLE \(name)",
        ])
        do {
            let stats = try await conn.introspector.tableStats(TableRef(name: name))
            #expect(stats.estimatedRowCount == 3)
            let size = try #require(stats.sizeBytes)
            #expect(size > 0)
            #expect(stats.engine == "InnoDB")
            #expect(stats.comment == "quick-info test table")
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE \(name)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE \(name)"])
    }

    @Test func introspectsSchema() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let parent = "berry_conf_parent_\(suffix)"
        let child = "berry_conf_child_\(suffix)"

        try await harness.exec(conn, [
            """
            CREATE TABLE \(parent) (
                id bigint PRIMARY KEY,
                email varchar(190) NOT NULL UNIQUE
            )
            """,
            """
            CREATE TABLE \(child) (
                id bigint PRIMARY KEY,
                parent_id bigint,
                FOREIGN KEY (parent_id) REFERENCES \(parent)(id)
            )
            """,
        ])
        do {
            let introspector = conn.introspector
            let objects = try await introspector.objects(in: nil)
            #expect(objects.contains { $0.name == parent && $0.kind == .table })

            let detail = try await introspector.tableDetail(TableRef(name: parent))
            #expect(detail.columns.map(\.name) == ["id", "email"])
            #expect(detail.columns[0].isPrimaryKey)
            #expect(!detail.columns[1].isNullable)
            #expect(detail.indexes.contains { $0.isUnique && $0.columns == ["email"] })

            let childDetail = try await introspector.tableDetail(TableRef(name: child))
            #expect(childDetail.foreignKeys == [
                ForeignKeyInfo(column: "parent_id", referencedTable: parent, referencedColumn: "id")
            ])

            let ddl = try await introspector.ddl(of: SchemaObject(kind: .table, name: parent))
            #expect(ddl.contains("CREATE TABLE"))
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE \(child)", "DROP TABLE \(parent)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE \(child)", "DROP TABLE \(parent)"])
    }

    // MySQL forbids CREATE FUNCTION over the prepared-statement protocol that
    // execute() uses; the driver must transparently retry via text protocol.
    @Test func executesRoutineDDLViaTextProtocolFallback() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let mysql = try #require(conn as? MySQLDriverConnection)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let fn = "berry_fnx_\(suffix)"

        try await harness.exec(conn, [
            "CREATE FUNCTION \(fn)(a INT) RETURNS INT DETERMINISTIC RETURN a + 1",
        ])
        func cleanup() async { _ = try? await mysql.queryAll("DROP FUNCTION \(fn)") }
        do {
            let objects = try await conn.introspector.objects(in: nil)
            #expect(objects.contains { $0.kind == .function && $0.name == fn })
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

 // functions and triggers surface in the object tree.
    @Test func introspectsRoutinesAndTriggers() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let mysql = try #require(conn as? MySQLDriverConnection)
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let fn = "berry_fn_\(suffix)"
        let tab = "berry_ttab_\(suffix)"
        let trg = "berry_trg_\(suffix)"

        // CREATE FUNCTION/TRIGGER can't run over the prepared-statement protocol
        // that execute() uses, so create them via the text protocol.
        _ = try await mysql.queryAll("CREATE FUNCTION \(fn)(a INT) RETURNS INT DETERMINISTIC RETURN a + 1")
        _ = try await mysql.queryAll("CREATE TABLE \(tab) (id INT)")
        _ = try await mysql.queryAll("CREATE TRIGGER \(trg) BEFORE INSERT ON \(tab) FOR EACH ROW SET NEW.id = NEW.id + 1")
        func cleanup() async {
            _ = try? await mysql.queryAll("DROP TRIGGER \(trg)")
            _ = try? await mysql.queryAll("DROP TABLE \(tab)")
            _ = try? await mysql.queryAll("DROP FUNCTION \(fn)")
        }
        do {
            let introspector = conn.introspector
            let objects = try await introspector.objects(in: nil)

            let function = try #require(objects.first {
                $0.kind == .function && $0.name == fn
            })
            let functionDDL = try await introspector.ddl(of: function)
            #expect(functionDDL.contains("FUNCTION"))

            let trigger = try #require(objects.first {
                $0.kind == .trigger && $0.name == trg
            })
            let triggerDDL = try await introspector.ddl(of: trigger)
            #expect(triggerDDL.contains("TRIGGER"))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func processListRunsAndKillGuardsID() async throws {
        let dialect = MySQLDialect()
 // The kill statement only accepts a numeric connection id.
        #expect(dialect.killSessionSQL(id: "42") == "KILL 42")
        #expect(dialect.killSessionSQL(id: "42; DROP TABLE x") == nil)
        #expect(dialect.killSessionSQL(id: "") == nil)

        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let sql = try #require(dialect.processListSQL())
        let result = try await harness.drain(conn.execute(sql))
        #expect(result.columns.map(\.name).contains("pid"))
    }

    @Test func userManagementCreatesListsGrantsAndDropsARealUser() async throws {
        let dialect = MySQLDialect()
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let username = "berry_ti03_test_user"
        let host = "%"

        // Defensive cleanup first — a prior failed run may have left the user behind.
        try? await harness.exec(conn, [dialect.dropUserSQL(username: username, host: host)!])

        func cleanup() async {
            try? await harness.exec(conn, [dialect.dropUserSQL(username: username, host: host)!])
        }

        do {
            let create = try #require(
                dialect.createUserSQL(username: username, password: "s3cret!", host: host)
            )
            try await harness.exec(conn, [create])

            let listSQL = try #require(dialect.listUsersSQL())
            let listed = try await harness.drain(conn.execute(listSQL))
            #expect(listed.rows.contains { row in
                if case .text(username) = row[0] { return true }
                return false
            }, "newly created user must appear in listUsersSQL")

            let grant = try #require(dialect.grantSQL(
                privilege: "SELECT", on: "berrydb_test", to: username, host: host
            ))
            try await harness.exec(conn, [grant])

            let grantsSQL = try #require(dialect.listGrantsSQL(for: username, host: host))
            let grants = try await harness.drain(conn.execute(grantsSQL))
            #expect(grants.rows.contains { row in
                guard case .text("berrydb_test") = row[0], case .text("SELECT") = row[1] else { return false }
                return true
            }, "granted SELECT privilege must show up in listGrantsSQL")

            let revoke = try #require(dialect.revokeSQL(
                privilege: "SELECT", on: "berrydb_test", from: username, host: host
            ))
            try await harness.exec(conn, [revoke])
            let afterRevoke = try await harness.drain(conn.execute(grantsSQL))
            #expect(!afterRevoke.rows.contains { row in
                guard case .text("berrydb_test") = row[0], case .text("SELECT") = row[1] else { return false }
                return true
            }, "revoked privilege must no longer show up in listGrantsSQL")

            let alterPassword = try #require(
                dialect.alterUserPasswordSQL(username: username, password: "new-s3cret!", host: host)
            )
            try await harness.exec(conn, [alterPassword])

            let drop = try #require(dialect.dropUserSQL(username: username, host: host))
            try await harness.exec(conn, [drop])
            let afterDrop = try await harness.drain(conn.execute(listSQL))
            #expect(!afterDrop.rows.contains { row in
                if case .text(username) = row[0] { return true }
                return false
            }, "dropped user must no longer appear in listUsersSQL")
        } catch {
            await cleanup()
            throw error
        }
    }
}
