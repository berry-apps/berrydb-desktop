import AppKit
import BerryDriverKit
import SwiftUI

/// Read-only DDL viewer: the CREATE statement for a table/view, from
/// the driver introspector. Selectable + copyable.
struct DDLSheet: View {
    let object: SchemaObject
    let load: () async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var ddl: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.secondary)
                Text(object.name).font(.headline)
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(ddl == nil)
                .help(L("Copy"))
                .accessibilityLabel(L("Copy"))
                Button(L("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            content
        }
        .frame(width: 640, height: 460)
        .task {
            ddl = await load()
            loading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(ddl ?? L("Schema not available"))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private func copy() {
        guard let ddl else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ddl, forType: .string)
    }
}
