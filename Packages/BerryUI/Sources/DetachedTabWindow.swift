import BerryCore
import BerryDriverKit
import SwiftUI

/// Bridge that lets detached-tab windows reach the main workspace's view model
/// (docs/ui/01 D1). One workspace per app for now (04 §3), so a single weak
/// reference is enough; the window looks its tab up by id.
@MainActor
public final class DetachedWorkspace {
    public static let shared = DetachedWorkspace()
    public weak var viewModel: WorkspaceViewModel?
    private init() {}
}

/// One tab moved into its own independent window (docs/ui/01 D1). The content
/// is backed by the SAME document/session as the main window — it's the tab
/// relocated, not a copy. Closing the window closes the tab.
public struct DetachedTabWindow: View {
    public let tabID: String

    public init(tabID: String) {
        self.tabID = tabID
    }

    public var body: some View {
        if let viewModel = DetachedWorkspace.shared.viewModel,
           let tab = viewModel.tab(for: tabID) {
            content(tab, viewModel: viewModel)
                .navigationTitle(tab.title)
                .frame(minWidth: 640, minHeight: 420)
                .onDisappear {
                    viewModel.closeDetachedTab(tabID)
                }
        } else {
            ContentUnavailableView(
                L("This tab was closed"),
                systemImage: "rectangle.on.rectangle.slash"
            )
            .frame(minWidth: 420, minHeight: 260)
        }
    }

    @ViewBuilder
    private func content(_ tab: WorkspaceTab, viewModel: WorkspaceViewModel) -> some View {
        switch tab {
        case .editor(let document):
            EditorTabView(
                document: document,
                session: viewModel.session,
                isProduction: viewModel.isProductionSession,
                objects: viewModel.objects,
                catalog: viewModel.catalog,
                transaction: viewModel.transaction,
                onPersist: { viewModel.persistEditor(document) },
                onSaveQueryReplay: { sql, durationMS in await viewModel.saveQueryReplay(sql: sql, durationMS: durationMS) }
            )
        case .table(let state):
            TableTabView(
                state: state,
                session: viewModel.session,
                isProduction: viewModel.isProductionSession,
                onOpenReference: { fk, value in viewModel.jumpToReference(fk, value: value) }
            )
        case .alterTable(let original):
            TableDesignerSheet(
                preview: { edited in
                    viewModel.alterStatements(original: original, edited: edited)
                },
                onApply: { edited in
                    await viewModel.applyAlteration(original: original, edited: edited)
                },
                onClose: {
                    viewModel.closeDetachedTab("alter:\(original.database ?? "").\(original.name)")
                },
                editingExisting: original,
                alterWarnings: { edited in
                    viewModel.alterWarnings(original: original, edited: edited)
                },
                migrationPreview: { edited in
                    viewModel.migrationPreview(editing: edited)
                },
                driver: viewModel.session?.config.driver ?? .sqlite
            )
        case .tool:
            // Tools are singleton tabs tied to the main window's chrome.
            ContentUnavailableView(
                L("This tab can't be detached"),
                systemImage: "rectangle.on.rectangle.slash"
            )
        case .collection(let state):
            CollectionTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                onWrite: { change in await viewModel.applyDataSourceWrite(change) }
            )
        case .mongoShell(let state):
            MongoShellTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) }
            )
        case .qdrantQuery(let state):
            QdrantQueryTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) }
            )
        case .elasticsearchQuery(let state):
            ElasticsearchQueryTabView(
                state: state,
                session: viewModel.dataSourceSession,
                isProduction: viewModel.isProductionSession,
                collections: viewModel.collections.map(\.name),
                onApplyWrite: { change in await viewModel.applyDataSourceWriteOutcome(change) }
            )
        }
    }
}
