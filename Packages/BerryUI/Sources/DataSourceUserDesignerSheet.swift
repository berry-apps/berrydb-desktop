import SwiftUI

/// Create-user form for the DataSource family (Phase C,
/// — the Mongo-shaped sibling of `UserDesignerSheet`.
/// Simpler than the SQL version: no host field (Mongo users aren't
/// host-scoped), and roles are a curated built-in-role picker instead of
/// privilege+database grant rows, since Mongo's `createUser` command takes
/// its initial roles directly in one call. The generated command is ALWAYS
/// shown before Create, same rule as `UserDesignerSheet`/`TableDesignerSheet`.
struct DataSourceUserDesignerSheet: View {
    let preview: (_ username: String, _ password: String, _ roles: [String]) -> String
    let onApply: (_ username: String, _ password: String, _ roles: [String]) async -> String?
    let onClose: () -> Void

 /// Curated built-in database roles (no
    /// custom-role definitions, no cluster-scoped roles like `clusterAdmin` —
    /// every role here is scoped to the connection's own working database).
    private static let roles = ["read", "readWrite", "dbAdmin", "userAdmin", "dbOwner"]

    @State private var username = ""
    @State private var password = ""
    @State private var selectedRoles: Set<String> = []
    @State private var applyError: String?
    @State private var isApplying = false

    private var isValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    form
                    previewPane
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 460)
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.badge.plus")
            Text(L("New User")).font(.headline)
        }
        .padding(10)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("Username"), text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField(L("Password"), text: $password)
                .textFieldStyle(.roundedBorder)
            rolesSection
        }
    }

    private var rolesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Roles (optional)")).font(.subheadline).fontWeight(.semibold)
            ForEach(Self.roles, id: \.self) { role in
                Toggle(role, isOn: Binding(
                    get: { selectedRoles.contains(role) },
                    set: { isOn in
                        if isOn { selectedRoles.insert(role) } else { selectedRoles.remove(role) }
                    }
                ))
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Command Preview")).font(.subheadline).fontWeight(.semibold)
            Text(preview(username, password, Array(selectedRoles).sorted()))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
        }
    }

    private var footer: some View {
        HStack {
            if let applyError {
                Label(applyError, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button(L("Cancel")) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button {
                guard !isApplying else { return }
                isApplying = true
                Task {
                    applyError = await onApply(username, password, Array(selectedRoles).sorted())
                    isApplying = false
                    if applyError == nil { onClose() }
                }
            } label: {
                if isApplying { ProgressView().controlSize(.small) } else { Text(L("Create")) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || isApplying)
        }
        .padding(10)
    }
}
