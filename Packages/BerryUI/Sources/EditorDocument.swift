import BerryCore
import BerryDriverKit
import Foundation
import Observation

/// Result of one statement inside an editor run (ED-05: one result tab per
/// statement).
@MainActor
public struct EditorResult: Identifiable {
    public let id = UUID()
    public let sql: String
    public let buffer: ResultBuffer
    /// In-place editing over this result when it maps to a single table
    /// (docs/ui/01 D4a); stays read-only otherwise.
    let editing = ResultEditState()

    /// Short label for the result tab.
    public var label: String {
        let flat = sql.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
    }
}

/// One SQL editor tab (ED-01): document text + its result sets.
@MainActor
@Observable
public final class EditorDocument: Identifiable {
    public let id: UUID
    public var title: String
    public var text: String = ""
    public private(set) var results: [EditorResult] = []
    public var selectedResultID: EditorResult.ID?
    public private(set) var isRunning = false
    /// UTF-16 cursor location, kept in sync by the editor view (⌘↩ target).
    public var cursorLocation: Int = 0
    /// Current selection, kept in sync by the editor view. Drives the Navicat
    /// exec rule: a non-empty selection runs only the highlighted SQL, an empty
    /// one runs the whole editor (docs/ui).
    public var selectedRange = NSRange(location: 0, length: 0)
    /// One-shot format trigger (ED-08). Bumping it asks the editor view to
    /// pretty-print in place — the view owns the caret/selection, so formatting
    /// there keeps the cursor where it was instead of resetting it.
    public var formatRequestID: Int = 0
    /// One-shot ⌘/ trigger (docs/ui): the editor view toggles line comments on
    /// the current selection when this changes.
    public var commentToggleRequestID: Int = 0
    /// One-shot request for this editor to take keyboard focus (docs/ui/03) —
    /// set when a new tab/split opens so the caret lands in the right pane.
    public var pendingFocus = false
    /// One-shot (ED-07): when set alongside `pendingFocus`, the editor selects
    /// this range instead of just placing the caret — used to pre-select a
    /// saved-query snippet's placeholder so typing replaces it immediately.
    public var pendingSelection: NSRange?
    /// The saved query this editor is a view of (docs/ui): opening a saved
    /// query links the tab, ⌘S then updates that same record, and re-opening
    /// focuses this tab instead of spawning a copy.
    public var savedQueryID: UUID?
    /// The artifact this editor is a view of (AI-29, docs/draft/09.md) —
    /// mirrors `savedQueryID`: opening an artifact links the tab and
    /// re-opening focuses it instead of spawning a copy.
    public var artifactID: UUID?
    /// Automatic row cap for SELECTs (ED-12). `nil` = no cap; the user can
    /// change or disable it per editor from the run bar.
    public var autoLimit: Int? = QueryService.defaultAutoLimit
    /// Column cache for completion (ED-03), warmed from SchemaCatalog for the
    /// tables referenced in the document.
    public var columnsByTable: [String: [String]] = [:]

    public var initialText: String
    public var isDirty: Bool { text != initialText }

    /// `id` is stable across restarts — it doubles as the persistence key
    /// for editor session restore (UD-05).
    public init(id: UUID = UUID(), title: String, text: String = "") {
        self.id = id
        self.title = title
        self.text = text
        self.initialText = text
    }

    public enum RunMode {
        /// Statement under the cursor, or the selection when one exists.
        case current(selection: NSRange?)
        case all
    }

    /// Executes through the single SQL path (N1) — auto-LIMIT, DangerGuard,
    /// and history come for free. Statements run sequentially; the run stops
    /// at the first failure (matching every serious SQL tool).
    public func run(_ mode: RunMode, on session: Session, onCompleted: (() -> Void)? = nil) {
        runStatements(statements(for: mode), on: session, autoLimit: autoLimit, onCompleted: onCompleted)
    }

    /// EXPLAIN for the statement at the cursor (ED-09) — plan rows land in a
    /// normal result tab; the tree renderer arrives with the V1.5 Query
    /// Analyzer (docs/architecture/11 §7).
    public func explain(on session: Session, analyze: Bool = false) {
        guard let statement = statements(for: .current(selection: nil)).first else { return }
        let prefix = session.dialect.explainPrefix(analyze: analyze)
        runStatements(["\(prefix) \(statement)"], on: session, autoLimit: nil)
    }

