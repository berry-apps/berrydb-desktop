import BerryGraph
import BerryStore
import SwiftUI

/// Time Machine Timeline: pick a recorded change of the schema and see what
/// changed since the one before it. Existence-only (added/removed tables,
/// columns, indexes) — see `TimelineChange`'s doc comment for why
/// attribute-level changes (e.g. a column's type) aren't tracked. Reads
/// through the viewModel — presentation only. The marks and the changes are
/// loaded in tasks into state, never computed in `body`: a comparison loads
/// two whole graphs, and `body` runs on the main actor on every redraw.
struct TimeMachineView: View {
    /// When the stored schema last changed; a new value reloads the marks.
    let graphChangedAt: Date?
    let marks: () async -> [SchemaChangeRecord]
    let changes: (Date, Date) async -> [TimelineChange]
    let onReveal: (String) -> Void
    let onClose: () -> Void

    private struct Shown {
        let markID: SchemaChangeRecord.ID
        let changes: [TimelineChange]
    }

    @State private var allMarks: [SchemaChangeRecord] = []
    @State private var selectedID: SchemaChangeRecord.ID?
    @State private var shown: Shown?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Time Machine")).font(.headline)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding()
            Divider()
            if allMarks.count < 2 {
                ContentUnavailableView(
                    L("Not enough history yet"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L("Time Machine needs at least two recorded schema snapshots — keep refreshing the schema as it evolves."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    markPicker
                    Divider()
                    detail
                }
            }
        }
        .task(id: graphChangedAt) {
            let loaded = await marks()
            guard !Task.isCancelled else { return }
            allMarks = loaded
            if !loaded.contains(where: { $0.id == selectedID }) { selectedID = loaded.first?.id }
        }
        // A mark's changes do not move once it is listed, so only a new
        // selection loads them again.
        .task(id: selectedID) {
            guard let selectedID, let index = allMarks.firstIndex(where: { $0.id == selectedID }),
                  index + 1 < allMarks.count
            else { return }
            // Newest first: the mark right after this one is the baseline.
            let loaded = await changes(allMarks[index + 1].at, allMarks[index].at)
            guard !Task.isCancelled else { return }
            shown = Shown(markID: selectedID, changes: loaded)
        }
    }

    private var markPicker: some View {
        List(allMarks, selection: $selectedID) { mark in
            VStack(alignment: .leading, spacing: 2) {
                Text(mark.at, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout)
                Text(L("\(mark.added) added · \(mark.changed) changed · \(mark.removed) removed"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(mark.id)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if let selectedID, let index = allMarks.firstIndex(where: { $0.id == selectedID }) {
            if index + 1 >= allMarks.count {
                ContentUnavailableView(
                    L("First recorded snapshot"),
                    systemImage: "flag.checkered",
                    description: Text(L("Nothing earlier to compare against."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let shown, shown.markID == selectedID {
                changeList(shown.changes)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView(
                L("Select a snapshot"),
                systemImage: "sidebar.left",
                description: Text(L("Pick a date to see what changed."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func changeList(_ changes: [TimelineChange]) -> some View {
        let grouped = Dictionary(grouping: changes) { $0.tableName ?? $0.name }
        return ScrollView {
            VStack(alignment: .leading, spacing: BerryTheme.Space.lg) {
                if grouped.isEmpty {
                    Text(L("No structural changes since the previous snapshot."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(grouped.keys.sorted(), id: \.self) { table in
                        changeGroup(table, grouped[table] ?? [])
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func changeGroup(_ table: String, _ items: [TimelineChange]) -> some View {
        VStack(alignment: .leading, spacing: BerryTheme.Space.sm) {
            HStack {
                Text(table).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    onReveal(table)
                } label: {
                    Label(L("Reveal"), systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            ForEach(items) { change in
                Label(changeDescription(change), systemImage: change.isAdded ? "plus.circle" : "minus.circle")
                    .foregroundStyle(change.isAdded ? .green : .red)
                    .font(.callout)
            }
        }
        .bentoCard()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeDescription(_ change: TimelineChange) -> String {
        let kind = switch change.kind {
        case .table: L("table")
        case .index: L("index")
        default: L("column")
        }
        return "\(change.name) (\(kind))"
    }
}
