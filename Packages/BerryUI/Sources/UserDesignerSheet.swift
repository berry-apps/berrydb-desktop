import BerryCore
import BerryDriverKit
import SwiftUI

/// Create-user form (TI-03, docs/architecture/14): username/password, host
/// (MySQL only — `'user'@'host'`), and an optional list of initial grants
/// from a curated privilege picker (docs/architecture/14 §Deferred: no
/// per-table/per-column grants, no role membership). The generated SQL is
/// ALWAYS shown before Create, same "preview before apply" rule as
/// `TableDesignerSheet` (CT-01) — `preview`/`onApply` follow that exact
/// calling convention so the caller wires this the same way.
struct UserDesignerSheet: View {
    let driver: DriverID
    let preview: (UserDesign) -> [String]
    let onApply: (UserDesign) async -> String?
    let onClose: () -> Void

    @State private var design = UserDesign()
    @State private var applyError: String?
    @State private var isApplying = false

    /// Curated common privileges (docs/architecture/14 §Architecture) — not
    /// every value is meaningful on every dialect (e.g. CONNECT is
    /// Postgres-only); an unsupported pick surfaces as the server's own
    /// error, not a client-side filter per driver.
    private static let privileges = ["SELECT", "INSERT", "UPDATE", "DELETE", "ALL PRIVILEGES", "CONNECT", "CREATE"]

    private var statements: [String] { preview(design) }

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
        .frame(width: 480, height: 560)
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
            TextField(L("Username"), text: $design.username)
                .textFieldStyle(.roundedBorder)
            SecureField(L("Password"), text: $design.password)
                .textFieldStyle(.roundedBorder)
            if driver == .mysql {
                TextField(L("Host (optional, default %)"), text: $design.host)
                    .textFieldStyle(.roundedBorder)
            }
            grantsSection
        }
    }

    private var grantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Grants (optional)")).font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button {
                    design.grants.append(UserGrantDesign())
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help(L("Add grant"))
            }
            ForEach($design.grants) { $grant in
                HStack {
                    Picker(L("Privilege"), selection: $grant.privilege) {
                        Text(L("Select…")).tag("")
                        ForEach(Self.privileges, id: \.self) { privilege in
                            Text(privilege).tag(privilege)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    TextField(L("Database"), text: $grant.database)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        design.grants.removeAll { $0.id == grant.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("SQL Preview")).font(.subheadline).fontWeight(.semibold)
            Text(statements.joined(separator: ";\n") + (statements.isEmpty ? "" : ";"))
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
                    applyError = await onApply(design)
                    isApplying = false
                    if applyError == nil { onClose() }
                }
            } label: {
                if isApplying { ProgressView().controlSize(.small) } else { Text(L("Create")) }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!design.isValid || isApplying)
        }
        .padding(10)
    }
}
