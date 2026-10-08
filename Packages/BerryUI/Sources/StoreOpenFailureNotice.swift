import BerryStore
import Foundation
import SwiftUI

/// What the main window says when the local store does not open at launch.
/// The app then runs without saved connections, so the reason has to read
/// as a sentence. The underlying error of a failed upgrade is an SQLite
/// message quoting the SQL that failed: needed in a bug report, meaningless
/// as the only visible text, so it is kept as details shown on request.
struct StoreOpenFailureMessage: Equatable {
    let headline: String
    let details: String

    init(_ error: any Error) {
        if case let .migrationFailed(identifier, reason) = error as? BerryStore.OpenError {
            headline = L("BerryDB could not open its data store. Upgrade step “\(identifier)” failed and changed no data.")
            details = reason
        } else {
            headline = L("BerryDB could not open its data store.")
            details = error.localizedDescription
        }
    }
}

/// The sidebar's notice for a store that did not open: the headline, and a
/// popover with the details as selectable text plus a copy button, the same
/// shape the AI panel uses to inspect a tool payload.
struct StoreOpenFailureNotice: View {
    let message: StoreOpenFailureMessage
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.headline)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Details…")) { showsDetails = true }
                .buttonStyle(.link)
                .font(.caption2)
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    details
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(message.headline)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                CopyButton(text: message.details, help: L("Copy error"))
            }
            ScrollView {
                Text(message.details)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 420, height: 220)
    }
}
