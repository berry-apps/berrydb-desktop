import AppKit
import BerryCore
import BerryDriverKit
import SwiftUI

/// Result grid — NSTableView wrapped in NSViewRepresentable because SwiftUI
/// Table cannot handle large tables (target 1M rows at 60fps).
/// View-based + virtualized: NSTableView only materializes visible rows.
///
/// Editing: when `isEditable`, cells accept inline edits and a
/// right-click menu offers Set NULL / Delete Row; every action only STAGES a
/// change via the callbacks — nothing touches the DBMS here (06).
public struct DataGridView: NSViewRepresentable {
    private let buffer: ResultBuffer
    var isEditable: Bool = false
    /// Staged-value display overlay: (row, columnIndex) → value.
    var overlay: ((Int, Int) -> BerryValue?)?
    var isRowDeleted: ((Int) -> Bool)?
    var onEdit: ((Int, Int, String) -> Void)?
    var onSetNull: ((Int, Int) -> Void)?
    var onDeleteRows: (([Int]) -> Void)?
    /// Paste clipboard rows as staged inserts; the handler reads NSPasteboard
    /// itself (mirrors how `onCopy` already writes to it via `GridCopy.copy`).
    var onPasteRows: (() -> Void)?
 /// Copy-as menu; formats are filtered by the host view.
    var copyFormats: [GridCopyFormat] = []
    var onCopy: (([Int], GridCopyFormat) -> Void)?
 /// Locally staged insert rows appended below the buffer; their
    /// values come exclusively through `overlay`.
    var appendedRowCount: Int = 0
 /// Column-header sort: (columnName, ascending).
    var onSort: ((String, Bool) -> Void)?
 /// Cell viewer, opened from the context menu.
    var onViewCell: ((Int, Int) -> Void)?
 /// FK jump: given a column index, returns the referenced table
    /// name when that column is a foreign key (for the menu title), else nil.
    var foreignKeyTarget: ((Int) -> String?)?
 /// FK jump: open the referenced row for (row, columnIndex).
    var onJumpToReference: ((Int, Int) -> Void)?

    public init(buffer: ResultBuffer) {
        self.buffer = buffer
    }

