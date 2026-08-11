import BerryDriverKit
import Foundation
import Testing

@testable import BerryUI

/// `EditorDocument.loadSnapshotResults` (AI-31, docs/draft/09.md): reopening
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
}
