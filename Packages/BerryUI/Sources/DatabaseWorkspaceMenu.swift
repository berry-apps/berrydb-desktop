import SwiftUI

struct DatabaseWorkspaceMenu: View {
    let currentDatabase: String?
    let loadDatabases: () async throws -> [String]
    let openDatabase: (String) -> Void

    @State private var databases: [String] = []
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var refresh = 0

    var body: some View {
        Menu {
            if isLoading {
                Text(L("Loading…"))
            } else if let loadError {
                Text(loadError)
            } else if databases.isEmpty {
                Text(L("No databases available"))
            }
            ForEach(databases, id: \.self) { database in
                Button {
                    openDatabase(database)
                } label: {
                    if database == currentDatabase {
                        Label(database, systemImage: "checkmark")
                    } else {
                        Text(database)
                    }
                }
                .disabled(database == currentDatabase)
            }
            Divider()
            Button(L("Refresh Databases")) { refresh += 1 }
                .disabled(isLoading)
        } label: {
            Label(currentDatabase ?? L("Select Database"), systemImage: "cylinder")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel(L("Database"))
        .accessibilityValue(currentDatabase ?? "")
        .help(L("Open another database in its own workspace"))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .task(id: refresh) {
            isLoading = true
            loadError = nil
            defer { isLoading = false }
            do {
                let available = try await loadDatabases()
                guard !Task.isCancelled else { return }
                if let currentDatabase, !available.contains(currentDatabase) {
                    databases = [currentDatabase] + available
                } else {
                    databases = available
                }
            } catch {
                guard !Task.isCancelled else { return }
                databases = []
                loadError = error.localizedDescription
            }
        }
    }
}
