import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverMySQL

@Suite("MySQL placeholder count")
struct MySQLPlaceholderTests {
    @Test func everyBareQuestionMarkCounts() {
        #expect(MySQLPlaceholders.count(in: "SELECT 1") == 0)
        #expect(MySQLPlaceholders.count(in: "SELECT ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ?, ? FROM t WHERE a = ?") == 3)
    }

    @Test func aQuestionMarkNextToAnOperatorCounts() {
        #expect(MySQLPlaceholders.count(in: "SELECT ?+?, (?)-?, ?=?, ?*?/?") == 9)
        #expect(MySQLPlaceholders.count(in: "SELECT a FROM t WHERE a>=?AND b<>?OR c IN(?,?)") == 4)
    }

    @Test func aQuestionMarkInAStringDoesNotCount() {
        #expect(MySQLPlaceholders.count(in: "SELECT '?', \"?\"") == 0)
        #expect(MySQLPlaceholders.count(in: "SELECT 'it''s ?', ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT \"say \"\"?\"\"\", ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT _utf8mb4'?', X'3F', ?") == 1)
    }

    /// A backslash escapes the next character in either kind of string, so
    /// an escaped quote does not end it and an escaped backslash does not
    /// escape the quote after it.
    @Test func aBackslashEscapesInAString() {
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\'?', ?"#) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT "a\"?", ?"#) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\\', ?"#) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\\\'?', ?"#) == 1)
    }

    /// A backslash is an ordinary character in a quoted identifier.
    @Test func aQuestionMarkInAQuotedIdentifierDoesNotCount() {
        #expect(MySQLPlaceholders.count(in: "SELECT `a?` FROM t WHERE b = ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT `a``?` FROM t WHERE b = ?") == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT `a\`, ? FROM t"#) == 1)
    }

    @Test func aQuestionMarkInADashCommentDoesNotCount() {
        #expect(MySQLPlaceholders.count(in: "SELECT ? -- ?\n, ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ? --\t?\n") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ? --") == 1)
        // A carriage return does not end the comment; a line feed does.
        #expect(MySQLPlaceholders.count(in: "SELECT ? -- \r?") == 1)
    }

    /// Without whitespace or a control character after it, `--` is two
    /// minus signs.
    @Test func dashDashWithoutASpaceIsNotAComment() {
        #expect(MySQLPlaceholders.count(in: "SELECT 1--?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ?--?") == 2)
    }

    @Test func aQuestionMarkInAHashCommentDoesNotCount() {
        #expect(MySQLPlaceholders.count(in: "SELECT ? # ?\n, ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ?#?") == 1)
    }

    @Test func aQuestionMarkInABlockCommentDoesNotCount() {
        #expect(MySQLPlaceholders.count(in: "SELECT /* ? */ ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT /*+ MAX_EXECUTION_TIME(?) */ ?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ?/*?*/?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT /**/?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT /*/ ? */ ?") == 1)
    }

    /// The first `*/` ends a block comment whatever it holds.
    @Test func blockCommentsDoNotNest() {
        #expect(MySQLPlaceholders.count(in: "SELECT /* /* ? */ ?") == 1)
    }

    /// The server refuses an unclosed string or comment; nothing after its
    /// start counts.
    @Test func nothingCountsAfterAnUnclosedStringOrComment() {
        #expect(MySQLPlaceholders.count(in: "SELECT ?, '?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ?, `?") == 1)
        #expect(MySQLPlaceholders.count(in: "SELECT ?, /* ?") == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT ?, 'a\"#) == 1)
    }

    @Test func theQuotingFollowsTheSQLMode() {
        let serverDefault = MySQLPlaceholders.Quoting(sqlMode: "ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES")
        let noBackslashEscapes = MySQLPlaceholders.Quoting(sqlMode: "ONLY_FULL_GROUP_BY,NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES")
        let ansiQuotes = MySQLPlaceholders.Quoting(sqlMode: "ANSI_QUOTES,STRICT_TRANS_TABLES")

        #expect(serverDefault == .serverDefault)
        #expect(MySQLPlaceholders.Quoting(sqlMode: "") == .serverDefault)
        #expect(!noBackslashEscapes.backslashEscapes && !noBackslashEscapes.doubleQuotesIdentifier)
        #expect(ansiQuotes.backslashEscapes && ansiQuotes.doubleQuotesIdentifier)
    }

    /// Under NO_BACKSLASH_ESCAPES a backslash is an ordinary character in
    /// either kind of string.
    @Test func withoutBackslashEscapesAQuoteAfterABackslashEndsTheString() {
        let quoting = MySQLPlaceholders.Quoting(sqlMode: "NO_BACKSLASH_ESCAPES")
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\', '?'"#, quoting: quoting) == 0)
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\', ?, "b\", ?"#, quoting: quoting) == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT 'it''s ?', ?", quoting: quoting) == 1)
    }

    /// Under ANSI_QUOTES `"…"` is an identifier, in which a backslash is an
    /// ordinary character; a single-quoted string keeps its escapes.
    @Test func withAnsiQuotesADoubleQuotedTextIsAnIdentifier() {
        let quoting = MySQLPlaceholders.Quoting(sqlMode: "ANSI_QUOTES")
        #expect(MySQLPlaceholders.count(in: #"SELECT 1 AS "a\", ?"#, quoting: quoting) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT 1 AS "a""?", ?"#, quoting: quoting) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\'?', ?"#, quoting: quoting) == 1)
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\', ?"#, quoting: quoting) == 0)
    }

