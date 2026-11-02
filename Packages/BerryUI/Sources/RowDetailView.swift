import BerryDriverKit
import Foundation
import SwiftUI

struct RowDetailView: View {
    let target: RowTarget

    let onClose: () -> Void
    @State private var cellTarget: CellTarget?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Row Details"))
                    .font(.headline)
                Spacer()
                Text(L("Row") + " \(target.row + 1)")
                    .foregroundStyle(.secondary)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(target.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(verbatim: field.column.name)
                                    .font(.system(.body, design: .monospaced).bold())
                                    .textSelection(.enabled)
                                Text(verbatim: field.column.declaredType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(L("View Cell…")) {
                                    cellTarget = CellTarget(
                                        row: target.row, column: field.id,
                                        value: field.value, columnName: field.column.name
                                    )
                                }
                            }
                            Text(verbatim: displayText(field.value))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(field.value == .null ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $cellTarget) { cell in
            CellViewerSheet(
                value: cell.value, columnName: cell.columnName,
                editable: false, onSave: nil
            )
        }
    }

    private func displayText(_ value: BerryValue) -> String {
        switch value {
        case .null:
            "NULL"
        case .bytes(let data):
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
        default:
            value.displayString ?? ""
        }
    }
}
