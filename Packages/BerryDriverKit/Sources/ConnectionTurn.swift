import Foundation

/// A connection's turn, taken by one statement or transaction at a time in
/// the order they asked. A connection carries one conversation with the
/// server, so a statement sent while another statement's transaction is open
/// runs inside that transaction, and that transaction's COMMIT ends both.
public final class ConnectionTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Returns once the turn is the caller's; the caller gives it back with
    /// `give()`.
    public func take() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let free = lock.withLock {
                if taken {
                    waiters.append(continuation)
                    return false
                }
                taken = true
                return true
            }
            if free { continuation.resume() }
        }
    }

    /// Hands the turn straight to the next waiter, so nothing can slip in
    /// between.
    public func give() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                taken = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// Whether a read-only statement holds its connection's turn, shared with
/// its stream's termination handler, which runs outside the connection's
/// actor. A server cancels by connection, whatever statement runs there
/// (https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL,
/// https://dev.mysql.com/doc/refman/8.4/en/kill.html), so a statement whose
/// stream is cancelled while it waits for the turn sends no cancel, which
/// would end the statement ahead of it, and passes the turn on without
/// running once the turn reaches it. Deciding both sides under one lock
/// means a cancel landing at the hand-off either stops the statement or is
/// sent for it, never neither.
public final class ReadOnlyTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var held = false

    public init() {}

    /// Marks the statement as running once it has the turn; false when its
    /// stream was cancelled while it waited, and it must not run.
    public func begin() -> Bool {
        lock.withLock {
            held = !cancelled
            return held
        }
    }

    public func end() {
        lock.withLock { held = false }
    }

    /// Marks the stream cancelled; true when the statement holds the turn,
    /// so a cancel sent to the server reaches it.
    public func cancel() -> Bool {
        lock.withLock {
            cancelled = true
            return held
        }
    }
}
