import Foundation
import Synchronization

/// A `berrydb-mcp` subprocess driven over its standard streams.
///
/// Nothing here blocks a thread while waiting. Pipe output arrives through
/// `readabilityHandler` callbacks rather than blocking reads; process exit
/// arrives through `terminationHandler`; every wait is an awaited
/// continuation bounded by a `Task.sleep` deadline, so a helper that never
/// answers fails the test instead of hanging the suite.
///
/// Unchecked `Sendable`: the process and the stdin handle are configured in
/// `init` and afterwards only signalled, written or closed.
final class HelperProcess: @unchecked Sendable {
    enum HarnessError: Error, CustomStringConvertible {
        case executableMissing([String])
        case timeout(String)
        case outputClosed(String)
        case exited(String)

        var description: String {
            switch self {
            case let .executableMissing(paths):
                return "berrydb-mcp is not built; looked at \(paths.joined(separator: ", ")). "
                    + "Run `swift build --product berrydb-mcp` first."
            case let .timeout(operation):
                return "Timed out waiting for \(operation)"
            case let .outputClosed(operation):
                return "The helper closed standard output before \(operation)"
            case let .exited(operation):
                return "The helper exited before \(operation)"
            }
        }
    }

    /// Bound on every wait. Generous because CI runners queue work heavily;
    /// it exists to turn a hang into a failure, not to measure latency.
    static let timeout: Duration = .seconds(30)

    let stdout = LineRecorder()
    let stderr = LineRecorder()
    private let process = Process()
    private let input: FileHandle
    private let exit = ExitWatch()

    init(arguments: [String], workingDirectory: URL) throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        input = stdinPipe.fileHandleForWriting
        // A write to the stdin of a helper that already exited would raise
        // SIGPIPE and kill the whole test runner; with F_SETNOSIGPIPE the
        // write fails with EPIPE instead, which `write(contentsOf:)` throws.
        // Documented in fcntl(2) on macOS.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)

        process.executableURL = try Self.executableURL()
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        Self.record(stdoutPipe.fileHandleForReading, into: stdout)
        Self.record(stderrPipe.fileHandleForReading, into: stderr)
        let exit = self.exit
        process.terminationHandler = { exit.record($0.terminationStatus, reason: $0.terminationReason) }
        try process.run()
    }

    /// Writes one JSON-RPC message followed by a newline.
    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(UInt8(ascii: "\n"))
        try input.write(contentsOf: data)
    }

    /// The first stdout message whose `id` is `id`.
    func response(id: Int) async throws -> [String: Any] {
        try await message("JSON-RPC response \(id)") { ($0["id"] as? Int) == id && $0["method"] == nil }
    }

    /// The first stdout message, already written or still to come, that
    /// `matches`; `operation` names it in a timeout error.
    func message(
        _ operation: String, where matches: @escaping @Sendable ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let line = try await Self.within(operation) { [stdout] in
            await stdout.first { line in
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    return false
                }
                return matches(object)
            }
        }
        guard let line else { throw HarnessError.outputClosed(operation) }
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HarnessError.outputClosed(operation)
        }
        return object
    }

    /// Closes the helper's standard input, which a host does to end a session.
    func closeInput() throws {
        try input.close()
    }

    /// Sends `signal` to the helper.
    func send(signal: Int32) {
        kill(process.processIdentifier, signal)
    }

    /// Returns once the helper ignores `signal`, which it does only after its
    /// handler for that signal is registered. Polls the kernel's view of the
    /// process with `Task.sleep` between reads, so no thread is blocked.
    func ignoring(_ signal: Int32) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.timeout)
        while !Self.ignores(signal, pid: process.processIdentifier) {
            if exit.hasExited { throw HarnessError.exited("ignoring signal \(signal)") }
            guard clock.now < deadline else { throw HarnessError.timeout("signal \(signal) to be ignored") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Whether process `pid` ignores `signal`, read from `p_sigignore` of its
    /// `kinfo_proc` (sysctl(3), `KERN_PROC_PID`).
    private static func ignores(_ signal: Int32, pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_sigignore & (1 << UInt32(signal - 1)) != 0
    }

    /// The helper's exit status and how it ended, once it has exited.
    func termination() async throws -> (status: Int32, reason: Process.TerminationReason) {
        try await Self.within("process exit") { [exit] in await exit.termination() }
    }

    /// Waits until both output pipes reached end of file, so `stdout` and
    /// `stderr` hold everything the helper wrote.
    func outputFinished() async throws {
        _ = try await Self.within("end of stdout") { [stdout] in await stdout.first { _ in false } }
        _ = try await Self.within("end of stderr") { [stderr] in await stderr.first { _ in false } }
    }

    /// Kills a helper that is still running. Called on every test exit path,
    /// so a failed test does not leave a process behind; SIGKILL because a
    /// broken signal handler is one of the things under test.
    func stop() {
        try? input.close()
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// The `berrydb-mcp` built with the test bundle, in the same build
    /// products directory. Only that location is used, so a binary left over
    /// from another configuration is never picked up. Observed with Swift
    /// 6.3: SwiftPM writes both products to `.build/<triple>/debug`, and
    /// `swift test` alone rebuilds a deleted `berrydb-mcp` before running the
    /// tests.
    private static func executableURL() throws -> URL {
        let executable = Bundle(for: HelperProcess.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("berrydb-mcp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw HarnessError.executableMissing([executable.path])
        }
        return executable
    }

    private static func record(_ handle: FileHandle, into recorder: LineRecorder) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                recorder.finish()
            } else {
                recorder.append(data)
            }
        }
    }

    /// The result of `body`, or `HarnessError.timeout` once `timeout` has
    /// passed. The body and the timer race to resume one continuation; a task
    /// group would instead wait for a body that never finishes. On timeout
    /// the body stays suspended until `stop()` closes the pipes it waits on.
    private static func within<T: Sendable>(
        _ operation: String, _ body: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                once.resume(with: .failure(HarnessError.timeout(operation)))
            }
            Task {
                once.resume(with: .success(await body()))
                timer.cancel()
            }
        }
    }
}

