import Foundation
import SwiftUI

/// "New Backup" sheet for a Mongo/Qdrant connection (docs/feature/04) — presented
/// from the Backup manager. Pick a name and which collections; writes a bundle
/// directory (manifest + NDJSON per collection) into the managed backups folder.
struct DataSourceBackupSheet: View {
    let session: DataSourceSession
    let collections: [String]
    let directory: URL
    var onCreated: () -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var selected: Set<String>
    @State private var isRunning = false
    @State private var status: String?
    @State private var progress = BackupProgress()

    init(session: DataSourceSession, collections: [String], directory: URL, onCreated: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.session = session
        self.collections = collections
        self.directory = directory
        self.onCreated = onCreated
        self.onCancel = onCancel
        _name = State(initialValue: "\(session.displayName)")
        _selected = State(initialValue: Set(collections))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L("New Backup"), systemImage: "plus.rectangle.on.folder").font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()

            Form { TextField(L("Name"), text: $name) }
                .padding(.horizontal, 12).padding(.top, 8)

            HStack {
                Text(L("Collections")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Select All")) { selected = Set(collections) }.buttonStyle(.link)
                Button(L("Deselect All")) { selected = [] }.buttonStyle(.link)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            List {
                ForEach(collections, id: \.self) { collection in
                    Toggle(isOn: binding(for: collection)) {
                        HStack(spacing: 6) {
                            Image(systemName: session.kind == .vector ? "point.3.filled.connected.trianglepath.dotted" : "tray.full")
                                .foregroundStyle(.secondary).frame(width: 16)
                            Text(collection)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack(spacing: 8) {
                if isRunning {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if let label = progress.label {
                        Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else if let status {
                    Text(status).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button(L("Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Create"), action: create)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 500, height: 460)
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(name) },
            set: { on in if on { selected.insert(name) } else { selected.remove(name) } }
        )
    }

    private func create() {
        let chosen = collections.filter { selected.contains($0) }
        let url = directory.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        isRunning = true
        status = nil
        progress.reset()
        let progress = progress
        Task {
            do {
                try await DataSourceBackupService.backup(
                    session: session, collections: chosen, to: url, createdAt: stamp,
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