    private func runStatements(_ statements: [String], on session: Session, autoLimit: Int? = QueryService.defaultAutoLimit, onCompleted: (() -> Void)? = nil) {
        guard !isRunning, !statements.isEmpty else { return }

        isRunning = true
        results = []
        selectedResultID = nil

        Task { [weak self] in
            guard let self else { return }

            // One summary confirmation for the whole run (docs/ui): count the
            // data-destroying statements up front; 100 DELETEs ask once, not 100
            // times. Production rules (07 §6) still confirm per statement.
            var preconfirmed = false
            if QueryService.confirmsDataDeletion, !session.isProduction {
                let destructive = statements.filter {
                    if case .confirm(let reason) = DangerGuard.classify($0, isProduction: false),
                       reason.isSoftDataDeletion { return true }
                    return false
                }
                if !destructive.isEmpty {
                    let approved = await QueryService.dangerConfirmer?.confirm(
                        .confirm(.deleteBatch(count: destructive.count)),
                        sql: destructive.prefix(5).joined(separator: "\n")
                            + (destructive.count > 5 ? "\n…" : "")
                    ) ?? true
                    guard approved else {
                        self.isRunning = false
                        return
                    }
                    preconfirmed = true
                }
            }

            for statement in statements {
                let buffer = ResultBuffer()
                let result = EditorResult(sql: statement, buffer: buffer)
                self.results.append(result)
                if self.selectedResultID == nil {
                    self.selectedResultID = result.id
                }
                buffer.consume(QueryService.execute(
                    statement, on: session, autoLimit: autoLimit,
                    dangerPreconfirmed: preconfirmed
                ))
                await buffer.waitUntilFinished()
                self.selectedResultID = result.id
                if case .failed = buffer.state { break }
                if buffer.state == .cancelled { break }
            }
            self.isRunning = false
            onCompleted?()
        }
    }

    public func cancel(session: Session?) {
        session?.connection.cancelCurrentQuery()
        results.last?.buffer.cancel()
    }

    /// Populates this tab with previously-captured result snapshots (AI-31,
    /// docs/draft/09.md) — reopening an artifact whose latest version has a
    /// `resultSnapshotJSON` shows "what did the agent actually get back"
    /// through the same result grid a live run would (ED-05: one tab per
    /// statement), instead of nothing. Values are display strings only (the
    /// original typed `BerryValue`s aren't preserved past the AI tool's own
    /// bounded sample), so every value renders as `.text`/`.null`.
    public func loadSnapshotResults(_ snapshots: [(sql: String, columns: [String], rows: [[String?]])]) {
        guard !snapshots.isEmpty else { return }
        let newResults = snapshots.map { snapshot -> EditorResult in
            let buffer = ResultBuffer()
            let metas = snapshot.columns.map { ColumnMeta(name: $0, declaredType: "") }
            let values: [[BerryValue]] = snapshot.rows.map { row in row.map { $0.map(BerryValue.text) ?? .null } }
            buffer.consume(AsyncThrowingStream { continuation in
                continuation.yield(.columns(metas))
                continuation.yield(.rows(values))
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            })
            return EditorResult(sql: snapshot.sql, buffer: buffer)
        }
        results = newResults
        selectedResultID = newResults.last?.id
    }

    /// Internal (not private) so WorkspaceViewModel can reuse this exact
    /// selection/cursor logic for the AI run_tab_statements tool (docs/agents/architecture/09 §3.2).
    func statements(for mode: RunMode) -> [String] {
        switch mode {
        case .all:
            return StatementSplitter.split(text).map(\.sql)
        case .current(let selection):
            if let selection, selection.length > 0 {
                let selected = (text as NSString).substring(with: selection)
                return StatementSplitter.split(selected).map(\.sql)
            }
            if let statement = StatementSplitter.statement(at: cursorLocation, in: text) {
                return [statement.sql]
            }
            return []
        }
    }
}
