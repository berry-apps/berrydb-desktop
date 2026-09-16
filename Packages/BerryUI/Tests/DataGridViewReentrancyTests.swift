import AppKit
import BerryCore
import BerryDriverKit
import Foundation
import Testing

@testable import BerryUI

@MainActor
@Suite("DataGridView and DocumentGridView Reentrancy and Deferral Tests")
struct DataGridViewReentrancyTests {

    private final class TrackingTableView: NSTableView {
        var reloadCount = 0
        var isInsideReload = false
        var detectedReentrancy = false
        var onReload: (() -> Void)?

        override func reloadData() {
            if isInsideReload {
                detectedReentrancy = true
            }
            isInsideReload = true
            reloadCount += 1
            super.reloadData()
            onReload?()
            isInsideReload = false
        }
    }

    @Test func sortDescriptorsDidChangeDefersCallbackToNextRunloopTick() async throws {
        let coordinator = DataGridView.Coordinator()
        let tableView = NSTableView()
        coordinator.tableView = tableView

        var sortCalls: [(column: String, ascending: Bool)] = []
        var grid = DataGridView(buffer: ResultBuffer())
        grid.onSort = { col, asc in
            sortCalls.append((col, asc))
        }
        coordinator.parent = grid

        tableView.sortDescriptors = [NSSortDescriptor(key: "created_at", ascending: false)]

        // Call delegate method directly as AppKit would on header click
        coordinator.tableView(tableView, sortDescriptorsDidChange: [])

        // Must NOT be executed synchronously on the delegate stack
        #expect(sortCalls.isEmpty)

        // Wait for deferred dispatch on main queue
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(sortCalls.count == 1)
        #expect(sortCalls[0].column == "created_at")
        #expect(sortCalls[0].ascending == false)
    }

    @Test func controlTextDidEndEditingDefersCallbackAndPreservesPayload() async throws {
        let coordinator = DataGridView.Coordinator()
        var editCalls: [(row: Int, column: Int, value: String)] = []
        var grid = DataGridView(buffer: ResultBuffer(), isEditable: true)
        grid.onEdit = { row, col, val in
            editCalls.append((row, col, val))
        }
        coordinator.parent = grid

        let field = EditableCellField(labelWithString: "staged_name")
        field.row = 4
        field.columnIndex = 1

        let notification = Notification(name: NSControl.textDidEndEditingNotification, object: field)
        coordinator.controlTextDidEndEditing(notification)

        // Must NOT be executed synchronously on the text field delegate stack
        #expect(editCalls.isEmpty)

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(editCalls.count == 1)
        #expect(editCalls[0].row == 4)
        #expect(editCalls[0].column == 1)
        #expect(editCalls[0].value == "staged_name")
    }

    @Test func rebuildColumnsDoesNotCallReloadDataTwice() {
        let coordinator = DataGridView.Coordinator()
        let tableView = TrackingTableView()
        coordinator.tableView = tableView

        let grid = DataGridView(buffer: ResultBuffer())
        coordinator.parent = grid

        let buffer = ResultBuffer()
        let columns = [
            ColumnMeta(name: "id", declaredType: "int"),
            ColumnMeta(name: "title", declaredType: "text")
        ]

        // Initial sync when columns arrive with 10 rows
        coordinator.sync(buffer: buffer, columns: columns, rowCount: 10)

        // Must only reload ONCE (never double-reload when columns change)
        #expect(tableView.reloadCount == 1)
        #expect(!tableView.detectedReentrancy)
    }

    @Test func nestedSyncDuringReloadIsCoalescedToLatestSnapshot() async throws {
        let coordinator = DataGridView.Coordinator()
        let tableView = TrackingTableView()
        coordinator.tableView = tableView

        let buffer = ResultBuffer()
        let columns = [ColumnMeta(name: "id", declaredType: "int")]

        // Setup reentrant trigger: during the first reload, trigger 2 more sync calls
        tableView.onReload = {
            // Rapid updates arriving while previous reload is still active
            coordinator.sync(buffer: buffer, columns: columns, rowCount: 20)
            coordinator.sync(buffer: buffer, columns: columns, rowCount: 30)
        }

        coordinator.sync(buffer: buffer, columns: columns, rowCount: 10)

        // The first reload should have finished without re-entering
        #expect(!tableView.detectedReentrancy)
        #expect(tableView.reloadCount == 1)

        // Clear reentrant trigger so subsequent reload doesn't loop
        tableView.onReload = nil

        // Wait for the single deferred coalesced reload on the next runloop turn
        try await Task.sleep(nanoseconds: 50_000_000)

        // Should have reloaded once more with the coalesced latest snapshot
        #expect(tableView.reloadCount == 2)
        #expect(!tableView.detectedReentrancy)
    }

    @Test func documentGridViewCoalescesNestedSync() async throws {
        let coordinator = DocumentGridView.Coordinator()
        let tableView = TrackingTableView()
        coordinator.tableView = tableView

        let buffer = DataSourceResultBuffer()
        let columns = ["key", "value"]

        tableView.onReload = {
            coordinator.sync(buffer: buffer, columns: columns, rowCount: 15)
            coordinator.sync(buffer: buffer, columns: columns, rowCount: 25)
        }

        coordinator.sync(buffer: buffer, columns: columns, rowCount: 5)

        #expect(!tableView.detectedReentrancy)
        #expect(tableView.reloadCount == 1)

        tableView.onReload = nil

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(tableView.reloadCount == 2)
        #expect(!tableView.detectedReentrancy)
    }
}
