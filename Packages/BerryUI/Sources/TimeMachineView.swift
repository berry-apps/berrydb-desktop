import BerryGraph
import BerryStore
import SwiftUI

/// Time Machine Timeline
/// pick a recorded Digital-Twin snapshot and see what changed since the
/// one before it. Existence-only (added/removed tables, columns, indexes) —
/// see `TimelineChange`'s doc comment for why attribute-level changes (e.g. a
/// column's type) aren't tracked. Reads through the viewModel — presentation
/// only.
struct TimeMachineView: View {
    let snapshots: () -> [GraphSnapshotRecord]
    let changes: (Date, Date) -> [TimelineChange]
    let onReveal: (String) -> Void
    let onClose: () -> Void

    @State private var allSnapshots: [GraphSnapshotRecord] = []
    @State private var selectedID: GraphSnapshotRecord.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Time Machine")).font(.headline)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding()
            Divider()
            if allSnapshots.count < 2 {
                ContentUnavailableView(
                    L("Not enough history yet"),
                    systemImage: "clock.arrow.circlepath",
                    description: Text(L("Time Machine needs at least two recorded schema snapshots — keep refreshing the schema as it evolves."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    snapshotPicker
                    Divider()
                    detail
                }
            }
        }
        .onAppear {
            allSnapshots = snapshots()
            selectedID = allSnapshots.first?.id
        }
    }

    private var snapshotPicker: some View {
        List(allSnapshots, selection: $selectedID) { snapshot in
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.takenAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.callout)
                Text("\(snapshot.nodeCount) \(L("nodes"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(snapshot.id)
        }
        .frame(width: 220)
    }

    @ViewBuilder private var detail: some View {
        if let selectedID, let index = allSnapshots.firstIndex(where: { $0.id == selectedID }) {
            let current = allSnapshots[index]
            // Newest first: the snapshot right before this one (higher index) is the baseline.
            if index + 1 < allSnapshots.count {
                let previous = allSnapshots[index + 1]
                changeList(from: previous.takenAt, to: current.takenAt)
            } else {
                ContentUnavailableView(
                    L("First recorded snapshot"),
                    systemImage: "flag.checkered",
                    description: Text(L("Nothing earlier to compare against."))
                )
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

    private func changeList(from earlier: Date, to later: Date) -> some View {
        let grouped = Dictionary(grouping: changes(earlier, later)) { $0.tableName ?? $0.name }
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
