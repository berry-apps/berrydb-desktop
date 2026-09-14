import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`
/// (see Tests/docker/compose.yml); skipped when the env var is unset.
@Suite("Postgres driver conformance", .enabled(if: TestServer.postgres != nil))
struct PostgresConformanceTests {
    private var harness: DriverConformance {
        DriverConformance {
            let server = TestServer.postgres!
            return try await PostgresDriverConnection(config: ConnectionConfig(
                driver: .postgres,
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
                CREATE TEMP TABLE berry_types (
                    b bool, i2 smallint, i8 bigint, f8 float8,
                    num numeric(12,4), t text, bin bytea, u uuid,
                    ts timestamptz, j jsonb, n text
                )
                """,
                """
                INSERT INTO berry_types VALUES (
                    true, 7, 9007199254740993, 2.5,
                    '12345.6789', 'xin chào', '\\xdeadbeef',
                    'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                    '2026-01-02T03:04:05Z', '{"k": 1}', NULL
                )
                """,
            ],
            select: "SELECT * FROM berry_types",
            expectedColumnCount: 11
        ) { row in
            guard case .bool(true) = row[0] else { throw ConformanceFailure("bool: \(row[0])") }
            guard case .int(7) = row[1] else { throw ConformanceFailure("smallint: \(row[1])") }
            // Value above 2^53 — must survive without Double round-trip loss.
            guard case .int(9_007_199_254_740_993) = row[2] else {
                throw ConformanceFailure("bigint: \(row[2])")
            }
            guard case .double(2.5) = row[3] else { throw ConformanceFailure("float8: \(row[3])") }
            guard case .decimal(let dec) = row[4], dec.contains("12345.6789") else {
                throw ConformanceFailure("numeric must stay verbatim: \(row[4])")
            }
            guard case .text("xin chào") = row[5] else { throw ConformanceFailure("text: \(row[5])") }
            guard case .bytes(Data([0xDE, 0xAD, 0xBE, 0xEF])) = row[6] else {
                throw ConformanceFailure("bytea: \(row[6])")
            }
            guard case .uuid = row[7] else { throw ConformanceFailure("uuid: \(row[7])") }
            guard case .timestamp(_, hasTimezone: true) = row[8] else {
                throw ConformanceFailure("timestamptz: \(row[8])")
            }
            guard case .json = row[9] else { throw ConformanceFailure("jsonb: \(row[9])") }
            guard case .null = row[10] else { throw ConformanceFailure("null: \(row[10])") }
        }
    }

    @Test func streamsInBatches() async throws {
        try await harness.checkStreaming(
            setup: [],
            select: "SELECT g AS id, 'row-' || g AS name FROM generate_series(1, 10000) g",
            expectedRows: 10_000
        )
    }

    @Test func backendPIDIsAvailableForCancel() async throws {
 // Precondition of the cancel path: the pid must be captured
        // right after connect, otherwise cancelCurrentQuery is a silent no-op.
        let conn = try await harness.makeConnection() as! PostgresDriverConnection
        #expect(conn.debugBackendPID != nil)
        await conn.close()
    }

    @Test func cancelViaBackendCancel() async throws {
        try await harness.checkCancel(
            // pg_sleep is cheap on the server and returns error 57014 when
            // cancelled — deterministic and fast for the suite.
            heavyQuery: "SELECT pg_sleep(60)",
            probeQuery: "SELECT 1"
        )
    }

    @Test func classifiesSQLErrors() async throws {
        try await harness.checkErrorClassification(
            badQuery: "SELECT * FROM berry_khong_ton_tai",
            probeQuery: "SELECT 1"
        )
    }

    // n_live_tup only updates after ANALYZE (autovacuum hasn't run yet on a
    // freshly-inserted table) — ANALYZE explicitly so the estimate is
 // deterministic instead of racing autovacuum.
    @Test func tableStatsReflectsRowsSizeAndComment() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let name = "berry_conf_stats_\(String(UUID().uuidString.prefix(8)).lowercased())"

        try await harness.exec(conn, [
            "CREATE TABLE \(name) (id bigint PRIMARY KEY, name text)",
            "INSERT INTO \(name) VALUES (1, 'a'), (2, 'b'), (3, 'c')",
            "ANALYZE \(name)",
            "COMMENT ON TABLE \(name) IS 'quick-info test table'",
        ])
        do {
            let stats = try await conn.introspector.tableStats(TableRef(database: "public", name: name))
            #expect(stats.estimatedRowCount == 3)
            let size = try #require(stats.sizeBytes)
            #expect(size > 0)
            #expect(stats.engine == nil) // Postgres has no storage-engine concept
            #expect(stats.comment == "quick-info test table")
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE \(name)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE \(name)"])
    }

    // A PascalCase / reserved-word table (quoted) must introspect too — regclass
    // downcases unquoted identifiers, so this used to fail with "relation does
    // not exist", leaving editing disabled (no PK detected).
    @Test func introspectsPascalCaseTable() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let name = "Berry_Conf_User_\(String(UUID().uuidString.prefix(6)))"

        try await harness.exec(conn, [
            #"CREATE TABLE "\#(name)" (id bigint PRIMARY KEY, "fullName" text)"#,
        ])
        do {
            let detail = try await conn.introspector.tableDetail(
                TableRef(database: "public", name: name)
            )
            #expect(detail.columns.map(\.name) == ["id", "fullName"])
            #expect(detail.columns[0].isPrimaryKey)
        } catch {
            _ = try? await harness.exec(conn, [#"DROP TABLE "\#(name)""#])
            throw error
        }
        try await harness.exec(conn, [#"DROP TABLE "\#(name)""#])
    }

    @Test func introspectsSchema() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let parent = "berry_conf_parent_\(suffix)"
        let child = "berry_conf_child_\(suffix)"

        try await harness.exec(conn, [
            "CREATE TABLE \(parent) (id bigint PRIMARY KEY, email text NOT NULL UNIQUE)",
            "CREATE TABLE \(child) (id bigint PRIMARY KEY, parent_id bigint REFERENCES \(parent)(id))",
        ])
        do {
            let introspector = conn.introspector
            let objects = try await introspector.objects(in: "public")
            #expect(objects.contains { $0.name == parent && $0.kind == .table })

            let detail = try await introspector.tableDetail(TableRef(database: "public", name: parent))
            #expect(detail.columns.map(\.name) == ["id", "email"])
            #expect(detail.columns[0].isPrimaryKey)
            #expect(!detail.columns[1].isNullable)
            #expect(detail.indexes.contains { $0.isUnique && $0.columns == ["email"] })

            let childDetail = try await introspector.tableDetail(TableRef(database: "public", name: child))
            #expect(childDetail.foreignKeys == [
                ForeignKeyInfo(column: "parent_id", referencedTable: parent, referencedColumn: "id")
            ])

            let ddl = try await introspector.ddl(of: SchemaObject(kind: .table, name: parent, database: "public"))
            #expect(ddl.contains("CREATE TABLE"))
            #expect(ddl.contains("PRIMARY KEY"))
        } catch {
            _ = try? await harness.exec(conn, ["DROP TABLE \(child)", "DROP TABLE \(parent)"])
            throw error
        }
        try await harness.exec(conn, ["DROP TABLE \(child)", "DROP TABLE \(parent)"])
    }

 // functions, procedures and triggers surface in the object tree.
    @Test func introspectsRoutinesAndTriggers() async throws {
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let fn = "berry_fn_\(suffix)"
        let tfn = "berry_tfn_\(suffix)"
        let tab = "berry_ttab_\(suffix)"
        let trg = "berry_trg_\(suffix)"

        try await harness.exec(conn, [
            "CREATE FUNCTION \(fn)(a integer) RETURNS integer LANGUAGE sql AS 'SELECT a + 1'",
            "CREATE FUNCTION \(tfn)() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$",
            "CREATE TABLE \(tab) (id integer)",
            "CREATE TRIGGER \(trg) BEFORE INSERT ON \(tab) FOR EACH ROW EXECUTE FUNCTION \(tfn)()",
        ])
        func cleanup() async {
            _ = try? await harness.exec(conn, [
                "DROP TABLE \(tab)", "DROP FUNCTION \(tfn)()",
                "DROP FUNCTION \(fn)(integer)",
            ])
        }
        do {
            let introspector = conn.introspector
            let objects = try await introspector.objects(in: "public")

            let function = try #require(objects.first {
                $0.kind == .function && $0.name.hasPrefix(fn)
            })
            let functionDDL = try await introspector.ddl(of: function)
            #expect(functionDDL.contains("FUNCTION"))

            let trigger = try #require(objects.first {
                $0.kind == .trigger && $0.name == trg
            })
            let triggerDDL = try await introspector.ddl(of: trigger)
            #expect(triggerDDL.contains("CREATE TRIGGER \(trg)"))
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @Test func processListRunsAndKillGuardsID() async throws {
        let dialect = PostgresDialect()
 // The kill statement only accepts a numeric pid.
        #expect(dialect.killSessionSQL(id: "123") == "SELECT pg_terminate_backend(123)")
        #expect(dialect.killSessionSQL(id: "1; DROP TABLE x") == nil)
        #expect(dialect.killSessionSQL(id: "") == nil)

        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let sql = try #require(dialect.processListSQL())
        let result = try await harness.drain(conn.execute(sql))
        // Normalized columns include pid (the kill target).
        #expect(result.columns.map(\.name).contains("pid"))
    }

    @Test func userManagementCreatesListsGrantsAndDropsARealRole() async throws {
        let dialect = PostgresDialect()
        let conn = try await harness.makeConnection()
        defer { Task { await conn.close() } }
        let username = "berry_ti03_test_user"

        // Defensive cleanup first — a prior failed run may have left the role behind.
        try? await harness.exec(conn, [try #require(dialect.dropUserSQL(username: username, host: nil))])

        func cleanup() async {
            try? await harness.exec(conn, [dialect.dropUserSQL(username: username, host: nil)!])
        }

        do {
            let create = try #require(dialect.createUserSQL(username: username, password: "s3cret!", host: nil))
            try await harness.exec(conn, [create])

            let listSQL = try #require(dialect.listUsersSQL())
            let listed = try await harness.drain(conn.execute(listSQL))
            #expect(listed.rows.contains { row in
                if case .text(username) = row[0] { return true }
                return false
            }, "newly created role must appear in listUsersSQL")

            let grant = try #require(dialect.grantSQL(
                privilege: "CONNECT", on: "berrydb_test", to: username, host: nil
            ))
            try await harness.exec(conn, [grant])

            let grantsSQL = try #require(dialect.listGrantsSQL(for: username, host: nil))
            let grants = try await harness.drain(conn.execute(grantsSQL))
            #expect(grants.rows.contains { row in
                guard case .text("berrydb_test") = row[0], case .text("CONNECT") = row[1] else { return false }
                return true
            }, "granted CONNECT privilege must show up in listGrantsSQL")

            let revoke = try #require(dialect.revokeSQL(
                privilege: "CONNECT", on: "berrydb_test", from: username, host: nil
            ))
            try await harness.exec(conn, [revoke])
            let afterRevoke = try await harness.drain(conn.execute(grantsSQL))
            #expect(!afterRevoke.rows.contains { row in
                guard case .text("berrydb_test") = row[0], case .text("CONNECT") = row[1] else { return false }
                return true
            }, "revoked privilege must no longer show up in listGrantsSQL")

            let alterPassword = try #require(
                dialect.alterUserPasswordSQL(username: username, password: "new-s3cret!", host: nil)
            )
            try await harness.exec(conn, [alterPassword])

            let drop = try #require(dialect.dropUserSQL(username: username, host: nil))
            try await harness.exec(conn, [drop])
            let afterDrop = try await harness.drain(conn.execute(listSQL))
            #expect(!afterDrop.rows.contains { row in
                if case .text(username) = row[0] { return true }
                return false
            }, "dropped role must no longer appear in listUsersSQL")
        } catch {
            await cleanup()
            throw error
        }
    }
}
