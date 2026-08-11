import BerryGraph
import SwiftUI

/// Graph Explorer (docs/architecture/11 §5, DI-02/04): pick a harvested table
/// and see what it depends on, what depends on it, and its full blast radius.
/// Reads the DSG through the viewModel — presentation only.
struct GraphExplorerView: View {
    let tables: () -> [String]
    let overview: (String) -> TableGraphOverview
    /// Quantified impact against real recent workload (docs/feature/07 §4,
    /// DI-16) — nil only when the feature itself is unavailable, not for "no
    /// matches" (see `WorkspaceViewModel.simulateImpact`).
    let simulateImpact: (String) -> ImpactSimulator.Report?
    let onReveal: (String) -> Void
    let onClose: () -> Void

    @State private var allTables: [String] = []
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Graph Explorer")).font(.headline)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding()
            Divider()
            if allTables.isEmpty {
                ContentUnavailableView(
                    L("No graph yet"),
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(L("Connect and refresh the schema to build the dependency graph."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    tablePicker
                    Divider()
                    detail
                }
            }
        }
        .onAppear { allTables = tables() }
    }

    private var tablePicker: some View {
        List(allTables, id: \.self, selection: $selected) { name in
            Label(name, systemImage: "tablecells").tag(name)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            let o = overview(selected)
            ScrollView {
                VStack(alignment: .leading, spacing: BerryTheme.Space.lg) {
                    Text(selected).font(.title3.weight(.semibold))
                    group(L("Depends on"), systemImage: "arrow.up.right", o.dependsOn,
                          empty: L("References no other tables."))
                    group(L("Depended on by"), systemImage: "arrow.down.left", o.dependents,
                          empty: L("No table references this one."))
                    group(L("Blast radius"), systemImage: "burst", o.blastRadius,
                          empty: L("Changing it affects nothing downstream."))
                    impactGroup(selected)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                L("Select a table"),
                systemImage: "sidebar.left",
                description: Text(L("Pick a table to see its dependencies."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func group(_ title: String, systemImage: String, _ names: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
            Label("\(title) (\(names.count))", systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            if names.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Button {
                            onReveal(name)
                        } label: {
                            Label(L("Reveal"), systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                }
            }
        }
        .bentoCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Quantified impact against real recent workload (docs/feature/07 §4,
    /// DI-16) — complements the pure-topology "Blast radius" group above with
    /// which of the recent history's queries actually touch this table (or
    /// anything in its blast radius), ranked by how often they ran.
    private func impactGroup(_ table: String) -> some View {
        let report = simulateImpact(table)
        return VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
            Label(L("Quantified impact (recent workload)"), systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
            if let report, !report.affectedQueries.isEmpty {
                Text("\(report.affectedQueries.count) \(L("affected queries")) · \(report.totalCallCount) \(L("total calls"))")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(Array(report.affectedQueries.prefix(10).enumerated()), id: \.offset) { _, query in
                    HStack(alignment: .top, spacing: 8) {
                        Text(query.sql)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text("×\(query.frequency)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(L("No recent queries in history touch this table."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .bentoCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
