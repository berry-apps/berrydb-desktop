import Synchronization

/// Thrown by `withDeadline` when its body did not finish in time.
struct DeadlineExceeded: Error {}

/// Returns the result of `body`, or throws `DeadlineExceeded` once `duration`
/// has passed. A task group cannot give this bound: it waits for every child
/// before returning, and a child suspended on a continuation that ignores
/// cancellation, as a pending MCP request does, never finishes. On timeout the
/// body keeps running; the caller tears down whatever it waits on.
func withDeadline<T: Sendable>(
    _ duration: Duration, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = ResumeOnce(continuation)
        let timer = Task {
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            once.resume(with: .failure(DeadlineExceeded()))
        }
        Task {
            do {
                once.resume(with: .success(try await body()))
            } catch {
                once.resume(with: .failure(error))
            }
            timer.cancel()
        }
    }
}

/// Resumes a continuation for the first result only; later results are dropped.
private final class ResumeOnce<T: Sendable>: Sendable {
    private let pending: Mutex<CheckedContinuation<T, Error>?>

    init(_ continuation: CheckedContinuation<T, Error>) {
        pending = Mutex(continuation)
    }

    func resume(with result: Result<T, Error>) {
        let continuation = pending.withLock { slot in
            let taken = slot
            slot = nil
            return taken
        }
        continuation?.resume(with: result)
    }
}
