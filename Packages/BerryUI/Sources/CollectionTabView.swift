import BerryDataSourceKit
import SwiftUI

/// One collection/point-collection tab: query params + result grid + write
/// actions (docs/architecture/12 §7), all funneled through
/// `onWrite` (`WorkspaceViewModel.applyDataSourceWrite`) so nothing bypasses
/// the native-command preview/confirm (§6). Mirrors `TableTabView`'s shape,
/// simplified: writes are single-shot, not staged (see `CollectionTabState`).
struct CollectionTabView: View {
    @Bindable var state: CollectionTabState
    let session: DataSourceSession?
    let isProduction: Bool
    let onWrite: (DataSourceChangeSet) async -> String?

    @State private var viewerTarget: DocumentTarget?
    @State private var showInsertSheet = false
    @State private var writeError: String?

    /// Label mode for the exec cluster (docs/ui) — shared app-wide setting,
    /// matches `EditorTabView`/`MongoShellTabView`'s toolbar.
    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            grid
            statusBar
        }
        .sheet(item: $viewerTarget) { target in
            DocumentCellViewerSheet(
                title: state.ref.name,
                document: target.document,
                editable: target.editable,
                onSave: target.editable ? { edited in
                    let patch = CollectionTabState.patch(from: edited, kind: state.kind)
                    Task {
                        writeError = await onWrite(.update(collection: state.ref.name, id: target.id, patch: patch))
                        state.run()
                    }
                } : nil
            )
        }
        .sheet(isPresented: $showInsertSheet) {
            DocumentCellViewerSheet(
                title: L("Insert Document"),
                document: .object([]),
                editable: true,
                onSave: { doc in
                    Task {
                        writeError = await onWrite(.insert(collection: state.ref.name, document: doc))
                        state.run()
                    }
                }
            )
        }
    }

    private var canWrite: Bool { session?.capabilities.write == true }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Button {
                state.run()
            } label: {
                Label(L("Reload"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .keyboardShortcut("r", modifiers: .command)

            if state.buffer.state == .running {
                ProgressView().controlSize(.small)
                Button {
                    state.cancel()
                } label: {
                    Label(L("Stop"), systemImage: "stop.fill")
                }
                .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
                .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            }

            Button {
                showInsertSheet = true
            } label: {
                Label(L("Insert…"), systemImage: "plus")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .disabled(!canWrite)

            Spacer()
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(.bar)
    }



    @ViewBuilder
    private var grid: some View {
        if case .failed(let message) = state.buffer.state {
            QueryErrorView(message: message)
        } else {
            DocumentGridView(
                buffer: state.buffer,
                onViewDocument: { row in
                    guard row < state.buffer.items.count else { return }
                    let doc = state.buffer.items[row]
                    viewerTarget = DocumentTarget(
                        id: CollectionTabState.id(of: doc, kind: state.kind),
                        document: doc,
                        editable: canWrite
                    )
                },
                onDeleteRows: { rows in
                    // Each id deletes individually — the write model carries one
                    // id per `.delete` (no batch delete), so a multi-row delete
                    // shows one confirm per row (only for the dangerous
                    // empty-filter case; ordinary by-id deletes are `.safe` and
                    // skip the alert, see `AlertDataSourceWriteConfirmer`).
                    Task {
                        for row in rows.sorted(by: >) where row < state.buffer.items.count {
                            let doc = state.buffer.items[row]
                            let id = CollectionTabState.id(of: doc, kind: state.kind)
                            writeError = await onWrite(.delete(collection: state.ref.name, id: id))
                        }
                        state.run()
                    }
                }
            )
        }
    }

    private var statusBar: some View {
        DataSourceStatusBar(buffer: state.buffer, showsProductionBadge: isProduction, writeError: writeError)
    }
}

private struct DocumentTarget: Identifiable {
    let id: BerryDocument
    let document: BerryDocument
    let editable: Bool
}