/// Newline-delimited output of one pipe, kept as raw lines so a test can
/// check that every line is well formed.
final class LineRecorder: Sendable {
    private struct Waiter {
        let matches: @Sendable (Data) -> Bool
        let continuation: CheckedContinuation<Data?, Never>
    }

    private struct State {
        var lines: [Data] = []
        var unterminated = Data()
        var finished = false
        var waiters: [Waiter] = []
    }

    private let state = Mutex(State())

    /// Complete lines, without their newline.
    var lines: [Data] {
        state.withLock { $0.lines }
    }

    /// Bytes after the last newline; non-empty only when the writer ended
    /// without terminating its last line.
    var unterminated: Data {
        state.withLock { $0.unterminated }
    }

    /// Everything recorded, decoded as UTF-8.
    var text: String {
        state.withLock { state in
            let joined = state.lines.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
            return joined + String(decoding: state.unterminated, as: UTF8.self)
        }
    }

    func append(_ chunk: Data) {
        let ready: [(CheckedContinuation<Data?, Never>, Data)] = state.withLock { state in
            state.unterminated.append(chunk)
            var ready: [(CheckedContinuation<Data?, Never>, Data)] = []
            while let newline = state.unterminated.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(state.unterminated[..<newline])
                state.unterminated = Data(state.unterminated[(newline + 1)...])
                state.lines.append(line)
                var waiting: [Waiter] = []
                for waiter in state.waiters {
                    if waiter.matches(line) {
                        ready.append((waiter.continuation, line))
                    } else {
                        waiting.append(waiter)
                    }
                }
                state.waiters = waiting
            }
            return ready
        }
        for (continuation, line) in ready {
            continuation.resume(returning: line)
        }
    }

    func finish() {
        let waiters = state.withLock { state in
            state.finished = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: nil)
        }
    }

    /// The first complete line, already recorded or still to come, that
    /// `matches`; nil once the pipe reached end of file without one.
    func first(where matches: @escaping @Sendable (Data) -> Bool) async -> Data? {
        await withCheckedContinuation { continuation in
            let immediate: Data?? = state.withLock { state in
                if let line = state.lines.first(where: matches) { return .some(line) }
                if state.finished { return .some(nil) }
                state.waiters.append(Waiter(matches: matches, continuation: continuation))
                return .none
            }
            if case let .some(line) = immediate {
                continuation.resume(returning: line)
            }
        }
    }
}

/// The termination of one process, delivered to any number of waiters.
private final class ExitWatch: Sendable {
    typealias Termination = (status: Int32, reason: Process.TerminationReason)

    private struct State {
        var termination: Termination?
        var waiters: [CheckedContinuation<Termination, Never>] = []
    }

    private let state = Mutex(State())

    var hasExited: Bool {
        state.withLock { $0.termination != nil }
    }

    func record(_ status: Int32, reason: Process.TerminationReason) {
        let waiters = state.withLock { state in
            state.termination = (status, reason)
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: (status, reason))
        }
    }

    func termination() async -> Termination {
        await withCheckedContinuation { continuation in
            let known = state.withLock { state in
                if let termination = state.termination { return termination as Termination? }
                state.waiters.append(continuation)
                return nil
            }
            if let known {
                continuation.resume(returning: known)
            }
        }
    }
}

/// Resumes a continuation with the first result only; later results are dropped.
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