    init(
        buffer: ResultBuffer,
        isEditable: Bool,
        overlay: ((Int, Int) -> BerryValue?)? = nil,
        isRowDeleted: ((Int) -> Bool)? = nil,
        onEdit: ((Int, Int, String) -> Void)? = nil,
        onSetNull: ((Int, Int) -> Void)? = nil,
        onDeleteRows: (([Int]) -> Void)? = nil,
        onPasteRows: (() -> Void)? = nil,
        copyFormats: [GridCopyFormat] = [],
        onCopy: (([Int], GridCopyFormat) -> Void)? = nil,
        appendedRowCount: Int = 0,
        onSort: ((String, Bool) -> Void)? = nil,
        onViewCell: ((Int, Int) -> Void)? = nil,
        foreignKeyTarget: ((Int) -> String?)? = nil,
        onJumpToReference: ((Int, Int) -> Void)? = nil
    ) {
        self.buffer = buffer
        self.isEditable = isEditable
        self.overlay = overlay
        self.isRowDeleted = isRowDeleted
        self.onEdit = onEdit
        self.onSetNull = onSetNull
        self.onDeleteRows = onDeleteRows
        self.onPasteRows = onPasteRows
        self.copyFormats = copyFormats
        self.onCopy = onCopy
        self.appendedRowCount = appendedRowCount
        self.onSort = onSort
        self.onViewCell = onViewCell
        self.foreignKeyTarget = foreignKeyTarget
        self.onJumpToReference = onJumpToReference
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
        let rowCount = buffer.rowCount
        context.coordinator.parent = self
        context.coordinator.sync(buffer: buffer, columns: columns, rowCount: rowCount)
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        weak var tableView: NSTableView?
        var parent: DataGridView?
        private var buffer: ResultBuffer?
        private var columnCount = 0
        private var lastRowCount = 0
        private var pendingVersion = 0
        /// Guards against SwiftUI re-invoking `updateNSView` (→ `sync` → `reloadData`)
        /// while a reload is already in flight — AppKit flags that as a "reentrant
        /// operation in its NSTableView delegate". The nested call is deferred to
        /// the next runloop tick, where it reloads with the latest buffer state.
        private var isReloading = false
        private var pendingSync: (buffer: ResultBuffer, columns: [ColumnMeta], rowCount: Int)?

        func sync(buffer: ResultBuffer, columns: [ColumnMeta], rowCount: Int) {
            self.buffer = buffer
            guard let tableView else { return }
            if isReloading {
                let shouldSchedule = pendingSync == nil
                pendingSync = (buffer, columns, rowCount)
                if shouldSchedule {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let latest = self.pendingSync else { return }
                        self.pendingSync = nil
                        self.sync(buffer: latest.buffer, columns: latest.columns, rowCount: latest.rowCount)
                    }
                }
                return
            }
            isReloading = true
            defer { isReloading = false }

            let totalRows = rowCount + (parent?.appendedRowCount ?? 0)
            if columns.count != columnCount || columnsChanged(columns, in: tableView) {
                rebuildColumns(columns, in: tableView)
                columnCount = columns.count
                lastRowCount = totalRows
                tableView.reloadData()
            } else if totalRows != lastRowCount {
                lastRowCount = totalRows
                tableView.reloadData()
            } else {
                // Same row count but overlay may have changed — refresh visible rows.
                let visibleRows = tableView.rows(in: tableView.visibleRect)
                if visibleRows.location != NSNotFound && visibleRows.length > 0 {
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integersIn: visibleRows.lowerBound ..< (visibleRows.lowerBound + visibleRows.length)),
                        columnIndexes: IndexSet(0..<max(columnCount, 0))
                    )
                }
            }
        }

        private func columnsChanged(_ columns: [ColumnMeta], in tableView: NSTableView) -> Bool {
            guard tableView.tableColumns.count == columns.count else { return true }
            return zip(tableView.tableColumns, columns).contains { $0.title != $1.name }
        }

        private func rebuildColumns(_ columns: [ColumnMeta], in tableView: NSTableView) {
            for column in tableView.tableColumns.reversed() {
                tableView.removeTableColumn(column)
            }
            for (index, meta) in columns.enumerated() {
                let column = NSTableColumn(identifier: .init("col\(index)"))
                column.title = meta.name
                column.width = 140
                column.minWidth = 40
                if parent?.onSort != nil {
 // Header-click sort via the standard sort-descriptor flow.
                    column.sortDescriptorPrototype = NSSortDescriptor(key: meta.name, ascending: true)
                }
                tableView.addTableColumn(column)
            }
        }

        public func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
        ) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = descriptor.key else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent?.onSort?(column, descriptor.ascending)
            }
        }

        // MARK: Context menu (Set NULL / Delete Row)

        func installMenu(on tableView: NSTableView) {
            let menu = NSMenu()
            menu.delegate = self
            tableView.menu = menu
        }

        // MARK: NSTableViewDataSource

        public func numberOfRows(in tableView: NSTableView) -> Int {
            (buffer?.rowCount ?? 0) + (parent?.appendedRowCount ?? 0)
        }

        // MARK: NSTableViewDelegate

        public func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard let buffer, let parent, let tableColumn,
                  let columnIndex = Int(tableColumn.identifier.rawValue.dropFirst(3)), // "col<i>" → i, O(1)
                  row < buffer.rowCount + parent.appendedRowCount,
                  columnIndex < buffer.columns.count
            else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell: EditableCellField
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? EditableCellField {
                cell = reused
            } else {
                cell = EditableCellField(labelWithString: "")
                cell.identifier = identifier
                cell.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                cell.lineBreakMode = .byTruncatingTail
                cell.maximumNumberOfLines = 1
                cell.delegate = self
            }
            cell.row = row
            cell.columnIndex = columnIndex
            cell.isEditable = parent.isEditable
            cell.isBordered = false
            cell.drawsBackground = false

 // Appended (inserted) rows live only in the overlay.
            let isAppended = row >= buffer.rowCount
            let staged = parent.overlay?(row, columnIndex)
            let value = staged ?? (isAppended ? .null : buffer.rows[row][columnIndex])
            let deleted = parent.isRowDeleted?(row) ?? false

            if let text = value.displayString {
                cell.stringValue = text
                cell.textColor = staged != nil ? .systemOrange : .labelColor
            } else {
 // NULL is clearly distinguished from an empty string.
                cell.stringValue = "NULL"
                cell.textColor = staged != nil ? .systemOrange : .tertiaryLabelColor
            }
            cell.alphaValue = deleted ? 0.35 : 1.0
            return cell
        }

        // MARK: NSTextFieldDelegate (inline edit → stage)

        public func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? EditableCellField,
                  let parent, parent.isEditable else { return }
            let row = field.row
            let col = field.columnIndex
            let val = field.stringValue
            DispatchQueue.main.async {
                parent.onEdit?(row, col, val)
            }
        }
    }
}

