import Foundation
import Synchronization

/// Returns the result of `operation`, or throws `MCPLiveReadError.timedOut`
/// once `limit` has passed, cancelling the operation then. A task group
/// cannot give this bound: it waits for every child, and a connection that
/// never opens (an SSH channel that never comes up) ignores cancellation.
/// The operation is left to unwind on its own; the coordinator closes what
/// it opened when it does, or at shutdown. Cancelling the caller throws
/// `CancellationError` at once, for the same reason.
enum MCPRequestDeadline {
    /// Raised by an operation once its connection is open, which ends the
    /// opening limit of `run(_:opening:_:)`.
    final class Opening: Sendable {
        private let limit = Mutex<Duration?>(nil)

        /// Ends the opening limit. An expiry after this reports
        /// `statementLimit`, the time the statement itself had, rather than
        /// the whole request's limit, which includes the open budget.
        func opened(statementLimit: Duration) {
            limit.withLock { $0 = statementLimit }
        }

        fileprivate var statementLimit: Duration? {
            limit.withLock { $0 }
        }
    }

    static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run(limit, opening: limit) { _ in try await operation() }
    }

    /// As `run(_:_:)`, and also throws `timedOut` once `openLimit` has passed
    /// unless the operation called `Opening.opened(statementLimit:)` by
    /// then. A connection that never opens therefore fails after the open
    /// budget, not after the whole request's limit.
    static func run<T: Sendable>(
        _ limit: Duration, opening openLimit: Duration,
        _ operation: @escaping @Sendable (Opening) async throws -> T
    ) async throws -> T {
        let opening = Opening()
        let work = Task { try await operation(opening) }
        // Created before the cancellation handler, which can run before the
        // continuation exists when the caller is already cancelled.
        let once = Once<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard once.install(continuation) else { return }
                let expire: @Sendable (Duration) -> Void = { reported in
                    if once.resume(with: .failure(MCPLiveReadError.timedOut(seconds: wholeSeconds(reported)))) {
                        work.cancel()
                    }
                }
                let timer = Task {
                    do {
                        if openLimit < limit {
                            try await Task.sleep(for: openLimit)
                            guard let statementLimit = opening.statementLimit else {
                                expire(openLimit)
                                return
                            }
                            try await Task.sleep(for: limit - openLimit)
                            expire(statementLimit)
                        } else {
                            try await Task.sleep(for: limit)
                            expire(limit)
                        }
                    } catch {
                        return
                    }
                }
                Task {
                    do {
                        once.resume(with: .success(try await work.value))
                    } catch {
                        once.resume(with: .failure(error))
                    }
                    timer.cancel()
                }
            }
        } onCancel: {
            work.cancel()
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// Whole seconds, rounded up, so a sub-second limit never reads as 0.
    static func wholeSeconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(1, Int(seconds) + (attoseconds > 0 ? 1 : 0))
    }

    /// Delivers the first result only. A result that arrives before the
    /// continuation is installed is kept and delivered on installation.
    private final class Once<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, Error>?
            var early: Result<T, Error>?
            var settled = false
        }

        private let state = Mutex(State())

        /// False when a result arrived first; the continuation is then
        /// already resumed with it.
        func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
            let early: Result<T, Error>? = state.withLock { state in
                guard let early = state.early else {
                    state.continuation = continuation
                    return nil
                }
                state.early = nil
                return early
            }
            guard let early else { return true }
            continuation.resume(with: early)
            return false
        }

        /// True for the first result only.
        @discardableResult
        func resume(with result: Result<T, Error>) -> Bool {
            let (first, continuation): (Bool, CheckedContinuation<T, Error>?) = state.withLock { state in
                guard !state.settled else { return (false, nil) }
                state.settled = true
                guard let continuation = state.continuation else {
                    state.early = result
                    return (true, nil)
                }
                state.continuation = nil
                return (true, continuation)
            }
            continuation?.resume(with: result)
            return first
        }
    }
}
