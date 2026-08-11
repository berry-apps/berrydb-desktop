import Foundation

/// A file-backed diagnostic log that coalesces high-frequency repeats.
///
/// The AI streaming path defeats `NSLog`-per-event: a single turn produced 681
/// `tool.arg_delta` and 191 `reasoning` events (docs/tests/crash.md). Printing
/// each one floods the terminal, buries the handful of lines that matter, and
/// leaves nothing that can practically be copied out for analysis. It also
/// costs real time on the MainActor in exactly the path being diagnosed, so the
/// instrument distorts what it measures.
///
/// So: `event` for the one-off boundaries worth a line each (stream open, tool
/// call, completion, error), and `tick` for anything per-token. A run of ticks
/// of the same kind becomes ONE line with a count and the span it covered —
/// which is also the number that matters, since a burst taking longer for the
/// same count is precisely how a client falling behind its producer shows up.
///
/// Writes are serialized on an internal queue and appended, so a caller on the
/// MainActor never blocks on file I/O.
public final class DiagnosticLog: @unchecked Sendable {
    /// Default sink. Fixed path (not per-launch) so a user can be pointed at
    /// one file without first asking which run it was.
    ///
    /// Tests write to a separate file. They share this process's temp directory,
    /// so a `swift test` run was overwriting the app log — which destroyed a real
    /// reproduction the user had just captured, twice.
    public static let `default` = DiagnosticLog(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(isRunningTests ? "berrydb-diagnostics-tests.log" : "berrydb-diagnostics.log")
    )

    /// True under `swift test`/XCTest. Checked via the injected test bundle
    /// rather than a compile flag, because this type ships in the app binary and
    /// has no test-only build configuration of its own.
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] != nil
            // `swift test`'s Swift Testing runner (`@Test`, not XCTest) hosts
            // tests in a separate `swiftpm-testing-helper` process that sets
            // none of the checks above — confirmed live: `NSClassFromString
            // ("XCTestCase")` is nil (XCTest.framework isn't even loaded,
            // this project uses only the Testing framework's macros) and
            // neither env var is set, so every `swift test` run was writing
            // into the production `berrydb-diagnostics.log` instead of
            // `berrydb-diagnostics-tests.log` — confirmed by watching the
            // production file's size grow after running a single test.
            // Caught live while a real bug report's log was contaminated
            // with an unrelated test run's turns/errors interleaved into it.
            || ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || CommandLine.arguments.contains("--testing-library")
    }

    public let fileURL: URL

    private let queue = DispatchQueue(label: "com.berrydb.diagnostic-log")
    private let formatter: DateFormatter
    /// Open run PER KIND, in first-seen order. Not a single "current run": the
    /// real stream interleaves kinds (producer and consumer tick the same event
    /// alternately, token by token), so closing on every switch produced
    /// thousands of `x1` lines — a 328KB file for one turn, the exact problem
    /// this type exists to prevent. Runs stay open until a discrete `event`
    /// marks a boundary, or `flush`.
    private var pending: [(kind: String, count: Int, started: Date, last: Date)] = []

    public init(fileURL: URL) {
        self.fileURL = fileURL
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    /// A one-off boundary worth its own line. Closes any pending tick run first
    /// so the file's ordering matches the order things actually happened.
    public func event(_ name: String, detail: String? = nil) {
        queue.async {
            self.closePendingRun()
            let suffix = detail.map { " \($0)" } ?? ""
            self.append("\(self.stamp()) \(name)\(suffix)")
        }
    }

    /// One occurrence of a high-frequency repeated event. Accumulates; nothing
    /// is written until the run ends.
    public func tick(_ kind: String) {
        queue.async {
            let now = Date()
            if let i = self.pending.firstIndex(where: { $0.kind == kind }) {
                self.pending[i].count += 1
                self.pending[i].last = now
                return
            }
            self.pending.append((kind: kind, count: 1, started: now, last: now))
        }
    }

    /// Writes out any pending run. Call at a turn boundary, or before reading
    /// the file.
    public func flush() {
        queue.sync { self.closePendingRun() }
    }

    /// Above this, `trimIfLarge` drops the oldest half. Sized to hold many
    /// coalesced turns (a turn is ~120 lines now) while staying pasteable.
    private static let maxBytes = 256 * 1024

    /// Writes a separator and drops the oldest half if the file has grown past
    /// `maxBytes`.
    ///
    /// Deliberately NOT a truncate-per-turn. That was the first design, and it
    /// destroyed the evidence it was meant to capture: anything the user did
    /// after a turn finished — clicking an artifact chip, for instance — was
    /// erased the moment they sent the next message. Cross-turn history also
    /// matters on its own, since slowdowns accumulate over a conversation.
    /// Trimming by size keeps recent turns and only ever discards the oldest.
    public func startSection(_ label: String) {
        queue.sync {
            self.closePendingRun()
            self.trimIfLarge()
            self.append("──── \(self.stamp()) \(label) ────")
        }
    }

    private func trimIfLarge() {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? Int,
            size > Self.maxBytes,
            let text = try? String(contentsOf: fileURL, encoding: .utf8)
        else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2)
        let rebuilt = "…older entries trimmed…\n" + kept.joined(separator: "\n")
        try? rebuilt.data(using: .utf8)?.write(to: fileURL)
    }

    // MARK: - Internals (all on `queue`)

    /// Writes every open run, oldest-first, then clears them. First-seen order
    /// is preserved so a producer run still reads before the consumer run it
    /// feeds.
    private func closePendingRun() {
        guard !pending.isEmpty else { return }
        let runs = pending
        pending = []
        for run in runs {
            let spanMS = Int(run.last.timeIntervalSince(run.started) * 1000)
            append("\(formatter.string(from: run.started)) \(run.kind) x\(run.count) over \(spanMS)ms")
        }
    }

    private func stamp() -> String {
        formatter.string(from: Date())
    }

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
