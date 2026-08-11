import AppKit
import BerryCore
import SwiftUI

/// Status line under a result grid — shared by table tabs and editor results.
/// It merges status, readonly reason, errors, and pending changes actions into a single compact line (docs/ui).
struct BufferStatusBar: View {
    let buffer: ResultBuffer
    var showsProductionBadge = false

    // Optional parameters for inline pending-changes management
    var pendingCount: Int = 0
    var isApplying: Bool = false
    var applyError: String? = nil
    var readOnlyReason: String? = nil
    var canEdit: Bool = true

    var onDiscard: (() -> Void)? = nil
    var onApply: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if showsProductionBadge {
                ProductionBadge()
            }

            // 1. Buffer State (rowCount, duration, loading indicator, etc.)
            HStack(spacing: 8) {
                switch buffer.state {
                case .running:
                    ProgressView().controlSize(.small)
                    Text(L("Loading…"))
                case .complete:
                    Text(L("\(buffer.rowCount) rows"))
                    if let stats = buffer.stats {
                        if let affected = stats.rowsAffected {
                            Text(L("\(Int(affected)) affected"))
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.format(stats.duration))
                            .foregroundStyle(.secondary)
                    }
                case .cancelled:
                    Text(L("Cancelled — kept \(buffer.rowCount) received rows"))
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .lineLimit(1)
                        .textSelection(.enabled)
                        .help(message)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(L("Copy error"))
                    .accessibilityLabel(L("Copy error"))
                }
            }

            // 2. Read-only reason
            if let reason = readOnlyReason, !canEdit {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill").font(.caption2)
                    Text(reason)
                }
                .foregroundStyle(.secondary)
            }

            // 3. Apply Error (Inline)
            if let error = applyError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                    Text(error)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .foregroundStyle(.red)
            }

            Spacer()

            // 4. Compact Actions for Pending Changes (Discard / Apply as icons)
            if pendingCount > 0 {
                HStack(spacing: 8) {
                    Text(L("\(pendingCount) pending"))
                        .foregroundStyle(BerryTheme.accent)
                        .fontWeight(.medium)

                    // Discard Button (Icon)
                    if let onDiscard {
                        Button(action: onDiscard) {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.compact)
                        .disabled(isApplying)
                        .help(L("Discard pending changes"))
                    }

                    // Apply Button (Icon)
                    if let onApply {
                        Button(action: onApply) {
                            if isApplying {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark")
                            }
                        }
                        .buttonStyle(.compactRun)
                        .disabled(isApplying)
                        .help(L("Apply pending changes"))
                    }
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    static func format(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000)
                           : String(format: "%.2f s", seconds)
    }
}

/// Persistent visual warning for production connections (KN-07).
struct ProductionBadge: View {
    var body: some View {
        Text(verbatim: "PROD")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.white)
    }
}
