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

    @Test func aQuoteInsideACommentDoesNotOpenAString() {
        #expect(MySQLPlaceholders.count(in: "SELECT ? -- it's\n, ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ? /* it's */ , ?") == 2)
        #expect(MySQLPlaceholders.count(in: "SELECT ? # it's\n, ?") == 2)
    }
}
