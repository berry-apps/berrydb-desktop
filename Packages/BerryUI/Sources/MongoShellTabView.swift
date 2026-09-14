import BerryDataSourceKit
import SwiftUI

/// One Mongo shell query tab (item 2): script editor on
/// top, one result tab per statement below — the NoSQL sibling of
/// `EditorTabView`.
struct MongoShellTabView: View {
    @Bindable var state: MongoShellTabState
    let session: DataSourceSession?
    let isProduction: Bool
    let collections: [String]
    let onApplyWrite: (DataSourceChangeSet) async -> DataSourceWriteOutcome
    var onRefreshSchema: (() -> Void)? = nil
    /// Fires when this editor takes focus, so the workspace activates its
 /// split pane — same as EditorTabView's onFocus. Without
    /// this, focusedGroupID never follows a Mongo tab into a split pane, so
    /// the global Run shortcut and menu keep targeting whichever tab was
    /// last focused elsewhere instead of the one on screen.
    var onFocus: (() -> Void)?

    /// Whether the results pane is collapsed (only tab bar visible).
    @State private var resultsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VSplitView {
                MongoShellTextView(
                    text: $state.text,
                    onCursorMove: { state.cursorLocation = $0 },
                    onRun: run,
                    completionItems: { script, cursor in
                        MongoShellCompletionProvider.suggestions(script: script, utf16Cursor: cursor, collections: collections)
                    },
                    onFocus: onFocus,
                    pendingFocus: state.pendingFocus,
                    onDidFocus: { state.pendingFocus = false }
                )
                .frame(minHeight: 120, maxHeight: .infinity)
                resultsPane
                    .frame(minHeight: resultsCollapsed ? 28 : 100, maxHeight: resultsCollapsed ? 28 : .infinity)
            }
        }
        .onAppear {
            if state.results.isEmpty, let session {
                state.run(session: session, applyWrite: onApplyWrite, onComplete: onRefreshSchema)
            }
        }
    }

    private var toolbar: some View {
        QueryTabToolbar(
            canRun: session != nil && !state.isRunning,
            isRunning: state.isRunning,
            isProduction: isProduction,
            onRun: run,
            onStop: { state.cancel() }
        )
    }

    private func run() {
        guard let session else { return }
        state.run(session: session, applyWrite: onApplyWrite, onComplete: onRefreshSchema)
    }

    @ViewBuilder
    private var resultsPane: some View {
        QueryResultContainerView(
            isEmpty: state.results.isEmpty,
            isCollapsed: $resultsCollapsed,
            tabs: {
                AnyView(
                    HStack(spacing: 2) {
                        ForEach(Array(state.results.enumerated()), id: \.element.id) { index, result in
                            Button {
                                state.selectedResultID = result.id
                            } label: {
                                Text(L("Result \(index + 1)")).font(.caption).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                result.id == state.selectedResultID ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .help(result.script)
                        }
                    }
                )
            },
            content: {
                resultContent
            }
        )
    }

    private var effectiveResult: MongoShellResult? {
        state.results.first { $0.id == state.selectedResultID } ?? state.results.last
    }

    @ViewBuilder
    private var resultContent: some View {
        if let result = effectiveResult {
            if case .failed(let message) = result.buffer.state {
                QueryErrorView(message: message)
            } else {
                VStack(spacing: 0) {
                    DocumentGridView(buffer: result.buffer)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    DataSourceStatusBar(buffer: result.buffer, showsProductionBadge: isProduction)
                }
            }
        }
    }
}
