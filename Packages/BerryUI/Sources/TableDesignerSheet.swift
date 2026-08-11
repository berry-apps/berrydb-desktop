import BerryCore
import BerryDriverKit
import BerryGraph
import SwiftUI

/// Table designer (CT-01/02/03) — a form that edits a `TableDesign`, shows the
/// generated DDL live (CT-01 always-preview rule), and applies it through the
/// single SQL path. Creates a NEW table; ALTER of existing tables is a
/// separate follow-up (docs/architecture/06 · L3).
struct TableDesignerSheet: View {
    let preview: (TableDesign) -> [String]
    let onApply: (TableDesign) async -> String?

    /// Close this tool tab (docs/ui/02 §4).
    let onClose: () -> Void
    /// Non-nil when EDITING an existing table (CT-01/02/03 ALTER mode): the
    /// name is fixed and the caller's preview/apply closures diff against it.
    let editingExisting: TableDesign?
    /// Unsupported-edit warnings from the alteration diff (ALTER mode).
    let alterWarnings: (TableDesign) -> [String]
    /// AI Schema Review findings for the edit-in-progress (DI-15, ALTER mode).
    let migrationPreview: (TableDesign) -> [Insight]
    /// Existing table names for FK "referenced table" suggestions (CT-03).
    let tableNames: [String]
    /// Columns of a referenced table, for FK "referenced column" suggestions.
    let columnsProvider: (String) async -> [String]
    /// Connected engine — picks the dialect-aware type list (CT-05); the field
    /// stays free-text so any DBMS-specific type still works.
    let driver: DriverID

    @State private var design: TableDesign
    @State private var isApplying = false
    @State private var applyError: String?
    /// Fetched columns per referenced table, for FK column suggestions (CT-03).
    @State private var refColumnCache: [String: [String]] = [:]
    /// Debounced AI Schema Review results (see `schedulePreviewRefresh`) — the
    /// analyzer runs over the whole harvested schema graph, so it must not
    /// re-run synchronously in the view body on every keystroke.
    @State private var previewInsights: [Insight] = []
    @State private var previewTask: Task<Void, Never>?

    init(
        preview: @escaping (TableDesign) -> [String],
        onApply: @escaping (TableDesign) async -> String?,
        onClose: @escaping () -> Void,
        editingExisting: TableDesign? = nil,
        alterWarnings: @escaping (TableDesign) -> [String] = { _ in [] },
        migrationPreview: @escaping (TableDesign) -> [Insight] = { _ in [] },
        tableNames: [String] = [],
        columnsProvider: @escaping (String) async -> [String] = { _ in [] },
        driver: DriverID = .sqlite
    ) {
        self.preview = preview
        self.onApply = onApply
        self.onClose = onClose
        self.editingExisting = editingExisting
        self.alterWarnings = alterWarnings
        self.migrationPreview = migrationPreview
        self.tableNames = tableNames
        self.columnsProvider = columnsProvider
        self.driver = driver
        _design = State(initialValue: editingExisting ?? TableDesign(
            columns: [ColumnDesign(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true)]
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                form
                    .frame(minWidth: 460, idealWidth: 520)
                previewPane
                    .frame(minWidth: 300, idealWidth: 340)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { schedulePreviewRefresh() }
        .onChange(of: design) { schedulePreviewRefresh() }
        .onDisappear { previewTask?.cancel() }
    }

    /// Debounces the AI Schema Review re-run (DI-15) to once per typing pause
    /// instead of once per keystroke — `migrationPreview` runs `InsightEngine`
    /// over the whole harvested schema graph, the same cost class this
    /// codebase already debounces elsewhere for streaming markdown (100ms)
    /// and referenced-column prefetch (400ms); 400ms matches the latter since
    /// both are triggered by discrete keystrokes, not a token stream.
    private func schedulePreviewRefresh() {
        previewTask?.cancel()
        let current = design
        previewTask = Task {
            // nanoseconds, not Task.sleep(for:) — confirmed Swift runtime
            // crash risk in release builds (swiftlang/swift#86204, #84793;
            // docs/tests/crash.md), not a style choice.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            previewInsights = migrationPreview(current)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tablecells.badge.ellipsis")
            Text(editingExisting == nil ? L("New Table") : L("Edit Table")).font(.headline)
            Spacer()
            HStack(spacing: 4) {
                Text(verbatim: editingExisting == nil ? "CREATE TABLE" : "ALTER TABLE")
                    .font(.caption).foregroundStyle(.secondary)
                TextField(L("table_name"), text: $design.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 220)
                    .disabled(editingExisting != nil) // rename is out of v1 scope
            }
        }
        .padding(10)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                columnsSection
                Divider()
                indexesSection
                Divider()
                foreignKeysSection
            }
            .padding(12)
        }
    }

    // MARK: - Columns (CT-01)

