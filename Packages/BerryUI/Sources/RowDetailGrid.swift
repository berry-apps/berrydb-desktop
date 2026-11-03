import BerryCore
import SwiftUI

struct RowInspectorState {
    private(set) var isOpen = false
    private(set) var selectedRow: Int?

    mutating func select(_ row: Int?) { selectedRow = row }
    mutating func toggle() { isOpen.toggle() }
    mutating func close() { isOpen = false }
    mutating func open(row: Int) {
        selectedRow = row
        isOpen = true
    }

    static func usesOverlay(width: CGFloat) -> Bool { width < 600 }
}

struct RowDetailGrid: View {
    let buffer: ResultBuffer
    let grid: DataGridView
    @State private var inspector = RowInspectorState()

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                if RowInspectorState.usesOverlay(width: geometry.size.width) {
                    inspectedGrid
                        .overlay(alignment: .trailing) {
                            if inspector.isOpen {
                                detailPanel
                                    .frame(width: min(340, max(0, geometry.size.width)))
                                    .background(.background)
                                    .overlay(alignment: .leading) { Divider() }
                            }
                        }
                } else {
                    HSplitView {
                        inspectedGrid
                            .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                        if inspector.isOpen {
                            detailPanel
                                .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button { inspector.toggle() } label: {
                    Label(L("Row Details"), systemImage: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(inspector.isOpen ? Color.accentColor : Color.secondary)
                .accessibilityValue(inspector.isOpen ? L("Shown") : L("Hidden"))
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.bar)
        }
        .onChange(of: buffer.state) {
            if buffer.state == .running { inspector.select(nil) }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let row = inspector.selectedRow,
           let target = RowTarget.from(
               buffer: buffer, row: row, appendedRowCount: grid.appendedRowCount,
               overlay: { grid.overlay?(row, $0) }
           ) {
            RowDetailView(target: target, onClose: { inspector.close() })
        } else {
            VStack {
                HStack {
                    Text(L("Row Details")).font(.headline)
                    Spacer()
                    Button { inspector.close() } label: { Image(systemName: "xmark") }
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
        grid.onSelectRow = { inspector.select($0) }
        grid.onViewRow = { inspector.open(row: $0) }
        return grid
    }
}
