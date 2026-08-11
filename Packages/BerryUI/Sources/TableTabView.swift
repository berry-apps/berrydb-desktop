import AppKit
import BerryCore
import BerryDriverKit
import SwiftUI

/// One table tab: editable grid + pending-changes bar + SQL preview sheet
/// (DL-03/04/05 — docs/architecture/06 · L3).
struct TableTabView: View {
    @Bindable var state: TableTabState
    let session: Session?
    let isProduction: Bool
    /// FK jump (DL-08): open the referenced row in another table tab.
    var onOpenReference: ((ForeignKeyInfo, BerryValue) -> Void)?

    @AppStorage("ui.showButtonLabels") private var showButtonLabels = true
    @State private var showSQLExport = false
    @State private var showFilterBuilder = false
    @State private var exportMessage: String?
    @State private var viewerTarget: CellTarget?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            grid
            BufferStatusBar(
                buffer: state.buffer,
                showsProductionBadge: isProduction,
                pendingCount: state.pendingCount,
                isApplying: state.isApplying,
                applyError: state.applyError,
                readOnlyReason: (state.detailLoaded && !state.canInsert) ? L("Read-only: table has no primary key") : nil,
                canEdit: state.canEdit,
                onDiscard: {
                    state.discard()
                    if let session { state.reload(session: session) }
                },
                onApply: {
                    if let session, state.beginApply() {
                        Task { await state.finishApply(session: session) }
                    }
                }
            )
        }
        .sheet(item: $viewerTarget) { target in
            CellViewerSheet(
                value: target.value,
                columnName: target.columnName,
                editable: state.canEdit,
                onSave: { newText in
                    state.stageEdit(row: target.row, column: target.column, text: newText)
                }
            )
        }
        .sheet(isPresented: $showSQLExport) {
            SQLExportSheet(
                canIncludeDDL: state.detail != nil,
                onExport: { batchSize, includeDDL in
                    guard let session else { return nil }
                    let ddlHeader: String? = includeDDL ? state.detail.map { detail in
                        TableDesign(detail: detail)
                            .statements(dialect: session.dialect)
                            .joined(separator: ";\n") + ";"
                    } : nil
                    return await ExportPanel.presentSQL(
                        buffer: state.buffer,
                        table: TableRef(database: state.object.database, name: state.object.name),
                        dialect: session.dialect,
                        batchSize: batchSize,
                        ddlHeader: ddlHeader
                    )
                }
            )
        }
    }

    private var headerBar: some View {
        HStack(spacing: 4) {
            Button {
                if let session { state.reload(session: session) }
            } label: {
                Label(L("Reload"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session == nil)
            .help(Text(L("Reload")) + Text(verbatim: "  ⌘R"))

            Button {
                state.addInsertRow()
            } label: {
                Label(L("Add Row"), systemImage: "plus")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .disabled(!state.canInsert)
            .help(L("Add Row"))

            Button {
                Task {
                    exportMessage = await ExportPanel.present(buffer: state.buffer)
                }
            } label: {
                Label(L("Export…"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .disabled(state.buffer.rowCount == 0)
            .help(L("Export…"))

            Button {
                showSQLExport = true
            } label: {
                Label(L("Export SQL…"), systemImage: "curlybraces.square")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .disabled(state.buffer.rowCount == 0 || session == nil)
            .help(L("Export SQL…"))

            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Raw WHERE filter (DL-02) — user-authored, same trust as the editor.
            HStack(spacing: 4) {
                Text(verbatim: "WHERE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField(L("filter…"), text: $state.filterClause)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(state.pendingCount > 0)
                    .onSubmit {
                        if let session { state.applyFilter(session: session) }
                    }
            }
            .padding(.horizontal, 6)
            .frame(width: 220, height: 20)
            .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 1))

            Button {
                showFilterBuilder = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(IconButtonStyle(showsLabel: false))
            .help(L("Filter rows"))
            .accessibilityLabel(L("Filter rows"))
            .disabled(state.buffer.columns.isEmpty || state.pendingCount > 0)
            .popover(isPresented: $showFilterBuilder, arrowEdge: .bottom) {
                if let session {
                    FilterBuilderPopover(
                        columns: state.buffer.columns.map(\.name),
                        dialect: session.dialect
                    ) { clause in
                        state.filterClause = clause
                        state.applyFilter(session: session)
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(.bar)
    }

    private var grid: some View {
        DataGridView(
            buffer: state.buffer,
            isEditable: state.canInsert,
            overlay: { row, column in state.displayValue(row: row, column: column) },
            isRowDeleted: { row in state.isRowDeleted(row) },
            onEdit: { row, column, text in state.stageEdit(row: row, column: column, text: text) },
            onSetNull: { row, column in state.stageNull(row: row, column: column) },
            onDeleteRows: { rows in state.stageDeleteRows(rows) },
            onPasteRows: {
                guard let text = NSPasteboard.general.string(forType: .string) else { return }
                state.pasteRows(text)
            },
            copyFormats: GridCopyFormat.allCases,
            onCopy: { rows, format in
                GridCopy.copy(
                    format: format,
                    buffer: state.buffer,
                    rowIndexes: rows,
                    tableRef: TableRef(database: state.object.database, name: state.object.name),
                    dialect: session?.dialect
                )
            },
            appendedRowCount: state.insertedRows.count,
            onSort: { column, ascending in
                if let session { state.sort(by: column, ascending: ascending, session: session) }
            },
            onViewCell: { row, column in
                viewerTarget = CellTarget.from(
                    buffer: state.buffer,
                    row: row,
                    column: column,
                    overlayValue: state.displayValue(row: row, column: column)
                )
            },
            foreignKeyTarget: { column in
                state.foreignKey(forColumnIndex: column)?.referencedTable
            },
            onJumpToReference: { row, column in
                guard let fk = state.foreignKey(forColumnIndex: column),
                      let target = CellTarget.from(
                          buffer: state.buffer,
                          row: row,
                          column: column,
                          overlayValue: state.displayValue(row: row, column: column)
                      )
                else { return }
                onOpenReference?(fk, target.value)
            }
        )
    }

    /// Staged-changes bar: review before anything is written (06 · L3).
    // Navicat-style (docs/ui): Apply runs immediately, errors show inline —
    // no preview modal. Buttons use the app's compact styles.

}
