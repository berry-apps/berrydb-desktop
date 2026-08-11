import BerryCore
import BerryDriverKit
import Foundation
import Observation

/// Editing state for one editor query result (docs/ui/01 D4a, Navicat-style):
/// when the statement is a plain single-table SELECT whose primary key is in
/// the result, the grid stages edits/inserts/deletes exactly like a table tab —
/// local until the SQL preview is applied.
@MainActor
@Observable
final class ResultEditState {
    private(set) var changeSet: ChangeSet?
    private(set) var pkColumns: [String] = []
    private(set) var pendingDisplay: [Int: [Int: BerryValue]] = [:]
    private(set) var deletedRowIndexes: Set<Int> = []
    private(set) var insertedRows: [[BerryValue]] = []
    private(set) var isApplying = false
    var applyError: String?
    /// One-shot resolution guard — a result's editability never changes.
    private var resolved = false
    private weak var buffer: ResultBuffer?

    /// The resolved base table, set for any single-table SELECT that maps to a
    /// known table — even without a PK (needed for INSERT).
    private(set) var resolvedTable: TableRef?
    /// Why the result isn't (fully) editable, for a visible hint (docs/ui).
    private(set) var readOnlyReason: String?

    /// Editing EXISTING rows needs a primary key to target the row (06 · L3).
    var canEdit: Bool { changeSet != nil && !pkColumns.isEmpty }
    /// Inserting needs no PK — allowed for any single-table result (like the
    /// table grid). Existing PK-less rows stay read-only.
    var canInsert: Bool { resolvedTable != nil }
    var pendingCount: Int { (changeSet?.count ?? 0) + insertedRows.count }

    /// Decide whether this result maps to editable rows: a single-table SELECT
    /// (EditableSelect) over a known relational object. Full edit needs the PK
    /// present in the result; otherwise only inserts are allowed. Sets
    /// `readOnlyReason` on every rejection so the UI can explain why.
    func resolve(sql: String, buffer: ResultBuffer, objects: [SchemaObject], catalog: SchemaCatalog?) async {
        guard !resolved else { return }
        self.buffer = buffer
        await buffer.waitUntilFinished()
        resolved = true
        guard buffer.state == .complete else { return }
        guard let catalog else { readOnlyReason = "Not connected"; return }
        guard let tableName = EditableSelect.editableTable(for: sql) else {
            readOnlyReason = "Read-only: not a simple single-table SELECT"
            return
        }

        // "schema.table" or bare name → match against the known objects.
        let parts = tableName.split(separator: ".").map(String.init)
        let bare = parts.last ?? tableName
        let schema = parts.count > 1 ? parts[parts.count - 2] : nil
        guard let object = objects.first(where: { object in
            object.kind.isRelational
                && object.name.caseInsensitiveCompare(bare) == .orderedSame
                && (schema == nil
                    || object.database?.caseInsensitiveCompare(schema!) == .orderedSame)
        }) else {
            readOnlyReason = "Read-only: \"\(bare)\" isn't a known table"
            return
        }

        let ref = TableRef(database: object.database, name: object.name)
        resolvedTable = ref
        guard let detail = try? await catalog.tableDetail(ref) else {
            readOnlyReason = "Read-only: couldn't read \(object.name)'s columns"
            return
        }

        // Empty (0-row) result: network drivers ship no columns. For a
        // `SELECT *` we know the shape from the catalog — seed it so an empty
        // table still shows headers and can be edited (docs/ui, like Navicat).
        if buffer.columns.isEmpty {
            let flat = sql.replacingOccurrences(of: "\n", with: " ")
            let isStar = flat.range(
                of: "\\bselect\\s+\\*\\s+from\\b", options: [.regularExpression, .caseInsensitive]
            ) != nil
            if isStar {
                buffer.seedColumnsIfEmpty(detail.columns.map {
                    ColumnMeta(name: $0.name, declaredType: $0.declaredType)
                })
            }
            guard !buffer.columns.isEmpty else {
                readOnlyReason = "Empty result — use SELECT * to add rows"
                return
            }
        }

        let pk = detail.columns.filter(\.isPrimaryKey).map(\.name)
        let pkPresent = pk.allSatisfy { column in
            buffer.columns.contains { $0.name.caseInsensitiveCompare(column) == .orderedSame }
        }
        // Always allow inserts into a known table; enable full editing only when
        // the PK is present in the result (needed to target UPDATE/DELETE).
        changeSet = ChangeSet(table: ref, pkColumns: pk)
        if pk.isEmpty {
            readOnlyReason = "Add-only: \(object.name) has no primary key (can't edit existing rows)"
        } else if !pkPresent {
            pkColumns = []
            readOnlyReason = "Add-only: include the primary key (\(pk.joined(separator: ", "))) to edit rows"
        } else {
            pkColumns = pk
        }
    }

