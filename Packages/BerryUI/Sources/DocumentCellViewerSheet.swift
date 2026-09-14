import BerryDataSourceKit
import Foundation
import SwiftUI

/// Whole-document viewer/editor (sibling)
/// pretty-printed JSON. Editing is document-granularity, not per-field:
/// Mongo's update wraps the WHOLE patch in `$set`, Qdrant's needs
/// vector+payload together, so there is no meaningful "edit one field
/// inline" the way SQL cells support (`CellViewerSheet`). Saving stages
/// nothing locally — `onSave` routes straight into
/// `WorkspaceViewModel.applyDataSourceWrite`, which still shows the
/// native-command preview/confirm before anything is sent.
struct DocumentCellViewerSheet: View {
    let title: String
    let document: BerryDocument
    let editable: Bool
    let onSave: ((BerryDocument) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var parseError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(10)
            Divider()

            if editable {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }

            Divider()
            VStack(alignment: .trailing, spacing: 4) {
                if let parseError {
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button(L("Close")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if editable, onSave != nil {
                        Button(L("Stage Change")) {
                            guard let parsed = Self.parse(text) else {
                                parseError = L("Invalid JSON")
                                return
                            }
                            onSave?(parsed)
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 680, height: 480)
        .onAppear {
            text = Self.prettyPrint(document)
        }
    }

    static func prettyPrint(_ document: BerryDocument) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: document.jsonObject, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
        ), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func parse(_ text: String) -> BerryDocument? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return BerryDocument(jsonObject: json)
    }
}
