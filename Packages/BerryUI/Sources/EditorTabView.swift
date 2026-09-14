import AppKit
import BerryCore
import BerryDriverKit
import BerryGraph
import BerryStore
import SwiftUI

/// One SQL editor tab: editor on top, result sets below.
struct EditorTabView: View {
    @Bindable var document: EditorDocument
    let session: Session?
    let isProduction: Bool
    var objects: [SchemaObject] = []
    var catalog: SchemaCatalog?
 /// Manual transaction control — shared across the session's tabs.
    var transaction: TransactionController?
    /// Fires when this editor takes focus, so the workspace activates its split
 /// pane.
    var onFocus: (() -> Void)?
 /// Debounced session persistence — wired to the view model.
    var onPersist: (() -> Void)?
    var onRefreshSchema: (() -> Void)?
    var availableProfiles: [ConnectionProfile] = []
    var onAttachProfile: ((ConnectionProfile) -> Void)?
    /// Saves a Query Replay snapshot for this result's SQL + measured
 /// duration; returns how it compares to the
    /// previous saved snapshot of the same query, if any.
    var onSaveQueryReplay: ((String, Double) async -> QueryReplayComparator.Comparison?)?

 /// Label mode for the exec cluster — shared app-wide setting.
    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false

    @State private var warmTask: Task<Void, Never>?
    @State private var persistTask: Task<Void, Never>?
    @State private var viewerTarget: CellTarget?
 /// EXPLAIN results render as a tree; this switches to the raw grid.
    @State private var showPlanGrid = false
    /// Selected result tab (Message / Summary / Result N).
    @State private var selectedResultTab: ResultTabKey?
 /// Data vs Info sub-tab inside a result.
    @State private var resultSubTab: ResultSubTab = .data
    /// Whether the results pane is collapsed (only tab bar visible).
    @State private var resultsCollapsed = false
    /// Set right after "Save for Replay" when a previous snapshot of the same
    /// query exists, so its tooltip has something to show.
    @State private var replayComparison: QueryReplayComparator.Comparison?
    /// Brief checkmark confirmation after "Save for Replay" (matches
    /// `CopyButton`'s pattern elsewhere in this file's family of views).
    @State private var justSavedReplay = false
 /// Visualize Result — chart sheet for the currently
    /// displayed result.
    @State private var showVisualize = false
    /// Set synchronously in `run(_:)`'s manual-transaction branch, before its
    /// `Task` — `document.isRunning` (which normally gives instant Run
    /// feedback) doesn't flip until `transaction.beginIfNeeded` resolves in
    /// that branch, so without this a second Run tap while a transaction is
    /// still starting looks like the first one did nothing.
    @State private var isBeginningTransaction = false

