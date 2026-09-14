import BerryDataSourceKit
import SwiftUI

/// One Elasticsearch query tab: a JSON editor on
/// top, the result grid below — the search-engine sibling of
/// `QdrantQueryTabView`, minus the Form half (no vector-shaped field awkward
/// in JSON, so a form surface adds no value here). Reads stream into the
/// grid; writes (index/update/delete) go through `onApplyWrite` so the
/// danger-gate/confirm is never bypassed.
struct ElasticsearchQueryTabView: View {
    @Bindable var state: ElasticsearchQueryTabState
    let session: DataSourceSession?
    let isProduction: Bool
    let collections: [String]
    let onApplyWrite: (DataSourceChangeSet) async -> DataSourceWriteOutcome
    var onRefreshSchema: (() -> Void)? = nil
    var onSave: (() -> Void)? = nil
    /// Same reasoning as MongoShellTabView.onFocus: without this,
    /// focusedGroupID never follows an Elasticsearch tab into a split pane.
    var onFocus: (() -> Void)?

    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                jsonEditor
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
            }
        )
    }

    // MARK: - Editor

    private var jsonEditor: some View {
        MongoShellTextView(
            text: $state.rawJSON,
            onCursorMove: { _ in },
            onRun: run,
            completionItems: { _, _ in [] },
            onFocus: onFocus,
            pendingFocus: state.pendingFocus,
            onDidFocus: { state.pendingFocus = false }
        )
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
