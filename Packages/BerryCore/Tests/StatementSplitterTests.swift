import Foundation
import Testing

@testable import BerryCore

@Suite("StatementSplitter")
struct StatementSplitterTests {
    @Test func splitsSimpleStatements() {
        let statements = StatementSplitter.split("SELECT 1; SELECT 2;\nSELECT 3")
        #expect(statements.map(\.sql) == ["SELECT 1", "SELECT 2", "SELECT 3"])
    }

    @Test func ignoresSemicolonsInStrings() {
        let statements = StatementSplitter.split("SELECT 'a;b'; SELECT 'it''s;ok'")
        #expect(statements.map(\.sql) == ["SELECT 'a;b'", "SELECT 'it''s;ok'"])
    }

    @Test func ignoresSemicolonsInQuotedIdentifiersAndBackticks() {
        let statements = StatementSplitter.split(#"SELECT "col;1" FROM t; SELECT `x;y` FROM u"#)
        #expect(statements.count == 2)
    }

    @Test func ignoresSemicolonsInComments() {
        let script = """
        SELECT 1; -- comment; with semicolon
        /* block; comment */ SELECT 2
        """
        let statements = StatementSplitter.split(script)
        #expect(statements.map(\.sql).first == "SELECT 1")
        #expect(statements.count == 2)
        #expect(statements[1].sql.hasSuffix("SELECT 2"))
    }

    @Test func handlesDollarQuoting() {
        let script = "CREATE FUNCTION f() RETURNS void AS $body$ BEGIN; END; $body$ LANGUAGE plpgsql; SELECT 1"
        let statements = StatementSplitter.split(script)
        #expect(statements.count == 2)
        #expect(statements[0].sql.contains("$body$ BEGIN; END; $body$"))
        #expect(statements[1].sql == "SELECT 1")
    }

    @Test func rangesPointBackIntoScript() {
        let script = "SELECT 1;  SELECT 22"
        let statements = StatementSplitter.split(script)
        let text = script as NSString
        #expect(text.substring(with: statements[0].range) == "SELECT 1")
        #expect(text.substring(with: statements[1].range) == "SELECT 22")
    }

    @Test func statementAtCursorPicksTheRightOne() {
        let script = "SELECT 1;\nSELECT 2;\nSELECT 3"
        // Cursor inside "SELECT 2".
        let cursor = (script as NSString).range(of: "SELECT 2").location + 3
        #expect(StatementSplitter.statement(at: cursor, in: script)?.sql == "SELECT 2")
        // Cursor at very end → last statement.
        #expect(StatementSplitter.statement(at: script.utf16.count, in: script)?.sql == "SELECT 3")
    }

    @Test func emptyAndWhitespaceOnlyScripts() {
        #expect(StatementSplitter.split("").isEmpty)
        #expect(StatementSplitter.split("  ;;  ;\n").isEmpty)
    }
}
