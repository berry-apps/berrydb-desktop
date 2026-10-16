import Foundation
import Synchronization

/// Returns the result of `operation`, or throws `MCPLiveReadError.timedOut`
/// once `limit` has passed, cancelling the operation then. A task group
/// cannot give this bound: it waits for every child, and a connection that
/// never opens (an SSH channel that never comes up) ignores cancellation.
/// The operation is left to unwind on its own; the coordinator closes what
/// it opened when it does, or at shutdown.
enum MCPRequestDeadline {
    /// Raised by an operation once its connection is open, which ends the
    /// opening limit of `run(_:opening:_:)`.
    final class Opening: Sendable {
        private let isOpen = Mutex(false)

        func opened() {
            isOpen.withLock { $0 = true }
        }

        fileprivate var hasOpened: Bool {
            isOpen.withLock { $0 }
        }
    }

    static func run<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await run(limit, opening: limit) { _ in try await operation() }
    }

    /// As `run(_:_:)`, and also throws `timedOut` once `openLimit` has passed
    /// unless the operation called `Opening.opened()` by then. A connection
    /// that never opens therefore fails after the open budget, not after the
    /// whole request's limit.
    static func run<T: Sendable>(
        _ limit: Duration, opening openLimit: Duration,
        _ operation: @escaping @Sendable (Opening) async throws -> T
    ) async throws -> T {
        let opening = Opening()
        let work = Task { try await operation(opening) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let once = Once(continuation)
                let timer = Task {
                    do {
                        if openLimit < limit {
                            try await Task.sleep(for: openLimit)
                            if !opening.hasOpened {
                                if once.resume(with: .failure(MCPLiveReadError.timedOut(seconds: wholeSeconds(openLimit)))) {
                                    work.cancel()
                                }
                                return
                            }
                            try await Task.sleep(for: limit - openLimit)
                        } else {
                            try await Task.sleep(for: limit)
                        }
                    } catch {
                        return
                    }
                    if once.resume(with: .failure(MCPLiveReadError.timedOut(seconds: wholeSeconds(limit)))) {
                        work.cancel()
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
        }
    }

    /// Whole seconds, rounded up, so a sub-second limit never reads as 0.
    static func wholeSeconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return max(1, Int(seconds) + (attoseconds > 0 ? 1 : 0))
    }

    private final class Once<T: Sendable>: Sendable {
        private let pending: Mutex<CheckedContinuation<T, Error>?>

        init(_ continuation: CheckedContinuation<T, Error>) {
            pending = Mutex(continuation)
        }

        /// True for the first result only.
        @discardableResult
        func resume(with result: Result<T, Error>) -> Bool {
            let continuation = pending.withLock { slot in
                let taken = slot
                slot = nil
                return taken
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
    }
}
