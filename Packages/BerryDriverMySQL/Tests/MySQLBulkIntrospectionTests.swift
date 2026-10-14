import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMySQL

/// Runs against a real MySQL from `BERRYDB_TEST_MYSQL`; skipped when the
/// variable is unset. Serialized because the tests create and drop tables of
/// the same names in the test schema.
@Suite("MySQL bulk introspection", .serialized, .enabled(if: TestServer.mysql != nil))
struct MySQLBulkIntrospectionTests {
    private let dialect = MySQLDialect()

    /// The schema the connection opens in, which is also where the tests create
    /// their tables.
    private var schema: String { TestServer.mysql!.database! }

    private func openConnection() async throws -> MySQLDriverConnection {
        let server = TestServer.mysql!
        return try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql,
            name: "bulk",
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            database: server.database
        ))
    }

    private func exec(_ sql: String, on connection: MySQLDriverConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }

    /// Opens a connection and drops what an earlier, interrupted run may have
    /// left behind, so every test starts from the same catalog.
    private func openConnection(dropping statements: [String]) async throws -> MySQLDriverConnection {
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
    /// other bulk suites do. The statements are `IF EXISTS` and run again at
    /// the start of the next test, so a task still pending when the process
    /// exits only leaves objects the next run removes first.
    private func closeAfterDropping(_ statements: [String], on connection: MySQLDriverConnection) {
        Task {
            for sql in statements { try? await exec(sql, on: connection) }
            await connection.close()
        }
    }

    private func ref(_ name: String, in database: String? = nil) -> TableRef {
        TableRef(database: database ?? schema, name: name)
    }

    private func fingerprints(
        _ connection: MySQLDriverConnection, scope: SchemaScope? = nil
    ) async throws -> [TableRef: String?] {
        let summaries = try await connection.introspector.objectSummaries(scope: scope ?? .schemas([schema]))
        return Dictionary(uniqueKeysWithValues: summaries.map { ($0.ref, $0.fingerprint) })
    }

    /// The fingerprint listed for `ref`, failing when the table is missing: two
    /// absent fingerprints compare equal, so a comparison that read them
    /// straight from the listing would pass whatever the listing did.
    private func fingerprint(of ref: TableRef, in listing: [TableRef: String?]) throws -> String {
        try #require(listing[ref] ?? nil, "no fingerprint listed for \(ref)")
    }

    // MARK: - Listing

    @Test func listsTablesAndViewsWithFingerprints() async throws {
        let drops = ["DROP VIEW IF EXISTS bd_bulk_v", "DROP TABLE IF EXISTS bd_bulk_a"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, `it's` TEXT)", on: connection)
        try await exec("CREATE VIEW bd_bulk_v AS SELECT id FROM bd_bulk_a", on: connection)

        let summaries = try await connection.introspector.objectSummaries(scope: .schemas([schema]))

        let table = try #require(summaries.first { $0.ref == ref("bd_bulk_a") })
        #expect(table.kind == .table)
        let view = try #require(summaries.first { $0.ref == ref("bd_bulk_v") })
        #expect(view.kind == .view)
        for summary in summaries {
            let fingerprint = try #require(summary.fingerprint, "no fingerprint for \(summary.ref)")
            #expect(fingerprint.count == 32 && fingerprint.allSatisfy(\.isHexDigit), "\(summary.ref): \(fingerprint)")
        }
    }

    @Test func alterChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, name VARCHAR(20))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id INT PRIMARY KEY, name VARCHAR(20))", on: connection)

        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        // Rows and refreshed statistics are not part of the definition, so
        // neither may move the fingerprint: a value that followed them would
        // send every table to a full re-read after any write.
        try await exec("INSERT INTO bd_bulk_a (id, name) VALUES (1, 'x'), (2, 'y')", on: connection)
        try await exec("ANALYZE TABLE bd_bulk_a", on: connection)
        let unchanged = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: unchanged) == fingerprintA)
        #expect(try fingerprint(of: b, in: unchanged) == fingerprintB)

        try await exec("ALTER TABLE bd_bulk_a ADD COLUMN extra INT", on: connection)
        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // The column already carries an index, so its key flag in `COLUMNS` stays
    // MUL when the second one is added; only `STATISTICS` shows the change.
    @Test func addedIndexChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, name VARCHAR(20), INDEX bd_bulk_a_name (name))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id INT PRIMARY KEY, name VARCHAR(20), INDEX bd_bulk_b_name (name))", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        try await exec("CREATE INDEX bd_bulk_b_name_again ON bd_bulk_b (name)", on: connection)

        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: b, in: after) != fingerprintB)
        #expect(try fingerprint(of: a, in: after) == fingerprintA)
    }

    // The details served to callers carry the default value, so a change of it
    // must reach the fingerprint.
    @Test func changedDefaultChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, x INT DEFAULT 0)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id INT PRIMARY KEY, x INT DEFAULT 0)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)
        let defaultBefore = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue

        try await exec("ALTER TABLE bd_bulk_a ALTER COLUMN x SET DEFAULT 1", on: connection)

        let after = try await fingerprints(connection)
        let defaultAfter = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue
        #expect(defaultBefore != defaultAfter, "the default is what the fingerprint has to follow")
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // A column without a default and one whose default is the empty string
    // differ in the details, so they must differ in the fingerprint.
    @Test func emptyDefaultChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, x VARCHAR(10))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id INT PRIMARY KEY, x VARCHAR(10))", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)
        let defaultBefore = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue

        try await exec("ALTER TABLE bd_bulk_a ALTER COLUMN x SET DEFAULT ''", on: connection)

        let after = try await fingerprints(connection)
        let defaultAfter = try await connection.introspector.tableDetail(a).columns.first { $0.name == "x" }?.defaultValue
        #expect(defaultBefore == nil && defaultAfter == "", "the details tell an absent default from an empty one")
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // A functional key part has no column name, and the per-table path still
    // lists the index, so the fingerprint has to see it as well.
    @Test func functionalIndexChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY, x INT)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id INT PRIMARY KEY, x INT)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        try await exec("ALTER TABLE bd_bulk_a ADD INDEX bd_bulk_fx ((x + 1))", on: connection)

        let indexes = try await connection.introspector.tableDetail(a).indexes
        #expect(indexes.contains { $0.name == "bd_bulk_fx" }, "the per-table path lists the index")
        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // GROUP_CONCAT cuts its result at group_concat_max_len, which is 1024
    // characters unless raised. A table whose column list is longer than that
    // would then keep one fingerprint while its last columns change.
    @Test func wideTableFingerprintFollowsItsLastColumn() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_wide"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        let columns = (0..<120).map { "bd_bulk_wide_column_\($0) INT" }.joined(separator: ", ")
        try await exec("CREATE TABLE bd_bulk_wide (\(columns))", on: connection)
        let wide = ref("bd_bulk_wide")
        let before = try #require(try await fingerprints(connection)[wide] ?? nil)

        try await exec("ALTER TABLE bd_bulk_wide ADD COLUMN bd_bulk_wide_tail INT", on: connection)

        #expect(try #require(try await fingerprints(connection)[wide] ?? nil) != before)
    }

    /// MariaDB reports a system-versioned table as `SYSTEM VERSIONED` and a
    /// sequence as `SEQUENCE`
    /// (https://mariadb.com/kb/en/information-schema-tables-table/). The
    /// first is a table with columns and keys and is listed as one; a sequence
    /// is not a table. MySQL has neither, so there the test has nothing to do.
    @Test func mariaDBListsASystemVersionedTableAsATableAndLeavesASequenceOut() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_versioned", "DROP SEQUENCE IF EXISTS bd_bulk_sequence"]
        let probe = try await openConnection()
        let version = try await probe.queryAll("SELECT VERSION()").first?.first
        await probe.close()
        guard case .text(let text)? = version, text.contains("MariaDB") else { return }
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_versioned (id INT PRIMARY KEY) WITH SYSTEM VERSIONING", on: connection)
        try await exec("CREATE SEQUENCE bd_bulk_sequence", on: connection)

        let summaries = try await connection.introspector.objectSummaries(scope: .schemas([schema]))

        let versioned = summaries.first { $0.ref == ref("bd_bulk_versioned") }
        #expect(versioned?.kind == .table)
        #expect(versioned?.fingerprint != nil)
        #expect(!summaries.contains { $0.ref == ref("bd_bulk_sequence") })
    }

    // MARK: - Scope

    /// A connection opened without a database has no default one, so the
    /// default scope is every database on the server but its own four.
    @Test func withoutADatabaseTheDefaultScopeIsEveryUserDatabase() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_s", "DROP DATABASE IF EXISTS bd_other"]
        let setUp = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: setUp) }
        try await exec("CREATE DATABASE bd_other", on: setUp)
        try await exec("CREATE TABLE bd_other.t (id INT PRIMARY KEY)", on: setUp)
        try await exec(
            "CREATE TABLE bd_bulk_s (id INT PRIMARY KEY, o INT, FOREIGN KEY (o) REFERENCES bd_other.t (id))", on: setUp
        )
        let server = TestServer.mysql!
        let connection = try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql, name: "bulk-no-database", host: server.host, port: server.port,
            username: server.username, password: server.password, database: nil
        ))
        defer { Task { await connection.close() } }
        let introspector = connection.introspector

        let everything = try await introspector.objectSummaries(scope: .allUserSchemas)
        #expect(everything.contains { $0.ref == ref("bd_bulk_s") })
        #expect(everything.contains { $0.ref == ref("t", in: "bd_other") })
        let systemSchemas: Set<String> = ["mysql", "information_schema", "performance_schema", "sys"]
        #expect(!everything.contains { systemSchemas.contains($0.ref.database ?? "") })
        let keys = try await introspector.foreignKeys(scope: .allUserSchemas)
        #expect(keys.contains { $0.source == ref("bd_bulk_s") && $0.target == ref("t", in: "bd_other") })
    }

    @Test func scopeFilterKeepsOtherSchemasOut() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_s", "DROP DATABASE IF EXISTS bd_other"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE DATABASE bd_other", on: connection)
        try await exec("CREATE TABLE bd_other.t (id INT PRIMARY KEY)", on: connection)
        try await exec(
            "CREATE TABLE bd_bulk_s (id INT PRIMARY KEY, o INT, FOREIGN KEY (o) REFERENCES bd_other.t (id))",
            on: connection
        )
        let introspector = connection.introspector
        let other = ref("t", in: "bd_other"), mine = ref("bd_bulk_s")

        let mineOnly = try await introspector.objectSummaries(scope: .schemas([schema]))
        #expect(mineOnly.contains { $0.ref == mine })
        #expect(!mineOnly.contains { $0.ref.database == "bd_other" })

        // The connection has a database, which is then the whole default
        // scope: the other databases on the server stay out unless named.
        let byDefault = try await introspector.objectSummaries(scope: .allUserSchemas)
        #expect(byDefault.contains { $0.ref == mine })
        #expect(byDefault.allSatisfy { $0.ref.database == schema })
        let defaultKeys = try await introspector.foreignKeys(scope: .allUserSchemas)
        #expect(defaultKeys.contains { $0.source == mine && $0.target == other })
        #expect(defaultKeys.allSatisfy { $0.source.database == schema })

        let otherOnly = try await introspector.objectSummaries(scope: .schemas(["bd_other"]))
        #expect(otherOnly.map(\.ref) == [other])

        #expect(try await introspector.objectSummaries(scope: .schemas([])).isEmpty)
        // A quote in a schema name must stay inside its literal.
        #expect(try await introspector.objectSummaries(scope: .schemas([#"it's "odd""#])).isEmpty)

        // The scope of a foreign key is its source table; the target may lie outside.
        let fromMine = try await introspector.foreignKeys(scope: .schemas([schema]))
        #expect(fromMine.contains { $0.source == mine && $0.target == other })
        #expect(try await introspector.foreignKeys(scope: .schemas(["bd_other"])).isEmpty)
        #expect(try await introspector.foreignKeys(scope: .schemas([])).isEmpty)
    }

    // MARK: - Foreign keys and details

    @Test func detailsForAChunkMatchPerTableDetail() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_c",
            "DROP TABLE IF EXISTS bd_bulk_p",
            "DROP TABLE IF EXISTS bd_bulk_q",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec(
            "CREATE TABLE bd_bulk_p (x INT, y INT, note VARCHAR(20) DEFAULT 'it''s', PRIMARY KEY (x, y))",
            on: connection
        )
        try await exec("CREATE TABLE bd_bulk_q (id INT PRIMARY KEY, score DECIMAL(10,2) NOT NULL)", on: connection)
        // The foreign key lists its columns in a different order than the
        // parent's key declares them, so a pair is only right when it follows
        // the key.
        try await exec(
            """
            CREATE TABLE bd_bulk_c (
                a INT, x INT, y INT NOT NULL DEFAULT 5,
                CONSTRAINT bd_bulk_fk_pair FOREIGN KEY (y, x) REFERENCES bd_bulk_p (x, y),
                CONSTRAINT bd_bulk_fk_q FOREIGN KEY (a) REFERENCES bd_bulk_q (id)
            )
            """,
            on: connection
        )
        try await exec("CREATE UNIQUE INDEX bd_bulk_c_ax ON bd_bulk_c (a, x)", on: connection)

        let introspector = connection.introspector
        let parent = ref("bd_bulk_p"), query = ref("bd_bulk_q"), child = ref("bd_bulk_c")
        // A nil schema means the connection's own, and the result keeps the ref it was asked for.
        let childAsAsked = TableRef(database: nil, name: "bd_bulk_c")
        let gone = ref("bd_bulk_gone")
        let asked = [parent, query, childAsAsked, gone]

        let details = try await introspector.tableDetails(asked)

        #expect(details.count == 3, "a table that does not exist is left out")
        for ref in [parent, query, childAsAsked] {
            let bulk = try #require(details.first { $0.ref == ref }, "no detail for \(ref)")
            let single = try await introspector.tableDetail(ref)
            #expect(!single.columns.isEmpty)
            #expect(bulk.columns == single.columns, "columns of \(ref)")
            #expect(bulk.indexes == single.indexes, "indexes of \(ref)")
            #expect(bulk.foreignKeys.isEmpty)
        }
        let childDetail = try #require(details.first { $0.ref == childAsAsked })
        #expect(childDetail.columns.map(\.name) == ["a", "x", "y"])
        #expect(childDetail.indexes.contains { $0.name == "bd_bulk_c_ax" && $0.isUnique && $0.columns == ["a", "x"] })
        // The foreign key's own index lists the columns in the key's order.
        #expect(childDetail.indexes.contains { $0.name == "bd_bulk_fk_pair" && $0.columns == ["y", "x"] })
        let parentDetail = try #require(details.first { $0.ref == parent })
        #expect(parentDetail.columns.filter(\.isPrimaryKey).map(\.name) == ["x", "y"])
        #expect(parentDetail.columns.first { $0.name == "note" }?.defaultValue == "it's")
        #expect(try await introspector.tableDetails([]).isEmpty)

        let relations = try await introspector.foreignKeys(scope: .schemas([schema])).filter { $0.source == child }
        #expect(relations == [
            ForeignKeyRelation(source: child, column: "y", target: parent, referencedColumn: "x", constraintName: "bd_bulk_fk_pair"),
            ForeignKeyRelation(source: child, column: "x", target: parent, referencedColumn: "y", constraintName: "bd_bulk_fk_pair"),
            ForeignKeyRelation(source: child, column: "a", target: query, referencedColumn: "id", constraintName: "bd_bulk_fk_q"),
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

    @Test func namesWithQuotesAndBackticksRoundTrip() async throws {
        let quoted = "bd_bulk_d\"q", ticked = "bd_bulk_b`t", apostrophe = "bd_bulk_it's"
        let drops = [quoted, ticked, apostrophe].map { "DROP TABLE IF EXISTS " + dialect.quoteIdentifier($0) }
        // The child holds the foreign key, so it goes first.
        let connection = try await openConnection(dropping: [drops[1], drops[0], drops[2]])
        defer { closeAfterDropping([drops[1], drops[0], drops[2]], on: connection) }
        let q = dialect.quoteIdentifier
        try await exec("CREATE TABLE \(q(quoted)) (id INT PRIMARY KEY, \(q("it's")) TEXT)", on: connection)
        try await exec(
            """
            CREATE TABLE \(q(ticked)) (id INT, \(q("p'id")) INT, \(q("odd`col")) INT,
                FOREIGN KEY (\(q("p'id"))) REFERENCES \(q(quoted)) (id))
            """,
            on: connection
        )
        try await exec("CREATE TABLE \(q(apostrophe)) (id INT PRIMARY KEY)", on: connection)
        let introspector = connection.introspector
        let refs = [quoted, ticked, apostrophe].map { ref($0) }

        let summaries = try await introspector.objectSummaries(scope: .schemas([schema]))
        for ref in refs {
            let summary = try #require(summaries.first { $0.ref == ref }, "\(ref) is not listed")
            #expect(summary.kind == .table)
            #expect(summary.fingerprint != nil)
        }

        let details = try await introspector.tableDetails(refs)
        #expect(details.count == 3)
        for ref in refs {
            let bulk = try #require(details.first { $0.ref == ref }, "no detail for \(ref)")
            let single = try await introspector.tableDetail(ref)
            #expect(bulk.columns == single.columns, "columns of \(ref)")
            #expect(bulk.indexes == single.indexes, "indexes of \(ref)")
        }
        #expect(try #require(details.first { $0.ref == refs[1] }).columns.map(\.name) == ["id", "p'id", "odd`col"])

        let relations = try await introspector.foreignKeys(scope: .schemas([schema])).filter { $0.source == refs[1] }
        #expect(relations.map { "\($0.column)->\($0.target.name).\($0.referencedColumn)" } == ["p'id->\(quoted).id"])
    }

    // MySQL reads a backslash in a string literal as an escape character by
    // default, so a name that ends with one would swallow the closing quote and
    // splice the next literal into it.
    @Test func namesWithBackslashesRoundTrip() async throws {
        let slashed = #"bd_bulk_back\slash"#, trailing = #"bd_bulk_end\"#
        let plain = "bd_bulk_after", referrer = "bd_bulk_refers"
        let drops = [referrer, slashed, trailing, plain].map { "DROP TABLE IF EXISTS " + dialect.quoteIdentifier($0) }
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        let q = dialect.quoteIdentifier
        try await exec("CREATE TABLE \(q(slashed)) (id INT PRIMARY KEY, note VARCHAR(10) DEFAULT 'a\\\\b')", on: connection)
        try await exec("CREATE TABLE \(q(trailing)) (id INT PRIMARY KEY)", on: connection)
        try await exec("CREATE TABLE \(q(plain)) (id INT PRIMARY KEY)", on: connection)
        try await exec(
            "CREATE TABLE \(q(referrer)) (id INT, s INT, FOREIGN KEY (s) REFERENCES \(q(slashed)) (id))",
            on: connection
        )
        let introspector = connection.introspector
        let refs = [slashed, trailing, plain].map { ref($0) }

        let summaries = try await introspector.objectSummaries(scope: .schemas([schema]))
        for ref in refs + [ref(referrer)] {
            #expect(summaries.contains { $0.ref == ref && $0.fingerprint != nil }, "\(ref) is not listed")
        }
        let details = try await introspector.tableDetails(refs)
        #expect(details.count == 3)
        for ref in refs {
            let bulk = try #require(details.first { $0.ref == ref }, "no detail for \(ref)")
            let single = try await introspector.tableDetail(ref)
            #expect(!single.columns.isEmpty, "the per-table path finds \(ref)")
            #expect(bulk.columns == single.columns, "columns of \(ref)")
            #expect(bulk.indexes == single.indexes, "indexes of \(ref)")
        }
        #expect(try #require(details.first { $0.ref == refs[0] }).columns.first { $0.name == "note" }?.defaultValue
            == #"a\b"#)
        // Whichever order the chunk lists them in, the name that ends with a
        // backslash is followed by, or follows, another literal.
        let pair = try await introspector.tableDetails([refs[1], refs[2]])
        #expect(Set(pair.map(\.ref)) == [refs[1], refs[2]])

        let relations = try await introspector.foreignKeys(scope: .schemas([schema])).filter { $0.source == ref(referrer) }
        #expect(relations.map(\.target) == [refs[0]])
        let singleRelations = try await introspector.tableDetail(ref(referrer)).foreignKeys
        #expect(singleRelations.map(\.referencedTable) == [slashed])
    }

    // The scope filter lists schema names in one literal list, so a name that
    // ends with a backslash must not swallow the literal that follows it.
    @Test func schemaNamesWithBackslashesStayInTheirLiteral() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id INT PRIMARY KEY)", on: connection)
        let introspector = connection.introspector
        let scope = SchemaScope.schemas([#"bd_bulk\"#, schema])

        let summaries = try await introspector.objectSummaries(scope: scope)
        #expect(summaries.contains { $0.ref == ref("bd_bulk_a") })
        #expect(!summaries.contains { $0.ref.database == #"bd_bulk\"# })
        _ = try await introspector.foreignKeys(scope: scope)
        #expect(try await introspector.objectSummaries(scope: .schemas([#"bd_bulk\"#])).isEmpty)
    }

    // MARK: - Version token

    /// `CREATE_TIME` has one-second resolution and does not move for a replaced
    /// view, and `UPDATE_TIME` follows row changes; the measurement is on
    /// `schemaVersionToken`. A token that missed an ALTER would let the caller
    /// skip a changed catalog, so none is offered.
    @Test func versionTokenIsNotOffered() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }

        let introspector = connection.introspector
        #expect(introspector.bulkIntrospection)
        #expect(try await introspector.schemaVersionToken(scope: .allUserSchemas) == nil)
        #expect(try await introspector.schemaVersionToken(scope: .schemas([schema])) == nil)
    }
}

/// The default scope widens to every database only when the server says the
/// connection has none. Needs no server: the answer is given directly.
@Suite("MySQL default scope")
struct MySQLDefaultScopeTests {
    private func filter(_ answer: [[BerryValue]]) throws -> String {
        try MySQLIntrospector.defaultScopeFilter(answer: answer, schemaColumn: "s")
    }

    @Test func aDatabaseNarrowsTheScopeToItself() throws {
        #expect(try filter([[.text("shop")]]) == "s = 'shop'")
        #expect(try filter([[.text("it's")]]) == "s = 'it''s'")
    }

    @Test func noDatabaseWidensToEveryUserDatabase() throws {
        #expect(try filter([[.null]]) == "s NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')")
    }

    /// A value that is neither a name nor NULL, or no answer at all, says
    /// nothing about the connection's database, so nothing is read.
    @Test func anythingElseFailsTheRead() {
        #expect(throws: DriverError.self) { try filter([[.bytes(Data([0x73]))]]) }
        #expect(throws: DriverError.self) { try filter([]) }
        #expect(throws: DriverError.self) { try filter([[]]) }
    }
}
