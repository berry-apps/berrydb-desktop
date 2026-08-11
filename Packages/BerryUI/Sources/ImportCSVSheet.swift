import AppKit
import BerryCore
import BerryDriverKit
import SwiftUI
import UniformTypeIdentifiers

/// CSV import (XN-05): pick a file, choose the target table, map source columns
/// to table columns, and run. The whole import is transactional; failures are
/// reported by source line. Small enough to fit without internal scrolling
/// except the (bounded) mapping list.
struct ImportCSVSheet: View {
    let tables: [SchemaObject]
    let loadColumns: (SchemaObject) async -> [String]
    let onImport: (_ records: [CSVParser.Record], _ table: SchemaObject,
                   _ mapping: [CSVImporter.ColumnMapping], _ batchSize: Int) async -> String

    /// Close this tool tab (docs/ui/02 §4).
    let onClose: () -> Void

    @State private var fileURL: URL?
    @State private var records: [CSVParser.Record] = []
    @State private var delimiter: DelimiterOption = .comma
    @State private var hasHeader = true
    @State private var batchSize = 100
    @State private var selectedTable: SchemaObject?
    @State private var mappings: [MappingRow] = []
    @State private var result: String?
    @State private var isRunning = false

    enum DelimiterOption: String, CaseIterable, Identifiable {
        case comma, semicolon, tab
        var id: String { rawValue }
        var character: Character {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            }
        }
        var label: String {
            switch self {
            case .comma: "Comma ( , )"
            case .semicolon: "Semicolon ( ; )"
            case .tab: "Tab"
            }
        }
    }

    struct MappingRow: Identifiable {
        let id = UUID()
        let tableColumn: String
        var sourceIndex: Int?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.and.arrow.down")
                Text(L("Import CSV")).font(.headline)
                Spacer()
            }
            .padding(10)
            Divider()

            HStack(alignment: .top, spacing: 0) {
                optionsColumn
                    .frame(width: 320)
                Divider()
                mappingColumn
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Options

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                pickFile()
            } label: {
                Label(fileURL?.lastPathComponent ?? L("Choose File…"), systemImage: "doc")
                    .lineLimit(1)
            }

            Picker(L("Delimiter"), selection: $delimiter) {
                ForEach(DelimiterOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .onChange(of: delimiter) { reparse() }

            Toggle(L("First row is header"), isOn: $hasHeader)
                .onChange(of: hasHeader) { rebuildMappings() }

            HStack {
                Text(L("Rows per INSERT"))
                Stepper(value: $batchSize, in: 1...1000, step: 10) {
                    Text(verbatim: "\(batchSize)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 46, alignment: .trailing)
                }
            }

            Picker(L("Target table"), selection: Binding(
                get: { selectedTable?.id },
                set: { id in selectedTable = tables.first { $0.id == id }; loadTable() }
            )) {
                Text(L("Select…")).tag(String?.none)
                ForEach(tables) { table in
                    Text(table.name).tag(Optional(table.id))
                }
            }

            if !records.isEmpty {
                Text(L("\(dataRecordCount) data rows")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Mapping + preview

    private var mappingColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Column mapping")).font(.subheadline).fontWeight(.semibold)
            if selectedTable == nil {
                Text(L("Pick a target table to map columns")).font(.caption).foregroundStyle(.secondary)
            } else if mappings.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach($mappings) { $row in
                            HStack {
                                Text(row.tableColumn)
                                    .font(.system(.callout, design: .monospaced))
                                    .frame(width: 150, alignment: .leading)
                                Image(systemName: "arrow.left").foregroundStyle(.secondary)
                                Picker("", selection: $row.sourceIndex) {
                                    Text(L("(skip)")).tag(Int?.none)
                                    ForEach(sourceColumns.indices, id: \.self) { index in
                                        Text(sourceColumns[index]).tag(Optional(index))
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 220)

                Divider()
                previewTable
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var previewTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Preview")).font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(previewRows.enumerated()), id: \.offset) { _, record in
                        HStack(spacing: 8) {
                            ForEach(record.fields.indices, id: \.self) { i in
                                Text(record.fields[i])
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(minWidth: 60, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 140)
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack {
            if let result {
                Text(result).font(.caption)
                    .foregroundStyle(result.contains("failed") ? .red : .secondary)
            }
            Spacer()
            Button(L("Cancel")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button {
                runImport()
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("Import"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canImport || isRunning)
        }
        .padding(10)
    }

    // MARK: - Derived

    private var sourceColumns: [String] {
        guard let first = records.first else { return [] }
        if hasHeader {
            return first.fields
        }
        return (0..<first.fields.count).map { String(localized: "Column \($0 + 1)", bundle: berryModuleBundle) }
    }

    private var dataRecords: [CSVParser.Record] {
        hasHeader ? Array(records.dropFirst()) : records
    }

    private var dataRecordCount: Int { dataRecords.count }

    private var previewRows: [CSVParser.Record] {
        Array(dataRecords.prefix(8))
    }

    private var canImport: Bool {
        selectedTable != nil && !dataRecords.isEmpty && mappings.contains { $0.sourceIndex != nil }
    }

    // MARK: - Actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        reparse()
    }

    private func reparse() {
        guard let fileURL else {
            records = []
            return
        }
        // Read + parse off the main actor — a large CSV would otherwise block the
        // UI (and re-parse on every delimiter change). `CSVParser.Record` is
        // Sendable, so the result crosses back safely.
        let delim = delimiter.character
        Task {
            let parsed: [CSVParser.Record] = await Task.detached {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
                return CSVParser.parse(text, delimiter: delim)
            }.value
            records = parsed
            rebuildMappings()
        }
    }

    private func loadTable() {
        guard let selectedTable else { return }
        mappings = []
        Task {
            let columns = await loadColumns(selectedTable)
            await MainActor.run {
                mappings = columns.map { MappingRow(tableColumn: $0, sourceIndex: nil) }
                autoMatch()
            }
        }
    }

    private func rebuildMappings() {
        guard selectedTable != nil, !mappings.isEmpty else { return }
        autoMatch()
    }

    /// Auto-maps each table column to a source column with a matching name.
    private func autoMatch() {
        let source = sourceColumns
        mappings = mappings.map { row in
            var updated = row
            updated.sourceIndex = source.firstIndex {
                $0.caseInsensitiveCompare(row.tableColumn) == .orderedSame
            }
            return updated
        }
    }

    private func runImport() {
        guard let selectedTable, !isRunning else { return }
        let mapping = mappings.compactMap { row -> CSVImporter.ColumnMapping? in
            guard let index = row.sourceIndex else { return nil }
            return CSVImporter.ColumnMapping(csvIndex: index, tableColumn: row.tableColumn)
        }
        isRunning = true
        Task {
            result = await onImport(dataRecords, selectedTable, mapping, batchSize)
            isRunning = false
        }
    }
}
