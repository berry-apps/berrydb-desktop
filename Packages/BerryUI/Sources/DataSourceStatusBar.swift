import SwiftUI

/// Status bar for a `DataSourceResultBuffer` (Mongo shell results, and
/// Task 14's Qdrant parity pass) — sibling of `BufferStatusBar` for the
/// NoSQL buffer type, reusing its `format(_:)` duration formatter so both
/// read identically instead of duplicating the logic.
struct DataSourceStatusBar: View {
    let buffer: DataSourceResultBuffer
    var showsProductionBadge = false
    var writeError: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if showsProductionBadge { ProductionBadge() }
            switch buffer.state {
            case .running:
                ProgressView().controlSize(.small)
                Text(L("Running…"))
            case .complete:
                Text(L("\(buffer.itemCount) items"))
                if let stats = buffer.stats {
                    Text(BufferStatusBar.format(stats.duration)).foregroundStyle(.secondary)
                }
            case .cancelled:
                Text(L("Cancelled — kept \(buffer.itemCount) received items"))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(message).lineLimit(1).textSelection(.enabled)
            }
            if let writeError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(writeError).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