    private var columnsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(L("Columns"), systemImage: "list.bullet") {
                design.columns.append(ColumnDesign())
            }
            ForEach($design.columns) { $column in
                columnRow($column)
            }
        }
    }

    private func columnRow(_ column: Binding<ColumnDesign>) -> some View {
        HStack(spacing: 6) {
            TextField(L("name"), text: column.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            typeField(column.type)
            Toggle(L("Null"), isOn: column.isNullable)
                .toggleStyle(.checkbox)
                .help(L("Allow NULL"))
            Toggle(L("PK"), isOn: column.isPrimaryKey)
                .toggleStyle(.checkbox)
                .help(L("Primary key"))
            TextField(L("default"), text: Binding(
                get: { column.wrappedValue.defaultValue ?? "" },
                set: { column.wrappedValue.defaultValue = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .frame(width: 90)
            Button {
                design.columns.removeAll { $0.id == column.wrappedValue.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel(L("Remove"))
        }
    }

    private func typeField(_ type: Binding<String>) -> some View {
        HStack(spacing: 2) {
            TextField(L("type"), text: type)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110)
            // Fixed-size, indicator-less menu — the default borderless menu adds
            // its own arrow and stretches, breaking the row (docs/ui/03).
            Menu {
                ForEach(SQLTypes.types(for: driver), id: \.self) { candidate in
                    Button(candidate) { type.wrappedValue = candidate }
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 18)
        }
    }

    // MARK: - Indexes (CT-02)

    private var indexesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(L("Indexes"), systemImage: "key") {
                design.indexes.append(IndexDesign())
            }
            if design.indexes.isEmpty {
                Text(L("No indexes")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach($design.indexes) { $index in
                HStack(spacing: 6) {
                    TextField(L("index_name"), text: $index.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField(L("columns (comma-separated)"), text: Binding(
                        get: { index.columns.joined(separator: ", ") },
                        set: { $index.columns.wrappedValue = splitList($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    Toggle(L("Unique"), isOn: $index.isUnique)
                        .toggleStyle(.checkbox)
                    Button {
                        design.indexes.removeAll { $0.id == index.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Foreign keys (CT-03)

    private var foreignKeysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(L("Foreign Keys"), systemImage: "link") {
                design.foreignKeys.append(ForeignKeyDesign())
            }
            if design.foreignKeys.isEmpty {
                Text(L("No foreign keys")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach($design.foreignKeys) { $fk in
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        // FK column is one of THIS table's columns.
                        suggestField(L("column"), text: $fk.column, width: 100,
                                     options: design.columns.map(\.name).filter { !$0.isEmpty })
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        // Referenced table from the known tables (CT-03).
                        suggestField(L("ref table"), text: $fk.referencedTable, width: 120,
                                     options: tableNames)
                        // Referenced column from that table's columns (fetched).
                        suggestField(L("ref column"), text: $fk.referencedColumn, width: 110,
                                     options: refColumnCache[fk.referencedTable] ?? [])
                            .task(id: fk.referencedTable) {
                                let table = fk.referencedTable
                                guard !table.isEmpty, refColumnCache[table] == nil else { return }
                                refColumnCache[table] = await columnsProvider(table)
                            }
                        Button {
                            design.foreignKeys.removeAll { $0.id == fk.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    HStack(spacing: 6) {
                        Text(L("ON DELETE")).font(.caption2).foregroundStyle(.secondary)
                        actionPicker($fk.onDelete)
                        Text(L("ON UPDATE")).font(.caption2).foregroundStyle(.secondary)
                        actionPicker($fk.onUpdate)
                        Spacer()
                    }
                }
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    /// A text field with a chevron menu of suggestions — type freely (for
    /// cross-schema or not-yet-created names) or pick a known one (CT-03).
    private func suggestField(_ placeholder: String, text: Binding<String>, width: CGFloat, options: [String]) -> some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
            if !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { text.wrappedValue = option }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 16)
            }
        }
    }

    private func actionPicker(_ action: Binding<ForeignKeyAction>) -> some View {
        Picker("", selection: action) {
            ForEach(ForeignKeyAction.allCases, id: \.self) { candidate in
                Text(candidate.rawValue).tag(candidate)
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    // MARK: - Preview + footer

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                Text(L("SQL Preview")).font(.headline)
            }
            .padding(10)
            Divider()
            // Unsupported edits are surfaced, never silently dropped (CT v1).
            ForEach(alterWarnings(design), id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            // AI Schema Review (DI-15) — findings this edit would introduce,
            // compared against the currently harvested schema. Debounced via
            // `schedulePreviewRefresh`, not called live here.
            ForEach(previewInsights) { insight in
                VStack(alignment: .leading, spacing: 2) {
                    Label(insight.title, systemImage: insightIcon(insight.severity))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(insightColor(insight.severity))
                    Text(insight.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
            ScrollView {
                Text(statements.joined(separator: ";\n\n"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.15))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let first = design.validationErrors.first {
                Label(first, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let applyError {
                Label(applyError, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer()
            Button(L("Cancel")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button {
                guard !isApplying else { return }
                isApplying = true
                Task {
                    applyError = await onApply(design)
                    isApplying = false
                    if applyError == nil { onClose() }
                }
            } label: {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Text(editingExisting == nil ? L("Create Table") : L("Apply Changes"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!design.isValid || isApplying
                || (editingExisting != nil && statements.isEmpty))
        }
        .padding(10)
    }

    private func sectionHeader(_ title: String, systemImage: String, add: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage).font(.subheadline).fontWeight(.semibold)
            Spacer()
            Button(action: add) {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L("Add"))
        }
    }

    private var statements: [String] {
        preview(design)
    }

    private func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Same severity → icon/color mapping as InsightPanelView, for visual consistency.
    private func insightIcon(_ severity: Insight.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "lightbulb"
        }
    }

    private func insightColor(_ severity: Insight.Severity) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}
