import BerryDriverKit
import SwiftUI

/// Quick-info panel: row count/size/engine/comment for the selected
/// object, best-effort per driver (any field the DBMS doesn't expose shows
/// "—", never a fake value — see each Introspector.tableStats).
struct TableStatsSheet: View {
    let object: SchemaObject
    let load: () async -> TableStats?

    @Environment(\.dismiss) private var dismiss
    @State private var stats: TableStats?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text(object.name).font(.headline)
                Spacer()
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            content
        }
        // Generous fixed frame, not sized to intrinsic content: .formStyle(.grouped)
        // is backed by a scrollable List on macOS, so a tight frame made it clip
        // and scroll instead of showing all 4 rows at once (window and layout rules).
        .frame(width: 420, height: 300)
        .task {
            stats = await load()
            loading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let stats {
            Form {
                row(L("Rows"), stats.estimatedRowCount.map { "\($0)" })
                row(L("Size"), stats.sizeBytes.map {
                    ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary)
                })
                row(L("Engine"), stats.engine)
                row(L("Comment"), stats.comment)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        } else {
            Text(L("Stats not available")).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        LabeledContent(label) {
            Text(value ?? "—")
                .foregroundStyle(value == nil ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }
}
