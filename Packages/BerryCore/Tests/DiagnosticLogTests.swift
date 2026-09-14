import Foundation
import Testing

@testable import BerryCore

/// `DiagnosticLog` exists because `NSLog`-per-event is unusable for the AI
/// streaming path: one turn emitted 681 `tool.arg_delta` plus 191 `reasoning`
/// lines, which floods the terminal and cannot be copied
/// out of it. Two requirements follow — write to a file, and coalesce repeated
/// events into one counted line instead of printing each.
@Suite("DiagnosticLog (file sink + event coalescing)")
struct DiagnosticLogTests {
    private func makeLog() -> (DiagnosticLog, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-diag-\(UUID().uuidString).log")
        return (DiagnosticLog(fileURL: url), url)
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func writesADiscreteEventToTheFile() throws {
        let (log, url) = makeLog()
        log.event("stream open", detail: "thread=abc")
        log.flush()

        let text = try contents(url)
        #expect(text.contains("stream open"))
        #expect(text.contains("thread=abc"))
    }

    /// The core requirement: N identical repeats collapse to ONE line carrying
    /// the count, not N lines.
    @Test func coalescesRepeatsOfTheSameKindIntoOneCountedLine() throws {
        let (log, url) = makeLog()
        for _ in 0..<681 { log.tick("tool.arg_delta") }
        log.flush()

        let text = try contents(url)
        let lines = text.split(separator: "\n").filter { $0.contains("tool.arg_delta") }
        #expect(lines.count == 1, "681 ticks must produce one line, got \(lines.count)")
        #expect(text.contains("681"))
    }

    /// The real event stream interleaves kinds — producer and consumer tick the
    /// same event alternately, token by token. A single shared "current run"
    /// closes on every switch, so 191 interleaved reasoning events produced
    /// thousands of `x1`/`x6` lines and a 328KB file instead of two lines.
    /// Counts must therefore accumulate PER KIND, not per contiguous run.
    @Test func coalescesPerKindEvenWhenKindsInterleave() throws {
        let (log, url) = makeLog()
        for _ in 0..<191 {
            log.tick("producer: reasoning")
            log.tick("consumer: reasoning")
        }
        log.flush()

        let text = try contents(url)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2, "two kinds must yield two lines, got \(lines.count)")
        #expect(text.contains("producer: reasoning x191"))
        #expect(text.contains("consumer: reasoning x191"))
    }

    /// A run of one kind must be closed off and reported when a different kind
    /// arrives, so ordering between groups survives.
    @Test func flushesTheRunningCountWhenTheKindChanges() throws {
        let (log, url) = makeLog()
        for _ in 0..<3 { log.tick("reasoning") }
        for _ in 0..<2 { log.tick("tool.arg_delta") }
        log.flush()

        let text = try contents(url)
        let reasoning = text.range(of: "reasoning")
        let argDelta = text.range(of: "tool.arg_delta")
        #expect(reasoning != nil)
        #expect(argDelta != nil)
        if let reasoning, let argDelta {
            #expect(reasoning.lowerBound < argDelta.lowerBound, "groups keep their order")
        }
        #expect(text.contains("3"))
        #expect(text.contains("2"))
    }

    /// A discrete `event` must also close a pending run — otherwise a tick
    /// group would be reported after events that actually came later.
    @Test func aDiscreteEventClosesAPendingTickRun() throws {
        let (log, url) = makeLog()
        log.tick("reasoning")
        log.tick("reasoning")
        log.event("message.complete")
        log.flush()

        let text = try contents(url)
        guard let ticks = text.range(of: "reasoning"),
              let complete = text.range(of: "message.complete")
        else { Issue.record("both entries expected"); return }
        #expect(ticks.lowerBound < complete.lowerBound)
    }

    @Test func recordsElapsedTimeForACoalescedRun() throws {
        let (log, url) = makeLog()
        log.tick("reasoning")
        log.tick("reasoning")
        log.flush()

        // The run's line reports how long the burst spanned, which is what
        // makes a widening producer/consumer gap visible at all.
        #expect(try contents(url).contains("ms"))
    }

    /// `DiagnosticLog.default` must route to the test-only sink under
    /// `swift test`, never the production `berrydb-diagnostics.log` a real
    /// user's report gets read from. Caught live: this repo's Swift Testing
    /// suite (`@Test`, not XCTest) runs inside SPM's `swiftpm-testing-helper`
    /// process, which sets neither `XCTestConfigurationFilePath` nor
    /// `SWIFT_TESTING_ENABLED` and never loads `XCTest.framework` at all — so
    /// `isRunningTests`'s original three checks all missed it, and every
    /// `swift test` run was silently appending real turn/error data into the
    /// exact file a live bug report gets diagnosed from. This test is
    /// self-verifying: it runs IN that same `swiftpm-testing-helper` process,
    /// so it only passes if the detection genuinely covers this project's
    /// actual test runner, not a mock of it.
    @Test func defaultSinkIsTheTestOnlyFileUnderSwiftTesting() {
        #expect(
            DiagnosticLog.default.fileURL.lastPathComponent == "berrydb-diagnostics-tests.log",
            "a swift-testing run must never write to the production diagnostics file"
        )
    }
}
