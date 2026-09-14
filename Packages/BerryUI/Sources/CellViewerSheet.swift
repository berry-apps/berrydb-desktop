import AppKit
import BerryCore
import BerryDriverKit
import SwiftUI

/// Cell viewer/editor: large text, pretty JSON, hex, and image tabs.
/// Editing (when allowed) stages through the same ChangeSet path as inline
/// edits — nothing bypasses the SQL preview (06).
struct CellViewerSheet: View {
    enum Tab: Hashable {
        case text
        case json
        case hex
        case image
    }

    let value: BerryValue
    let columnName: String
    let editable: Bool
    let onSave: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .text
    @State private var text: String = ""

    private var availableTabs: [Tab] {
        switch value {
        case .bytes(let data):
            var tabs: [Tab] = [.hex]
            if NSImage(data: data) != nil { tabs.append(.image) }
            return tabs
        case .json:
            return [.text, .json]
        default:
            var tabs: [Tab] = [.text]
            if case .text(let s) = value, HexDump.prettyJSON(s) != nil {
                tabs.append(.json)
            }
            return tabs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(columnName)
                    .font(.headline)
                Spacer()
                if availableTabs.count > 1 {
                    Picker("", selection: $tab) {
                        ForEach(availableTabs, id: \.self) { tab in
                            Text(title(for: tab)).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: CGFloat(availableTabs.count) * 90)
                }
            }
            .padding(10)
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if case .bytes(let data) = value {
                    Text(verbatim: ByteCountFormatter.string(
                        fromByteCount: Int64(data.count), countStyle: .binary
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if editable, onSave != nil {
                    Button(L("Stage Change")) {
                        onSave?(text)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(tab != .text)
                }
            }
            .padding(10)
        }
        .frame(width: 680, height: 480)
        .onAppear {
            text = value.displayString ?? ""
            tab = availableTabs.first ?? .text
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .text:
            if editable {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
            } else {
                scrollableMonospaced(text)
            }
        case .json:
            scrollableMonospaced(HexDump.prettyJSON(text) ?? text)
        case .hex:
            if case .bytes(let data) = value {
                scrollableMonospaced(HexDump.format(data))
            }
        case .image:
            if case .bytes(let data) = value, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
        }
    }

    private func scrollableMonospaced(_ content: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .text: L("Text")
        case .json: L("JSON")
        case .hex: L("Hex")
        case .image: L("Image")
        }
    }
}
