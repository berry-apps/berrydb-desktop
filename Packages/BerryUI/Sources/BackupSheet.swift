import BerryCore
import BerryDriverKit
import SwiftUI

/// "New Backup" sheet for a SQL connection (docs/feature/04) — presented from the
/// Backup manager. Pick a name, which objects, and structure/data; writes a
/// `.sql` dump into the connection's managed backups directory.
struct BackupSheet: View {
    let session: Session
    let objects: [SchemaObject]
    let directory: URL
    var onCreated: () -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var selected: Set<String>
    @State private var includeStructure = true
    @State private var includeData = true
    @State private var isRunning = false
    @State private var status: String?
    @State private var progress = BackupProgress()

    init(session: Session, objects: [SchemaObject], directory: URL, onCreated: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.objects = objects
        self.directory = directory
        self.onCreated = onCreated
        self.onCancel = onCancel
        _name = State(initialValue: "\(session.displayName)")
        _selected = State(initialValue: Set(objects.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("New Backup"), systemImage: "plus.rectangle.on.folder").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form {
                TextField(L("Name"), text: $name)
                HStack(spacing: 16) {
                    Toggle(L("Structure"), isOn: $includeStructure)
                    Toggle(L("Data"), isOn: $includeData)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            HStack {
                Text(L("Objects")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Select All")) { selected = Set(objects.map(\.id)) }.buttonStyle(.link)
                Button(L("Deselect All")) { selected = [] }.buttonStyle(.link)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            List {
                ForEach(objects) { object in
                    Toggle(isOn: binding(for: object.id)) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(object.kind)).foregroundStyle(.secondary).frame(width: 16)
                            Text(object.name)
                            Text(object.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                if isRunning {
                    progressIndicator
                } else if let status {
                    Text(status).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(L("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Create"), action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || name.trimmingCharacters(in: .whitespaces).isEmpty
                        || selected.isEmpty || (!includeStructure && !includeData))
            }
            .padding(12)
        }
        .frame(width: 500, height: 480)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction).frame(width: 120)
        } else {
            ProgressView().controlSize(.small)
        }
        if let label = progress.label {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in if on { selected.insert(id) } else { selected.remove(id) } }
        )
    }

    private func icon(_ kind: SchemaObjectKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .view: "rectangle.on.rectangle"
        case .function, .procedure: "function"
        case .trigger: "bolt"
        case .index: "list.bullet.indent"
        }
    }

    private func create() {
        let chosen = objects.filter { selected.contains($0.id) }
        let url = directory.appendingPathComponent("\(name.trimmingCharacters(in: .whitespaces)).sql")
        isRunning = true
        status = nil
        progress.reset()
        let progress = progress
        Task {
            do {
                try await BackupService.backupSQL(
                    session: session,
                    objects: chosen,
                    options: .init(includeStructure: includeStructure, includeData: includeData),
                    to: url,
                    progress: { done, total, label in
                        Task { @MainActor in progress.update(done: done, total: total, label: label) }
                    }
                )
                onCreated()
            } catch {
                status = error.localizedDescription
            }
            isRunning = false
        }
    }
}
