import BerryCore
import BerryDriverKit
import Foundation
import Observation

/// State of one table tab: streamed rows + staged edits
/// Edits stay local (ChangeSet + display overlay)
/// until the user reviews the SQL preview and applies.
@MainActor
@Observable
public final class TableTabState: @preconcurrency Identifiable {
    public let object: SchemaObject
    public let buffer = ResultBuffer()

    public private(set) var pkColumns: [String] = []
 /// Foreign keys of this table — drives the grid's "jump to
    /// referenced row" action.
    public private(set) var foreignKeys: [ForeignKeyInfo] = []
 /// Full introspected detail, kept for the SQL-export DDL header.
    public private(set) var detail: TableDetail?
    public private(set) var detailLoaded = false
    public private(set) var changeSet: ChangeSet
    /// Display overlay for staged edits: row → column index → new value.
    public private(set) var pendingDisplay: [Int: [Int: BerryValue]] = [:]
    public private(set) var deletedRowIndexes: Set<Int> = []
 /// Locally staged NEW rows, appended below the buffer rows in the
    /// grid; values are keyed by column index, NULL until edited.
    public private(set) var insertedRows: [[BerryValue]] = []
    public private(set) var isApplying = false
    public var applyError: String?

 /// Server-side sort & filter.
    public private(set) var sortColumn: String?
    public private(set) var sortAscending = true
    public var filterClause: String = ""

    public var id: String { object.id }
 /// Editing EXISTING rows requires a discovered primary key (06 safety).
    public var canEdit: Bool { detailLoaded && changeSet.canEdit }
    /// Inserting needs no primary key — an INSERT has no row identity to match —
    /// so an empty table is always insertable, enabling quick data entry on
 /// fresh tables (D4b).
    public var canInsert: Bool {
        detailLoaded && !buffer.columns.isEmpty && (canEdit || buffer.rowCount == 0)
    }
    /// Count of inserted rows that have actual edited (non-null) values.
    public var realInsertedRowCount: Int {
        insertedRows.filter { row in
            row.contains(where: { !$0.isNull })
        }.count
    }
    public var pendingCount: Int { changeSet.count + realInsertedRowCount }

    public init(object: SchemaObject) {
        self.object = object
        self.changeSet = ChangeSet(
            table: TableRef(database: object.database, name: object.name),
            pkColumns: []
        )
    }

    // MARK: - Loading

    public func load(session: Session, catalog: SchemaCatalog?) {
        reload(session: session)
        Task { [weak self] in
            guard let self, let catalog else { return }
            // Wait for the actual row data before introspecting: driver
            // connections have no pool, so tableDetail's pg_catalog/information_
            // schema round trips would otherwise contend with the SELECT for the
            // same connection and delay rows appearing, even for a tiny table.
            await self.buffer.waitUntilFinished()
            let ref = TableRef(database: object.database, name: object.name)
            if let detail = try? await catalog.tableDetail(ref) {
                self.pkColumns = detail.columns.filter(\.isPrimaryKey).map(\.name)
                self.foreignKeys = detail.foreignKeys
                self.detail = detail
                self.changeSet = ChangeSet(table: ref, pkColumns: self.pkColumns)
                self.detailLoaded = true
            } else {
                self.detailLoaded = true   // stays read-only (pkColumns empty)
            }
 // an empty editable table opens with one blank
            // row so you can start typing data immediately.
            // Network drivers ship no columns for a 0-row result — seed them from
            // the introspected detail so an empty table still shows its headers
            // and the blank row has cells to type into.
            if self.buffer.columns.isEmpty, let detail = self.detail {
                self.buffer.seedColumnsIfEmpty(detail.columns.map {
                    ColumnMeta(name: $0.name, declaredType: $0.declaredType)
                })
            }
            if self.canInsert, self.buffer.rowCount == 0, self.insertedRows.isEmpty {
                self.addInsertRow()
            }
        }
    }

    public func reload(session: Session) {
        discard()
        buffer.consume(QueryService.selectAll(
            table: TableRef(database: object.database, name: object.name),
            on: session,
            whereClause: filterClause.isEmpty ? nil : filterClause,
            orderBy: sortColumn.map { ($0, sortAscending) }
        ))
    }

 /// Column-header sort. Ignored while edits are pending — a reload
    /// would silently drop them.
    public func sort(by column: String, ascending: Bool, session: Session) {
        guard pendingCount == 0 else { return }
        sortColumn = column
        sortAscending = ascending
        reload(session: session)
    }

