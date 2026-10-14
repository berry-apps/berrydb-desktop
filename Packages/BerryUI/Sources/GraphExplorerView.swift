import BerryGraph
import SwiftUI

/// Graph Explorer: pick a harvested table
/// and see what it depends on, what depends on it, and its full blast radius.
/// Reads the DSG through the viewModel — presentation only. What it shows is
/// loaded in tasks into state, never computed in `body`: every read walks the
/// whole graph, and `body` runs on the main actor on every redraw.
struct GraphExplorerView: View {
    /// When the stored schema last changed; a new value reloads the view.
    let graphChangedAt: Date?
    let tables: () async -> [String]
    let overview: (String) async -> TableGraphOverview
 /// Quantified impact against real recent workload
 /// — nil only when the feature itself is unavailable, not for "no
    /// matches" (see `WorkspaceViewModel.simulateImpact`).
    let simulateImpact: (String) async -> ImpactSimulator.Report?
    let onReveal: (String) -> Void
    let onClose: () -> Void

    private struct Detail {
        let table: String
        let overview: TableGraphOverview
        let impact: ImpactSimulator.Report?
    }

    private struct DetailKey: Equatable {
        let table: String?
        let changedAt: Date?
    }

    @State private var allTables: [String] = []
    @State private var tablesLoaded = false
    @State private var selected: String?
    @State private var detailShown: Detail?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Graph Explorer")).font(.headline)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding()
            Divider()
            if !tablesLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allTables.isEmpty {
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
        .task(id: graphChangedAt) {
            let loaded = await tables()
            guard !Task.isCancelled else { return }
            allTables = loaded
            tablesLoaded = true
        }
        .task(id: DetailKey(table: selected, changedAt: graphChangedAt)) {
            guard let selected else {
                detailShown = nil
                return
            }
            let dependencies = await overview(selected)
            let impact = await simulateImpact(selected)
            guard !Task.isCancelled else { return }
            detailShown = Detail(table: selected, overview: dependencies, impact: impact)
        }
    }

    private var tablePicker: some View {
        List(allTables, id: \.self, selection: $selected) { name in
            Label(name, systemImage: "tablecells").tag(name)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if let selected, let shown = detailShown, shown.table == selected {
            let o = shown.overview
            ScrollView {
                VStack(alignment: .leading, spacing: BerryTheme.Space.lg) {
                    Text(selected).font(.title3.weight(.semibold))
                    group(L("Depends on"), systemImage: "arrow.up.right", o.dependsOn,
                          empty: L("References no other tables."))
                    group(L("Depended on by"), systemImage: "arrow.down.left", o.dependents,
                          empty: L("No table references this one."))
                    group(L("Blast radius"), systemImage: "burst", o.blastRadius,
                          empty: L("Changing it affects nothing downstream."))
                    impactGroup(shown.impact)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if selected != nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

 /// Quantified impact against real recent workload
 /// — complements the pure-topology "Blast radius" group above with
    /// which of the recent history's queries actually touch this table (or
    /// anything in its blast radius), ranked by how often they ran.
    private func impactGroup(_ report: ImpactSimulator.Report?) -> some View {
        VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
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
