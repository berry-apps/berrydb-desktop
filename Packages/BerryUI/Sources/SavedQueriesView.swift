import BerryStore
import SwiftUI

/// Saved-query library (ED-07): reusable SQL snippets, scoped to the active
/// connection or global. Open a snippet into a new editor tab, save the
/// current editor's SQL, or delete. Local-only — nothing is uploaded.
struct SavedQueriesView: View {
    /// Snapshot loaded when the sheet opens; refreshed after each mutation.
    @State private var queries: [SavedQuery]
    let currentSQL: String?
    /// Opens the saved query as a linked tab (docs/ui) — like opening a file.
    let onOpen: (SavedQuery) -> Void
    let onSave: (_ name: String, _ sql: String, _ folder: String?, _ global: Bool) -> Void
    let onDelete: (UUID) -> Void
    let onRename: (_ id: UUID, _ name: String) -> Void
    let reload: () -> [SavedQuery]
    /// Close this tool tab (docs/ui/02 §4).
    let onClose: () -> Void

    @State private var search = ""
    @State private var showSaveForm = false
    /// In-place rename state (docs/ui).
    @State private var renamingID: UUID?
    @State private var renameDraft = ""

    init(
        queries: [SavedQuery],
        currentSQL: String?,
        onOpen: @escaping (SavedQuery) -> Void,
        onSave: @escaping (_ name: String, _ sql: String, _ folder: String?, _ global: Bool) -> Void,
        onDelete: @escaping (UUID) -> Void,
        onRename: @escaping (_ id: UUID, _ name: String) -> Void,
        reload: @escaping () -> [SavedQuery],
        onClose: @escaping () -> Void
    ) {
        _queries = State(initialValue: queries)
        self.currentSQL = currentSQL
        self.onOpen = onOpen
        self.onSave = onSave
        self.onDelete = onDelete
        self.onRename = onRename
        self.reload = reload
        self.onClose = onClose
    }

    private var filtered: [SavedQuery] {
        guard !search.isEmpty else { return queries }
        return queries.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.sql.localizedCaseInsensitiveContains(search)
        }
    }

    /// Group by folder; nil folder sorts first under an empty header.
    private var grouped: [(folder: String?, items: [SavedQuery])] {
        let groups = Dictionary(grouping: filtered) { $0.folder }
        return groups
            .sorted { ($0.key ?? "") < ($1.key ?? "") }
            .map { (folder: $0.key, items: $0.value) }
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
        // Load once when the tab appears. `queries` is @State (the initial arg is
        // only read at creation), so refreshing the view model's cache alone
        // wouldn't repopulate this view — pull the fresh list into our state here.
        .task { queries = reload() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "bookmark")
            Text(L("Saved Queries")).font(.headline)
            Spacer()
            TextField(L("Search saved queries"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                L("No saved queries yet"),
                systemImage: "bookmark",
                description: Text(L("Save Current SQL"))
            )
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(grouped, id: \.folder) { group in
                    Section(group.folder ?? "") {
                        ForEach(group.items) { query in
                            row(query)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ query: SavedQuery) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: query.profileID == nil ? "globe" : "cylinder.split.1x2")
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 3) {
                if renamingID == query.id {
                    TextField(L("Name"), text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit {
                            let name = renameDraft.trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { onRename(query.id, name) }
                            renamingID = nil
                            queries = reload()
                        }
                } else {
                    Text(query.name).fontWeight(.medium)
                }
                Text(query.sql)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(query.sql)
            }
            Spacer()
            Button {
                onOpen(query)
                onClose()
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help(L("Open in Editor"))
            Button {
                renamingID = query.id
                renameDraft = query.name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help(L("Rename"))
            Button(role: .destructive) {
                onDelete(query.id)
                queries = reload()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete"))
        }
        .padding(.vertical, 2)
    }

    // MARK: - Save form

    @State private var draftName = ""
    @State private var draftFolder = ""
    @State private var draftGlobal = false

    private var saveForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Name"), text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField(L("Folder (optional)"), text: $draftFolder)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Toggle(L("Global (all connections)"), isOn: $draftGlobal)
                Spacer()
                Button(L("Save")) {
                    guard let sql = currentSQL, !draftName.isEmpty else { return }
                    onSave(draftName, sql, draftFolder, draftGlobal)
                    draftName = ""
                    draftFolder = ""
                    draftGlobal = false
                    showSaveForm = false
                    queries = reload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftName.isEmpty || (currentSQL?.isEmpty ?? true))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
    }

    private var footer: some View {
        HStack {
            Button {
                showSaveForm.toggle()
            } label: {
                Label(L("Save Current SQL"), systemImage: "plus")
            }
            .disabled(currentSQL?.isEmpty ?? true)
            Spacer()
            Button(L("Close")) { onClose() }
        }
        .padding(10)
    }
}