 /// Applies the user's WHERE fragment; same guard as sorting.
    public func applyFilter(session: Session) {
        guard pendingCount == 0 else { return }
        reload(session: session)
    }

 /// Retargets the WHERE filter and reloads (FK jump). Skips when edits
    /// are pending so they are never silently dropped.
    public func setFilterAndReload(_ clause: String, session: Session) {
        guard pendingCount == 0 else { return }
        filterClause = clause
        sortColumn = nil
        reload(session: session)
    }

 /// The foreign key defined on the column at `index`, if any.
    public func foreignKey(forColumnIndex index: Int) -> ForeignKeyInfo? {
        guard index < buffer.columns.count else { return nil }
        let columnName = buffer.columns[index].name
        return foreignKeys.first {
            $0.column.caseInsensitiveCompare(columnName) == .orderedSame
        }
    }

 // MARK: - Staging

    /// Primary-key values of a row, read from the ORIGINAL buffer content —
    /// never from the overlay, so a staged edit cannot corrupt its own WHERE.
    private func pkValues(forRow row: Int) -> ChangeSet.RowKey? {
        guard !pkColumns.isEmpty, row < buffer.rowCount else { return nil }
        var key: ChangeSet.RowKey = [:]
        for pkColumn in pkColumns {
            guard let index = buffer.columns.firstIndex(where: {
                $0.name.caseInsensitiveCompare(pkColumn) == .orderedSame
            }) else { return nil }
            key[pkColumn] = buffer.rows[row][index]
        }
        return key
    }

 /// Rows shown by the grid = streamed rows + locally inserted rows.
    public var totalRowCount: Int { buffer.rowCount + insertedRows.count }

    private func isInsertedRow(_ row: Int) -> Bool {
        row >= buffer.rowCount
    }

    public func displayValue(row: Int, column: Int) -> BerryValue? {
        if isInsertedRow(row) {
            let insertIndex = row - buffer.rowCount
            guard insertIndex < insertedRows.count, column < insertedRows[insertIndex].count else {
                return .null
            }
            return insertedRows[insertIndex][column]
        }
        return pendingDisplay[row]?[column]
    }

    public func isRowDeleted(_ row: Int) -> Bool {
        deletedRowIndexes.contains(row)
    }

 /// Appends a staged new row — all NULL until edited, so column
 /// DEFAULTs apply for anything the user leaves untouched.
    public func addInsertRow() {
        guard canInsert, !buffer.columns.isEmpty else { return }
        insertedRows.append(Array(repeating: .null, count: buffer.columns.count))
    }

    /// Paste-into-grid: parse clipboard text as TSV (Excel/Numbers/Sheets copy
    /// a cell range as tab-separated) or CSV (matches BerryDB's own "Copy as
    /// CSV", ClipboardFormatter.csv) and stage each line as an inserted row,
 /// same mechanism as `addInsertRow`. Reuses CSVParser (already the
    /// import parser) rather than a new one. Only guards on having columns to
    /// pad/truncate against — the "is this table insertable right now" check
    /// (canInsert) is the view layer's job (DataGridView only wires the Paste
    /// menu item when isEditable), same trust boundary ChangeSet itself uses.
    public func pasteRows(_ text: String) {
        guard !buffer.columns.isEmpty else { return }
        let delimiter: Character = text.contains("\t") ? "\t" : ","
        let columnCount = buffer.columns.count
        for record in CSVParser.parse(text, delimiter: delimiter) {
            var row = record.fields.map { field in
                field.isEmpty ? BerryValue.null : BerryValue.text(field)
            }
            if row.count > columnCount {
                row = Array(row.prefix(columnCount))
            } else if row.count < columnCount {
                row.append(contentsOf: Array(repeating: .null, count: columnCount - row.count))
            }
            insertedRows.append(row)
        }
    }

    /// Stages a cell edit typed as text; the new value is parsed against the
 /// ORIGINAL value's type so numbers stay numbers.
    public func stageEdit(row: Int, column: Int, text: String) {
        guard canInsert, column < buffer.columns.count else { return }
        if isInsertedRow(row) {
            let insertIndex = row - buffer.rowCount
            guard insertIndex < insertedRows.count else { return }
            insertedRows[insertIndex][column] = Self.parse(text: text, like: .null)
            return
        }
        guard let pk = pkValues(forRow: row), row < buffer.rowCount else { return }
        let original = buffer.rows[row][column]
        let newValue = Self.parse(text: text, like: original)
        guard newValue != original else { return }
        changeSet.stageUpdate(pk: pk, column: buffer.columns[column].name, value: newValue)
        pendingDisplay[row, default: [:]][column] = newValue
    }

