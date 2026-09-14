import BerryKeyValueKit
import SwiftUI

/// Create a new string key — v1 write scope is
/// string SET/DEL/EXPIRE only (`KeyValueChangeSet`), same reasoning
/// `NewCollectionSheet` documents for its own scope: small enough to fit
/// without internal scrolling. The generated command is always shown
/// before Create, same rule as `UserDesignerSheet`/`TableDesignerSheet`.
struct NewKeyValueSheet: View {
    let preview: (KeyValueChangeSet) -> String
    let onCreate: (KeyValueChangeSet) async -> String?
    let onClose: () -> Void

    @State private var key = ""
    @State private var value = ""
    @State private var ttlText = ""
    @State private var errorMessage: String?
    @State private var isCreating = false

    private var change: KeyValueChangeSet? {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        guard !trimmedKey.isEmpty else { return nil }
        let ttl = ttlText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TimeInterval(ttlText)
        return .set(key: trimmedKey, value: value, ttl: ttl)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "plus.circle")
                Text(L("New Key")).font(.headline)
            }

            TextField(L("Key"), text: $key)
                .textFieldStyle(.roundedBorder)
            TextField(L("Value"), text: $value)
                .textFieldStyle(.roundedBorder)
            TextField(L("TTL in seconds (optional)"), text: $ttlText)
                .textFieldStyle(.roundedBorder)

            if let change {
                Text(preview(change))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await submit() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text(L("Create")) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(change == nil || isCreating)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func submit() async {
        guard let change else {
            errorMessage = L("Key cannot be empty")
            return
        }
        if !ttlText.trimmingCharacters(in: .whitespaces).isEmpty && TimeInterval(ttlText) == nil {
            errorMessage = L("TTL must be a number")
            return
        }
        isCreating = true
        errorMessage = await onCreate(change)
        isCreating = false
        if errorMessage == nil { onClose() }
    }
}
