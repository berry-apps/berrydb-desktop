import BerryCore
import BerryDriverKit
import Testing

@testable import BerryUI

@MainActor
@Suite("TableTabState.pasteRows (paste-into-grid)")
struct TableTabStatePasteTests {
    /// `seedColumnsIfEmpty` only takes effect once the buffer's stream has
    /// completed (empty), matching the real `TableTabState.load()` sequence —
    /// so drive an empty stream through `consume` first, same as production.
    private func makeState(columns: [String]) async -> TableTabState {
        let state = TableTabState(object: SchemaObject(kind: .table, name: "t"))
        let stream = AsyncThrowingStream<ResultEvent, Error> { continuation in
            continuation.finish()
        }
        state.buffer.consume(stream)
        await state.buffer.waitUntilFinished()
        state.buffer.seedColumnsIfEmpty(columns.map { ColumnMeta(name: $0, declaredType: "") })
        return state
    }

    @Test func pastesTSVAsInsertedRows() async {
        let state = await makeState(columns: ["id", "name"])
        state.pasteRows("1\tAlice\n2\tBob")
        #expect(state.insertedRows == [
            [.text("1"), .text("Alice")],
            [.text("2"), .text("Bob")],
        ])
    }

    @Test func pastesCSVWhenNoTabPresent() async {
        let state = await makeState(columns: ["id", "name"])
        state.pasteRows("1,Alice\n2,Bob")
        #expect(state.insertedRows == [
            [.text("1"), .text("Alice")],
            [.text("2"), .text("Bob")],
        ])
    }

    @Test func emptyFieldBecomesNull() async {
        let state = await makeState(columns: ["id", "name"])
        state.pasteRows("1\t")
        #expect(state.insertedRows == [[.text("1"), .null]])
    }

    @Test func rowWidthIsNormalizedToColumnCount() async {
        let state = await makeState(columns: ["id", "name"])
        state.pasteRows("1\tAlice\tExtra\n2")
        #expect(state.insertedRows == [
            [.text("1"), .text("Alice")],
            [.text("2"), .null],
        ])
    }
}
