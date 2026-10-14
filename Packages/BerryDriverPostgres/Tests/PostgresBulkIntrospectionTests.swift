import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`; skipped when
/// the variable is unset. Serialized because the tests create and drop
/// tables of the same names in the public schema.
@Suite("Postgres bulk introspection", .serialized, .enabled(if: TestServer.postgres != nil))
struct PostgresBulkIntrospectionTests {
    private func openConnection() async throws -> PostgresDriverConnection {
        let server = TestServer.postgres!
        return try await PostgresDriverConnection(config: ConnectionConfig(
            driver: .postgres,
            name: "bulk",
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            database: server.database
        ))
    }

    private func exec(_ sql: String, on connection: PostgresDriverConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }

    /// Opens a connection and drops what an earlier, interrupted run may have
    /// left behind, so every test starts from the same catalog.
    private func openConnection(dropping statements: [String]) async throws -> PostgresDriverConnection {
        let connection = try await openConnection()
        do {
            for sql in statements { try await exec(sql, on: connection) }
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    /// Drops the test objects and closes the connection from a task, as the
    /// harvester suite does. The statements are `IF EXISTS` and run again at
    /// the start of the next test, so a task still pending when the process
    /// exits only leaves objects the next run removes first.
    private func closeAfterDropping(_ statements: [String], on connection: PostgresDriverConnection) {
        Task {
            for sql in statements { try? await exec(sql, on: connection) }
            await connection.close()
        }
    }

    private func ref(_ name: String, in schema: String = "public") -> TableRef {
        TableRef(database: schema, name: name)
    }

    private func fingerprints(
        _ connection: PostgresDriverConnection, scope: SchemaScope = .schemas(["public"])
    ) async throws -> [TableRef: String?] {
        let summaries = try await connection.introspector.objectSummaries(scope: scope)
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.ref, $0.fingerprint) })
    }

    // MARK: - Tier 2 listing

    /// Renaming a user-defined type keeps its oid, so a fingerprint over the
    /// raw type oid did not move, while every column of that type now reads
    /// as the new name. The fingerprint hashes the formatted type.
    @Test func renamingAColumnsTypeMovesTheFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_typed", "DROP TYPE IF EXISTS bd_mood", "DROP TYPE IF EXISTS bd_feeling"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TYPE bd_mood AS ENUM ('calm', 'cross')", on: connection)
        try await exec("CREATE TABLE bd_bulk_typed (id int, mood bd_mood)", on: connection)
        let before = try await fingerprints(connection)[ref("bd_bulk_typed")] ?? nil

        try await exec("ALTER TYPE bd_mood RENAME TO bd_feeling", on: connection)
        let after = try await fingerprints(connection)[ref("bd_bulk_typed")] ?? nil

        #expect(before != nil && after != before)
    }

    /// `ADD PRIMARY KEY USING INDEX` on columns already `NOT NULL` changes
    /// only the index's `indisprimary`: it keeps its name, its uniqueness and
    /// its key (https://www.postgresql.org/docs/16/sql-altertable.html). The
    /// fingerprint hashes the flag.
    @Test func promotingAUniqueIndexToThePrimaryKeyMovesTheFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_promoted"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_promoted (id int NOT NULL)", on: connection)
        try await exec("CREATE UNIQUE INDEX bd_bulk_promoted_id ON bd_bulk_promoted (id)", on: connection)
        let before = try await fingerprints(connection)[ref("bd_bulk_promoted")] ?? nil

        try await exec("ALTER TABLE bd_bulk_promoted ADD PRIMARY KEY USING INDEX bd_bulk_promoted_id", on: connection)
        let after = try await fingerprints(connection)[ref("bd_bulk_promoted")] ?? nil

        #expect(before != nil && after != before)
    }

    @Test func listsTablesViewsAndPartitionParentsWithFingerprints() async throws {
        let drops = [
            "DROP VIEW IF EXISTS bd_bulk_v",
            "DROP TABLE IF EXISTS bd_bulk_p CASCADE",
            "DROP TABLE IF EXISTS bd_bulk_a CASCADE",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec(#"CREATE TABLE bd_bulk_a (id int PRIMARY KEY, "quoted""col" text)"#, on: connection)
        try await exec("CREATE VIEW bd_bulk_v AS SELECT id FROM bd_bulk_a", on: connection)
        try await exec("CREATE TABLE bd_bulk_p (id int) PARTITION BY RANGE (id)", on: connection)
        try await exec("CREATE TABLE bd_bulk_p1 PARTITION OF bd_bulk_p FOR VALUES FROM (0) TO (10)", on: connection)

        let summaries = try await connection.introspector.objectSummaries(scope: .schemas(["public"]))

        let table = try #require(summaries.first { $0.ref == ref("bd_bulk_a") })
        #expect(table.kind == .table)
        let view = try #require(summaries.first { $0.ref == ref("bd_bulk_v") })
        #expect(view.kind == .view)
        let parent = try #require(summaries.first { $0.ref == ref("bd_bulk_p") })
        #expect(parent.kind == .table)
        #expect(!summaries.contains { $0.ref.name == "bd_bulk_p1" })

        for summary in summaries {
            let fingerprint = try #require(summary.fingerprint, "no fingerprint for \(summary.ref)")
            #expect(fingerprint.count == 32 && fingerprint.allSatisfy(\.isHexDigit), "\(summary.ref): \(fingerprint)")
        }
    }

    @Test func alterChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a CASCADE", "DROP TABLE IF EXISTS bd_bulk_b CASCADE"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, name text)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, name text)", on: connection)

        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try #require(before[a] ?? nil)
        let fingerprintB = try #require(before[b] ?? nil)

        // Nothing changed, so nothing may move: a fingerprint that depended on
        // anything volatile would send every table to a full re-read.
        let unchanged = try await fingerprints(connection)
        #expect(unchanged[a] == before[a] && unchanged[b] == before[b])

        try await exec("ALTER TABLE bd_bulk_a ADD COLUMN extra int", on: connection)
        let afterAlter = try await fingerprints(connection)
        #expect(try #require(afterAlter[a] ?? nil) != fingerprintA)
        #expect(afterAlter[b] == before[b])

        try await exec("CREATE INDEX bd_bulk_b_name ON bd_bulk_b (name)", on: connection)
        let afterIndex = try await fingerprints(connection)
        #expect(try #require(afterIndex[b] ?? nil) != fingerprintB)
        #expect(afterIndex[a] == afterAlter[a])
    }

    // The column and index details served to callers carry the default
    // expression and the index name, so a change of either must reach them.
    @Test func changedDefaultChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a CASCADE", "DROP TABLE IF EXISTS bd_bulk_b CASCADE"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, x int DEFAULT 0)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, x int DEFAULT 0)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let defaultBefore = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue

        try await exec("ALTER TABLE bd_bulk_a ALTER COLUMN x SET DEFAULT 1", on: connection)

        let after = try await fingerprints(connection)
        let defaultAfter = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue
        #expect(defaultBefore != defaultAfter, "the default is what the fingerprint has to follow")
        #expect(try #require(after[a] ?? nil) != (try #require(before[a] ?? nil)))
        #expect(after[b] == before[b])
    }

    @Test func renamedIndexChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a CASCADE", "DROP TABLE IF EXISTS bd_bulk_b CASCADE"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, x int)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, x int)", on: connection)
        try await exec("CREATE INDEX bd_bulk_idx ON bd_bulk_a (x)", on: connection)
        try await exec("CREATE INDEX bd_bulk_idx_b ON bd_bulk_b (x)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")

        try await exec("ALTER INDEX bd_bulk_idx RENAME TO bd_bulk_idx2", on: connection)

        let after = try await fingerprints(connection)
        let names = try await connection.introspector.tableDetail(a).indexes.map(\.name)
        #expect(names.contains("bd_bulk_idx2") && !names.contains("bd_bulk_idx"))
        #expect(try #require(after[a] ?? nil) != (try #require(before[a] ?? nil)))
        #expect(after[b] == before[b])
    }

    @Test func scopeFilterKeepsOtherSchemasOut() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_s CASCADE",
            "DROP SCHEMA IF EXISTS bd_other CASCADE",
            "DROP SCHEMA IF EXISTS pgxtemp_bd_bulk CASCADE",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE SCHEMA bd_other", on: connection)
        try await exec("CREATE TABLE bd_other.t (id int PRIMARY KEY)", on: connection)
        // Only the prefix `pg_temp_` marks a session's temporary schema; this name
        // matches it when the underscores are read as wildcards.
        try await exec("CREATE SCHEMA pgxtemp_bd_bulk", on: connection)
        try await exec("CREATE TABLE pgxtemp_bd_bulk.t (id int)", on: connection)
        try await exec("CREATE TABLE bd_bulk_s (id int PRIMARY KEY, o int REFERENCES bd_other.t (id))", on: connection)
        let introspector = connection.introspector
        let other = ref("t", in: "bd_other"), mine = ref("bd_bulk_s")

        let publicOnly = try await introspector.objectSummaries(scope: .schemas(["public"]))
        #expect(publicOnly.contains { $0.ref == mine })
        #expect(!publicOnly.contains { $0.ref.database == "bd_other" })

        let everything = try await introspector.objectSummaries(scope: .allUserSchemas)
        #expect(everything.contains { $0.ref == mine })
        #expect(everything.contains { $0.ref == other })
        #expect(everything.contains { $0.ref == ref("t", in: "pgxtemp_bd_bulk") })
        // System schemas stay out of "every user schema".
        #expect(!everything.contains {
            let schema = $0.ref.database ?? ""
            return schema == "information_schema" || schema.hasPrefix("pg_")
        })

        let otherOnly = try await introspector.objectSummaries(scope: .schemas(["bd_other"]))
        #expect(otherOnly.map(\.ref) == [other])

        #expect(try await introspector.objectSummaries(scope: .schemas([])).isEmpty)
        // A quote in a schema name must stay inside its literal.
        #expect(try await introspector.objectSummaries(scope: .schemas([#"it's "odd""#])).isEmpty)

        // The scope of a foreign key is its source table; the target may lie outside.
        let fromPublic = try await introspector.foreignKeys(scope: .schemas(["public"]))
        #expect(fromPublic.contains { $0.source == mine && $0.target == other })
        #expect(try await introspector.foreignKeys(scope: .schemas(["bd_other"])).isEmpty)
    }

    // MARK: - Tier 2 foreign keys and tier 3 details

    @Test func detailsForAChunkMatchPerTableDetail() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_child CASCADE",
            #"DROP TABLE IF EXISTS "bd_bulk_it's" CASCADE"#,
            #"DROP TABLE IF EXISTS "bd_bulk_User" CASCADE"#,
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec(
            #"CREATE TABLE "bd_bulk_it's" (a int, b int, note text DEFAULT 'it''s', PRIMARY KEY (a, b))"#,
            on: connection
        )
        try await exec(
            """
            CREATE TABLE "bd_bulk_User" (id int PRIMARY KEY, "Mixed Col" text NOT NULL DEFAULT 'n', score numeric(10,2))
            """,
            on: connection
        )
        try await exec(
            #"CREATE UNIQUE INDEX "bd_bulk_User_score" ON "bd_bulk_User" (score, "Mixed Col")"#,
            on: connection
        )
        // The foreign key lists its columns in a different order than the table
        // declares them, so a pair is only right when it follows the key.
        try await exec(
            """
            CREATE TABLE bd_bulk_child (
                x int, y int, uid int,
                CONSTRAINT bd_bulk_fk_pair FOREIGN KEY (y, x) REFERENCES "bd_bulk_it's" (b, a),
                CONSTRAINT bd_bulk_fk_user FOREIGN KEY (uid) REFERENCES "bd_bulk_User" (id)
            )
            """,
            on: connection
        )
        try await exec("CREATE INDEX bd_bulk_child_yx ON bd_bulk_child (y, x)", on: connection)

        let introspector = connection.introspector
        let quoted = ref("bd_bulk_it's"), mixed = ref("bd_bulk_User"), child = ref("bd_bulk_child")
        // A nil schema means public here, and the result keeps the ref it was asked for.
        let childAsAsked = TableRef(database: nil, name: "bd_bulk_child")
        let gone = ref("bd_bulk_gone")
        let asked = [quoted, mixed, childAsAsked, gone]

        let details = try await introspector.tableDetails(asked)

        #expect(details.count == 3, "a table that does not exist is left out")
        for ref in [quoted, mixed, childAsAsked] {
            let bulk = try #require(details.first { $0.ref == ref }, "no detail for \(ref)")
            let single = try await introspector.tableDetail(ref)
            #expect(!single.columns.isEmpty)
            #expect(bulk.columns == single.columns, "columns of \(ref)")
            #expect(bulk.indexes == single.indexes, "indexes of \(ref)")
            #expect(bulk.foreignKeys.isEmpty)
        }
        let mixedDetail = try #require(details.first { $0.ref == mixed })
        #expect(mixedDetail.columns.map(\.name) == ["id", "Mixed Col", "score"])
        #expect(mixedDetail.indexes.contains { $0.name == "bd_bulk_User_score" && $0.columns == ["score", "Mixed Col"] })
        #expect(try await introspector.tableDetails([]).isEmpty)

        let relations = try await introspector.foreignKeys(scope: .schemas(["public"])).filter { $0.source == child }
        #expect(relations == [
            ForeignKeyRelation(source: child, column: "y", target: quoted, referencedColumn: "b", constraintName: "bd_bulk_fk_pair"),
            ForeignKeyRelation(source: child, column: "x", target: quoted, referencedColumn: "a", constraintName: "bd_bulk_fk_pair"),
            ForeignKeyRelation(source: child, column: "uid", target: mixed, referencedColumn: "id", constraintName: "bd_bulk_fk_user"),
        ])
        // The per-table path reports the same pairs, which is what the bulk one replaces.
        let single = try await introspector.tableDetail(child)
        #expect(Set(relations.map {
            ForeignKeyInfo(
                column: $0.column, referencedSchema: $0.target.database,
                referencedTable: $0.target.name, referencedColumn: $0.referencedColumn
            )
        }) == Set(single.foreignKeys))
    }

    @Test func foreignKeysSkipTheCopiesPostgresKeepsOnPartitions() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_ref CASCADE",
            "DROP TABLE IF EXISTS bd_bulk_pf CASCADE",
            "DROP TABLE IF EXISTS bd_bulk_p CASCADE",
            "DROP TABLE IF EXISTS bd_bulk_target CASCADE",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_target (id int PRIMARY KEY)", on: connection)
        // A key on a partitioned table, and a key that points at one, are each
        // copied onto every partition by PostgreSQL.
        try await exec(
            "CREATE TABLE bd_bulk_pf (id int PRIMARY KEY, t int REFERENCES bd_bulk_target (id)) PARTITION BY RANGE (id)",
            on: connection
        )
        try await exec("CREATE TABLE bd_bulk_pf1 PARTITION OF bd_bulk_pf FOR VALUES FROM (0) TO (10)", on: connection)
        try await exec("CREATE TABLE bd_bulk_p (id int PRIMARY KEY) PARTITION BY RANGE (id)", on: connection)
        try await exec("CREATE TABLE bd_bulk_p1 PARTITION OF bd_bulk_p FOR VALUES FROM (0) TO (10)", on: connection)
        try await exec("CREATE TABLE bd_bulk_ref (p int REFERENCES bd_bulk_p (id))", on: connection)

        let relations = try await connection.introspector.foreignKeys(scope: .schemas(["public"]))
            .filter { $0.source.name.hasPrefix("bd_bulk_") }

        #expect(Set(relations.map { "\($0.source.name).\($0.column)->\($0.target.name).\($0.referencedColumn)" })
            == ["bd_bulk_pf.t->bd_bulk_target.id", "bd_bulk_ref.p->bd_bulk_p.id"])
        #expect(relations.count == 2)
    }

    // MARK: - Tier 1 token

    /// The counters a token would be built from trail an ALTER TABLE by seconds
    /// when the session that ran it stays connected; the measurement is on
    /// `schemaVersionToken`. A token that is sometimes stale would let the
    /// caller skip a changed catalog, so none is offered until one is measured
    /// to follow every change.
    @Test func versionTokenIsNotOffered() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }

        #expect(try await connection.introspector.schemaVersionToken(scope: .allUserSchemas) == nil)
        #expect(try await connection.introspector.schemaVersionToken(scope: .schemas(["public"])) == nil)
    }
}
