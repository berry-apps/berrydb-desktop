import BerryCore
import SwiftUI

struct RowDetailGrid: View {
    let buffer: ResultBuffer
    let grid: DataGridView
    @State private var selectedRow: Int?

    var body: some View {
        HSplitView {
            inspectedGrid
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
            if let selectedRow,
               let target = RowTarget.from(
                   buffer: buffer, row: selectedRow, appendedRowCount: grid.appendedRowCount,
                   overlay: { grid.overlay?(selectedRow, $0) }
               ) {
                RowDetailView(target: target, onClose: { self.selectedRow = nil })
                    .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
            }
        }
        .onChange(of: buffer.state) {
            if buffer.state == .running { selectedRow = nil }
        }
    }

    private var inspectedGrid: DataGridView {
        var grid = grid
        grid.onSelectRow = { selectedRow = $0 }
        grid.onViewRow = { selectedRow = $0 }
        return grid
    }
}
