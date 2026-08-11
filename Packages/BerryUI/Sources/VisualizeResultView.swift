import BerryDriverKit
import Charts
import SwiftUI

/// Visualize Result (docs/feature/07 §8, AI SQL Copilot): a bar/line chart
/// over the current result set. A transient, single-result view — a sheet
/// like `DDLSheet`/`TableStatsSheet`, not a tab (unlike Insights/Graph
/// Explorer/Time Machine, this isn't an ongoing, navigable analysis surface,
/// just a one-off look at whatever the grid currently shows). Presentation
/// only — never re-queries the database.
struct VisualizeResultView: View {
    let columns: [ColumnMeta]
    let rows: [[BerryValue]]
    let onClose: () -> Void

    enum ChartKind: String, CaseIterable, Identifiable {
        case bar, line
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bar: L("Bar")
            case .line: L("Line")
            }
        }
    }

    struct Point: Equatable {
        let x: String
        let y: Double
    }

    @State private var xColumn: Int
    @State private var yColumn: Int
    @State private var kind: ChartKind = .bar

    init(columns: [ColumnMeta], rows: [[BerryValue]], onClose: @escaping () -> Void) {
        self.columns = columns
        self.rows = rows
        self.onClose = onClose
        let numericIndex = columns.indices.first { index in
            rows.contains { index < $0.count && $0[index].numericValue != nil }
        }
        let y = numericIndex ?? (columns.count > 1 ? 1 : 0)
        let x = columns.indices.first { $0 != y } ?? 0
        _xColumn = State(initialValue: x)
        _yColumn = State(initialValue: y)
    }

    /// Rows reduced to (label, value) pairs for the chosen columns — rows
    /// missing a numeric Y value are skipped rather than plotted as zero.
    static func points(rows: [[BerryValue]], xColumn: Int, yColumn: Int) -> [Point] {
        rows.compactMap { row in
            guard xColumn < row.count, yColumn < row.count,
                  let y = row[yColumn].numericValue
            else { return nil }
            return Point(x: row[xColumn].displayString ?? "", y: y)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Visualize Result")).font(.headline)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding()
            Divider()
            if columns.count < 2 || rows.isEmpty {
                ContentUnavailableView(
                    L("Not enough data to visualize"),
                    systemImage: "chart.bar",
                    description: Text(L("Run a query with at least two columns and one numeric value."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                controls
                chartView.padding()
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Picker(L("X"), selection: $xColumn) {
                ForEach(columns.indices, id: \.self) { i in Text(columns[i].name).tag(i) }
            }
            .frame(width: 160)
            Picker(L("Y"), selection: $yColumn) {
                ForEach(columns.indices, id: \.self) { i in Text(columns[i].name).tag(i) }
            }
            .frame(width: 160)
            Picker(L("Chart type"), selection: $kind) {
                ForEach(ChartKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder private var chartView: some View {
        let points = Self.points(rows: rows, xColumn: xColumn, yColumn: yColumn)
        if points.isEmpty {
            ContentUnavailableView(
                L("No numeric values in this column"),
                systemImage: "chart.bar",
                description: Text(L("Pick a different Y column."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    switch kind {
                    case .bar:
                        BarMark(
                            x: .value(columns[xColumn].name, point.x),
                            y: .value(columns[yColumn].name, point.y)
                        )
                    case .line:
                        LineMark(
                            x: .value(columns[xColumn].name, point.x),
                            y: .value(columns[yColumn].name, point.y)
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
