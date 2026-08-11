import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

private struct DoubleQuoteDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
}

/// Visual filter builder (DL-02).
@Suite("FilterBuilder (DL-02)")
struct FilterBuilderTests {
    private let dialect = DoubleQuoteDialect()

    private func condition(_ column: String, _ op: FilterBuilder.Operator, _ value: String = "")
        -> FilterBuilder.Condition {
        FilterBuilder.Condition(column: column, op: op, value: value)
    }

    @Test func rendersComparisonWithQuotedIdentifierAndValue() {
        #expect(FilterBuilder.render(condition("age", .greaterOrEqual, "18"), dialect: dialect)
            == "\"age\" >= '18'")
        #expect(FilterBuilder.render(condition("name", .notEquals, "Al"), dialect: dialect)
            == "\"name\" <> 'Al'")
    }

    @Test func rendersLikeForContainsAndStartsWith() {
        #expect(FilterBuilder.render(condition("email", .contains, "berry"), dialect: dialect)
            == "\"email\" LIKE '%berry%'")
        #expect(FilterBuilder.render(condition("email", .startsWith, "a"), dialect: dialect)
            == "\"email\" LIKE 'a%'")
    }

    @Test func nullOperatorsNeedNoValue() {
        #expect(FilterBuilder.render(condition("deleted_at", .isNull), dialect: dialect)
            == "\"deleted_at\" IS NULL")
        #expect(FilterBuilder.render(condition("deleted_at", .isNotNull), dialect: dialect)
            == "\"deleted_at\" IS NOT NULL")
        #expect(FilterBuilder.Operator.isNull.needsValue == false)
        #expect(FilterBuilder.Operator.equals.needsValue == true)
    }

    @Test func escapesSingleQuotesInValues() {
        #expect(FilterBuilder.render(condition("note", .equals, "O'Brien"), dialect: dialect)
            == "\"note\" = 'O''Brien'")
    }

    @Test func skipsIncompleteConditions() {
        // Empty value on a value operator → dropped; empty column → dropped.
        #expect(FilterBuilder.render(condition("age", .equals, ""), dialect: dialect) == nil)
        #expect(FilterBuilder.render(condition("", .isNull), dialect: dialect) == nil)
    }

    @Test func joinsValidConditionsWithAnd() {
        let clause = FilterBuilder.whereClause([
            condition("age", .greater, "18"),
            condition("name", .equals, ""),        // dropped
            condition("active", .isNull),
        ], dialect: dialect)
        #expect(clause == "\"age\" > '18' AND \"active\" IS NULL")
    }
}