/// Cell field that remembers its grid position for edit callbacks.
final class EditableCellField: NSTextField {
    var row = 0
    var columnIndex = 0
}

extension DataGridView.Coordinator: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let parent, let tableView, tableView.clickedRow >= 0 else { return }

 // Cell viewer — every grid.
        if parent.onViewCell != nil {
            let view = NSMenuItem(
                title: String(localized: "View Cell…", bundle: berryModuleBundle),
                action: #selector(viewCellAction), keyEquivalent: ""
            )
            view.target = self
            menu.addItem(view)
            menu.addItem(.separator())
        }

 // FK jump — only when the clicked column is a foreign key.
        if tableView.clickedColumn >= 0,
           let referenced = parent.foreignKeyTarget?(tableView.clickedColumn) {
            let jump = NSMenuItem(
                title: String(localized: "Jump to \(referenced)", bundle: berryModuleBundle),
                action: #selector(jumpToReferenceAction), keyEquivalent: ""
            )
            jump.target = self
            menu.addItem(jump)
            menu.addItem(.separator())
        }

 // Copy-as — available on every grid, table tabs and editor
        // results alike.
        for (index, format) in parent.copyFormats.enumerated() {
            let item = NSMenuItem(title: format.title, action: #selector(copyAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }

        guard parent.isEditable else { return }
        if !parent.copyFormats.isEmpty {
            menu.addItem(.separator())
        }

        let setNull = NSMenuItem(
            title: String(localized: "Set NULL", bundle: berryModuleBundle),
            action: #selector(setNullAction), keyEquivalent: ""
        )
        setNull.target = self
        menu.addItem(setNull)

        let selectedCount = max(tableView.selectedRowIndexes.count, 1)
        let delete = NSMenuItem(
            title: String(localized: "Delete \(selectedCount) row(s)", bundle: berryModuleBundle),
            action: #selector(deleteRowsAction), keyEquivalent: ""
        )
        delete.target = self
        menu.addItem(delete)

        if parent.onPasteRows != nil, NSPasteboard.general.string(forType: .string) != nil {
            menu.addItem(.separator())
            let paste = NSMenuItem(
                title: String(localized: "Paste Rows", bundle: berryModuleBundle),
                action: #selector(pasteRowsAction), keyEquivalent: ""
            )
            paste.target = self
            menu.addItem(paste)
        }
    }

    private func targetRows() -> [Int] {
        guard let tableView else { return [] }
        var rows = IndexSet(tableView.selectedRowIndexes)
        if tableView.clickedRow >= 0, !rows.contains(tableView.clickedRow) {
            rows = IndexSet(integer: tableView.clickedRow)
        }
        return Array(rows)
    }

    @objc private func copyAction(_ sender: NSMenuItem) {
        guard let parent, sender.tag < parent.copyFormats.count else { return }
        parent.onCopy?(targetRows(), parent.copyFormats[sender.tag])
    }

    @objc private func viewCellAction() {
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0 else { return }
        parent?.onViewCell?(tableView.clickedRow, tableView.clickedColumn)
    }

    @objc private func jumpToReferenceAction() {
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0 else { return }
        parent?.onJumpToReference?(tableView.clickedRow, tableView.clickedColumn)
    }

    @objc private func setNullAction() {
        guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 0 else { return }
        parent?.onSetNull?(tableView.clickedRow, tableView.clickedColumn)
    }

    @objc private func deleteRowsAction() {
        parent?.onDeleteRows?(targetRows())
    }

    @objc private func pasteRowsAction() {
        parent?.onPasteRows?()
    }
}
