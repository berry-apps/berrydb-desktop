import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

@Suite("CompletionProvider")
struct CompletionProviderTests {
    private let objects = [
        SchemaObject(kind: .table, name: "users"),
        SchemaObject(kind: .table, name: "orders"),
        SchemaObject(kind: .view, name: "user_stats"),
    ]
    private let columns = [
        "users": ["id", "email", "created_at"],
        "orders": ["id", "user_id", "total"],
    ]

    private func complete(_ script: String, cursorAfter marker: String) -> [CompletionProvider.Suggestion] {
        let cursor = (script as NSString).range(of: marker).upperBound
        return CompletionProvider.suggestions(
            script: script, utf16Cursor: cursor,
            objects: objects, columnsByTable: columns
        )
    }

    @Test func suggestsTablesAfterFrom() {
        let suggestions = complete("SELECT * FROM ", cursorAfter: "FROM ")
        #expect(suggestions.prefix(3).allSatisfy {
            if case .table = $0 { true } else { false }
        })
        #expect(suggestions.contains(.table("users")))
        #expect(suggestions.contains(.table("user_stats")))
    }

 // subsequence match offsets for highlighting the typed chars.
    @Test func matchOffsetsHighlightSubsequence() {
        #expect(CompletionProvider.matchOffsets(of: "us", in: "users") == [0, 1])
        #expect(CompletionProvider.matchOffsets(of: "ur", in: "users") == [0, 3]) // u..s..r? -> u(0) r(3)
        #expect(CompletionProvider.matchOffsets(of: "AC", in: "Accounts") == [0, 1]) // case-insensitive
        #expect(CompletionProvider.matchOffsets(of: "xyz", in: "users") == [])
        #expect(CompletionProvider.matchOffsets(of: "", in: "users") == [])
    }

 // statement + transaction keywords are completable, not just DML clauses.
    @Test func suggestsStatementAndTransactionKeywords() {
        for keyword in ["ROLLBACK", "COMMIT", "BEGIN", "TRUNCATE", "RETURNING", "ANALYZE"] {
            let prefix = String(keyword.prefix(3))
            let hits = complete(prefix, cursorAfter: prefix)
            #expect(hits.contains(.keyword(keyword)), "expected keyword \(keyword) for prefix \(prefix)")
        }
    }

 // Phase 2: dialect commands passed in are suggested as keywords.
    @Test func suggestsDialectStatementsPassedIn() {
        let hits = CompletionProvider.suggestions(
            script: "PRAG", utf16Cursor: 4, objects: [],
            statements: SQLStatements.statements(for: .sqlite)
        )
        #expect(hits.contains(.keyword("PRAGMA")))
        // MySQL-only command must NOT appear for a SQLite list.
        #expect(!hits.contains(.keyword("OPTIMIZE TABLE")))
    }

    @Test func suggestionMetadata() {
        #expect(CompletionProvider.Suggestion.table("t").iconName == "tablecells")
        #expect(CompletionProvider.Suggestion.column(name: "id", table: "users").detail == "users")
        #expect(CompletionProvider.Suggestion.keyword("SELECT").detail == "keyword")
    }

 // identifiers that survive case-folding aren't quoted;
    // PascalCase / special-char / leading-digit ones are.
    @Test func identifierQuotingHeuristic() {
        #expect(!CompletionProvider.identifierNeedsQuoting("users"))
        #expect(!CompletionProvider.identifierNeedsQuoting("user_stats"))
        #expect(!CompletionProvider.identifierNeedsQuoting("t123"))
        #expect(CompletionProvider.identifierNeedsQuoting("Users"))
        #expect(CompletionProvider.identifierNeedsQuoting("order-items"))
        #expect(CompletionProvider.identifierNeedsQuoting("2020_report"))
        #expect(CompletionProvider.identifierNeedsQuoting("my table"))
        #expect(CompletionProvider.identifierNeedsQuoting(""))
    }

    // Functions/procedures/triggers ARE suggested in the general pool…
    @Test func suggestsRoutinesInGeneralPool() {
        let withRoutines = objects + [
            SchemaObject(kind: .function, name: "calc_total"),
            SchemaObject(kind: .trigger, name: "audit_ai"),
        ]
        let cursor = ("SELECT calc" as NSString).length
        let suggestions = CompletionProvider.suggestions(
            script: "SELECT calc", utf16Cursor: cursor,
            objects: withRoutines, columnsByTable: columns
        )
        #expect(suggestions.contains(.routine(name: "calc_total", kind: .function)))
        #expect(CompletionProvider.Suggestion.routine(name: "audit_ai", kind: .trigger).detail == "trigger")
    }

 // routines/triggers live in the sidebar, never as table completions.
    @Test func excludesNonRelationalObjectsFromTableSuggestions() {
        let withRoutines = objects + [
            SchemaObject(kind: .function, name: "calc_total"),
            SchemaObject(kind: .trigger, name: "audit_ai"),
        ]
        let cursor = ("SELECT * FROM " as NSString).length
        let suggestions = CompletionProvider.suggestions(
            script: "SELECT * FROM ", utf16Cursor: cursor,
            objects: withRoutines, columnsByTable: columns
        )
        #expect(!suggestions.contains(.table("calc_total")))
        #expect(!suggestions.contains(.table("audit_ai")))
        #expect(suggestions.contains(.table("users")))
    }

    @Test func filtersTablePrefixAfterJoin() {
        let suggestions = complete("SELECT * FROM users JOIN ord", cursorAfter: "JOIN ord")
        #expect(suggestions.first == .table("orders"))
    }

    @Test func suggestsColumnsForAliasQualifier() {
        let script = "SELECT u. FROM users u"
        let cursor = (script as NSString).range(of: "u.").upperBound
        let suggestions = CompletionProvider.suggestions(
            script: script, utf16Cursor: cursor,
            objects: objects, columnsByTable: columns
        )
        #expect(suggestions.contains(.column(name: "email", table: "users")))
        #expect(!suggestions.contains { if case .keyword = $0 { true } else { false } })
    }

    @Test func suggestsColumnsForTableQualifier() {
        let script = "SELECT orders. FROM orders"
        let cursor = (script as NSString).range(of: "orders.").upperBound
        let suggestions = CompletionProvider.suggestions(
            script: script, utf16Cursor: cursor,
            objects: objects, columnsByTable: columns
        )
        #expect(suggestions.contains(.column(name: "user_id", table: "orders")))
    }

    @Test func resolvesAliasWithASKeyword() {
        let map = CompletionProvider.aliasMap(
            statement: "SELECT * FROM users AS u JOIN orders o ON o.user_id = u.id",
            tableNames: ["users", "orders"]
        )
        #expect(map["u"] == "users")
        #expect(map["o"] == "orders")
    }

    /// Reported crash-risk audit: Postgres allows a quoted `"Users"` and an
    /// unquoted `users` as two distinct tables (unquoted identifiers fold to
    /// lowercase, quoted ones don't) — a real, non-malicious schema shape.
    /// `aliasMap` built its lookup with `Dictionary(uniqueKeysWithValues:)`,
    /// which traps the instant two table names collide once lowercased.
    @Test func doesNotCrashWhenTwoTableNamesCollideOnlyByCase() {
        let map = CompletionProvider.aliasMap(
            statement: "SELECT * FROM Users u JOIN users AS u2 ON u2.id = u.id",
            tableNames: ["Users", "users"]
        )
        #expect(map["u"] != nil)
    }

    @Test func defaultPoolMixesKeywordsAndTables() {
        let suggestions = complete("SEL", cursorAfter: "SEL")
        #expect(suggestions.first == .keyword("SELECT"))
    }

    @Test func inScopeColumnsAppearInDefaultPool() {
        let script = "SELECT  FROM users"
        let cursor = ("SELECT " as NSString).length
        let suggestions = CompletionProvider.suggestions(
            script: script, utf16Cursor: cursor,
            objects: objects, columnsByTable: columns
        )
        #expect(suggestions.contains(.column(name: "email", table: "users")))
    }

    @Test func referencedTablesFindsFromAndJoin() {
        let tables = CompletionProvider.referencedTables(
            statement: "SELECT * FROM users u JOIN orders ON orders.user_id = u.id",
            objects: objects
        )
        #expect(Set(tables) == Set(["users", "orders"]))
    }

    @Test func deduplicatesSuggestionsAcrossDifferentSchemasWithoutCollision() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "berry_s1"),
            SchemaObject(kind: .table, name: "items", database: "berry_s2")
        ]
        let suggestions = CompletionProvider.suggestions(
            for: "SELECT * FROM ",
            cursor: 14,
            objects: objects,
            tableDetails: [
                TableRef(database: "berry_s1", name: "items"): TableDetail(
                    ref: TableRef(database: "berry_s1", name: "items"),
                    columns: [ColumnInfo(name: "price", declaredType: "NUMERIC", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                    indexes: [], foreignKeys: []
                ),
                TableRef(database: "berry_s2", name: "items"): TableDetail(
                    ref: TableRef(database: "berry_s2", name: "items"),
                    columns: [ColumnInfo(name: "sku", declaredType: "TEXT", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                    indexes: [], foreignKeys: []
                )
            ]
        )
        let itemSuggestions = suggestions.filter { $0.text == "items" }
        #expect(itemSuggestions.count == 2)
        #expect(itemSuggestions.contains { $0.detail == "berry_s1" })
        #expect(itemSuggestions.contains { $0.detail == "berry_s2" })
    }

    @Test func deduplicatesColumnSuggestionsAcrossDifferentSchemas() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "berry_s1"),
            SchemaObject(kind: .table, name: "items", database: "berry_s2")
        ]
        let suggestions = CompletionProvider.suggestions(
            for: "SELECT items. FROM items",
            cursor: 13,
            objects: objects,
            tableDetails: [
                TableRef(database: "berry_s1", name: "items"): TableDetail(
                    ref: TableRef(database: "berry_s1", name: "items"),
                    columns: [ColumnInfo(name: "price", declaredType: "NUMERIC", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                    indexes: [], foreignKeys: []
                ),
                TableRef(database: "berry_s2", name: "items"): TableDetail(
                    ref: TableRef(database: "berry_s2", name: "items"),
                    columns: [ColumnInfo(name: "sku", declaredType: "TEXT", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                    indexes: [], foreignKeys: []
                )
            ]
        )
        let price = suggestions.first { $0.text == "price" }
        let sku = suggestions.first { $0.text == "sku" }
        #expect(price?.detail == "berry_s1.items")
        #expect(sku?.detail == "berry_s2.items")
    }

    @Test func doesNotCrashOnIncompleteQualifiedTableNameDot() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "berry_s1")
        ]
        let suggestions = CompletionProvider.suggestions(
            for: "SELECT * FROM .",
            cursor: 16,
            objects: objects
        )
        #expect(!suggestions.isEmpty)

        let map = CompletionProvider.aliasMap(statement: "SELECT * FROM .", tableNames: ["items"])
        #expect(map.isEmpty)
    }

    @Test func schemaQualifiedAliasResolvesOnlyTargetSchemaColumns() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "berry_s1"),
            SchemaObject(kind: .table, name: "items", database: "berry_s2")
        ]
        let tableDetails = [
            TableRef(database: "berry_s1", name: "items"): TableDetail(
                ref: TableRef(database: "berry_s1", name: "items"),
                columns: [ColumnInfo(name: "price", declaredType: "NUMERIC", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                indexes: [], foreignKeys: []
            ),
            TableRef(database: "berry_s2", name: "items"): TableDetail(
                ref: TableRef(database: "berry_s2", name: "items"),
                columns: [ColumnInfo(name: "sku", declaredType: "TEXT", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                indexes: [], foreignKeys: []
            )
        ]
        let script = "SELECT i. FROM berry_s1.items i"
        let cursor = (script as NSString).range(of: "i.").upperBound
        let suggestions = CompletionProvider.suggestions(
            for: script,
            cursor: cursor,
            objects: objects,
            tableDetails: tableDetails
        )
        let columnNames = suggestions.filter {
            if case .column = $0 { true } else { false }
        }.map(\.text)
        #expect(columnNames.contains("price"))
        #expect(!columnNames.contains("sku"))
        let priceSuggestion = suggestions.first { $0.text == "price" }
        #expect(priceSuggestion?.detail == "berry_s1.items")
    }
}
