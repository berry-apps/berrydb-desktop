import BerryKeyValueKit
import SwiftUI

/// Redis key browser (docs/architecture/15 §4) — the key-value sibling of
/// `CollectionTabView` (Mongo/Qdrant), but much simpler: no collections, no
/// tabs, just a `SCAN`-paginated key list (N3: never `KEYS`) and a per-type
/// value viewer. Shown directly as the main content when a key-value session
/// is active (`WorkspaceView.detailContent`), bypassing the tab/pane system
/// entirely — there's nothing to open side by side for one flat key space.
struct KeyValueBrowserView: View {
    let capabilities: KeyValueCapabilities
    /// The database the connection actually opened on (`KeyValueSession.database`)
    /// — seeds the live switcher below so it starts in sync, not always at 0.
    let initialDatabase: Int
    let onScan: (_ pattern: String, _ cursor: String?) async throws -> KeyValueScanPage
    let onGet: (_ key: String) async throws -> KeyValueValue
    let onTTL: (_ key: String) async -> TimeInterval?
    /// Preview text the user sees before confirming a write/delete — a
    /// literal redis-cli-style command string, same "always show the native
    /// command" rule as `DataSourceCommandPreview` (docs/architecture/12 §6).
    let preview: (KeyValueChangeSet) -> String
    let onWrite: (KeyValueChangeSet) async -> String?
    /// Switches the numbered database (0–15) without reconnecting — shown
    /// only when `capabilities.numberedDatabases` (v1 gap closed:
    /// docs/architecture/15 §5 used to require reconnecting via
    /// `ConnectionSheet` to change database).
    let onSelectDatabase: (Int) async -> String?

    @State private var pattern = ""
    @State private var entries: [KeyValueEntry] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedKey: String?
    @State private var showNewKeySheet = false
    @State private var pendingDelete: String?
    @State private var currentDatabase: Int
    /// Guards the picker-revert-on-failure path below from re-triggering
    /// `onSelectDatabase` a second time for the same failed switch — setting
    /// `currentDatabase` back to `oldValue` is itself a state change and
    /// would otherwise fire `onChange` again.
    @State private var isRevertingDatabase = false

