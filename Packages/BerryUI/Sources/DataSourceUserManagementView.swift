import BerryDataSourceKit
import SwiftUI

/// User/role list for the DataSource family (Phase C,
/// — the Mongo-shaped sibling of `UserManagementView`.
/// Works off a plain `[DataSourceUserInfo]` array instead of a SQL
/// `ResultBuffer`: Mongo has no single-text-query channel to stream results
/// through, `listUsers()` just returns the array directly.
struct DataSourceUserManagementView: View {
    let onLoad: () async throws -> [DataSourceUserInfo]
    let onDrop: (_ username: String) async -> String?
    let preview: (_ username: String, _ password: String, _ roles: [String]) -> String
    let onCreate: (_ username: String, _ password: String, _ roles: [String]) async -> String?
    let onClose: () -> Void

    @State private var users: [DataSourceUserInfo] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var dropError: String?
    @State private var droppingUser: String?
    @State private var showCreateSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let dropError {
                Divider()
                Label(dropError, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .padding(8)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await reload() }
        .sheet(isPresented: $showCreateSheet) {
            DataSourceUserDesignerSheet(
                preview: preview,
                onApply: { username, password, roles in
                    let error = await onCreate(username, password, roles)
                    if error == nil { await reload() }
                    return error
                },
                onClose: { showCreateSheet = false }
            )
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.2")
            Text(L("Users")).font(.headline)
            Spacer()
            Button {
                showCreateSheet = true
            } label: {
                Label(L("New User…"), systemImage: "plus")
            }
            Button {
                Task { await reload() }
            } label: {
                Label(L("Reload"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && users.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, users.isEmpty {
            ContentUnavailableView(L("Couldn't load users"), systemImage: "xmark.octagon", description: Text(loadError))
                .frame(maxHeight: .infinity)
        } else if users.isEmpty {
            ContentUnavailableView(
                L("No users"),
                systemImage: "person.2",
                description: Text(L("Database users appear here"))
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    columnHeader
                    Divider()
                    ForEach(users, id: \.username) { user in
                        userRow(user)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(L("User")).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Roles")).fontWeight(.semibold).frame(width: 220, alignment: .leading)
            Text(verbatim: "").frame(width: 56)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func userRow(_ user: DataSourceUserInfo) -> some View {
        HStack(spacing: 8) {
            Text(user.username).frame(maxWidth: .infinity, alignment: .leading)
            Text(user.roles.isEmpty ? "—" : user.roles.joined(separator: ", "))
                .lineLimit(1)
                .frame(width: 220, alignment: .leading)
            Button(role: .destructive) {
                guard droppingUser == nil else { return }
                droppingUser = user.username
                Task {
                    dropError = await onDrop(user.username)
                    droppingUser = nil
                    if dropError == nil { await reload() }
                }
            } label: {
                if droppingUser == user.username {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(L("Drop"))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .frame(width: 56)
            .disabled(droppingUser != nil)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }

    private var footer: some View {
        HStack {
            Text(L("\(users.count) users")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            users = try await onLoad()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
