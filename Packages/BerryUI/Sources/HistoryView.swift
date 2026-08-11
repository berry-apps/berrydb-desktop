import BerryStore
import SwiftUI

/// Query history viewer (ED-06): searchable, paged list of executed statements
/// for the active profile, with one-click insert into a new query tab. Search
/// and paging happen in SQLite (`WorkspaceViewModel.refreshHistory`/
/// `loadMoreHistory`), so a large history stays flat in RAM and search hits the
/// whole table, not just a loaded slice.
struct HistoryView: View {
    let entries: [QueryHistoryEntry]
    let hasMore: Bool
    /// Called with the current search term to (re)load the first page.
    let onSearch: (String) -> Void
    /// Called as the list scrolls to its end to append the next page.
    let onLoadMore: () -> Void
    let onInsert: (String) -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text(L("History")).font(.headline)
                Spacer()
                TextField(L("Search history"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            .padding(10)
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    L("No history yet"),
                    systemImage: "clock",
                    description: Text(L("Executed statements appear here"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                    if hasMore {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .onAppear { onLoadMore() }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Button(role: .destructive) {
                    onClear()
                } label: {
                    Label(L("Clear All"), systemImage: "trash")
                }
                .disabled(entries.isEmpty)
                Spacer()
                Button(L("Close")) { onClose() }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Initial page load, and reload whenever the search term changes — both
        // go through SQLite (keyset paging), not a client-side filter.
        .task { onSearch(search) }
        .onChange(of: search) { onSearch(search) }
    }

    private func row(_ entry: QueryHistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot(entry.status)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.sql)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(2)
                    .help(entry.sql)
                HStack(spacing: 8) {
                    Text(entry.startedAt, format: .dateTime.day().month().hour().minute().second())
                    Text(verbatim: "\(entry.durationMS) ms")
                    if let rowCount = entry.rowCount {
                        Text(L("\(rowCount) rows"))
                    }
                    if let error = entry.errorMessage {
                        Text(error).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onInsert(entry.sql)
            } label: {
                Image(systemName: "arrow.down.doc")
            }
            .buttonStyle(.borderless)
            .help(L("Insert into new SQL tab"))
        }
        .padding(.vertical, 2)
    }

    private func statusDot(_ status: String) -> some View {
        let color: Color = switch status {
        case "success": .green
        case "cancelled": .orange
        default: .red
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }
}
