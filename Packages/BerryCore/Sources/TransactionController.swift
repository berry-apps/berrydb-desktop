import BerryDriverKit
import Foundation
import Observation

/// Manual transaction control for the SQL editor (ED-11) — docs/architecture/06 · L2.
///
/// State is connection-scoped: the workspace shares one physical connection,
/// so a transaction opened here spans every editor tab on that session. When
/// `autoCommit` is off, the editor calls `beginIfNeeded` before running, and
/// the user ends the transaction with Commit or Rollback. BEGIN/COMMIT/ROLLBACK
/// go through the single SQL path (N1), so history still records them.
///
/// Scope note: the grid's inline-edit apply (L3) wraps its own transaction and
/// is meant to be used with autoCommit on; nesting is not attempted here.
@MainActor
@Observable
public final class TransactionController {
    /// A manual transaction is currently open on the connection.
    public private(set) var isActive = false
    /// When false, the editor opens a transaction before the next run and
    /// holds it until the user commits or rolls back.
    public var autoCommit = true
    /// Last BEGIN/COMMIT/ROLLBACK failure, surfaced by the editor toolbar.
    public private(set) var lastError: String?

    public init() {}

    /// Opens a transaction if manual mode is on and none is open yet.
    /// Returns true when it is safe to proceed with the run.
    @discardableResult
    public func beginIfNeeded(session: Session) async -> Bool {
        guard !autoCommit, !isActive else { return true }
        return await run("BEGIN", session: session, activeAfter: true)
    }

    @discardableResult
    public func begin(session: Session) async -> Bool {
        await run("BEGIN", session: session, activeAfter: true)
    }

    @discardableResult
    public func commit(session: Session) async -> Bool {
        guard isActive else { return true }
        return await run("COMMIT", session: session, activeAfter: false)
    }

    @discardableResult
    public func rollback(session: Session) async -> Bool {
        guard isActive else { return true }
        return await run("ROLLBACK", session: session, activeAfter: false)
    }

    /// Turning auto-commit back ON while a transaction is open commits it,
    /// matching what every SQL client does on mode switch.
    public func setAutoCommit(_ on: Bool, session: Session) async {
        autoCommit = on
        if on, isActive {
            _ = await commit(session: session)
        }
    }

    private func run(_ sql: String, session: Session, activeAfter: Bool) async -> Bool {
        let buffer = ResultBuffer()
        buffer.consume(QueryService.execute(sql, on: session, autoLimit: nil))
        await buffer.waitUntilFinished()
        if case .failed(let message) = buffer.state {
            lastError = message
            return false
        }
        lastError = nil
        isActive = activeAfter
        return true
    }
}
