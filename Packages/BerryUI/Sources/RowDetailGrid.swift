import BerryCore
import SwiftUI

enum RowInspectorState {
    static func usesOverlay(width: CGFloat) -> Bool { width < 600 }
}

struct RowDetailGrid: View {
    let buffer: ResultBuffer
    let grid: DataGridView
    @Binding var isOpen: Bool
    @State private var selectedRow: Int?

    var body: some View {
        GeometryReader { geometry in
            let narrow = RowInspectorState.usesOverlay(width: geometry.size.width)
            HSplitView {
                inspectedGrid
                    .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                if isOpen && !narrow {
                    detailPanel
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                }
            }
            .overlay(alignment: .trailing) {
                if isOpen && narrow {
                    detailPanel
                        .frame(width: min(340, max(0, geometry.size.width)))
                        .background(.background)
                        .overlay(alignment: .leading) { Divider() }
                }
            }
        }
        .onChange(of: buffer.state) {
            if buffer.state == .running { selectedRow = nil }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let row = selectedRow,
           let target = RowTarget.from(
               buffer: buffer, row: row, appendedRowCount: grid.appendedRowCount,
               overlay: { grid.overlay?(row, $0) }
           ) {
            RowDetailView(target: target, onClose: { isOpen = false })
        } else {
            VStack {
                HStack {
                    Text(L("Row Details")).font(.headline)
                    Spacer()
                    Button { isOpen = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("Close"))
                }
                .padding(12)
                Divider()
                Spacer()
                Text(L("Select a single row to view details."))
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var inspectedGrid: DataGridView {
        var grid = grid
        grid.onSelectRow = { selectedRow = $0 }
        grid.onViewRow = { selectedRow = $0; isOpen = true }
        return grid
    }
}
