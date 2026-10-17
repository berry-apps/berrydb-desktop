import Foundation

/// Thrown by `within(_:_:)` when its body has not answered in time.
struct DeadlinePassed: Error, CustomStringConvertible {
    let limit: Duration
    var description: String { "no answer within \(limit)" }
}

/// `body`'s result, or `DeadlinePassed` once `limit` passes, so a driver
/// call that never returns fails its test instead of stalling the suite.
/// `body` runs in a task of its own: a call that is never answered need not
/// end when its task is cancelled, and a task group would wait for it.
public func within<T: Sendable>(
    _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let answer = FirstAnswer<T>()
    return try await withCheckedThrowingContinuation { continuation in
        answer.wait(with: continuation)
        Task {
            do { answer.give(.success(try await body())) } catch { answer.give(.failure(error)) }
        }
        Task {
            // Task.sleep(nanoseconds:), not Task.sleep(for:), for the
            // release-build crash `DriverConformance.checkCancel` cites
            // (swiftlang/swift#86204, #84793).
            let (seconds, attoseconds) = limit.components
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000))
            answer.give(.failure(DeadlinePassed(limit: limit)))
        }
    }
}

/// Resumes its continuation with the first answer it is given.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var answer: Result<T, Error>?

    func wait(with continuation: CheckedContinuation<T, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func give(_ result: Result<T, Error>) {
        let waiting: CheckedContinuation<T, Error>? = lock.withLock {
            guard answer == nil else { return nil }
            answer = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }
}