    @Test func withBothModesNoQuoteEscapesWithABackslash() {
        let quoting = MySQLPlaceholders.Quoting(sqlMode: "ANSI_QUOTES,NO_BACKSLASH_ESCAPES")
        #expect(MySQLPlaceholders.count(in: #"SELECT 'a\', ? AS "b\", ?"#, quoting: quoting) == 2)
    }

    @Test func aQuoteInsideACommentDoesNotOpenAString() {
        #expect(MySQLPlaceholders.count(in: "SELECT ? -- it's\n, ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ? /* it's */ , ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ? # it's\n, ?") == 2)
    }
}

@Suite("MySQL parameter refusals")
struct MySQLParameterRefusalTests {
    private func refusal(_ sql: String, _ parameters: Int, _ session: MySQLPlaceholders.Session = .serverDefault) -> String? {
        MySQLPlaceholders.refusal(of: sql, parameters: parameters, in: session)?.detail
    }

    @Test func aMatchingCountIsNotRefused() {
        #expect(refusal("SELECT ?, ?", 2) == nil)
    }

    @Test func aMismatchedCountIsRefused() {
        #expect(refusal("SELECT ?", 2) == "The statement has 1 placeholder and 2 parameters were given.")
    }

    /// The server ends the text at a NUL after `;`, and a comment at a NUL,
    /// where this count reads on.
    @Test func aTextWithANulIsRefusedInEverySession() {
        let message = "Parameters are not bound in a text that holds a NUL character; write the values into the statement instead."
        #expect(refusal("SELECT ?;\u{0}?", 2) == message)
        #expect(refusal("SELECT ?;\u{0}?", 1) == message)
        #expect(refusal("SELECT '\u{0}', ?", 1, MySQLPlaceholders.Session(sqlMode: "", characterSetClient: "utf8mb4")) == message)
    }

    @Test func modesThatQuoteOtherwiseAreRefused() {
        for mode in ["MSSQL", "ORACLE"] {
            let session = MySQLPlaceholders.Session(sqlMode: "PIPES_AS_CONCAT,ANSI_QUOTES,\(mode),NO_KEY_OPTIONS", characterSetClient: "utf8mb4")
            #expect(
                refusal("SELECT ?", 1, session)
                    == "Parameters are not bound under the session's \(mode) SQL mode; write the values into the statement instead."
            )
        }
    }

    /// A character set whose multi-byte characters can end in the byte of a
    /// backslash, read here as an escape.
    @Test func aMultiByteClientCharacterSetIsRefused() {
        for characterSet in ["gbk", "big5", "sjis", "cp932", "gb18030", "ujis"] {
            let session = MySQLPlaceholders.Session(sqlMode: "", characterSetClient: characterSet)
            #expect(
                refusal("SELECT ?", 1, session)
                    == "Parameters are not bound with the session's \(characterSet) client character set; write the values into the statement instead."
            )
        }
    }

    @Test func characterSetsWithoutMultiByteCharactersOrInUTF8AreCounted() {
        for characterSet in ["utf8mb4", "utf8mb3", "utf8", "latin1", "ascii", "binary", "UTF8MB4"] {
            let session = MySQLPlaceholders.Session(sqlMode: "ANSI_QUOTES", characterSetClient: characterSet)
            #expect(refusal(#"SELECT "a\", ?"#, 1, session) == nil, "\(characterSet)")
            #expect(session.quoting.doubleQuotesIdentifier)
        }
    }

    /// What `prepareReadOnly()` reads back: the lock wait, the SQL mode and
    /// the client character set, in one row.
    @Test func theSessionIsReadFromOneRowOfThreeValues() throws {
        let session = try MySQLDriverConnection.readOnlySession(from: [[.int(5), .text("NO_BACKSLASH_ESCAPES"), .text("gbk")]])
        #expect(session == MySQLPlaceholders.Session(sqlMode: "NO_BACKSLASH_ESCAPES", characterSetClient: "gbk"))
        #expect(try MySQLDriverConnection.readOnlySession(from: [[.text("5"), .bytes(Data("ANSI_QUOTES".utf8)), .text("utf8mb4")]])
            == MySQLPlaceholders.Session(sqlMode: "ANSI_QUOTES", characterSetClient: "utf8mb4"))
    }

    @Test func aReadBackOfTheWrongShapeSaysSo() {
        let shapes: [[[BerryValue]]] = [
            [],
            [[.int(5), .text("")]],
            [[.int(5), .text(""), .text("utf8mb4")], [.int(5), .text(""), .text("utf8mb4")]],
        ]
        for settings in shapes {
            let error = #expect(throws: DriverError.self) { try MySQLDriverConnection.readOnlySession(from: settings) }
            #expect(error?.detail.contains("did not read back as one row of three values") == true, "\(String(describing: error))")
        }
        let lockWait = #expect(throws: DriverError.self) {
            try MySQLDriverConnection.readOnlySession(from: [[.int(7), .text(""), .text("utf8mb4")]])
        }
        #expect(lockWait?.detail.contains("lock_wait_timeout did not read back as 5") == true, "\(String(describing: lockWait))")
    }
}
