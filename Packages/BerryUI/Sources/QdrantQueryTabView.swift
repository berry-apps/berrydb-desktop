import BerryDataSourceKit
import SwiftUI

/// One Qdrant query tab (docs/feature/03): a hybrid Form/JSON editor on top, the
/// result grid below — the vector sibling of `MongoShellTabView`. Reads stream
/// into the grid; writes (upsert/delete points) go through `onApplyWrite` so the
/// danger-gate/confirm is never bypassed.
struct QdrantQueryTabView: View {
    @Bindable var state: QdrantQueryTabState
    let session: DataSourceSession?
    let isProduction: Bool
    let collections: [String]
    let onApplyWrite: (DataSourceChangeSet) async -> DataSourceWriteOutcome
    var onRefreshSchema: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    /// Same reasoning as MongoShellTabView.onFocus: without this,
    /// focusedGroupID never follows a Qdrant tab into a split pane.
    var onFocus: (() -> Void)?

    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                editor
                    .frame(minHeight: 140, maxHeight: .infinity)
                resultsPane
                    .frame(minHeight: 100, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        QueryTabToolbar(
            canRun: session != nil && !state.isRunning,
            isRunning: state.isRunning,
            isProduction: isProduction,
            onRun: run,
            onStop: { state.cancel() },
            leading: {
                if let onSave {
                    Button(action: onSave) {
                        Label(L("Save"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
                    .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
                    .help(L("Save query"))
                }
            },
            trailing: {
                Picker("", selection: $state.mode) {
                    Text(L("Form")).tag(QdrantQueryTabState.Mode.form)
                    Text(L("JSON")).tag(QdrantQueryTabState.Mode.json)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: state.mode) { old, new in
                    if old == .form, new == .json { state.syncFormToJSON() }
                    if old == .json, new == .form { state.syncJSONToForm() }
                }
            }
        )
    }

    // MARK: - Editor (Form or JSON)

    @ViewBuilder
    private var editor: some View {
        switch state.mode {
        case .form: form
        case .json: jsonEditor
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                labeled(L("Collection")) {
                    if collections.isEmpty {
                        TextField(L("Collection name"), text: $state.collection)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $state.collection) {
                            Text(L("Select a collection")).tag("")
                            ForEach(collections, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                labeled(L("Vector")) {
                    TextField(L("[0.1, 0.2, …] — empty browses all points"), text: $state.vectorText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .font(.system(.callout, design: .monospaced))
                }
                HStack(spacing: 16) {
                    labeled(L("Top K")) {
                        TextField("", value: $state.topK, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    labeled(L("Score ≥")) {
                        TextField(L("optional"), text: $state.scoreThresholdText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    Spacer()
                }
                labeled(L("Payload filter")) {
                    TextField(L("{ \"lang\": \"vi\" } — optional"), text: $state.payloadFilterText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .font(.system(.callout, design: .monospaced))
                }
                Text(L("Switch to JSON for upsert/delete (write) queries."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        // Form mode has no NSTextView to hook a first-responder callback on
        // (unlike jsonEditor/MongoShellTextView) — notice a tap anywhere in
        // the form without stealing it from the TextFields/Picker underneath.
        .simultaneousGesture(TapGesture().onEnded { onFocus?() })
    }

    private var jsonEditor: some View {
        MongoShellTextView(
            text: $state.rawJSON,
            onCursorMove: { _ in },
            onRun: run,
            completionItems: { text, cursor in
                QdrantCompletionProvider.suggestions(text: text, utf16Cursor: cursor, collections: collections)
            },
            onFocus: onFocus,
            pendingFocus: state.pendingFocus,
            onDidFocus: { state.pendingFocus = false }
        )
    }

    private func labeled(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsPane: some View {
        if let error = state.lastError {
            QueryErrorView(message: error)
        } else if case .failed(let message) = state.buffer.state {
            QueryErrorView(message: message)
        } else {
            VStack(spacing: 0) {
                DocumentGridView(buffer: state.buffer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                DataSourceStatusBar(buffer: state.buffer, showsProductionBadge: isProduction)
            }
        }
    }

    private func run() {
        guard let session else { return }
        state.run(session: session, applyWrite: onApplyWrite, onComplete: onRefreshSchema)
    }
}
