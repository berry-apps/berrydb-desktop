import AppKit
import SwiftUI

/// Prominent, copyable error panel shown when a statement/query fails
/// (docs/ui/02 §2). Shared by the SQL editor and the Mongo shell tab
/// (docs/feedback/01.md item 2 — NoSQL previously only had a one-line status
/// bar message, easy to miss).
struct QueryErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
            Text(L("Query failed")).font(.headline)
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .frame(maxHeight: 160)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Label(L("Copy error"), systemImage: "doc.on.doc")
            }
            .buttonStyle(.compact)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
