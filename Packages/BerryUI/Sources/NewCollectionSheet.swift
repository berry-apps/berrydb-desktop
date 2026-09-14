import BerryDataSourceKit
import SwiftUI

/// Explicit collection creation (gap fix):
/// a fresh Mongo/Qdrant connection starts with zero collections and — unlike
/// SQL's "New Table…" — there was previously no UI action to create one.
/// A Name field always; `.vector` (Qdrant) additionally needs vector size +
/// distance metric up front, since `PUT /collections/{name}` has no
/// implicit-creation-on-insert equivalent to Mongo's (see
/// `QdrantConnection.createCollection`). Small enough to fit without internal
/// scrolling. Not gated behind `DataSourceDangerGuard`/write-confirm:
/// creating a collection isn't a destructive action, so `onCreate` calls
/// `WorkspaceViewModel.createCollection` directly.
struct NewCollectionSheet: View {
    let kind: DataSourceKind
    let existingNames: Set<String>
    let onCreate: (_ ref: CollectionRef, _ options: BerryDocument) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var vectorSizeText = ""
    @State private var distance: QdrantDistance = .cosine
    @State private var errorMessage: String?
    @State private var isCreating = false

 /// Qdrant's supported distance metrics — same
    /// baseline already used by `WorkspaceQdrantDataSourceTests`.
    enum QdrantDistance: String, CaseIterable, Identifiable {
        case cosine = "Cosine"
        case euclid = "Euclid"
        case dot = "Dot"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "folder.badge.plus")
                Text(L("New Collection")).font(.headline)
            }

            TextField(L("Name"), text: $name)
                .textFieldStyle(.roundedBorder)

            if kind == .vector {
                TextField(L("Vector Size"), text: $vectorSizeText)
                    .textFieldStyle(.roundedBorder)
                Picker(L("Distance"), selection: $distance) {
                    ForEach(QdrantDistance.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("Create"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            errorMessage = L("Name cannot be empty")
            return
        }
        guard !existingNames.contains(trimmed) else {
            errorMessage = L("A collection named \"\(trimmed)\" already exists")
            return
        }
        var options: BerryDocument = .object([])
        if kind == .vector {
            guard let size = Int64(vectorSizeText.trimmingCharacters(in: .whitespaces)), size > 0 else {
                errorMessage = L("Vector Size must be a positive integer")
                return
            }
            options = .object([
                ("vectorSize", .int(size)),
                ("distance", .string(distance.rawValue)),
            ])
        }
        isCreating = true
        errorMessage = await onCreate(CollectionRef(name: trimmed), options)
        isCreating = false
        if errorMessage == nil { dismiss() }
    }
}
