import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverSQLServer

/// Runs against a real SQL Server from `BERRYDB_TEST_SQLSERVER`; skipped when
/// the variable is unset. Serialized because the tests create and drop tables
/// of the same names, and because FreeTDS DB-Library's message handlers are
/// process-global, as the conformance suite explains.
@Suite("SQL Server bulk introspection", .serialized, .enabled(if: TestServer.sqlServer != nil))
struct SQLServerBulkIntrospectionTests {
    private let dialect = SQLServerDialect()

    /// Where the tests create their tables: the default schema of `sa`.
    private let schema = "dbo"

    private func openConnection() async throws -> SQLServerConnection {
        let server = TestServer.sqlServer!
        return try await SQLServerConnection(config: ConnectionConfig(
            driver: .sqlserver,
            name: "bulk",
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password,
            database: server.database
        ))
    }

    private func exec(_ sql: String, on connection: SQLServerConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }

    /// Opens a connection and drops what an earlier, interrupted run may have
    /// left behind, so every test starts from the same catalog.
    private func openConnection(dropping statements: [String]) async throws -> SQLServerConnection {
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
    private func closeAfterDropping(_ statements: [String], on connection: SQLServerConnection) {
        Task {
            for sql in statements { try? await exec(sql, on: connection) }
            await connection.close()
        }
    }

    /// Runs a statement whose effect the test then reads through `modify_date`,
    /// after a pause. The date is a `datetime`, which rounds to ticks of about
    /// 3 ms, so a change made within a tick of the previous one to the same
    /// object could keep the old value; the pause keeps the tests from
    /// depending on how fast the server answers.
    private func change(_ sql: String, on connection: SQLServerConnection) async throws {
        try await Task.sleep(for: .milliseconds(10))
        try await exec(sql, on: connection)
    }

    private func ref(_ name: String, in schema: String? = nil) -> TableRef {
        TableRef(database: schema ?? self.schema, name: name)
    }

    private func fingerprints(
        _ connection: SQLServerConnection, scope: SchemaScope? = nil
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

    private func token(_ connection: SQLServerConnection, scope: SchemaScope? = nil) async throws -> String {
        try #require(
            try await connection.introspector.schemaVersionToken(scope: scope ?? .schemas([schema])),
            "no version token"
        )
    }

    // MARK: - Listing

    @Test func listsTablesAndViewsWithFingerprints() async throws {
        let drops = ["DROP VIEW IF EXISTS bd_bulk_v", "DROP TABLE IF EXISTS bd_bulk_a"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, [it's] nvarchar(10))", on: connection)
        try await exec("CREATE VIEW bd_bulk_v AS SELECT id FROM bd_bulk_a", on: connection)

        let summaries = try await connection.introspector.objectSummaries(scope: .schemas([schema]))

        let table = try #require(summaries.first { $0.ref == ref("bd_bulk_a") })
        #expect(table.kind == .table)
        let view = try #require(summaries.first { $0.ref == ref("bd_bulk_v") })
        #expect(view.kind == .view)
        for summary in summaries {
            #expect(summary.fingerprint != nil, "no fingerprint for \(summary.ref)")
        }
    }

    // MARK: - Fingerprints and the version token

    @Test func alterChangesOnlyThatTablesFingerprintAndTheToken() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, name varchar(20))", on: connection)

        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)
        let tokenBefore = try await token(connection)

        // Rows are not part of the definition, so they must not move either
        // value: one that followed them would send every table to a full
        // re-read after any write.
        try await exec("INSERT INTO bd_bulk_a (id, name) VALUES (1, 'x'), (2, 'y')", on: connection)
        let unchanged = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: unchanged) == fingerprintA)
        #expect(try fingerprint(of: b, in: unchanged) == fingerprintB)
        #expect(try await token(connection) == tokenBefore)

        try await change("ALTER TABLE bd_bulk_a ADD extra int", on: connection)

        // Read straight after the statement, with no wait: the value is the
        // catalog's own, not a cache that lags.
        let tokenAfter = try await token(connection)
        let after = try await fingerprints(connection)
        #expect(tokenAfter != tokenBefore)
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    @Test func addedIndexChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, extra int)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, extra int)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        try await change("CREATE INDEX bd_bulk_a_extra ON bd_bulk_a (extra)", on: connection)

        let indexes = try await connection.introspector.tableDetail(a).indexes
        #expect(indexes.contains { $0.name == "bd_bulk_a_extra" }, "the per-table path lists the index")
        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // Renaming an index changes the index names the details list, and is not an
    // ALTER of the table.
    @Test func renamedIndexChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE INDEX bd_bulk_a_old ON bd_bulk_a (name)", on: connection)
        try await exec("CREATE INDEX bd_bulk_b_old ON bd_bulk_b (name)", on: connection)
        let before = try await fingerprints(connection)
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        try await change("EXEC sp_rename 'dbo.bd_bulk_a.bd_bulk_a_old', 'bd_bulk_a_new', 'INDEX'", on: connection)

        let names = try await connection.introspector.tableDetails([a]).first?.indexes.map(\.name) ?? []
        #expect(names.contains("bd_bulk_a_new") && !names.contains("bd_bulk_a_old"), "the details follow the rename")
        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: a, in: after) != fingerprintA)
        #expect(try fingerprint(of: b, in: after) == fingerprintB)
    }

    // The details carry the default value, so adding and dropping a default
    // constraint must each move the fingerprint.
    @Test func changedDefaultChangesOnlyThatTablesFingerprint() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, x int)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, x int)", on: connection)
        let introspector = connection.introspector
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        func defaultOfX() async throws -> String? {
            try await introspector.tableDetails([a]).first?.columns.first { $0.name == "x" }?.defaultValue
        }
        let before = try await fingerprints(connection)
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)
        #expect(try await defaultOfX() == nil)

        try await change("ALTER TABLE bd_bulk_a ADD CONSTRAINT bd_bulk_df DEFAULT 1 FOR x", on: connection)

        let added = try await fingerprints(connection)
        #expect(try await defaultOfX() != nil, "the details show the default")
        let fingerprintAdded = try fingerprint(of: a, in: added)
        #expect(fingerprintAdded != fingerprintA)
        #expect(try fingerprint(of: b, in: added) == fingerprintB)

        try await change("ALTER TABLE bd_bulk_a DROP CONSTRAINT bd_bulk_df", on: connection)

        let dropped = try await fingerprints(connection)
        #expect(try await defaultOfX() == nil, "the details no longer show it")
        #expect(try fingerprint(of: a, in: dropped) != fingerprintAdded)
        #expect(try fingerprint(of: b, in: dropped) == fingerprintB)
    }

    // A default bound with `sp_bindefault` is read by the details too, and
    // binding or unbinding it is not an `ALTER TABLE`.
    @Test func boundAndUnboundDefaultChangeOnlyThatTablesFingerprint() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b", "DROP DEFAULT IF EXISTS bd_bulk_legacy",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, x int)", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, x int)", on: connection)
        try await exec("CREATE DEFAULT bd_bulk_legacy AS 7", on: connection)
        let introspector = connection.introspector
        let a = ref("bd_bulk_a"), b = ref("bd_bulk_b")
        func defaultOfX() async throws -> String? {
            try await introspector.tableDetails([a]).first?.columns.first { $0.name == "x" }?.defaultValue
        }
        let before = try await fingerprints(connection)
        let fingerprintA = try fingerprint(of: a, in: before)
        let fingerprintB = try fingerprint(of: b, in: before)

        try await change("EXEC sp_bindefault 'bd_bulk_legacy', 'bd_bulk_a.x'", on: connection)

        let bound = try await fingerprints(connection)
        #expect(try await defaultOfX() != nil, "the details show the bound default")
        let fingerprintBound = try fingerprint(of: a, in: bound)
        #expect(fingerprintBound != fingerprintA)
        #expect(try fingerprint(of: b, in: bound) == fingerprintB)

        try await change("EXEC sp_unbindefault 'bd_bulk_a.x'", on: connection)

        let unbound = try await fingerprints(connection)
        #expect(try await defaultOfX() == nil, "the details no longer show it")
        #expect(try fingerprint(of: a, in: unbound) != fingerprintBound)
        #expect(try fingerprint(of: b, in: unbound) == fingerprintB)
    }

    // MARK: - Views

    @Test func alterViewChangesOnlyTheViewsFingerprint() async throws {
        let drops = ["DROP VIEW IF EXISTS bd_bulk_v", "DROP TABLE IF EXISTS bd_bulk_a"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE VIEW bd_bulk_v AS SELECT id FROM bd_bulk_a", on: connection)
        let before = try await fingerprints(connection)
        let table = ref("bd_bulk_a"), view = ref("bd_bulk_v")
        let fingerprintTable = try fingerprint(of: table, in: before)
        let fingerprintView = try fingerprint(of: view, in: before)

        try await change("ALTER VIEW bd_bulk_v AS SELECT id, name FROM bd_bulk_a", on: connection)

        let after = try await fingerprints(connection)
        #expect(try fingerprint(of: view, in: after) != fingerprintView)
        #expect(try fingerprint(of: table, in: after) == fingerprintTable)
        let introspector = connection.introspector
        let bulk = try #require(try await introspector.tableDetails([view]).first)
        let single = try await introspector.tableDetail(view)
        #expect(bulk.columns.map(\.name) == ["id", "name"])
        #expect(bulk.columns == single.columns)
        #expect(bulk.indexes == single.indexes)
    }

    // A view keeps the columns it had when its base table gains one, in the
    // details as in the fingerprint, until `sp_refreshview` brings them up to
    // date, which changes the view's columns without an `ALTER VIEW`.
    @Test func refreshedViewChangesOnlyTheViewsFingerprint() async throws {
        let drops = ["DROP VIEW IF EXISTS bd_bulk_v", "DROP TABLE IF EXISTS bd_bulk_a", "DROP TABLE IF EXISTS bd_bulk_b"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE TABLE bd_bulk_b (id int PRIMARY KEY, name varchar(20))", on: connection)
        try await exec("CREATE VIEW bd_bulk_v AS SELECT * FROM bd_bulk_a", on: connection)
        let introspector = connection.introspector
        let table = ref("bd_bulk_a"), other = ref("bd_bulk_b"), view = ref("bd_bulk_v")
        func viewColumns() async throws -> [String] {
            try await introspector.tableDetails([view]).first?.columns.map(\.name) ?? []
        }
        let before = try await fingerprints(connection)
        let fingerprintView = try fingerprint(of: view, in: before)
        let fingerprintOther = try fingerprint(of: other, in: before)

        try await change("ALTER TABLE bd_bulk_a ADD extra int", on: connection)

        let grown = try await fingerprints(connection)
        let fingerprintTable = try fingerprint(of: table, in: grown)
        #expect(try await viewColumns() == ["id", "name"], "the view keeps its columns until it is refreshed")
        #expect(try fingerprint(of: view, in: grown) == fingerprintView)

        try await change("EXEC sp_refreshview 'bd_bulk_v'", on: connection)

        let refreshed = try await fingerprints(connection)
        #expect(try await viewColumns() == ["id", "name", "extra"], "the details follow the refresh")
        #expect(try fingerprint(of: view, in: refreshed) != fingerprintView)
        #expect(try fingerprint(of: table, in: refreshed) == fingerprintTable)
        #expect(try fingerprint(of: other, in: refreshed) == fingerprintOther)
    }

    // MARK: - Scope

    @Test func scopeFilterKeepsOtherSchemasOut() async throws {
        let drops = [
            "DROP TABLE IF EXISTS bd_bulk_s",
            "DROP TABLE IF EXISTS bd_other.t",
            "DROP SCHEMA IF EXISTS bd_other",
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE SCHEMA bd_other", on: connection)
        try await exec("CREATE TABLE bd_other.t (id int PRIMARY KEY)", on: connection)
        try await exec(
            "CREATE TABLE bd_bulk_s (id int PRIMARY KEY, o int, FOREIGN KEY (o) REFERENCES bd_other.t (id))",
            on: connection
        )
        let introspector = connection.introspector
        let other = ref("t", in: "bd_other"), mine = ref("bd_bulk_s")

        let mineOnly = try await introspector.objectSummaries(scope: .schemas([schema]))
        #expect(mineOnly.contains { $0.ref == mine })
        #expect(!mineOnly.contains { $0.ref.database == "bd_other" })

        let everything = try await introspector.objectSummaries(scope: .allUserSchemas)
        #expect(everything.contains { $0.ref == mine })
        #expect(everything.contains { $0.ref == other })
        // The server's own schemas stay out of "every user schema".
        #expect(!everything.contains { ["sys", "INFORMATION_SCHEMA"].contains($0.ref.database ?? "") })

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

        // A change in one schema leaves the token of another schema's scope alone.
        let tokenOther = try await token(connection, scope: .schemas(["bd_other"]))
        let tokenMine = try await token(connection, scope: .schemas([schema]))
        let tokenEverything = try await token(connection, scope: .allUserSchemas)
        try await change("ALTER TABLE bd_bulk_s ADD extra int", on: connection)
        #expect(try await token(connection, scope: .schemas(["bd_other"])) == tokenOther)
        #expect(try await token(connection, scope: .schemas([schema])) != tokenMine)
        #expect(try await token(connection, scope: .allUserSchemas) != tokenEverything)
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
            "CREATE TABLE bd_bulk_p (x int, y int, note varchar(20) DEFAULT 'it''s', PRIMARY KEY (x, y))",
            on: connection
        )
        try await exec("CREATE TABLE bd_bulk_q (id int PRIMARY KEY, score decimal(10,2) NOT NULL)", on: connection)
        // The foreign key lists its columns in a different order than the
        // parent's key declares them, so a pair is only right when it follows
        // the key.
        try await exec(
            """
            CREATE TABLE bd_bulk_c (
                a int, x int, y int NOT NULL DEFAULT 5,
                CONSTRAINT bd_bulk_fk_pair FOREIGN KEY (y, x) REFERENCES bd_bulk_p (x, y),
                CONSTRAINT bd_bulk_fk_q FOREIGN KEY (a) REFERENCES bd_bulk_q (id)
            )
            """,
            on: connection
        )
        try await exec("CREATE UNIQUE INDEX bd_bulk_c_ax ON bd_bulk_c (a, x)", on: connection)

        let introspector = connection.introspector
        let parent = ref("bd_bulk_p"), query = ref("bd_bulk_q"), child = ref("bd_bulk_c")
        // A nil schema means dbo, and the result keeps the ref it was asked for.
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
        #expect(childDetail.columns.first { $0.name == "y" }?.isNullable == false)
        #expect(childDetail.indexes.contains { $0.name == "bd_bulk_c_ax" && $0.isUnique && $0.columns == ["a", "x"] })
        let parentDetail = try #require(details.first { $0.ref == parent })
        #expect(parentDetail.columns.filter(\.isPrimaryKey).map(\.name) == ["x", "y"])
        #expect(parentDetail.columns.first { $0.name == "note" }?.defaultValue == "('it''s')")
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

    // A quote ends a string literal and a closing bracket ends a bracketed
    // identifier; a name holding either must stay inside both.
    @Test func namesWithQuotesAndBracketsRoundTrip() async throws {
        let bracket = "bd_bulk_br]acket", apostrophe = "bd_bulk_it's"
        let drops = [apostrophe, bracket].map { "DROP TABLE IF EXISTS " + dialect.quoteIdentifier($0) }
        // The table with the foreign key goes first.
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        let q = dialect.quoteIdentifier
        try await exec("CREATE TABLE \(q(bracket)) (id int PRIMARY KEY, \(q("it's")) nvarchar(10), \(q("odd]col")) int)", on: connection)
        try await exec(
            """
            CREATE TABLE \(q(apostrophe)) (id int, \(q("p'id")) int,
                CONSTRAINT \(q("fk'name")) FOREIGN KEY (\(q("p'id"))) REFERENCES \(q(bracket)) (id))
            """,
            on: connection
        )
        try await exec("CREATE INDEX \(q("ix'name")) ON \(q(apostrophe)) (\(q("p'id")))", on: connection)
        let introspector = connection.introspector
        let refs = [bracket, apostrophe].map { ref($0) }

        let summaries = try await introspector.objectSummaries(scope: .schemas([schema]))
        for ref in refs {
            let summary = try #require(summaries.first { $0.ref == ref }, "\(ref) is not listed")
            #expect(summary.kind == .table)
            #expect(summary.fingerprint != nil)
        }

        let details = try await introspector.tableDetails(refs)
        #expect(details.count == 2)
        let bracketDetail = try #require(details.first { $0.ref == refs[0] })
        #expect(bracketDetail.columns.map(\.name) == ["id", "it's", "odd]col"])
        #expect(bracketDetail.columns.first?.isPrimaryKey == true)
        let apostropheDetail = try #require(details.first { $0.ref == refs[1] })
        #expect(apostropheDetail.columns.map(\.name) == ["id", "p'id"])
        #expect(apostropheDetail.indexes == [IndexInfo(name: "ix'name", isUnique: false, columns: ["p'id"])])
        // The per-table path asks for the object by its unbracketed name, and
        // does not find a table whose name holds a closing bracket, so only
        // the other table is compared with it.
        let single = try await introspector.tableDetail(refs[1])
        #expect(!single.columns.isEmpty)
        #expect(apostropheDetail.columns == single.columns)
        #expect(apostropheDetail.indexes == single.indexes)

        let relations = try await introspector.foreignKeys(scope: .schemas([schema])).filter { $0.source == refs[1] }
        #expect(relations == [
            ForeignKeyRelation(
                source: refs[1], column: "p'id", target: refs[0], referencedColumn: "id", constraintName: "fk'name"
            ),
        ])
    }

    // A name read as a non-Unicode literal passes through the code page of the
    // database's collation, which has no room for every character.
    @Test func unicodeNamesRoundTrip() async throws {
        let table = "bd_bulk_tiếng_việt", schemaName = "bd_bulk_sơ_đồ"
        let drops = [
            "DROP TABLE IF EXISTS " + dialect.quoteIdentifier(table),
            "DROP TABLE IF EXISTS \(dialect.quoteIdentifier(schemaName)).t",
            "DROP SCHEMA IF EXISTS " + dialect.quoteIdentifier(schemaName),
        ]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        let q = dialect.quoteIdentifier
        try await exec("CREATE TABLE \(q(table)) (id int PRIMARY KEY, \(q("tên")) nvarchar(10))", on: connection)
        try await exec("CREATE SCHEMA \(q(schemaName))", on: connection)
        try await exec("CREATE TABLE \(q(schemaName)).t (id int PRIMARY KEY)", on: connection)
        let introspector = connection.introspector
        let named = ref(table), inSchema = ref("t", in: schemaName)

        let summaries = try await introspector.objectSummaries(scope: .schemas([schema, schemaName]))
        #expect(summaries.contains { $0.ref == named && $0.fingerprint != nil })
        #expect(summaries.contains { $0.ref == inSchema && $0.fingerprint != nil })
        #expect(try await introspector.objectSummaries(scope: .schemas([schemaName])).map(\.ref) == [inSchema])
        _ = try await token(connection, scope: .schemas([schemaName]))

        let details = try await introspector.tableDetails([named, inSchema])
        #expect(details.count == 2)
        #expect(details.first { $0.ref == named }?.columns.map(\.name) == ["id", "tên"])
        #expect(details.first { $0.ref == inSchema }?.columns.map(\.name) == ["id"])
    }

    // A default bound with `sp_bindefault`, the feature that `CREATE DEFAULT`
    // belongs to, has no row in `sys.default_constraints`, but the per-table
    // path reads its text, so the bulk path has to as well.
    @Test func legacyBoundDefaultReadsLikeThePerTablePath() async throws {
        let drops = ["DROP TABLE IF EXISTS bd_bulk_a", "DROP DEFAULT IF EXISTS bd_bulk_legacy"]
        let connection = try await openConnection(dropping: drops)
        defer { closeAfterDropping(drops, on: connection) }
        try await exec("CREATE TABLE bd_bulk_a (id int PRIMARY KEY, x int, y int DEFAULT 3)", on: connection)
        try await exec("CREATE DEFAULT bd_bulk_legacy AS 7", on: connection)
        try await exec("EXEC sp_bindefault 'bd_bulk_legacy', 'bd_bulk_a.x'", on: connection)
        let introspector = connection.introspector
        let a = ref("bd_bulk_a")

        let single = try await introspector.tableDetail(a)
        let bulk = try #require(try await introspector.tableDetails([a]).first)

        let legacy = try #require(single.columns.first { $0.name == "x" }?.defaultValue, "the per-table path reads it")
        #expect(legacy.contains("bd_bulk_legacy"))
        #expect(bulk.columns == single.columns)
    }

    // MARK: - Contract

    @Test func bulkIntrospectionIsOffered() async throws {
        let connection = try await openConnection()
        defer { Task { await connection.close() } }

        #expect(connection.introspector.bulkIntrospection)
    }
}
