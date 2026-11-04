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

/// Returns once `condition` holds, polling it, or throws `DeadlineExceeded`
/// after 60 s, so a regression fails the test instead of hanging it. The
/// limit is checked in the loop itself, so a failed wait stops polling
/// rather than running on for the rest of the test process.
func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while await !condition() {
        guard ContinuousClock.now < deadline else { throw DeadlineExceeded() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
