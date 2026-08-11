import SwiftUI

/// Read-only sibling of `UserManagementView` (TI-03 Phase D,
/// docs/architecture/14) for a connection with no in-DB user system —
/// DynamoDB (AWS IAM) and Qdrant (API key). A static note instead of a
/// list/create/drop UI: there is nothing to list, nothing to reload.
struct UserManagementInfoView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.2")
                Text(L("Users")).font(.headline)
                Spacer()
            }
            .padding(10)
            Divider()
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(L("Close")) { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
