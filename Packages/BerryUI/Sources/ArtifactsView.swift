import BerryStore
import SwiftUI

/// Shared with the artifact chips `TurnView` (AIPanelView.swift) renders
/// under a bubble — one mapping, not duplicated per view.
extension Artifact.Kind {
    var systemImage: String {
        switch self {
        case .editorTab: "terminal"
        case .mongoShell: "leaf"
        case .qdrantQuery: "point.3.filled.connected.trianglepath.dotted"
        case .elasticsearchQuery: "magnifyingglass"
        case .table: "tablecells"
        case .view: "eye"
        case .trigger: "bolt"
        case .function: "function"
        case .other: "shippingbox"
        }
    }
}

/// Artifacts library: durable, linkable references
/// to queries/tabs the AI agent (or the user) created — mirrors
/// `SavedQueriesView`, minus folder/global (an artifact always belongs to one
/// connection). Reopen a past artifact into a linked tab, save the active
/// tab as a new artifact, or delete. Local-only — nothing is uploaded.
struct ArtifactsView: View {
    @State private var artifacts: [Artifact]
    let currentPayload: String?
    let onOpen: (Artifact) -> Void
    let onSave: (_ title: String) -> Void
    let onDelete: (UUID) -> Void
    let reload: () -> [Artifact]
    let onClose: () -> Void

    @State private var search = ""
    @State private var showSaveForm = false
    @State private var draftTitle = ""

    init(
        artifacts: [Artifact],
        currentPayload: String?,
        onOpen: @escaping (Artifact) -> Void,
        onSave: @escaping (_ title: String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        reload: @escaping () -> [Artifact],
        onClose: @escaping () -> Void
    ) {
        _artifacts = State(initialValue: artifacts)
        self.currentPayload = currentPayload
        self.onOpen = onOpen
        self.onSave = onSave
        self.onDelete = onDelete
        self.reload = reload
        self.onClose = onClose
    }

    private var filtered: [Artifact] {
        guard !search.isEmpty else { return artifacts }
        return artifacts.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showSaveForm {
                saveForm
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Load once when the tab appears — `artifacts` is @State (the initial
        // arg is only read at creation), so refreshing the view model's cache
        // alone wouldn't repopulate this view (mirrors SavedQueriesView).
        .task { artifacts = reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "shippingbox")
            Text(L("Artifacts")).font(.headline)
            Spacer()
            TextField(L("Search artifacts"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                L("No artifacts yet"),
                systemImage: "shippingbox",
                description: Text(L("Save Current Query"))
            )
            .frame(maxHeight: .infinity)
        } else {
            List(filtered) { artifact in
                row(artifact)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ artifact: Artifact) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: artifact.kind.systemImage)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(artifact.title).fontWeight(.medium)
                Text(artifact.kind.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onOpen(artifact)
                onClose()
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help(L("Open"))
            Button(role: .destructive) {
                onDelete(artifact.id)
                artifacts = reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Save form

    private var saveForm: some View {
        HStack {
            TextField(L("Title"), text: $draftTitle)
                .textFieldStyle(.roundedBorder)
            Spacer()
            Button(L("Save")) {
                guard !draftTitle.isEmpty else { return }
                onSave(draftTitle)
                draftTitle = ""
                showSaveForm = false
                artifacts = reload()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftTitle.isEmpty || (currentPayload?.isEmpty ?? true))
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
    }

    private var footer: some View {
        HStack {
            Button {
                showSaveForm.toggle()
            } label: {
                Label(L("Save Current Query"), systemImage: "plus")
            }
            .disabled(currentPayload?.isEmpty ?? true)
            Spacer()
            Button(L("Close")) { onClose() }
        }
        .padding(10)
    }
}
