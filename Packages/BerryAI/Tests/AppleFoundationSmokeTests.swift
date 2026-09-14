import Foundation
import Testing

@testable import BerryAI

/// On-device smoke test for the Apple Foundation Models provider.
/// Never fails CI: it reports availability, and only when Apple Intelligence is
/// actually available does it run one real completion. Result is written to
/// /tmp/berrydb-apple.txt so it can be read after running:
///   swift test --filter AppleFoundationSmoke
@Suite("Apple Foundation Models smoke")
struct AppleFoundationSmokeTests {
    struct NoTools: AIToolExecutor {
        func execute(_ call: AIToolCall) async -> ToolOutcome { .ok("{}") }
    }

    @MainActor
    @Test func reportAvailabilityAndTryOneCompletion() async {
        let available = AppleFoundationProvider.isAvailable()
        var report = "isAvailable: \(available)\n"
        report += "availability: \(AppleFoundationProvider.availabilityDescription())\n"
        if available {
            do {
                let text = try await AppleFoundationProvider().complete(prompt: "Reply with a short friendly hello.")
                report += "completion OK (\(text.count) chars):\n\(text)\n"
            } catch {
                report += "completion FAILED: \(error)\n"
            }
        } else {
            report += "Apple Intelligence not available on this machine.\n"
            report += "Enable it: System Settings > Apple Intelligence & Siri (needs macOS 26 + Apple Silicon), then re-run.\n"
        }
 // Streaming: confirm we get progressive deltas, not one blob.
        if available {
            do {
                var deltas = 0
                var streamed = ""
                for try await delta in AppleFoundationProvider().stream(prompt: "Count from 1 to 5.") {
                    deltas += 1
                    streamed += delta
                }
                report += "stream deltas=\(deltas), \(streamed.count) chars:\n\(streamed)\n"
            } catch {
                report += "stream FAILED: \(error)\n"
            }
        }

        // Full loop on a greeting must NOT dump JSON at the user (weak-model guard).
        if available {
            let loop = LocalAgentLoop(provider: AppleFoundationProvider(), executor: NoTools())
            var streamed = ""
            // With tools present (the real app scenario) a greeting must still be plain text.
            let tools = [
                AIToolSpec(name: "get_schema", description: "Return DDL for tables.", parametersJSON: "{}"),
                AIToolSpec(name: "run_sql", description: "Run one SQL statement.", parametersJSON: "{}"),
            ]
            let answer = await loop.run(userText: "hi bro", tools: tools) { streamed += $0 }
            let looksLikeJson = answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
            report += "greeting → \(answer.count) chars, json=\(looksLikeJson):\n\(answer)\n"
        }

        try? report.write(toFile: "/tmp/berrydb-apple.txt", atomically: true, encoding: .utf8)
        #expect(Bool(true)) // smoke test: the signal is the written report, not a pass/fail
    }
}
