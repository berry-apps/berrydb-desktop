import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverSQLite

/// SQLite is in-process, so these run against a temporary database file on
/// every run. Each test starts from the same small schema: a parent, a child
/// with a foreign key and an index, a view, and a composite key pair.
@Suite("SQLite bulk introspection")
struct SQLiteBulkIntrospectionTests {
    private static let baseSchema = [
        #"CREATE TABLE a (id INTEGER PRIMARY KEY, "it's" TEXT)"#,
        "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER REFERENCES a(id))",
        "CREATE INDEX b_a_id ON b(a_id)",
        "CREATE VIEW v AS SELECT id FROM a",
        // The key's order is not the columns' order, so a key resolved
        // through it shows whether the key positions are followed.
        "CREATE TABLE d (p, q, PRIMARY KEY (q, p))",
        "CREATE TABLE c (x, y, FOREIGN KEY (x, y) REFERENCES d(p, q))",
    ]

    /// Runs `body` against a fresh database file holding `baseSchema` plus
    /// `extra`, and removes the file afterwards, also when `body` throws.
    private func withDatabase(
        extra: [String] = [], _ body: (SQLiteConnection, String) async throws -> Void
    ) async throws {
        let path = NSTemporaryDirectory() + "berrydb-bulk-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let connection = try SQLiteConnection(path: path)
        do {
            for sql in Self.baseSchema + extra { try await exec(sql, on: connection) }
            try await body(connection, path)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    private func exec(_ sql: String, on connection: SQLiteConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }

    private func fingerprints(_ connection: SQLiteConnection) async throws -> [String: String?] {
        let summaries = try await connection.introspector.objectSummaries(scope: .allUserSchemas)
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.ref.name, $0.fingerprint) })
    }

    private func relations(_ connection: SQLiteConnection) async throws -> [ForeignKeyRelation] {
        try await connection.introspector.foreignKeys(scope: .allUserSchemas)
    }

    /// SQLite stores a view's `CREATE` text as written, so with `SELECT *`
    /// the text stays the same when the base table gains a column, while
    /// `PRAGMA table_info` on the view lists the new column (checked with the
    /// sqlite3 3.51.0 shell). The view's fingerprint follows the column list.
    @Test func aSelectStarViewsFingerprintFollowsItsBaseTable() async throws {
        try await withDatabase(extra: ["CREATE VIEW everything AS SELECT * FROM a"]) { connection, _ in
            let before = try await fingerprints(connection)
            try await exec("ALTER TABLE a ADD COLUMN note TEXT", on: connection)
            let after = try await fingerprints(connection)
            #expect(after["everything"] != before["everything"])
            // A view that names its columns keeps its fingerprint.
            #expect(after["v"] == before["v"])
        }
    }

    /// A view over a dropped table has no column list; its fingerprint holds
    /// a marker instead, the same on every listing, so its definition is not
    /// asked for on every pass.
    @Test func aViewOverADroppedTableHasAStableFingerprint() async throws {
        let extra = ["CREATE TABLE gone (id INTEGER)", "CREATE VIEW broken AS SELECT id FROM gone"]
        try await withDatabase(extra: extra) { connection, _ in
            let intact = try await fingerprints(connection)
            try await exec("DROP TABLE gone", on: connection)
            let first = try await fingerprints(connection)
            let second = try await fingerprints(connection)
            #expect(first["broken"] != intact["broken"])
            #expect(first["broken"] == second["broken"])
        }
    }

    // MARK: - Details

    /// `DROP TABLE` leaves a view over the table in place, and the view's
    /// `PRAGMA table_info` then fails to prepare with "no such table"
    /// (checked with the sqlite3 3.51.0 shell). The view is left out like a
    /// table dropped since the listing, so the rest of the chunk still gets
    /// its details and a harvest can complete.
    @Test func aViewOverADroppedTableIsLeftOutOfTheDetails() async throws {
        let extra = ["CREATE TABLE gone (id INTEGER)", "CREATE VIEW broken AS SELECT id FROM gone", "DROP TABLE gone"]
        try await withDatabase(extra: extra) { connection, _ in
            let details = try await connection.introspector.tableDetails(
                [TableRef(name: "a"), TableRef(name: "broken"), TableRef(name: "b")]
            )
            #expect(details.map(\.ref.name) == ["a", "b"])
        }
    }

    /// Only a statement about one object is left out: a connection that is
    /// gone fails the whole read, so the harvest records the failure and
    /// connects again.
    @Test func aClosedConnectionStillFailsTheDetails() async throws {
        try await withDatabase { connection, _ in
            await connection.close()
            await #expect(throws: DriverError.self) {
                _ = try await connection.introspector.tableDetails([TableRef(name: "a")])
            }
        }
    }

    // MARK: - Listing

    @Test func listsTablesAndViewsWithFingerprintsAndHidesInternalTables() async throws {
        // AUTOINCREMENT makes SQLite create the internal sqlite_sequence table.
        try await withDatabase(extra: ["CREATE TABLE s (id INTEGER PRIMARY KEY AUTOINCREMENT)"]) { connection, _ in
            let introspector = connection.introspector
            #expect(introspector.bulkIntrospection)

            let summaries = try await introspector.objectSummaries(scope: .allUserSchemas)
            let kinds = Dictionary(uniqueKeysWithValues: summaries.map { ($0.ref.name, $0.kind) })
            #expect(kinds == ["a": .table, "b": .table, "c": .table, "d": .table, "s": .table, "v": .view])
            #expect(summaries.allSatisfy { $0.ref.database == nil })
            for summary in summaries {
                let fingerprint = try #require(summary.fingerprint, "no fingerprint for \(summary.ref.name)")
                #expect(fingerprint.count == 16)
                #expect(fingerprint.allSatisfy { $0.isHexDigit })
            }
        }
    }

    @Test func scopeIsIgnoredBecauseAFileIsOneNamespace() async throws {
        try await withDatabase { connection, _ in
            let introspector = connection.introspector
            let everything = try await introspector.objectSummaries(scope: .allUserSchemas)
            let named = try await introspector.objectSummaries(scope: .schemas(["main"]))
            let elsewhere = try await introspector.objectSummaries(scope: .schemas(["other"]))
            #expect(named == everything)
            #expect(elsewhere == everything)
        }
    }

    // MARK: - Version token

    @Test func versionTokenMovesWithTheSchemaAndNotWithData() async throws {
        try await withDatabase { connection, _ in
            let introspector = connection.introspector
            let first = try #require(try await introspector.schemaVersionToken(scope: .allUserSchemas))
            #expect(try await introspector.schemaVersionToken(scope: .allUserSchemas) == first)

            try await exec("INSERT INTO a (id) VALUES (1)", on: connection)
            #expect(try await introspector.schemaVersionToken(scope: .allUserSchemas) == first)

            try await exec("ALTER TABLE a ADD COLUMN z INTEGER", on: connection)
            let afterAlter = try #require(try await introspector.schemaVersionToken(scope: .allUserSchemas))
            #expect(afterAlter != first)

            try await exec("CREATE INDEX a_z ON a(z)", on: connection)
            let afterIndex = try #require(try await introspector.schemaVersionToken(scope: .allUserSchemas))
            #expect(afterIndex != afterAlter)
        }
    }

    /// The app reads the catalog on a connection of its own, so a change made
    /// by the SQL editor's connection must move the token it reads.
    @Test func versionTokenSeesASchemaChangeMadeThroughAnotherConnection() async throws {
        try await withDatabase { reader, path in
            let writer = try SQLiteConnection(path: path)
            do {
                let before = try #require(try await reader.introspector.schemaVersionToken(scope: .allUserSchemas))
                try await exec("ALTER TABLE a ADD COLUMN z INTEGER", on: writer)
                let after = try #require(try await reader.introspector.schemaVersionToken(scope: .allUserSchemas))
                #expect(after != before)
            } catch {
                await writer.close()
                throw error
            }
            await writer.close()
        }
    }

    // MARK: - Fingerprints

    @Test func fingerprintIsStableUntilTheDefinitionChanges() async throws {
        try await withDatabase { connection, _ in
            let before = try await fingerprints(connection)
            #expect(before.values.allSatisfy { $0 != nil })
            #expect(try await fingerprints(connection) == before)
            try await exec("INSERT INTO a (id) VALUES (1)", on: connection)
            #expect(try await fingerprints(connection) == before)
        }
    }

    @Test func alterTableChangesOnlyThatTablesFingerprint() async throws {
        try await withDatabase { connection, _ in
            let before = try await fingerprints(connection)
            try await exec("ALTER TABLE a ADD COLUMN z INTEGER", on: connection)
            let after = try await fingerprints(connection)

            #expect(Set(after.keys) == Set(before.keys))
            let changed = Set(after.keys.filter { after[$0]! != before[$0]! })
            #expect(changed == ["a"])
        }
    }

    @Test func createIndexChangesOnlyThatTablesFingerprintAndDropRestoresIt() async throws {
        try await withDatabase { connection, _ in
            let before = try await fingerprints(connection)
            try await exec("CREATE INDEX b_id2 ON b(id)", on: connection)
            let withIndex = try await fingerprints(connection)
            let changed = Set(withIndex.keys.filter { withIndex[$0]! != before[$0]! })
            #expect(changed == ["b"])

            try await exec("DROP INDEX b_id2", on: connection)
            #expect(try await fingerprints(connection) == before)
        }
    }

    @Test func changedViewBodyChangesTheViewsFingerprint() async throws {
        try await withDatabase { connection, _ in
            let before = try await fingerprints(connection)
            try await exec("DROP VIEW v", on: connection)
            try await exec("CREATE VIEW v AS SELECT id, \"it's\" FROM a", on: connection)
            let after = try await fingerprints(connection)
            let changed = Set(after.keys.filter { after[$0]! != before[$0]! })
            #expect(changed == ["v"])
        }
    }

    // MARK: - Foreign keys

    @Test func foreignKeysListSingleAndCompositeKeysInKeyOrder() async throws {
        try await withDatabase { connection, _ in
            let found = try await relations(connection)
            func pairs(from table: String) -> [[String]] {
                found.filter { $0.source.name == table }
                    .map { [$0.column, $0.target.name, $0.referencedColumn] }
            }
            #expect(pairs(from: "b") == [["a_id", "a", "id"]])
            #expect(pairs(from: "c") == [["x", "d", "p"], ["y", "d", "q"]])
            #expect(found.count == 3)
            #expect(found.allSatisfy { $0.source.database == nil && $0.target.database == nil })
            #expect(found.allSatisfy { $0.constraintName == nil })
        }
    }

    @Test func keyWithoutColumnListResolvesThroughTheParentPrimaryKey() async throws {
        // A key that names no parent column references the parent's primary
        // key, which the key list reports as NULL.
        let extra = [
            "CREATE TABLE e (a_id INTEGER REFERENCES a)",
            "CREATE TABLE f (x, y, FOREIGN KEY (x, y) REFERENCES d)",
            "CREATE TABLE g (z INTEGER REFERENCES nowhere)",
            "CREATE TABLE h (z INTEGER REFERENCES c)",
        ]
        try await withDatabase(extra: extra) { connection, _ in
            let found = try await relations(connection)
            func pairs(from table: String) -> [[String]] {
                found.filter { $0.source.name == table }
                    .map { [$0.column, $0.target.name, $0.referencedColumn] }
            }
            #expect(pairs(from: "e") == [["a_id", "a", "id"]])
            #expect(pairs(from: "f") == [["x", "d", "q"], ["y", "d", "p"]])
            // A missing parent and a parent without a primary key have no
            // column to name, so the pair is left out.
            #expect(pairs(from: "g").isEmpty)
            #expect(pairs(from: "h").isEmpty)
        }
    }

    /// `PRAGMA foreign_key_list` reports the parent as the `REFERENCES`
    /// clause wrote it, and SQLite resolves that name ignoring the case of
    /// ASCII letters only: with the sqlite3 3.51.0 shell, `orders` clashes
    /// with an existing `Orders` while `äpfel` and `Äpfel` are two tables. The
    /// target is named as the table is listed, so the relation joins the
    /// object it points at.
    @Test func aKeyTargetIsNamedAsItsTableIsListed() async throws {
        let extra = [
            "CREATE TABLE k (a_id INTEGER REFERENCES A(id))",
            #"CREATE TABLE "Äpfel" (id INTEGER PRIMARY KEY)"#,
            #"CREATE TABLE m (x INTEGER REFERENCES "äpfel"(id))"#,
        ]
        try await withDatabase(extra: extra) { connection, _ in
            let found = try await relations(connection)
            #expect(found.first { $0.source.name == "k" }?.target.name == "a")
            #expect(found.first { $0.source.name == "m" }?.target.name == "äpfel")
        }
    }

    // MARK: - Table details

    @Test func tableDetailsEqualThePerTableDetails() async throws {
        try await withDatabase(extra: ["CREATE UNIQUE INDEX b_u ON b(a_id, id)"]) { connection, _ in
            let introspector = connection.introspector
            let refs = ["a", "b", "c"].map { TableRef(name: $0) }
            let bulk = try await introspector.tableDetails(refs)
            #expect(bulk.map(\.ref) == refs)
            for (ref, detail) in zip(refs, bulk) {
                let single = try await introspector.tableDetail(ref)
                #expect(detail.columns == single.columns)
                #expect(detail.indexes == single.indexes)
                #expect(detail.foreignKeys == single.foreignKeys)
            }
            let b = try #require(bulk.first { $0.ref.name == "b" })
            #expect(b.indexes.contains(IndexInfo(name: "b_a_id", isUnique: false, columns: ["a_id"])))
            #expect(b.indexes.contains(IndexInfo(name: "b_u", isUnique: true, columns: ["a_id", "id"])))
        }
    }

    @Test func tableDroppedSinceTheListingIsLeftOut() async throws {
        try await withDatabase { connection, _ in
            let introspector = connection.introspector
            try await exec("DROP TABLE c", on: connection)
            let details = try await introspector.tableDetails(["a", "c", "d"].map { TableRef(name: $0) })
            #expect(details.map(\.ref.name) == ["a", "d"])
        }
    }

    // MARK: - Identifier quoting

    @Test func namesWithAQuoteRoundTripThroughEveryMember() async throws {
        let extra = [
            #"CREATE TABLE "q""uote" (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES "q""uote"(id))"#,
            #"CREATE INDEX "q""idx" ON "q""uote"(parent)"#,
        ]
        try await withDatabase(extra: extra) { connection, _ in
            let introspector = connection.introspector
            let quoted = TableRef(name: #"q"uote"#)

            let summaries = try await introspector.objectSummaries(scope: .allUserSchemas)
            #expect(summaries.contains { $0.ref == quoted && $0.kind == .table && $0.fingerprint != nil })

            #expect(try await relations(connection).contains(
                ForeignKeyRelation(source: quoted, column: "parent", target: quoted, referencedColumn: "id")
            ))

            let details = try await introspector.tableDetails([quoted])
            let detail = try #require(details.first)
            #expect(detail.ref == quoted)
            #expect(detail.columns.map(\.name) == ["id", "parent"])
            #expect(detail.indexes.contains(IndexInfo(name: #"q"idx"#, isUnique: false, columns: ["parent"])))
        }
    }
}
