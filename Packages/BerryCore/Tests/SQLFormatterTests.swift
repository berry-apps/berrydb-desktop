import Foundation
import Testing

@testable import BerryCore

@Suite("SQL formatter")
struct SQLFormatterTests {
    @Test func breaksMajorClausesOntoOwnLines() {
        let out = SQLFormatter.format("select id, name from users where id = 1 order by name")
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "SELECT id,")
        #expect(lines.contains("FROM users"))
        #expect(lines.contains("WHERE id = 1"))
        #expect(lines.contains("ORDER BY name"))
    }

    @Test func keepsJoinModifierAttachedToJoin() {
        let out = SQLFormatter.format("select * from a left join b on a.id = b.a_id")
        #expect(out.contains("LEFT JOIN b"))
        // The JOIN clause head must break onto its own line.
        #expect(out.contains("\nLEFT JOIN"))
    }

    @Test func preservesStringLiteralsVerbatim() {
        let out = SQLFormatter.format("select 'from where select' as note")
        #expect(out.contains("'from where select'"))
        // Keywords inside the string must not be uppercased or broken.
        #expect(!out.contains("'FROM"))
    }

    @Test func indentsParenthesisedGroups() {
        let out = SQLFormatter.format("select * from t where id in (1, 2, 3)")
        #expect(out.contains("("))
        #expect(out.contains("1,"))
    }

    @Test func uppercasesBareKeywordsOnly() {
        let out = SQLFormatter.format("select distinct a from t")
        #expect(out.contains("DISTINCT"))
        #expect(out.contains("a"))
    }

    @Test func emptyInputRoundTrips() {
        #expect(SQLFormatter.format("") == "")
        #expect(SQLFormatter.format("   ") == "")
    }

    @Test func lineCommentSurvives() {
        let out = SQLFormatter.format("select 1 -- trailing note\nfrom t")
        #expect(out.contains("-- trailing note"))
    }

    /// Multi-char operators must survive formatting intact — splitting them
    /// (`>=`→`> =`, `::`→`: :`) produced SQL that no longer executed.
    @Test func keepsMultiCharOperatorsIntact() {
        #expect(SQLFormatter.format("select * from t where a >= 1 and b <= 2")
            .contains("a >= 1"))
        #expect(SQLFormatter.format("select * from t where a >= 1 and b <= 2")
            .contains("b <= 2"))
        #expect(SQLFormatter.format("select * from t where a <> 1").contains("a <> 1"))
        #expect(SQLFormatter.format("select * from t where a != 1").contains("a != 1"))
        // Cast binds tight; concatenation stays intact.
        #expect(SQLFormatter.format("select id::text from t").contains("id::text"))
        #expect(SQLFormatter.format("select a || b from t").contains("a || b"))
        // JSON path operators (Postgres) stay tight and unbroken.
        #expect(SQLFormatter.format("select data->>'k' from t").contains("data->>'k'"))
    }

    /// A formatted statement must not gain spaces that break tokens the parser
 /// reads as a unit — the whole point of the fix.
    @Test func formattedOutputHasNoBrokenOperators() {
        let out = SQLFormatter.format("select * from t where a>=1 and c::int=b->>'x'")
        for broken in ["> =", "< =", ": :", "- >", "| |", "> >"] {
            #expect(!out.contains(broken), "formatter split an operator: \(broken)")
        }
    }

    @Test func functionCallHasNoSpaceAfterParen() {
        let out = SQLFormatter.format("select count(*) from t")
        #expect(out.contains("count(*)"))
    }

    /// SELECT columns after the first should be indented under the clause, not
    /// flush with the keywords — the readability fix.
    @Test func indentsSelectListContinuation() {
        let out = SQLFormatter.format("select id, name, email from users")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "SELECT id,")
        #expect(lines.contains("    name,"))
        #expect(lines.contains("    email"))
        #expect(lines.contains("FROM users"))
    }
}
