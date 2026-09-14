import AppKit
import BerryCore
import SwiftUI

/// One row of the custom completion popup: what the row shows,
/// what accepting it inserts (may be dialect-quoted), and its type metadata.
struct CompletionItem: Equatable {
    let display: String
    let insert: String
    /// SF Symbol for the suggestion type (keyword/table/column).
    let icon: String
    /// Muted secondary text — category or a column's owning table.
    let detail: String
}

/// Observable state the popup list renders from.
@MainActor
@Observable
final class CompletionPopupModel {
    var items: [CompletionItem] = []
    var query = ""
    var selectedIndex = 0
}

/// Floating autocomplete panel under the text caret: rounded,
/// shadowed, scrollable; blue selection, yellow highlight on matched chars.
/// A non-activating panel — the editor keeps keyboard focus and routes
/// ↑ ↓ ↩ ⇥ ⎋ here while the popup is visible.
@MainActor
final class CompletionPopupController {
    private let panel: NSPanel
    private let model = CompletionPopupModel()
    /// Called when a suggestion is accepted (keyboard or click).
    var onAccept: ((CompletionItem) -> Void)?

    private static let rowHeight: CGFloat = 24
    private static let width: CGFloat = 360
    private static let maxVisibleRows = 8

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: CompletionListView(
            model: model,
            accept: { [weak self] item in
                self?.onAccept?(item)
                self?.hide()
            }
        ))
    }

    var isVisible: Bool { panel.isVisible }

    /// Present (or refresh) the popup anchored below the caret's screen rect.
    func show(items: [CompletionItem], query: String, below caretRect: NSRect) {
        model.items = items
        model.query = query
        model.selectedIndex = 0
        let height = CGFloat(min(items.count, Self.maxVisibleRows)) * Self.rowHeight + 10
        panel.setContentSize(NSSize(width: Self.width, height: height))
        // firstRect(forCharacterRange:) is in screen coordinates; the panel's
        // top-left goes just under the caret line.
        panel.setFrameTopLeftPoint(NSPoint(x: caretRect.minX, y: caretRect.minY - 3))
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// Arrow-key navigation; clamped to the list bounds.
    func moveSelection(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selectedIndex = min(max(model.selectedIndex + delta, 0), model.items.count - 1)
    }

    /// Accept the highlighted row. Returns false when nothing is selectable.
    @discardableResult
    func acceptSelected() -> Bool {
        guard model.items.indices.contains(model.selectedIndex) else { return false }
        let item = model.items[model.selectedIndex]
        onAccept?(item)
        hide()
        return true
    }
}

/// The scrollable suggestion list: icon + label with matched
/// characters in yellow + muted detail; selected row solid blue with white text.
private struct CompletionListView: View {
    let model: CompletionPopupModel
    let accept: (CompletionItem) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        row(item, selected: index == model.selectedIndex)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { accept(item) }
                    }
                }
                .padding(5)
            }
            .onChange(of: model.selectedIndex) {
                proxy.scrollTo(model.selectedIndex)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BerryTheme.hairline, lineWidth: 1))
    }

    private func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(selected ? .white : .secondary)
            highlightedLabel(item.display, selected: selected)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(item.detail)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white.opacity(0.75) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(
            selected ? AnyShapeStyle(BerryTheme.accent) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .foregroundStyle(selected ? Color.white : Color.primary)
    }

    /// The typed characters light up yellow inside each suggestion (fuzzy-match
 /// scanability, spec).
    private func highlightedLabel(_ text: String, selected: Bool) -> Text {
        let offsets = Set(CompletionProvider.matchOffsets(of: model.query, in: text))
        var attributed = AttributedString()
        for (index, character) in text.enumerated() {
            var piece = AttributedString(String(character))
            if offsets.contains(index) {
                piece.foregroundColor = selected ? .yellow : .orange
                piece.font = .system(size: 12.5, design: .monospaced).bold()
            }
            attributed += piece
        }
        return Text(attributed)
    }
}