    // MARK: - Staging (mirrors the table grid, DL-03/04/05)

    private func pkValues(forRow row: Int) -> ChangeSet.RowKey? {
        guard let buffer, row < buffer.rowCount else { return nil }
        var key: ChangeSet.RowKey = [:]
        for pkColumn in pkColumns {
            guard let index = buffer.columns.firstIndex(where: {
                $0.name.caseInsensitiveCompare(pkColumn) == .orderedSame
            }) else { return nil }
            key[pkColumn] = buffer.rows[row][index]
        }
        return key
    }

    private func isInsertedRow(_ row: Int) -> Bool {
        row >= (buffer?.rowCount ?? 0)
    }

    func displayValue(row: Int, column: Int) -> BerryValue? {
        if isInsertedRow(row) {
            let insertIndex = row - (buffer?.rowCount ?? 0)
            guard insertIndex < insertedRows.count, column < insertedRows[insertIndex].count else {
                return .null
            }
            return insertedRows[insertIndex][column]
        }
        return pendingDisplay[row]?[column]
    }

    func isRowDeleted(_ row: Int) -> Bool { deletedRowIndexes.contains(row) }

    func addInsertRow() {
        guard canInsert, let buffer, !buffer.columns.isEmpty else { return }
        insertedRows.append(Array(repeating: .null, count: buffer.columns.count))
    }

    /// Paste-into-grid — mirrors `TableTabState.pasteRows` exactly (same
    /// CSVParser reuse, same empty→null/truncate/pad rules); only guards on
    /// having columns (not `canInsert`) since the view layer already gates
    /// whether the Paste menu item is offered at all (isEditable).
    func pasteRows(_ text: String) {
        guard let buffer, !buffer.columns.isEmpty else { return }
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

    func stageEdit(row: Int, column: Int, text: String) {
        guard canInsert, let buffer, column < buffer.columns.count else { return }
        if isInsertedRow(row) {
            let insertIndex = row - buffer.rowCount
            guard insertIndex < insertedRows.count else { return }
            insertedRows[insertIndex][column] = TableTabState.parse(text: text, like: .null)
            return
        }
        guard let pk = pkValues(forRow: row), row < buffer.rowCount else { return }
        let original = buffer.rows[row][column]
        let newValue = TableTabState.parse(text: text, like: original)
        guard newValue != original else { return }
        changeSet?.stageUpdate(pk: pk, column: buffer.columns[column].name, value: newValue)
        pendingDisplay[row, default: [:]][column] = newValue
    }

    func stageNull(row: Int, column: Int) {
        guard canInsert, let buffer, column < buffer.columns.count else { return }
        if isInsertedRow(row) {
            let insertIndex = row - buffer.rowCount
            guard insertIndex < insertedRows.count else { return }
            insertedRows[insertIndex][column] = .null
            return
        }
        guard let pk = pkValues(forRow: row) else { return }
        changeSet?.stageUpdate(pk: pk, column: buffer.columns[column].name, value: .null)
        pendingDisplay[row, default: [:]][column] = .null
    }

    func stageDeleteRows(_ rows: [Int]) {
        guard canInsert else { return }
        for row in rows.filter(isInsertedRow).sorted(by: >) {
            let insertIndex = row - (buffer?.rowCount ?? 0)
            if insertIndex < insertedRows.count {
                insertedRows.remove(at: insertIndex)
            }
        }
        for row in rows where !isInsertedRow(row) {
            guard let pk = pkValues(forRow: row) else { continue }
            changeSet?.stageDelete(pk: pk)
            deletedRowIndexes.insert(row)
            pendingDisplay[row] = nil
        }
    }

    func discard() {
        changeSet?.clear()
        pendingDisplay = [:]
        deletedRowIndexes = []
        insertedRows = []
        applyError = nil
    }

    /// ChangeSet + staged inserts — exactly what the preview shows and apply
    /// runs (06 · L3). NULL insert cells are omitted so DEFAULTs apply.
    private func combinedChangeSet() -> ChangeSet? {
        guard var combined = changeSet, let buffer else { return nil }
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

    func previewStatements(session: Session) -> [String] {
        combinedChangeSet()?.statements(dialect: session.dialect) ?? []
    }

    /// Apply in a transaction; on success clear the staging so the caller can
    /// re-run the SELECT for fresh rows. Returns whether it succeeded.
    func apply(session: Session) async -> Bool {
        guard let combined = combinedChangeSet(), !combined.isEmpty, !isApplying else { return false }
        isApplying = true
        applyError = nil
        var succeeded = false
        do {
            try await combined.apply(on: session)
            discard()
            succeeded = true
        } catch {
            applyError = error.localizedDescription
        }
        isApplying = false
        return succeeded
    }
}

