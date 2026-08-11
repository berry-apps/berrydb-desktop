import SwiftUI

/// Global command palette (DI-22, docs/architecture/13 §5.3, ⌘K): fuzzy-search
/// the workspace's actions and run one without leaving the keyboard. Row/
/// keyboard pattern mirrors `QuickOpenView.swift` — plain Buttons, not
/// `List(selection:)` (same click-to-select bug class avoided there).
struct CommandPaletteView: View {
    let entries: [CommandPaletteEntry]
    let onCancel: () -> Void
    /// NL routing fallback (DI-22 §5.3) for when no local keyword matches —
    /// `AIPanelController.routeCommandPaletteQuery`. `performed` lets this
    /// view dismiss deterministically instead of parsing `reply`'s text.
    let onAskAI: (String) async -> (performed: Bool, reply: String?)

    @State private var query = ""
    @State private var selectedID: String?
    @State private var isAsking = false
    @State private var aiMessage: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [CommandPaletteEntry] {
        CommandPaletteEntries.matching(query, in: entries).filter(\.isEnabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Type a command…"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit(selectHighlightedOrFirst)
            }
            .padding(10)
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            Button { run(entry) } label: {
                                HStack(spacing: 8) {
                                    Text(entry.title)
                                    Spacer(minLength: 0)
                                    Text(entry.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(
                                    entry.id == selectedID ? Color.accentColor.opacity(0.15) : .clear,
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
        .frame(width: 460)
        .onAppear {
            searchFocused = true
            selectedID = filtered.first?.id
        }
        .onChange(of: query) { _, _ in
            selectedID = filtered.first?.id
            aiMessage = nil
        }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.return, action: { selectHighlightedOrFirst(); return .handled })
    }

    /// No local keyword match: offer to route the query through
    /// `perform_ui_action` instead (DI-22 §5.3) rather than a dead end.
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if isAsking {
                ProgressView().controlSize(.small)
                Text(L("Asking AI…")).font(.caption).foregroundStyle(.secondary)
            } else if let aiMessage {
                Text(aiMessage).font(.callout).multilineTextAlignment(.center)
            } else if !query.isEmpty {
                Button(action: askAI) {
                    Label("\(L("Ask AI")): \u{201C}\(query)\u{201D}", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
                Text(L("No matching commands — press Return to ask AI"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("No matching commands")).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let currentIndex = filtered.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let next = max(0, min(filtered.count - 1, currentIndex + delta))
        selectedID = filtered[next].id
    }

    private func selectHighlightedOrFirst() {
        guard !filtered.isEmpty, let entry = filtered.first(where: { $0.id == selectedID }) ?? filtered.first else {
            if !query.isEmpty { askAI() }
            return
        }
        run(entry)
    }

    private func askAI() {
        guard !isAsking, !query.isEmpty else { return }
        isAsking = true
        aiMessage = nil
        let text = query
        Task {
            let result = await onAskAI(text)
            isAsking = false
            if result.performed {
                onCancel()
            } else {
                aiMessage = result.reply ?? L("Couldn't find a matching action.")
            }
        }
    }

    private func run(_ entry: CommandPaletteEntry) {
        entry.perform()
        onCancel()
    }
}