    init(
        capabilities: KeyValueCapabilities,
        initialDatabase: Int,
        onScan: @escaping (_ pattern: String, _ cursor: String?) async throws -> KeyValueScanPage,
        onGet: @escaping (_ key: String) async throws -> KeyValueValue,
        onTTL: @escaping (_ key: String) async -> TimeInterval?,
        preview: @escaping (KeyValueChangeSet) -> String,
        onWrite: @escaping (KeyValueChangeSet) async -> String?,
        onSelectDatabase: @escaping (Int) async -> String?
    ) {
        self.capabilities = capabilities
        self.initialDatabase = initialDatabase
        self.onScan = onScan
        self.onGet = onGet
        self.onTTL = onTTL
        self.preview = preview
        self.onWrite = onWrite
        self.onSelectDatabase = onSelectDatabase
        _currentDatabase = State(initialValue: initialDatabase)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                keyList
                    .frame(minWidth: 240, idealWidth: 300)
                valueDetail
                    .frame(minWidth: 320, maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await runScan(reset: true) }
        .onChange(of: currentDatabase) { oldValue, newValue in
            Task { await switchDatabase(from: oldValue, to: newValue) }
        }
        .sheet(isPresented: $showNewKeySheet) {
            NewKeyValueSheet(
                preview: preview,
                onCreate: { change in
                    let error = await onWrite(change)
                    if error == nil { await runScan(reset: true) }
                    return error
                },
                onClose: { showNewKeySheet = false }
            )
        }
        .alert(L("Delete this key?"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(L("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(L("Delete"), role: .destructive) {
                guard let key = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    let error = await onWrite(.delete(key: key))
                    if error == nil {
                        if selectedKey == key { selectedKey = nil }
                        await runScan(reset: true)
                    } else {
                        loadError = error
                    }
                }
            }
        } message: {
            if let key = pendingDelete {
                Text(preview(.delete(key: key)))
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "memorychip")
            Text(L("Keys")).font(.headline)
            if capabilities.numberedDatabases {
                Picker(L("Database"), selection: $currentDatabase) {
                    ForEach(0..<16) { index in
                        Text("DB \(index)").tag(index)
                    }
                }
                .frame(width: 100)
                .disabled(isLoading)
            }
            TextField(L("Pattern (e.g. user:*)"), text: $pattern)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { Task { await runScan(reset: true) } }
            Button {
                Task { await runScan(reset: true) }
            } label: {
                Label(L("Scan"), systemImage: "arrow.clockwise")
            }
            Spacer()
            if capabilities.write {
                Button {
                    showNewKeySheet = true
                } label: {
                    Label(L("New Key…"), systemImage: "plus")
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var keyList: some View {
        if isLoading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, entries.isEmpty {
            ContentUnavailableView(L("Scan failed"), systemImage: "xmark.octagon", description: Text(loadError))
        } else if entries.isEmpty {
            ContentUnavailableView(L("No keys"), systemImage: "memorychip", description: Text(L("Matching keys appear here")))
        } else {
            List(selection: $selectedKey) {
                ForEach(entries, id: \.key) { entry in
                    HStack {
                        Text(entry.key).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(entry.type.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        if capabilities.write {
                            Button(role: .destructive) {
                                pendingDelete = entry.key
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .tag(entry.key)
                }
                if nextCursor != nil {
                    Button(isLoading ? L("Loading…") : L("Load More")) {
                        Task { await runScan(reset: false) }
                    }
                    .disabled(isLoading)
                }
            }
        }
    }

    @ViewBuilder
    private var valueDetail: some View {
        if let selectedKey {
            KeyValueDetailView(
                key: selectedKey, canWrite: capabilities.write,
                onGet: onGet, onTTL: onTTL, preview: preview, onWrite: onWrite
            )
        } else {
            ContentUnavailableView(
                L("Select a key"),
                systemImage: "memorychip",
                description: Text(L("Pick a key from the list to see its value"))
            )
        }
    }

    private func runScan(reset: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await onScan(pattern, reset ? nil : nextCursor)
            if reset {
                entries = page.entries
            } else {
                entries.append(contentsOf: page.entries)
            }
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func switchDatabase(from oldValue: Int, to newValue: Int) async {
        guard oldValue != newValue else { return }
        if isRevertingDatabase {
            isRevertingDatabase = false
            return
        }
        isLoading = true
        let error = await onSelectDatabase(newValue)
        isLoading = false
        if let error {
            loadError = error
            // The switch failed server-side — snap the picker back so it
            // doesn't silently claim a database the connection isn't on.
            // `isRevertingDatabase` stops this from re-triggering the call.
            isRevertingDatabase = true
            currentDatabase = oldValue
            return
        }
        // A different database is an entirely different key space — the old
        // list/selection would otherwise show keys from the database that's
        // no longer selected.
        selectedKey = nil
        entries = []
        nextCursor = nil
        await runScan(reset: true)
    }
}

/// Loads and renders one key's value, typed per Redis's own data model.
/// Collection types (hash/list/set/zset/stream) get inline add/remove
/// affordances when `canWrite` — each edit goes through the same
/// preview-before-apply `onWrite` path as string SET/DEL (N1), then reloads
/// the value so the view always reflects what the server actually holds.
private struct KeyValueDetailView: View {
    let key: String
    let canWrite: Bool
    let onGet: (String) async throws -> KeyValueValue
    let onTTL: (String) async -> TimeInterval?
    let preview: (KeyValueChangeSet) -> String
    let onWrite: (KeyValueChangeSet) async -> String?

    @State private var value: KeyValueValue?
    @State private var ttl: TimeInterval?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var writeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if let ttl {
                    Label(L("TTL \(Int(ttl))s"), systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if isLoading {
                        ProgressView()
                    } else if let loadError {
                        Text(loadError).foregroundStyle(.red)
                    } else if let value {
                        valueView(value)
                    }
                    if let writeError {
                        Text(writeError).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .id(key)
        .task(id: key) { await load() }
    }

    @ViewBuilder
    private func valueView(_ value: KeyValueValue) -> some View {
        switch value {
        case .none:
            Text(L("(key does not exist)")).foregroundStyle(.secondary)
        case .string(let s):
            Text(s).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .hash(let fields):
            HashEditor(key: key, fields: fields, canWrite: canWrite, preview: preview, apply: apply)
        case .list(let items):
            ListEditor(key: key, items: items, canWrite: canWrite, preview: preview, apply: apply)
        case .set(let members):
            SetEditor(key: key, members: members, canWrite: canWrite, preview: preview, apply: apply)
        case .sortedSet(let members):
            SortedSetEditor(key: key, members: members, canWrite: canWrite, preview: preview, apply: apply)
        case .stream(let messages):
            StreamEditor(key: key, messages: messages, canWrite: canWrite, preview: preview, apply: apply)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            value = try await onGet(key)
            ttl = await onTTL(key)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(_ change: KeyValueChangeSet) async {
        writeError = await onWrite(change)
        if writeError == nil { await load() }
    }
}

/// Shared shape for a "field/value" (or "member/score") add row followed by
/// an Add button, with the literal command previewed once both inputs are
/// non-empty — same rule `NewKeyValueSheet` already follows for the string case.
private struct AddRow: View {
    let placeholder1: String
    let placeholder2: String?
    let previewText: String?
    let isAddable: Bool
    @Binding var field1: String
    @Binding var field2: String
    let onAdd: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(placeholder1, text: $field1).textFieldStyle(.roundedBorder)
                if let placeholder2 {
                    TextField(placeholder2, text: $field2).textFieldStyle(.roundedBorder)
                }
                Button(L("Add")) { Task { await onAdd() } }
                    .disabled(!isAddable)
            }
            if let previewText {
                Text(previewText).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HashEditor: View {
    let key: String
    let fields: [String: String]
    let canWrite: Bool
    let preview: (KeyValueChangeSet) -> String
    let apply: (KeyValueChangeSet) async -> Void

    @State private var newField = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading) {
                ForEach(fields.keys.sorted(), id: \.self) { field in
                    GridRow {
                        Text(field).fontWeight(.semibold)
                        Text(fields[field] ?? "")
                        if canWrite {
                            Button(role: .destructive) {
                                Task { await apply(.hashFieldDelete(key: key, field: field)) }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

            if canWrite {
                AddRow(
                    placeholder1: L("Field"), placeholder2: L("Value"),
                    previewText: canAdd ? preview(.hashFieldSet(key: key, field: newField, value: newValue)) : nil,
                    isAddable: canAdd, field1: $newField, field2: $newValue
                ) {
                    await apply(.hashFieldSet(key: key, field: newField, value: newValue))
                    newField = ""; newValue = ""
                }
            }
        }
    }

    private var canAdd: Bool { !newField.trimmingCharacters(in: .whitespaces).isEmpty }
}

private struct ListEditor: View {
    let key: String
    let items: [String]
    let canWrite: Bool
    let preview: (KeyValueChangeSet) -> String
    let apply: (KeyValueChangeSet) async -> Void

    @State private var newValue = ""
    @State private var end: ListEnd = .tail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text("\(index). \(item)").font(.system(.body, design: .monospaced))
                        if canWrite {
                            Spacer()
                            Button(role: .destructive) {
                                Task { await apply(.listRemove(key: key, value: item)) }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .textSelection(.enabled)

            if canWrite {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(L("Value"), text: $newValue).textFieldStyle(.roundedBorder)
                        Picker("", selection: $end) {
                            Text(L("Head")).tag(ListEnd.head)
                            Text(L("Tail")).tag(ListEnd.tail)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        Button(L("Push")) {
                            Task {
                                await apply(.listPush(key: key, value: newValue, end: end))
                                newValue = ""
                            }
                        }
                        .disabled(newValue.isEmpty)
                    }
                    if !newValue.isEmpty {
                        Text(preview(.listPush(key: key, value: newValue, end: end)))
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct SetEditor: View {
    let key: String
    let members: [String]
    let canWrite: Bool
    let preview: (KeyValueChangeSet) -> String
    let apply: (KeyValueChangeSet) async -> Void

    @State private var newMember = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowChips(items: members.sorted(), onRemove: canWrite ? { member in
                Task { await apply(.setRemove(key: key, member: member)) }
            } : nil)

            if canWrite {
                AddRow(
                    placeholder1: L("Member"), placeholder2: nil,
                    previewText: newMember.isEmpty ? nil : preview(.setAdd(key: key, member: newMember)),
                    isAddable: !newMember.isEmpty, field1: $newMember, field2: .constant("")
                ) {
                    await apply(.setAdd(key: key, member: newMember))
                    newMember = ""
                }
            }
        }
    }
}

private struct SortedSetEditor: View {
    let key: String
    let members: [SortedSetMember]
    let canWrite: Bool
    let preview: (KeyValueChangeSet) -> String
    let apply: (KeyValueChangeSet) async -> Void

    @State private var newMember = ""
    @State private var newScore = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading) {
                ForEach(members, id: \.member) { member in
                    GridRow {
                        Text(member.member).fontWeight(.semibold)
                        Text(String(member.score))
                        if canWrite {
                            Button(role: .destructive) {
                                Task { await apply(.sortedSetRemove(key: key, member: member.member)) }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

            if canWrite {
                AddRow(
                    placeholder1: L("Member"), placeholder2: L("Score"),
                    previewText: canAdd ? preview(.sortedSetAdd(key: key, member: newMember, score: Double(newScore) ?? 0)) : nil,
                    isAddable: canAdd, field1: $newMember, field2: $newScore
                ) {
                    guard let score = Double(newScore) else { return }
                    await apply(.sortedSetAdd(key: key, member: newMember, score: score))
                    newMember = ""; newScore = ""
                }
            }
        }
    }

    private var canAdd: Bool {
        !newMember.trimmingCharacters(in: .whitespaces).isEmpty && Double(newScore) != nil
    }
}

private struct StreamEditor: View {
    let key: String
    let messages: [KeyValueStreamEntry]
    let canWrite: Bool
    let preview: (KeyValueChangeSet) -> String
    let apply: (KeyValueChangeSet) async -> Void

    @State private var newField = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(messages, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        ForEach(message.fields.keys.sorted(), id: \.self) { field in
                            Text("\(field): \(message.fields[field] ?? "")")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
            .textSelection(.enabled)

            // Entry deletion (XDEL) is deferred — streams are typically
            // append-only/trimmed logs, not row-edited (docs/architecture/15 §5).
            if canWrite {
                AddRow(
                    placeholder1: L("Field"), placeholder2: L("Value"),
                    previewText: canAdd ? preview(.streamAdd(key: key, field: newField, value: newValue)) : nil,
                    isAddable: canAdd, field1: $newField, field2: $newValue
                ) {
                    await apply(.streamAdd(key: key, field: newField, value: newValue))
                    newField = ""; newValue = ""
                }
            }
        }
    }

    private var canAdd: Bool { !newField.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Wrapping chip layout for a set's members — no ordering to preserve,
/// unlike a list. `onRemove`, when non-nil, adds a right-click "Remove"
/// action per chip (a chip has no room for an inline trash button).
private struct FlowChips: View {
    let items: [String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        // A simple wrap using LazyVGrid's adaptive columns — sets are
        // typically small (Redis set browsing isn't paginated in v1), so a
        // hand-rolled flow layout isn't worth the complexity here.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .contextMenu {
                        if let onRemove {
                            Button(L("Remove"), role: .destructive) { onRemove(item) }
                        }
                    }
            }
        }
    }
}
