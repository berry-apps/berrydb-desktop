import BerryCore
import BerryDriverKit
import SwiftUI

/// Server user/role list: the DBMS's own
/// users, with a per-row Drop action and a "New User…" sheet. Columns are
/// normalized by the dialect to user/host/superuser/can_login. Every
/// statement still goes through the single SQL path (N1).
struct UserManagementView: View {
    let buffer: ResultBuffer
    let driver: DriverID
    let onReload: () -> Void
    let onDrop: (_ username: String, _ host: String?) async -> String?
    let designPreview: (UserDesign) -> [String]
    let onCreate: (UserDesign) async -> String?

 /// Close this tool tab.
    let onClose: () -> Void
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
        .onAppear(perform: onReload)
        .sheet(isPresented: $showCreateSheet) {
            UserDesignerSheet(
                driver: driver,
                preview: designPreview,
                onApply: { design in
                    let error = await onCreate(design)
                    if error == nil { onReload() }
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
                dropError = nil
                onReload()
            } label: {
                Label(L("Reload"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if buffer.rowCount == 0 {
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
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        userRow(row)
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
            cell(L("Host"), width: 90).fontWeight(.semibold)
            cell(L("Superuser"), width: 80).fontWeight(.semibold)
            cell(L("Can Login"), width: 80).fontWeight(.semibold)
            Text(verbatim: "").frame(width: 56)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func userRow(_ row: UserRow) -> some View {
        HStack(spacing: 8) {
            Text(row.user).frame(maxWidth: .infinity, alignment: .leading)
            cell(row.host.isEmpty ? "—" : row.host, width: 90)
            cell(row.superuser, width: 80)
            cell(row.canLogin, width: 80)
            Button(role: .destructive) {
                guard droppingUser == nil else { return }
                droppingUser = row.user
                Task {
                    dropError = await onDrop(row.user, row.host.isEmpty ? nil : row.host)
                    droppingUser = nil
                    if dropError == nil { onReload() }
                }
            } label: {
                if droppingUser == row.user {
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

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).lineLimit(1).frame(width: width, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text(L("\(buffer.rowCount) users")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    // MARK: - Row extraction

    private struct UserRow {
        var user = ""
        var host = ""
        var superuser = ""
        var canLogin = ""
    }

    private var rows: [UserRow] {
        let index = columnIndexes
        return buffer.rows.map { values in
            func value(_ i: Int?) -> String {
                guard let i, i < values.count else { return "" }
                return values[i].displayString ?? ""
            }
            return UserRow(
                user: value(index.user), host: value(index.host),
                superuser: value(index.superuser), canLogin: value(index.canLogin)
            )
        }
    }

    private var columnIndexes: (user: Int?, host: Int?, superuser: Int?, canLogin: Int?) {
        func find(_ name: String) -> Int? {
            buffer.columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (find("user"), find("host"), find("superuser"), find("can_login"))
    }
}
