import AppKit
import BerryDataSourceKit
import SwiftUI

/// Result grid for `DataSourceResultBuffer` — the NoSQL/vector sibling of
/// `DataGridView`. NSTableView-backed for the same
/// virtualization reasoning (N3, large result sets) — not a plain SwiftUI
/// List/Table. Columns are the union of top-level `.object` keys in the
/// buffer's first batch (`DataSourceResultBuffer.columns`); a cell whose
/// value is a nested `.object`/`.array` shows a short placeholder. Read-only
/// in the grid itself: editing/inserting is document-granularity (a whole
/// `BerryDocument`, not a single field — Mongo's update wraps a whole `$set`
/// patch, Qdrant's needs vector+payload together), so a cell opens
/// `DocumentCellViewerSheet` on the WHOLE row instead of an inline per-cell
/// edit the way `DataGridView` supports for SQL.
public struct DocumentGridView: NSViewRepresentable {
    private let buffer: DataSourceResultBuffer
    var onViewDocument: ((Int) -> Void)?
    var onDeleteRows: (([Int]) -> Void)?

    public init(
        buffer: DataSourceResultBuffer,
        onViewDocument: ((Int) -> Void)? = nil,
        onDeleteRows: (([Int]) -> Void)? = nil
    ) {
        self.buffer = buffer
        self.onViewDocument = onViewDocument
        self.onDeleteRows = onDeleteRows
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnReordering = false
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 22
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        context.coordinator.tableView = tableView
        context.coordinator.installMenu(on: tableView)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Read the @Observable properties here so SwiftUI re-invokes this when the buffer changes.
        let columns = buffer.columns
        let rowCount = buffer.itemCount
        context.coordinator.parent = self
        context.coordinator.sync(buffer: buffer, columns: columns, rowCount: rowCount)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView: NSTableView?
        var parent: DocumentGridView?
        private var buffer: DataSourceResultBuffer?
        private var columnCount = 0
        private var lastRowCount = 0
        /// Guards against SwiftUI re-invoking `updateNSView` (→ `sync` → `reloadData`)
        /// while a reload is already in flight — AppKit flags that as a "reentrant
        /// operation in its NSTableView delegate". The nested call is deferred to
        /// the next runloop tick, where it reloads with the latest buffer state.
        private var isReloading = false

        func sync(buffer: DataSourceResultBuffer, columns: [String], rowCount: Int) {
            self.buffer = buffer
            guard let tableView else { return }
            if isReloading {
                DispatchQueue.main.async { [weak self] in
                    self?.sync(buffer: buffer, columns: columns, rowCount: rowCount)
                }
                return
            }
            isReloading = true
            defer { isReloading = false }

            if columns.count != columnCount || columnsChanged(columns, in: tableView) {
                rebuildColumns(columns, in: tableView)
                columnCount = columns.count
                lastRowCount = 0
                tableView.reloadData()
            }
            if rowCount != lastRowCount {
                lastRowCount = rowCount
                tableView.reloadData()
            }
        }

        private func columnsChanged(_ columns: [String], in tableView: NSTableView) -> Bool {
            guard tableView.tableColumns.count == columns.count else { return true }
            return zip(tableView.tableColumns, columns).contains { $0.0.title != $0.1 }
        }

        private func rebuildColumns(_ columns: [String], in tableView: NSTableView) {
            for column in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(column)
            }
            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: .init("col\(index)"))
                column.title = name
                column.width = 160
                column.minWidth = 40
                tableView.addTableColumn(column)
            }
        }

        // MARK: NSTableViewDataSource

        public func numberOfRows(in tableView: NSTableView) -> Int {
            buffer?.itemCount ?? 0
        }

        // MARK: NSTableViewDelegate

        public func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let buffer, let tableColumn,
                  let columnIndex = Int(tableColumn.identifier.rawValue.dropFirst(3)), // "col<i>" → i, O(1)
                  row < buffer.items.count, columnIndex < buffer.columns.count
            else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = identifier
                cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
                cell.isBordered = false
                cell.drawsBackground = false
            }
            let key = buffer.columns[columnIndex]
            let value = buffer.items[row][key] ?? .null
            cell.stringValue = value.gridCellString
            cell.textColor = value == .null ? .tertiaryLabelColor : .labelColor
            return cell
        }

        // MARK: Context menu (View Document… / Delete)

        func installMenu(on tableView: NSTableView) {
            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu
        }
    }
}

extension DocumentGridView.Coordinator: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let parent, let tableView, tableView.clickedRow >= 0 else { return }

        if parent.onViewDocument != nil {
            let view = NSMenuItem(
                title: String(localized: "View Document…", bundle: berryModuleBundle),
                action: #selector(viewDocumentAction), keyEquivalent: ""
            )
            view.target = self
            menu.addItem(view)
        }

        guard parent.onDeleteRows != nil else { return }
        if parent.onViewDocument != nil { menu.addItem(.separator()) }
        let selectedCount = max(tableView.selectedRowIndexes.count, 1)
        let delete = NSMenuItem(
            title: String(localized: "Delete \(selectedCount) row(s)", bundle: berryModuleBundle),
            action: #selector(deleteRowsAction), keyEquivalent: ""
        )
        delete.target = self
        menu.addItem(delete)
    }

    private func targetRows() -> [Int] {
        guard let tableView else { return [] }
        var rows = IndexSet(tableView.selectedRowIndexes)
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        return Array(rows)
    }

    @objc private func viewDocumentAction() {
        guard let tableView, tableView.clickedRow >= 0 else { return }
        parent?.onViewDocument?(tableView.clickedRow)
    }

    @objc private func deleteRowsAction() {
        parent?.onDeleteRows?(targetRows())
    }
}

extension BerryDocument {
    /// Shared across every date cell — `ISO8601DateFormatter()` is costly to
    /// allocate and `gridCellString` runs per visible cell while scrolling.
    /// `nonisolated(unsafe)`: only ever read on the main actor (the table
    /// delegate) and `ISO8601DateFormatter.string(from:)` is read-only here.
    nonisolated(unsafe) fileprivate static let gridDateFormatter = ISO8601DateFormatter()

    /// One-line grid-cell rendering — nested containers collapse to a short
    /// placeholder; the full value opens in `DocumentCellViewerSheet`.
    var gridCellString: String {
        switch self {
        case .null: return "NULL"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return v
        case .binary(let v):
            let hex = v.prefix(8).map { String(format: "%02x", $0) }.joined()
            return "0x" + hex + (v.count > 8 ? "…" : "")
        case .objectID(let v): return v
        case .date(let v): return Self.gridDateFormatter.string(from: v)
        case .vector(let v): return "[\(v.count) dims]"
        case .array: return "[…]"
        case .object: return "{…}"
        }
    }
}
