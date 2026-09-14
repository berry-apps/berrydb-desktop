import AppKit
import Foundation
import Testing
@testable import BerryUI

@MainActor
@Suite("SQLEditor Highlighting Tests")
struct SQLEditorHighlightTests {
    private func color(at string: String, sub: String, in storage: NSTextStorage) -> NSColor? {
        let nsString = string as NSString
        let range = nsString.range(of: sub)
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
    }

    @Test("Highlights SQL keywords in keyword color")
    func testKeywordHighlighting() {
        let sql = "SELECT id, name FROM users WHERE active = TRUE ORDER BY id DESC LIMIT 10;"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let selectColor = color(at: sql, sub: "SELECT", in: storage)
        let fromColor = color(at: sql, sub: "FROM", in: storage)
        let whereColor = color(at: sql, sub: "WHERE", in: storage)
        let orderColor = color(at: sql, sub: "ORDER", in: storage)
        let limitColor = color(at: sql, sub: "LIMIT", in: storage)

        #expect(selectColor == SQLSyntaxHighlighter.keywordColor)
        #expect(fromColor == SQLSyntaxHighlighter.keywordColor)
        #expect(whereColor == SQLSyntaxHighlighter.keywordColor)
        #expect(orderColor == SQLSyntaxHighlighter.keywordColor)
        #expect(limitColor == SQLSyntaxHighlighter.keywordColor)
    }

    @Test("Highlights built-in and custom SQL functions in function color")
    func testFunctionHighlighting() {
        let sql = "SELECT COUNT(*), NOW(), COALESCE(email, 'unknown'), my_custom_func(123) FROM accounts;"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let countColor = color(at: sql, sub: "COUNT", in: storage)
        let nowColor = color(at: sql, sub: "NOW", in: storage)
        let coalesceColor = color(at: sql, sub: "COALESCE", in: storage)
        let customColor = color(at: sql, sub: "my_custom_func", in: storage)

        #expect(countColor == SQLSyntaxHighlighter.functionColor)
        #expect(nowColor == SQLSyntaxHighlighter.functionColor)
        #expect(coalesceColor == SQLSyntaxHighlighter.functionColor)
        #expect(customColor == SQLSyntaxHighlighter.functionColor)
    }

    @Test("Highlights SQL data types in type color")
    func testTypeHighlighting() {
        let sql = "CREATE TABLE items (id BIGINT, name VARCHAR(255), is_active BOOLEAN, data JSONB, created_at TIMESTAMPTZ);"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let bigintColor = color(at: sql, sub: "BIGINT", in: storage)
        let varcharColor = color(at: sql, sub: "VARCHAR", in: storage)
        let boolColor = color(at: sql, sub: "BOOLEAN", in: storage)
        let jsonbColor = color(at: sql, sub: "JSONB", in: storage)
        let timestampColor = color(at: sql, sub: "TIMESTAMPTZ", in: storage)

        #expect(bigintColor == SQLSyntaxHighlighter.typeColor)
        #expect(varcharColor == SQLSyntaxHighlighter.typeColor)
        #expect(boolColor == SQLSyntaxHighlighter.typeColor)
        #expect(jsonbColor == SQLSyntaxHighlighter.typeColor)
        #expect(timestampColor == SQLSyntaxHighlighter.typeColor)
    }

    @Test("Highlights quoted identifiers (double quotes, backticks, brackets)")
    func testQuotedIdentifierHighlighting() {
        let sql = "SELECT \"order id\", `product_code`, [unit_price] FROM \"sales_records\";"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let dquoteColor = color(at: sql, sub: "\"order id\"", in: storage)
        let btickColor = color(at: sql, sub: "`product_code`", in: storage)
        let bracketColor = color(at: sql, sub: "[unit_price]", in: storage)

        #expect(dquoteColor == SQLSyntaxHighlighter.quotedIdentifierColor)
        #expect(btickColor == SQLSyntaxHighlighter.quotedIdentifierColor)
        #expect(bracketColor == SQLSyntaxHighlighter.quotedIdentifierColor)
    }

    @Test("Highlights single-quoted strings and dollar-quoted strings in string color")
    func testStringHighlighting() {
        let sql = "SELECT 'hello world', $$dollar string with SELECT and FROM$$;"
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let singleQuoteColor = color(at: sql, sub: "'hello world'", in: storage)
        let dollarColor = color(at: sql, sub: "$$dollar string with SELECT and FROM$$", in: storage)

        #expect(singleQuoteColor == SQLSyntaxHighlighter.stringColor)
        #expect(dollarColor == SQLSyntaxHighlighter.stringColor)
    }

    @Test("Comments override keywords and strings")
    func testCommentHighlighting() {
        let sql = """
        -- SELECT * FROM hidden
        SELECT 1; /* block SELECT COUNT(*) comment */
        # mysql style comment with WHERE 1=1
        """
        let storage = NSTextStorage(string: sql)
        SQLSyntaxHighlighter.highlight(storage)

        let lineCommentColor = color(at: sql, sub: "-- SELECT * FROM hidden", in: storage)
        let blockCommentColor = color(at: sql, sub: "/* block SELECT COUNT(*) comment */", in: storage)
        let hashCommentColor = color(at: sql, sub: "# mysql style comment with WHERE 1=1", in: storage)
        let realSelectColor = color(at: sql, sub: "SELECT 1", in: storage)

        #expect(lineCommentColor == SQLSyntaxHighlighter.commentColor)
        #expect(blockCommentColor == SQLSyntaxHighlighter.commentColor)
        #expect(hashCommentColor == SQLSyntaxHighlighter.commentColor)
        #expect(realSelectColor == SQLSyntaxHighlighter.keywordColor)
    }

    @Test("Skips highlighting on texts larger than 256KB to maintain UI responsiveness")
    func testLargeTextHighlightGuard() {
        let base = "SELECT 1;\n"
        let repeatCount = (256 * 1024 / base.utf8.count) + 10
        let largeSQL = String(repeating: base, count: repeatCount)
        let storage = NSTextStorage(string: largeSQL)
        SQLSyntaxHighlighter.highlight(storage)

        let firstCharColor = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(firstCharColor == NSColor.labelColor)
    }
}
