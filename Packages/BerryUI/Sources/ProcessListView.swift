import BerryCore
import BerryDriverKit
import SwiftUI

/// Server process/activity list (TI-01): the running sessions on the server,
/// with a per-row Kill action. Columns are normalized by the dialect to
/// pid/user/db/state/query/seconds. Read-only otherwise; every statement still
/// goes through the single SQL path (N1).
struct ProcessListView: View {
    let buffer: ResultBuffer
    let onReload: () -> Void
    let onKill: (String) async -> String?

    /// Close this tool tab (docs/ui/02 §4).
    let onClose: () -> Void
    @State private var killError: String?
    @State private var killingPID: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let killError {
                Divider()
                Label(killError, systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .padding(8)
            }
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: onReload)
    }

    private var header: some View {
        HStack {
            Image(systemName: "cpu")
            Text(L("Processes")).font(.headline)
            Spacer()
            Button {
                killError = nil
                onReload()
            } label: {
                Label(L("Reload"), systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if buffer.rowCount == 0 {
            ContentUnavailableView(
                L("No active processes"),
                systemImage: "cpu",
                description: Text(L("Running server sessions appear here"))
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    columnHeader
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        processRow(row)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            cell(L("PID"), width: 70).fontWeight(.semibold)
            cell(L("User"), width: 90).fontWeight(.semibold)
            cell(L("DB"), width: 90).fontWeight(.semibold)
            cell(L("State"), width: 90).fontWeight(.semibold)
            Text(L("Query")).fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
            cell(L("Sec"), width: 44).fontWeight(.semibold)
            Text(verbatim: "").frame(width: 52)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 5)
    }

    private func processRow(_ row: ProcessRow) -> some View {
        HStack(spacing: 8) {
            cell(row.pid, width: 70).font(.system(.caption, design: .monospaced))
            cell(row.user, width: 90)
            cell(row.db, width: 90)
            cell(row.state, width: 90)
            Text(row.query)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.query)
            cell(row.seconds, width: 44).font(.system(.caption, design: .monospaced))
            Button(role: .destructive) {
                guard killingPID == nil else { return }
                killingPID = row.pid
                Task {
                    killError = await onKill(row.pid)
                    killingPID = nil
                    if killError == nil { onReload() }
                }
            } label: {
                if killingPID == row.pid {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(L("Kill"))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .frame(width: 52)
            .disabled(!PIDValidator.isValid(row.pid) || killingPID != nil)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }

    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).lineLimit(1).frame(width: width, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text(L("\(buffer.rowCount) processes")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("Close")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(10)
    }

    // MARK: - Row extraction

    private struct ProcessRow {
        var pid = ""
        var user = ""
        var db = ""
        var state = ""
        var query = ""
        var seconds = ""
    }

    private var rows: [ProcessRow] {
        let index = columnIndexes
        return buffer.rows.map { values in
            func value(_ i: Int?) -> String {
                guard let i, i < values.count else { return "" }
                return values[i].displayString ?? ""
            }
            return ProcessRow(
                pid: value(index.pid), user: value(index.user), db: value(index.db),
                state: value(index.state), query: value(index.query), seconds: value(index.seconds)
            )
        }
    }

    private var columnIndexes: (pid: Int?, user: Int?, db: Int?, state: Int?, query: Int?, seconds: Int?) {
        func find(_ name: String) -> Int? {
            buffer.columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        return (find("pid"), find("user"), find("db"), find("state"), find("query"), find("seconds"))
    }
}

/// Local numeric-id guard mirroring `SQLDialect.isValidSessionID` so the view
/// can disable Kill for non-numeric pids without importing a concrete driver.
private enum PIDValidator {
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber)
    }
}