    var body: some View {
        VSplitView {
            editorPane
                .frame(minHeight: 140, maxHeight: .infinity)
            resultsPane
                .frame(minHeight: resultsCollapsed ? 28 : 100, maxHeight: resultsCollapsed ? 28 : .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: document.text) {
            warmReferencedColumns()
            schedulePersist()
        }
        .onDisappear {
            warmTask?.cancel()
            persistTask?.cancel()
            onPersist?()
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            // nanoseconds, not Task.sleep(for:) — confirmed Swift runtime
            // crash risk in release builds (swiftlang/swift#86204, #84793;
 // not a style choice.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            onPersist?()
        }
    }

 /// Pre-fetches columns for the tables referenced in the document
    /// so the completion callback can stay synchronous.
    private func warmReferencedColumns() {
        guard let catalog, document.text.utf8.count <= 256 * 1024 else { return }
        warmTask?.cancel()
        let snapshotObjects = objects
        warmTask = Task { [text = document.text] in
            // nanoseconds, not Task.sleep(for:) — see schedulePersist above.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let tables = CompletionProvider.referencedTables(statement: text, objects: snapshotObjects)
            for table in tables where document.columnsByTable[table] == nil {
                guard !Task.isCancelled else { return }
                guard let object = snapshotObjects.first(where: {
                    $0.name.caseInsensitiveCompare(table) == .orderedSame
                }) else { continue }
                let ref = TableRef(database: object.database, name: object.name)
                if let detail = try? await catalog.tableDetail(ref) {
                    document.columnsByTable[table] = detail.columns.map(\.name)
                }
            }
        }
    }

    private var editorPane: some View {
        VStack(spacing: 0) {
 // ONE exec button: it runs every statement in the active
            // editor; ⌘R / ⌘↩ do the same. DangerGuard confirms any
            // data-destroying statement before it executes.
            QueryTabToolbar(
                canRun: session != nil && !document.isRunning && !isBeginningTransaction,
                isRunning: document.isRunning || isBeginningTransaction,
                isProduction: isProduction,
                onRun: { runSmart() },
                onStop: { document.cancel(session: session) },
                leading: {
                    if session?.capabilities.explain == true {
                        Button {
                            if let session { document.explain(on: session) }
                        } label: {
                            Label(L("Explain"), systemImage: "chart.bar.doc.horizontal")
                        }
                        .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
                        .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(document.isRunning)
                        .help(Text(L("Explain")) + Text(verbatim: "  ⌘E"))
                    }
                    Button {
                        document.formatRequestID += 1
                    } label: {
                        Label(L("Format"), systemImage: "text.alignleft")
                    }
                    .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
                    .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(document.text.isEmpty)
                    .help(Text(L("Format")) + Text(verbatim: "  ⇧⌘L"))
                },
                trailing: {
                    if session == nil || document.isDetached {
                        Menu {
                            if availableProfiles.isEmpty {
                                Text(L("No Saved Connections"))
                            } else {
                                ForEach(availableProfiles) { profile in
                                    Button(profile.name) {
                                        onAttachProfile?(profile)
                                    }
                                }
                            }
                        } label: {
                            Label(L("Attach Connection to Run"), systemImage: "bolt.badge.link")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    autoLimitControl
                    transactionControls
                }
            )
            Divider()

            SQLEditorTextView(
                text: $document.text,
                onCursorMove: { document.cursorLocation = $0 },
                onSelectionChange: { document.selectedRange = $0 },
                // Execution rule: ⌘R/⌘↩ run the selection if there is
                // one, else the whole editor. ⇧⌘↩ always runs everything.
                onRunCurrent: { selection in runSmart(selection: selection) },
                onRunAll: { runAll() },
                formatRequestID: document.formatRequestID,
                commentToggleRequestID: document.commentToggleRequestID,
                completionItems: { script, cursor in
                    let dialect = session?.dialect
                    let builtins = session.map { SQLBuiltins.functions(for: $0.config.driver) } ?? []
 // Dialect-specific commands (PRAGMA/USE/COPY…) alongside builtins.
                    let statements = session.map { SQLStatements.statements(for: $0.config.driver) } ?? []
                    return CompletionProvider.suggestions(
                        script: script,
                        utf16Cursor: cursor,
                        objects: objects,
                        columnsByTable: document.columnsByTable,
                        builtins: builtins,
                        statements: statements
                    ).prefix(50).map { suggestion in
                        let display = suggestion.text
                        var insert = display
                        switch suggestion {
                        case .keyword:
                            break
                        case .builtin:
                            // Built-ins insert callable form, never quoted (P1.4).
                            insert = display + "()"
                        case .snippet(_, let template, _):
                            insert = template
                        default:
                            // Quote identifiers that need it so a PascalCase/odd
 // name survives; display stays bare.
                            if let dialect, CompletionProvider.identifierNeedsQuoting(display) {
                                insert = dialect.quoteIdentifier(display)
                            }
                        }
                        return CompletionItem(
                            display: display,
                            insert: insert,
                            icon: suggestion.iconName,
                            detail: suggestion.detail
                        )
                    }
                },
                onFocus: onFocus,
                pendingFocus: document.pendingFocus,
                pendingSelection: document.pendingSelection,
                onDidFocus: { document.pendingFocus = false }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

 /// Automatic row-cap selector — change or turn off the SELECT LIMIT.
    private var autoLimitControl: some View {
        Menu {
            Button(L("No limit")) { document.autoLimit = nil }
            Divider()
            ForEach([100, 500, 1000, 5000], id: \.self) { n in
                Button { document.autoLimit = n } label: { Text(verbatim: "\(n)") }
            }
        } label: {
            Text(verbatim: document.autoLimit.map { "LIMIT \($0)" } ?? "LIMIT ∞")
                .font(BerryTheme.Typeface.ui(12, .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Automatic row limit"))
    }

 /// Manual transaction controls — only when the driver supports
    /// transactions. Auto-commit toggle plus Commit/Rollback while a
    /// transaction is open.
    @ViewBuilder
    private var transactionControls: some View {
        if let transaction, session?.capabilities.transactions == true {
            HStack(spacing: 6) {
                if transaction.isActive {
                    Label(L("In transaction"), systemImage: "circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button(L("Commit")) {
                        if let session { Task { await transaction.commit(session: session) } }
                    }
                    .help(Text(verbatim: "COMMIT"))
                    Button(L("Rollback")) {
                        if let session { Task { await transaction.rollback(session: session) } }
                    }
                    .help(Text(verbatim: "ROLLBACK"))
                }
                Toggle(L("Auto-commit"), isOn: Binding(
                    get: { transaction.autoCommit },
                    set: { newValue in
                        // Instant toggle feedback — setAutoCommit's own
                        // assignment is only reached once the Task below gets
                        // its MainActor turn, which otherwise reads as the
                        // switch not responding to the click.
                        transaction.autoCommit = newValue
                        if let session { Task { await transaction.setAutoCommit(newValue, session: session) } }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            .disabled(document.isRunning)
        }
    }

    // MARK: - Result area (Message / Summary / Result N tabs;
    // Data / Info sub-tabs inside a result).

    /// Result sets (statements with columns), numbered sequentially. A SELECT
    /// that returned 0 rows still counts — network drivers ship no columns for
    /// an empty table, so we keep its tab and seed columns from the catalog.
    private var resultSets: [(number: Int, result: EditorResult)] {
        var output: [(Int, EditorResult)] = []
        var number = 0
        for result in document.results where isResultSet(result) {
            number += 1
            output.append((number, result))
        }
        return output
    }

    private func isResultSet(_ result: EditorResult) -> Bool {
        if !result.buffer.columns.isEmpty { return true }
        guard result.buffer.state == .complete else { return false }
        let head = result.sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("select") || head.hasPrefix("with") || head.hasPrefix("table")
    }

    /// The effective selected tab, defaulting to the first result set.
    private var effectiveResultTab: ResultTabKey {
        if let selected = selectedResultTab {
            switch selected {
            case .message, .summary:
                return selected
            case .result(let id):
                if resultSets.contains(where: { $0.result.id == id }) { return selected }
            }
        }
        return resultSets.first.map { .result($0.result.id) } ?? .message
    }

    @ViewBuilder
    private var resultsPane: some View {
        QueryResultContainerView(
            isEmpty: document.results.isEmpty,
            isCollapsed: $resultsCollapsed,
            tabs: {
                AnyView(
                    HStack(spacing: 2) {
                        resultTab(.message, label: L("Message"), icon: "text.alignleft")
                        resultTab(.summary, label: L("Summary"), icon: "info.circle")
                        ForEach(resultSets, id: \.result.id) { entry in
                            resultTab(
                                .result(entry.result.id),
                                label: L("Result \(entry.number)"),
                                buffer: entry.result.buffer
                            )
                        }
                    }
                )
            },
            headerActions: {
                Group {
                    if case .result(let id) = effectiveResultTab,
                       let result = document.results.first(where: { $0.id == id }) {
                        resultActions(result)
                        Divider().frame(height: 14)
                    }
                }
            },
            content: {
                resultContent
            }
        )
    }

    private func resultTab(_ key: ResultTabKey, label: String, icon: String? = nil, buffer: ResultBuffer? = nil) -> some View {
        let selected = effectiveResultTab == key
        return Button {
            selectedResultTab = key
            resultSubTab = .data
        } label: {
            HStack(spacing: 4) {
                if let buffer {
                    statusDot(buffer)
                } else if let icon {
                    Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                }
                Text(label).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected ? AnyShapeStyle(BerryTheme.accent.opacity(0.16)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
    }

    /// A Data / Info sub-tab chip — same look as the Result N tabs so the
 /// header reads as one consistent tab strip.
    private func subTab(_ tab: ResultSubTab, label: String, icon: String) -> some View {
        let selected = resultSubTab == tab
        return Button {
            resultSubTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(label).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected ? AnyShapeStyle(BerryTheme.accent.opacity(0.16)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
    }

    /// Data | Info toggle plus the grid actions, contextual to a result tab.
    private func resultActions(_ result: EditorResult) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                subTab(.data, label: L("Data"), icon: "tablecells")
                subTab(.info, label: L("Info"), icon: "info.circle")
            }
            if resultSubTab == .data {
                if result.editing.canInsert {
                    Button { result.editing.addInsertRow() } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.iconAction).help(L("Add Row"))
                }
                if planTree(for: result) != nil {
                    Button { showPlanGrid.toggle() } label: {
                        Image(systemName: showPlanGrid ? "arrow.triangle.branch" : "tablecells")
                    }
                    .buttonStyle(.iconAction)
                    .help(showPlanGrid ? L("Show Plan Tree") : L("Show Grid"))
                }
                Button { Task { _ = await ExportPanel.present(buffer: result.buffer) } } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.iconAction).help(L("Export…"))
                .disabled(result.buffer.rowCount == 0)
 // Visualize Result — only a quick,
                // first-row check for "has a numeric column" (not a full
                // table scan every render; the sheet itself handles "no
                // numeric values after all" gracefully).
                Button { showVisualize = true } label: {
                    Image(systemName: "chart.bar")
                }
                .buttonStyle(.iconAction).help(L("Visualize Result"))
                .disabled(result.buffer.columns.count < 2
                    || !(result.buffer.rows.first?.contains { $0.numericValue != nil } ?? false))
                .sheet(isPresented: $showVisualize) {
                    VisualizeResultView(
                        columns: result.buffer.columns, rows: result.buffer.rows,
                        onClose: { showVisualize = false }
                    )
                }
                if let onSaveQueryReplay, let stats = result.buffer.stats {
                    Button {
                        Task {
                            replayComparison = await onSaveQueryReplay(result.sql, Self.milliseconds(stats.duration))
                            justSavedReplay = true
                            // nanoseconds, not Task.sleep(for:) — see
                            // schedulePersist above.
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            justSavedReplay = false
                        }
                    } label: {
                        Image(systemName: justSavedReplay ? "checkmark" : "clock.badge.checkmark")
                    }
                    .buttonStyle(.iconAction)
                    .help(replayComparisonHelp)
                    .accessibilityLabel(L("Save for Replay"))
                }
            }
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

 /// Tooltip text for the "Save for Replay" button
 /// — the comparison against the previous saved snapshot when one
    /// exists, otherwise a plain explanation of what the button does.
    private var replayComparisonHelp: String {
        guard let replayComparison else {
            return L("Save this run for later comparison")
        }
        let laterMS = Int(replayComparison.later.durationMS.rounded())
        let earlierMS = Int(replayComparison.earlier.durationMS.rounded())
        guard let percent = replayComparison.percentChange else {
            return "\(laterMS)ms (\(L("was")) \(earlierMS)ms)"
        }
        let direction = replayComparison.improved ? L("faster") : L("slower")
        return "\(laterMS)ms (\(L("was")) \(earlierMS)ms, \(Int(abs(percent).rounded()))% \(direction))"
    }

    @ViewBuilder
    private var resultContent: some View {
        switch effectiveResultTab {
        case .message:
            messageLogView
        case .summary:
            summaryView
        case .result(let id):
            if let result = document.results.first(where: { $0.id == id }) {
                resultBody(result)
                    .task(id: result.id) {
                        await result.editing.resolve(
                            sql: result.sql, buffer: result.buffer,
                            objects: objects, catalog: catalog
                        )
                    }
            }
        }
    }

    @ViewBuilder
    private func resultBody(_ result: EditorResult) -> some View {
        if resultSubTab == .info {
            resultInfoView(result)
        } else if case .failed(let message) = result.buffer.state {
            QueryErrorView(message: message)
        } else if let plan = planTree(for: result), !showPlanGrid {
            ExplainTreeView(nodes: plan)
        } else {
            VStack(spacing: 0) {
                DataGridView(
                    buffer: result.buffer,
                    isEditable: result.editing.canInsert,
                    overlay: { row, column in result.editing.displayValue(row: row, column: column) },
                    isRowDeleted: { row in result.editing.isRowDeleted(row) },
                    onEdit: { row, column, text in
                        result.editing.stageEdit(row: row, column: column, text: text)
                    },
                    onSetNull: { row, column in result.editing.stageNull(row: row, column: column) },
                    onDeleteRows: { rows in result.editing.stageDeleteRows(rows) },
                    onPasteRows: {
                        guard let text = NSPasteboard.general.string(forType: .string) else { return }
                        result.editing.pasteRows(text)
                    },
                    copyFormats: [.csv, .json, .markdown],
                    onCopy: { rows, format in
                        GridCopy.copy(
                            format: format, buffer: result.buffer,
                            rowIndexes: rows, tableRef: nil, dialect: nil
                        )
                    },
                    appendedRowCount: result.editing.insertedRows.count,
                    onViewCell: { row, column in
                        viewerTarget = CellTarget.from(buffer: result.buffer, row: row, column: column)
                    }
                )
                .sheet(item: $viewerTarget) { target in
                    CellViewerSheet(
                        value: target.value, columnName: target.columnName,
                        editable: false, onSave: nil
                    )
                }
                BufferStatusBar(
                    buffer: result.buffer,
                    showsProductionBadge: isProduction,
                    pendingCount: result.editing.pendingCount,
                    isApplying: result.editing.isApplying,
                    applyError: result.editing.applyError,
                    readOnlyReason: result.editing.readOnlyReason,
                    canEdit: result.editing.canEdit,
                    onDiscard: { result.editing.discard() },
                    onApply: { applyResultEdits(result) }
                )
            }
        }
    }

    /// Run log — one line per statement ("Message").
    private var messageLogView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(document.results.enumerated()), id: \.element.id) { index, result in
                    HStack(alignment: .top, spacing: 8) {
                        statusDot(result.buffer)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "[\(index + 1)] \(result.label)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(messageLine(result))
                                .font(.caption)
                                .textSelection(.enabled)
                                .foregroundStyle(isFailure(result) ? .red : .primary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    /// Aggregate overview of the whole run ("Summary").
    private var summaryView: some View {
        let total = document.results.count
        let failed = document.results.filter(isFailure).count
        let rows = document.results.reduce(0) { $0 + $1.buffer.rowCount }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow(L("Statements"), "\(total)")
                summaryRow(L("Succeeded"), "\(total - failed)")
                if failed > 0 { summaryRow(L("Failed"), "\(failed)") }
                summaryRow(L("Result sets"), "\(resultSets.count)")
                summaryRow(L("Rows returned"), "\(rows)")
                summaryRow(L("Total time"), totalDurationText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    /// Column metadata + stats for one result ("Info").
    private func resultInfoView(_ result: EditorResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Query")).font(.caption).foregroundStyle(.secondary)
                Text(result.sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text(L("Columns")).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(result.buffer.columns.enumerated()), id: \.offset) { _, column in
                    HStack {
                        Text(column.name).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(column.declaredType).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                summaryRow(L("Rows"), "\(result.buffer.rowCount)")
                if let stats = result.buffer.stats {
                    summaryRow(L("Duration"), BufferStatusBar.format(stats.duration))
                    if let affected = stats.rowsAffected {
                        summaryRow(L("Affected"), "\(Int(affected))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .font(.callout)
    }

    private func isFailure(_ result: EditorResult) -> Bool {
        if case .failed = result.buffer.state { return true }
        return false
    }

    private func messageLine(_ result: EditorResult) -> String {
        switch result.buffer.state {
        case .running: return L("Running…")
        case .cancelled: return L("Cancelled — kept \(result.buffer.rowCount) received rows")
        case .failed(let message): return message
        case .complete:
            let time = result.buffer.stats.map { " · " + BufferStatusBar.format($0.duration) } ?? ""
            if let affected = result.buffer.stats?.rowsAffected {
                return L("\(Int(affected)) row(s) affected") + time
            }
            return L("\(result.buffer.rowCount) row(s) returned") + time
        }
    }

    private var totalDurationText: String {
        let total = document.results.compactMap { $0.buffer.stats?.duration }
            .reduce(Duration.zero, +)
        return BufferStatusBar.format(total)
    }

 /// The plan tree for an EXPLAIN result, when its output parses.
    private func planTree(for result: EditorResult) -> [PlanNode]? {
        guard result.buffer.state == .complete,
              result.sql.trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased().hasPrefix("explain")
        else { return nil }
        return ExplainTreeParser.parse(columns: result.buffer.columns, rows: result.buffer.rows)
    }


 /// Apply staged edits directly. On success re-run the SELECT for
    /// fresh rows; on failure `editing.applyError` shows inline under the grid.
    private func applyResultEdits(_ result: EditorResult) {
        guard let session else { return }
        Task {
            if await result.editing.apply(session: session) {
                result.buffer.consume(QueryService.execute(
                    result.sql, on: session, autoLimit: document.autoLimit
                ))
            }
        }
    }

    private func statusDot(_ buffer: ResultBuffer) -> some View {
        let color: Color = switch buffer.state {
        case .running: .blue
        case .complete: .green
        case .cancelled: .orange
        case .failed: .red
        }
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    /// Query execution rule: a non-empty selection runs only the
    /// highlighted SQL; an empty selection runs the whole editor.
    private func runSmart(selection: NSRange? = nil) {
        let range = selection ?? document.selectedRange
        if range.length > 0 {
            run(.current(selection: range))
        } else {
            run(.all)
        }
    }

    private func runAll() {
        run(.all)
    }

    private func run(_ mode: EditorDocument.RunMode) {
        guard let session else { return }
        // Driver connections have no pool (one physical connection per tab), so
        // a still-in-flight autocomplete warm-up (tableDetail introspection)
        // would otherwise contend with — and delay — the query the user is
        // actually waiting on. Running now always wins.
        warmTask?.cancel()
        let handleCompletion = {
            let statements = document.statements(for: mode)
            let hasDDL = statements.contains { sql in
                let upper = sql.uppercased()
                return upper.contains("CREATE ") || upper.contains("DROP ") || upper.contains("ALTER ") || upper.contains("TRUNCATE ") || upper.contains("RENAME ")
            }
            if hasDDL {
                onRefreshSchema?()
            }
        }
        if let transaction, !transaction.autoCommit {
            guard !isBeginningTransaction, !document.isRunning else { return }
            isBeginningTransaction = true
            Task {
                let began = await transaction.beginIfNeeded(session: session)
                isBeginningTransaction = false
                if began {
                    document.run(mode, on: session, onCompleted: handleCompletion)
                }
            }
        } else {
            document.run(mode, on: session, onCompleted: handleCompletion)
        }
    }
}

/// Result tab navigation keys.
private enum ResultTabKey: Hashable {
    case message
    case summary
    case result(UUID)
}

private enum ResultSubTab: Hashable {
    case data
    case info
}
