import BerryCore
import BerryDriverKit
import Foundation
import Testing

@testable import BerryUI

/// `EditorDocument.loadSnapshotResults`: reopening
/// an artifact with a captured result snapshot shows "what did the agent
/// actually get back" through the same result grid a live run would.
@MainActor
@Suite("EditorDocument result snapshots")
struct EditorDocumentTests {
    @Test func loadSnapshotResultsPopulatesOneResultPerStatement() async throws {
        let document = EditorDocument(title: "Reopened", text: "SELECT 1; SELECT 2")

        document.loadSnapshotResults([
            (sql: "SELECT 1", columns: ["a", "b"], rows: [["1", "2"], [nil, "x"]]),
            (sql: "SELECT 2", columns: ["c"], rows: [["y"]]),
        ])
        for result in document.results { await result.buffer.waitUntilFinished() }

        #expect(document.results.count == 2)
        #expect(document.results[0].sql == "SELECT 1")
        #expect(document.results[0].buffer.columns.map(\.name) == ["a", "b"])
        #expect(document.results[0].buffer.rows == [[.text("1"), .text("2")], [.null, .text("x")]])
        #expect(document.results[1].sql == "SELECT 2")
        #expect(document.results[1].buffer.columns.map(\.name) == ["c"])
        #expect(document.results[1].buffer.rows == [[.text("y")]])
        #expect(document.selectedResultID == document.results.last?.id)
    }

    @Test func loadSnapshotResultsIsANoOpForAnEmptyList() {
        let document = EditorDocument(title: "Untouched", text: "SELECT 1")

        document.loadSnapshotResults([])

        #expect(document.results.isEmpty)
    }

    @Test func tableDetailsCacheKeyedByTableRefSeparatesCrossSchemaTables() {
        let document = EditorDocument(title: "Multi-schema test", text: "")
        let refA = TableRef(database: "schema_a", name: "items")
        let refB = TableRef(database: "schema_b", name: "items")
        let detailA = TableDetail(
            ref: refA,
            columns: [ColumnInfo(name: "price", declaredType: "numeric", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [],
            foreignKeys: []
        )
        let detailB = TableDetail(
            ref: refB,
            columns: [ColumnInfo(name: "sku", declaredType: "text", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [],
            foreignKeys: []
        )

        document.tableDetails[refA] = detailA
        document.tableDetails[refB] = detailB

        #expect(document.tableDetails[refA]?.columns.map(\.name) == ["price"])
        #expect(document.tableDetails[refB]?.columns.map(\.name) == ["sku"])
    }

    private struct TestDialect: SQLDialect {
        func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
        func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
    }

    @Test func editorCompletionIsolatesMultiSchemaColumnsAndQuotesComponents() {
        let objects = [
            SchemaObject(kind: .table, name: "items", database: "schema_a"),
            SchemaObject(kind: .table, name: "items", database: "schema_b")
        ]
        let refA = TableRef(database: "schema_a", name: "items")
        let refB = TableRef(database: "schema_b", name: "items")
        let detailA = TableDetail(
            ref: refA,
            columns: [ColumnInfo(name: "price", declaredType: "numeric", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [],
            foreignKeys: []
        )
        let detailB = TableDetail(
            ref: refB,
            columns: [ColumnInfo(name: "sku", declaredType: "text", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [],
            foreignKeys: []
        )

        let document = EditorDocument(title: "Query", text: "")
        document.tableDetails[refA] = detailA
        document.tableDetails[refB] = detailB

        let dialect = TestDialect()

        // 1. Alias in schema_a: only price, never sku
        let scriptA = "SELECT * FROM schema_a.items i WHERE i."
        let suggestionsA = CompletionProvider.suggestions(
            script: scriptA,
            utf16Cursor: scriptA.utf16.count,
            objects: objects,
            tableDetails: document.tableDetails
        )
        let itemsA = suggestionsA.map {
            CompletionItem(
                display: $0.text,
                insert: $0.insertText(dialect: dialect),
                icon: $0.iconName,
                detail: $0.detail
            )
        }
        #expect(itemsA.contains { $0.display == "price" && $0.detail == "schema_a.items" && $0.insert == "price" })
        #expect(!itemsA.contains { $0.display == "sku" })

        // 2. Alias in schema_b: only sku, never price
        let scriptB = "SELECT * FROM schema_b.items i WHERE i."
        let suggestionsB = CompletionProvider.suggestions(
            script: scriptB,
            utf16Cursor: scriptB.utf16.count,
            objects: objects,
            tableDetails: document.tableDetails
        )
        let itemsB = suggestionsB.map {
            CompletionItem(
                display: $0.text,
                insert: $0.insertText(dialect: dialect),
                icon: $0.iconName,
                detail: $0.detail
            )
        }
        #expect(itemsB.contains { $0.display == "sku" && $0.detail == "schema_b.items" && $0.insert == "sku" })
        #expect(!itemsB.contains { $0.display == "price" })

        // 3. Reversed objects order: schema_a still resolves only price
        let reversedObjects = Array(objects.reversed())
        let suggestionsAReversed = CompletionProvider.suggestions(
            script: scriptA,
            utf16Cursor: scriptA.utf16.count,
            objects: reversedObjects,
            tableDetails: document.tableDetails
        )
        #expect(suggestionsAReversed.contains { $0.text == "price" })
        #expect(!suggestionsAReversed.contains { $0.text == "sku" })

        // 4. Table suggestion insertion: qualified and component-quoted
        let scriptTable = "SELECT * FROM "
        let tableSuggestions = CompletionProvider.suggestions(
            script: scriptTable,
            utf16Cursor: scriptTable.utf16.count,
            objects: objects,
            tableDetails: document.tableDetails
        )
        let tableItems = tableSuggestions.map {
            CompletionItem(
                display: $0.text,
                insert: $0.insertText(dialect: dialect),
                icon: $0.iconName,
                detail: $0.detail
            )
        }
        let itemB = tableItems.first { $0.detail == "schema_b" }
        #expect(itemB != nil)
        #expect(itemB?.display == "items")
        #expect(itemB?.insert == "\"schema_b\".\"items\"")
    }
}