 /// Explicit NULL — distinct from an empty string.
    public func stageNull(row: Int, column: Int) {
        guard canInsert, column < buffer.columns.count else { return }
        if isInsertedRow(row) {
            let insertIndex = row - buffer.rowCount
            guard insertIndex < insertedRows.count else { return }
            insertedRows[insertIndex][column] = .null
            return
        }
        guard let pk = pkValues(forRow: row) else { return }
        changeSet.stageUpdate(pk: pk, column: buffer.columns[column].name, value: .null)
        pendingDisplay[row, default: [:]][column] = .null
    }

    public func stageDeleteRows(_ rows: [Int]) {
        guard canInsert else { return }
        // Inserted rows are removed locally (descending order keeps indexes
        // stable); real rows stage a DELETE.
        for row in rows.filter(isInsertedRow).sorted(by: >) {
            let insertIndex = row - buffer.rowCount
            if insertIndex < insertedRows.count {
                insertedRows.remove(at: insertIndex)
            }
        }
        for row in rows where !isInsertedRow(row) {
            guard let pk = pkValues(forRow: row) else { continue }
            changeSet.stageDelete(pk: pk)
            deletedRowIndexes.insert(row)
            pendingDisplay[row] = nil
        }
    }

    public func discard() {
        changeSet.clear()
        pendingDisplay = [:]
        deletedRowIndexes = []
        insertedRows = []
        applyError = nil
    }

    /// ChangeSet + staged inserts combined — the exact statements previewed
 /// and applied (06). NULL cells are omitted from INSERTs so column
    /// DEFAULTs take effect.
    private func combinedChangeSet() -> ChangeSet {
        var combined = changeSet
        for rowValues in insertedRows {
            var values: ChangeSet.RowKey = [:]
            for (index, value) in rowValues.enumerated() where !value.isNull {
                guard index < buffer.columns.count else { continue }
                values[buffer.columns[index].name] = value
            }
            if !values.isEmpty {
                combined.stageInsert(values: values)
            }
        }
        return combined
    }

 /// SQL preview content (06 — always shown before writing).
    public func previewStatements(session: Session) -> [String] {
        combinedChangeSet().statements(dialect: session.dialect)
    }

 // MARK: - Apply (06)

    /// Must be called directly from the tap handler, before any `Task` is
    /// created — this is what makes `isApplying` (and the spinner/disabled
    /// state it drives, `BufferStatusBar`) flip instantly on tap instead of
    /// waiting for a `Task`'s turn on a possibly-busy MainActor, which
    /// otherwise reads as "the Apply button needs multiple clicks." Returns
    /// false (caller should not proceed) if there's nothing staged or a
    /// previous apply is still in flight.
    public func beginApply() -> Bool {
        guard !combinedChangeSet().isEmpty, !isApplying else { return false }
        isApplying = true
        applyError = nil
        return true
    }

    /// The async continuation of `beginApply()` — call only after it
    /// returns true, from inside a `Task`.
    public func finishApply(session: Session) async {
        do {
            try await combinedChangeSet().apply(on: session)
            reload(session: session)
        } catch {
            applyError = error.localizedDescription
        }
        isApplying = false
    }

    // MARK: - Text → BerryValue

    static func parse(text: String, like original: BerryValue) -> BerryValue {
        switch original {
        case .int:
            return Int64(text).map(BerryValue.int) ?? .text(text)
        case .double:
            return Double(text).map(BerryValue.double) ?? .text(text)
        case .decimal:
            return .decimal(text)
        case .bool:
            let lowered = text.lowercased()
            if ["1", "true", "t", "yes"].contains(lowered) { return .bool(true) }
            if ["0", "false", "f", "no"].contains(lowered) { return .bool(false) }
            return .text(text)
        case .null:
            // Typing into a NULL cell: numbers stay numeric, rest is text.
            if let int = Int64(text) { return .int(int) }
            if let double = Double(text) { return .double(double) }
            return .text(text)
        default:
            return .text(text)
        }
    }
}
