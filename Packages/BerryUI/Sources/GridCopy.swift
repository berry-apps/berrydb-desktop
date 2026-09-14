import AppKit
import BerryCore
import BerryDriverKit
import Foundation
import UniformTypeIdentifiers

/// Copy-as formats surfaced in the grid context menu.
enum GridCopyFormat: CaseIterable {
    case csv
    case json
    case markdown
    case sqlInsert

    var title: String {
        switch self {
        case .csv: String(localized: "Copy as CSV", bundle: berryModuleBundle)
        case .json: String(localized: "Copy as JSON", bundle: berryModuleBundle)
        case .markdown: String(localized: "Copy as Markdown", bundle: berryModuleBundle)
        case .sqlInsert: String(localized: "Copy as SQL INSERT", bundle: berryModuleBundle)
        }
    }
}

@MainActor
enum GridCopy {
    /// Builds the clipboard payload for the picked rows and puts it on the
    /// general pasteboard.
    static func copy(
        format: GridCopyFormat,
        buffer: ResultBuffer,
        rowIndexes: [Int],
        tableRef: TableRef?,
        dialect: (any SQLDialect)?
    ) {
        let rows = rowIndexes.compactMap { index in
            index < buffer.rowCount ? buffer.rows[index] : nil
        }
        guard !rows.isEmpty else { return }

        let text: String
        switch format {
        case .csv:
            text = ClipboardFormatter.csv(columns: buffer.columns, rows: rows)
        case .json:
            text = ClipboardFormatter.json(columns: buffer.columns, rows: rows)
        case .markdown:
            text = ClipboardFormatter.markdown(columns: buffer.columns, rows: rows)
        case .sqlInsert:
            guard let tableRef, let dialect else { return }
            text = ClipboardFormatter.sqlInserts(
                table: tableRef, columns: buffer.columns, rows: rows, dialect: dialect
            )
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Target of the cell viewer sheet.
struct CellTarget: Identifiable {
    let id = UUID()
    let row: Int
    let column: Int
    let value: BerryValue
    let columnName: String

    /// Resolves the target from a buffer, honoring an optional overlay value.
    @MainActor
    static func from(
        buffer: ResultBuffer,
        row: Int,
        column: Int,
        overlayValue: BerryValue? = nil
    ) -> CellTarget? {
        guard column < buffer.columns.count else { return nil }
        let value: BerryValue
        if let overlayValue {
            value = overlayValue
        } else if row < buffer.rowCount, column < buffer.rows[row].count {
            value = buffer.rows[row][column]
        } else {
            value = .null
        }
        return CellTarget(
            row: row, column: column,
            value: value, columnName: buffer.columns[column].name
        )
    }
}

/// Shared export flow: save panel → streaming ExportEngine over
/// the buffer's rows; format follows the chosen file extension.
@MainActor
enum ExportPanel {
    static func present(buffer: ResultBuffer) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.csv"
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [
            UTType.commaSeparatedText,
            UTType.tabSeparatedText,
            UTType.json,
            UTType(filenameExtension: "ndjson"),
        ].compactMap(\.self)

        // Accessory: format + encoding + header, so TSV and UTF-16 are reachable
 // instead of inferring everything from the file extension.
        let extensions = ["csv", "tsv", "json", "ndjson"]
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: [
            L("CSV (comma)"), L("TSV (tab)"), L("JSON array"), L("NDJSON"),
        ])
        let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        encodingPopup.addItems(withTitles: ["UTF-8", "UTF-16"])
        let headerCheck = NSButton(checkboxWithTitle: L("Include header row"), target: nil, action: nil)
        headerCheck.state = .on

        let stack = NSStackView(views: [
            NSTextField(labelWithString: L("Format:")), formatPopup,
            NSTextField(labelWithString: L("Encoding:")), encodingPopup,
            headerCheck,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        stack.frame = NSRect(x: 0, y: 0, width: 560, height: 40)
        panel.accessoryView = stack

        guard panel.runModal() == .OK, var url = panel.url else { return nil }

        let index = formatPopup.indexOfSelectedItem
        let ext = extensions[index]
        if url.pathExtension.lowercased() != ext {
            url = url.deletingPathExtension().appendingPathExtension(ext)
        }
        let encoding: String.Encoding = encodingPopup.indexOfSelectedItem == 1 ? .utf16 : .utf8
        let header = headerCheck.state == .on
        let format: ExportFormat = switch index {
        case 0: .csv(delimiter: ",", header: header, encoding: encoding)
        case 1: .csv(delimiter: "\t", header: header, encoding: encoding)
        case 2: .jsonArray
        default: .ndjson
        }
        do {
            let count = try await ExportEngine.export(
                columns: buffer.columns,
                rows: buffer.rows,
                to: url,
                format: format
            )
            return String(localized: "Exported \(count) rows", bundle: berryModuleBundle)
        } catch {
            return error.localizedDescription
        }
    }

 /// SQL export: INSERT statements with a chosen batch size and an
    /// optional CREATE TABLE header, saved via a `.sql` panel.
    static func presentSQL(
        buffer: ResultBuffer,
        table: TableRef,
        dialect: any SQLDialect,
        batchSize: Int,
        ddlHeader: String?
    ) async -> String? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql")].compactMap(\.self)
        panel.nameFieldStringValue = "\(table.name).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let count = try await ExportEngine.export(
                columns: buffer.columns,
                rows: buffer.rows,
                to: url,
                format: .sqlInsert(
                    table: table, dialect: dialect,
                    batchSize: batchSize, ddlHeader: ddlHeader
                )
            )
            return String(localized: "Exported \(count) rows", bundle: berryModuleBundle)
        } catch {
            return error.localizedDescription
        }
    }
}
