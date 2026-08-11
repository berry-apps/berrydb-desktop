import BerryDataSourceKit
import BerryDriverKit
import SwiftUI

/// Global quick-open palette (TR-02, ⌘P): fuzzy-search tables/views/
/// collections and jump straight to one, reachable from anywhere in the
/// window instead of requiring the sidebar's own filter field to have focus.
/// Uses plain Buttons (not `List(selection:)`) for the rows — a competing
/// custom tap handler on a `List` row is exactly the click-to-select bug
/// fixed in WorkspaceView's sidebar (docs/feedback/01.md #1); Buttons avoid
/// that class of bug entirely.
struct QuickOpenView: View {
    let objects: [SchemaObject]
    let collections: [CollectionRef]
    let onSelect: (QuickOpenItem) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var selectedID: String?
    @FocusState private var searchFocused: Bool

    private var items: [QuickOpenItem] {
        QuickOpenItem.filter(objects: objects, collections: collections, query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Go to table or collection…"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(selectHighlightedOrFirst)
            }
            .padding(10)
            Divider()
            if items.isEmpty {
                Text(L("No matches")).foregroundStyle(.secondary).padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            Button { onSelect(item) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.iconName).frame(width: 16)
                                    Text(item.name)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(
                                    item.id == selectedID ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 420)
        .onAppear {
            searchFocused = true
            selectedID = items.first?.id
        }
        .onChange(of: query) { _, _ in selectedID = items.first?.id }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.return, action: { selectHighlightedOrFirst(); return .handled })
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(items.count - 1, currentIndex + delta))
        selectedID = items[next].id
    }

    private func selectHighlightedOrFirst() {
        guard let item = items.first(where: { $0.id == selectedID }) ?? items.first else { return }
        onSelect(item)
    }
}
