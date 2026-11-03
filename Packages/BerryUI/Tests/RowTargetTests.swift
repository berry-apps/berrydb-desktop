import AppKit
import BerryCore
import BerryDriverKit
import Foundation
import Testing

@testable import BerryUI

@MainActor
@Suite("Row detail snapshots")
struct RowTargetTests {
    private func buffer() async -> ResultBuffer {
        let buffer = ResultBuffer()
        buffer.consume(AsyncThrowingStream { continuation in
            continuation.yield(.columns([
                ColumnMeta(name: "value", declaredType: "TEXT"),
                ColumnMeta(name: "value", declaredType: "BLOB"),
                ColumnMeta(name: "optional", declaredType: "TEXT"),
            ]))
            continuation.yield(.rows([[.text("first\nsecond"), .bytes(Data([0, 255])), .null]]))
            continuation.finish()
        })
        await buffer.waitUntilFinished()
        return buffer
    }

    @Test func preservesColumnOrderDuplicateNamesAndTypedValues() async throws {
        let buffer = await buffer()
        let target = try #require(RowTarget.from(buffer: buffer, row: 0))
        #expect(target.fields.map(\.id) == [0, 1, 2])
        #expect(target.fields.map { $0.column.name } == ["value", "value", "optional"])
        #expect(target.fields.map(\.value) == [.text("first\nsecond"), .bytes(Data([0, 255])), .null])
    }

    @Test func stagedValuesTakePrecedenceAndInsertedRowsAreIncluded() async throws {
        let buffer = await buffer()
        let edited = try #require(RowTarget.from(buffer: buffer, row: 0) { column in
            column == 0 ? .text("edited") : nil
        })
        #expect(edited.fields[0].value == .text("edited"))
        #expect(edited.fields[1].value == .bytes(Data([0, 255])))
        let inserted = try #require(RowTarget.from(buffer: buffer, row: 1, appendedRowCount: 1) { column in
            column == 0 ? .text("new") : .null
        })
        #expect(inserted.fields.map(\.value) == [.text("new"), .null, .null])
    }

    @Test func invalidRowsDoNotOpenDetails() async {
        let buffer = await buffer()
        #expect(RowTarget.from(buffer: buffer, row: -1) == nil)
        #expect(RowTarget.from(buffer: buffer, row: buffer.rowCount) == nil)
        #expect(RowTarget.from(buffer: ResultBuffer(), row: 0) == nil)
    }
}

@MainActor
@Suite("Row detail selection")
struct RowDetailSelectionTests {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    @Test func selectionIsDeferredAndMultipleRowsClearTheInspector() async throws {
        let rows = Rows()
        defer { _ = rows }
        let table = NSTableView()
        table.allowsMultipleSelection = true
        table.dataSource = rows
        table.reloadData()
        let coordinator = DataGridView.Coordinator()
        coordinator.tableView = table
        var selections: [Int?] = []
        var grid = DataGridView(buffer: ResultBuffer())
        grid.onSelectRow = { selections.append($0) }
        coordinator.parent = grid

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(selections.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(selections.count == 1)
        #expect(selections.last! == 1)

        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        try await Task.sleep(for: .milliseconds(50))
        #expect(selections.count == 2)
        #expect(selections.last! == nil)
    }
}

@Suite("Row inspector controls and previews")
struct RowInspectorTests {
    @Test func closingStaysClosedAcrossSelectionChangesAndContextMenuReopens() {
        var state = RowInspectorState()
        state.select(0)
        #expect(!state.isOpen)
        state.toggle()
        #expect(state.isOpen)
        #expect(state.selectedRow == 0)
        state.close()
        state.select(1)
        #expect(!state.isOpen)
        state.open(row: 2)
        #expect(state.isOpen)
        #expect(state.selectedRow == 2)
        state.select(nil)
        #expect(state.isOpen)
        #expect(state.selectedRow == nil)
    }

    @Test func largeValuesHaveBoundedPreviewsWithoutChangingTheFullValue() {
        let text = String(repeating: "{\"value\":\"large\"}", count: 200_000)
        for value in [BerryValue.text(text), .json(text)] {
            let preview = RowValuePreview(value)
            #expect(preview.isTruncated)
            #expect(preview.text.utf8.count <= RowValuePreview.byteLimit)
            #expect(value.displayString == text)
        }
        let combining = BerryValue.text("a" + String(repeating: "\u{0301}", count: 2_000_000))
        #expect(RowValuePreview(combining).isTruncated)
        #expect(RowValuePreview(.null).text == "NULL")
        #expect(RowValuePreview(.text("")).text == "")
        #expect(!RowValuePreview(.text("small")).isTruncated)
    }

    @Test func narrowGroupsUseAnOverlayInsteadOfAddingMinimumWidths() {
        #expect(RowInspectorState.usesOverlay(width: 320))
        #expect(RowInspectorState.usesOverlay(width: 420))
        #expect(!RowInspectorState.usesOverlay(width: 800))
    }
}
