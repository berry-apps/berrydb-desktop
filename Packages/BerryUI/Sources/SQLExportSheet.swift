import SwiftUI

/// SQL export options (XN-03): batch size for multi-row INSERTs and whether to
/// prepend the CREATE TABLE DDL. Confirming runs the save panel + export.
struct SQLExportSheet: View {
    let canIncludeDDL: Bool
    let onExport: (_ batchSize: Int, _ includeDDL: Bool) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var batchSize = 100
    @State private var includeDDL = false
    @State private var isExporting = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "curlybraces.square")
                Text(L("Export SQL")).font(.headline)
            }

            HStack {
                Text(L("Rows per INSERT"))
                Stepper(value: $batchSize, in: 1...1000, step: 10) {
                    Text(verbatim: "\(batchSize)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }

            Toggle(L("Include CREATE TABLE"), isOn: $includeDDL)
                .disabled(!canIncludeDDL)
                .help(canIncludeDDL ? "" : L("Schema not available"))

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    guard !isExporting else { return }
                    isExporting = true
                    Task {
                        message = await onExport(batchSize, includeDDL && canIncludeDDL)
                        isExporting = false
                        // A nil message means the user cancelled the save panel;
                        // keep the sheet open. A real result dismisses.
                        if message != nil { dismiss() }
                    }
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L("Export…"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
