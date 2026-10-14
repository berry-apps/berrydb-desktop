import Foundation
import Testing

@testable import BerryDriverKit

@Suite("Read-only allowlist")
struct ReadOnlyAllowlistTests {
    private func runs(_ sql: String, on allowlist: ReadOnlyAllowlist) -> Bool {
        allowlist.refusal(of: sql) == nil
    }

    @Test func aReadRunsOnEveryEngine() {
        for allowlist in [ReadOnlyAllowlist.postgres, .mysql, .sqlite] {
            for sql in [
                "SELECT 1", "  select 1", "\n\tSelect 1", "SELECT(1)", "SELECT*FROM t",
                "WITH x AS (SELECT 1) SELECT * FROM x", "show tables", "EXPLAIN SELECT 1", "TABLE t", "VALUES (1)",
            ] {
                #expect(runs(sql, on: allowlist), "\(sql)")
            }
        }
    }

    @Test func describeRunsOnMySQLOnly() {
        #expect(runs("DESCRIBE t", on: .mysql))
        #expect(runs("desc t", on: .mysql))
        #expect(!runs("DESCRIBE t", on: .postgres))
        #expect(!runs("DESC t", on: .sqlite))
    }

    @Test func anyOtherStatementIsRefused() {
        for allowlist in [ReadOnlyAllowlist.postgres, .mysql, .sqlite] {
            for sql in [
                "INSERT INTO t VALUES (1)", "DROP TABLE t", "CALL writer()", "DO $$ BEGIN NULL; END $$",
                "SET TRANSACTION READ WRITE", "SET STATEMENT transaction_read_only=0 FOR DROP TABLE t",
                "BEGIN NOT ATOMIC COMMIT; END", "PRAGMA query_only = OFF", "(SELECT 1)",
            ] {
                #expect(!runs(sql, on: allowlist), "\(sql)")
            }
        }
    }

    /// A word that only begins like a lead is another word. So is one that
    /// becomes a lead only through Unicode case mapping (long s, dotless i)
    /// or once a leading byte-order mark is dropped: the first word the
    /// check sees has to be the first word the server runs.
    @Test func aLeadIsAWholeWord() {
        for sql in [
            "SELECTX 1", "SELECT_1", "SELECT$1", "SELECT1", "WITHIN", "SHOWS", "SELECTé 1", "\u{A0}SELECT 1",
            "\u{17F}elect 1", "w\u{131}th x AS (SELECT 1) SELECT 1", "expla\u{131}n SELECT 1", "value\u{17F} (1)",
            "de\u{17F}c t", "\u{FEFF}SELECT 1",
        ] {
            #expect(!runs(sql, on: .mysql), "\(sql)")
            #expect(!runs(sql, on: .postgres), "\(sql)")
            #expect(!runs(sql, on: .sqlite), "\(sql)")
        }
    }

    @Test func anEmptyTextIsRefused() {
        for sql in ["", "   ", "-- only a comment", "/* only a comment */", "/* SELECT 1"] {
            #expect(!runs(sql, on: .postgres), "\(sql)")
            #expect(!runs(sql, on: .mysql), "\(sql)")
            #expect(!runs(sql, on: .sqlite), "\(sql)")
        }
    }

    @Test func leadingCommentsAreSkipped() {
        for allowlist in [ReadOnlyAllowlist.postgres, .mysql, .sqlite] {
            #expect(runs("-- note\nSELECT 1", on: allowlist))
            #expect(runs("/* note */ SELECT 1", on: allowlist))
            #expect(runs("/* a */ -- b\n /* c */SELECT 1", on: allowlist))
            #expect(!runs("-- note\nDELETE FROM t", on: allowlist))
            #expect(!runs("/* SELECT */ DELETE FROM t", on: allowlist))
        }
    }

    /// MySQL and MariaDB read `#` as a comment, and `--` only before
    /// whitespace or a control character; both end at a line feed alone.
    /// Verified against MySQL 8.4.11 and MariaDB 11.8.9.
    @Test func mySQLCommentsEndWhereTheServersDo() {
        #expect(runs("# note\nSELECT 1", on: .mysql))
        #expect(!runs("# note\nSELECT 1", on: .postgres))
        #expect(!runs("--x\nSELECT 1", on: .mysql))
        #expect(runs("--\tnote\nSELECT 1", on: .mysql))
        #expect(!runs("-- note\rSELECT 1\nDELETE FROM t", on: .mysql))
        #expect(!runs("# note\rSELECT 1\nDELETE FROM t", on: .mysql))
    }

    /// PostgreSQL ends `--` at a carriage return too and nests block
    /// comments; SQLite ends `--` at a line feed alone. Verified against
    /// PostgreSQL 16.15 and SQLite 3.51.0.
    @Test func postgresAndSQLiteCommentsEndWhereTheServersDo() {
        #expect(runs("--x\nSELECT 1", on: .postgres))
        #expect(runs("-- note\rSELECT 1", on: .postgres))
        #expect(!runs("-- note\rDELETE FROM t\nSELECT 1", on: .postgres))
        #expect(!runs("/* /* */ SELECT 1 */ DO $$ BEGIN NULL; END $$", on: .postgres))
        #expect(runs("/* /* */ */ SELECT 1", on: .postgres))
        #expect(runs("/* /* */ SELECT 1", on: .mysql))
        #expect(runs("/* /* */ SELECT 1", on: .sqlite))
        #expect(!runs("-- note\rSELECT 1\nDELETE FROM t", on: .sqlite))
    }

    /// MySQL runs the text of `/*! … */` and MariaDB that of `/*M! … */`
    /// as SQL, wherever it appears; MariaDB reads a lowercase `/*m!` as a
    /// plain comment. Verified against MySQL 8.4.11 and MariaDB 11.8.9.
    @Test func anExecutableCommentIsRefusedOnMySQL() {
        #expect(!runs("SELECT 1 /*!, (SELECT 2) */", on: .mysql))
        #expect(!runs("/*!50000 DROP TABLE t */ SELECT 1", on: .mysql))
        #expect(!runs("SELECT 1 /*M!100000 , 2 */", on: .mysql))
        #expect(!runs("SELECT '/*!'", on: .mysql))
        #expect(runs("SELECT 1 /*m! plain */", on: .mysql))
        #expect(runs("SELECT 1 /*! not a MySQL comment here */", on: .postgres))
    }

    /// The same error the SQLite read-only path gives a text of several
    /// statements: a failed query with no server code, since nothing ran.
    @Test func theRefusalIsAFailedQueryWithNoCode() {
        guard case let .queryFailed(message, code)? = ReadOnlyAllowlist.mysql.refusal(of: "CALL writer()") else {
            Issue.record("expected queryFailed")
            return
        }
        #expect(code == nil)
        #expect(message.contains("SELECT"))
        #expect(message.contains("DESCRIBE"))
        guard case let .queryFailed(comment, nil)? = ReadOnlyAllowlist.mysql.refusal(of: "SELECT 1 /*! , 2 */") else {
            Issue.record("expected queryFailed")
            return
        }
        #expect(comment.contains("executable comment"))
    }
}
