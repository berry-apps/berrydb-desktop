import Foundation
import Testing

@testable import BerryAI

@Suite("LocalAgentLoop (docs/agents/architecture/10, AI-20)")
struct LocalAgentLoopTests {
    @Test func parsesBareAndFencedToolCalls() {
        #expect(LocalAgentLoop.parseToolCall(#"{"tool":"get_schema","args":{}}"#)?.name == "get_schema")
        let fenced = LocalAgentLoop.parseToolCall("```json\n{\"tool\":\"run_sql\",\"args\":{\"sql\":\"SELECT 1\"}}\n```")
        #expect(fenced?.name == "run_sql")
        #expect(fenced?.args["sql"] as? String == "SELECT 1")
        #expect(LocalAgentLoop.parseToolCall("Here is your answer.") == nil)
    }

    @Test func parseToolCallHandlesFenceLanguageTrailingAndBraces() {
        // A ```tool fence (not ```json) — the object inside is still found.
        #expect(LocalAgentLoop.parseToolCall("```tool\n{\"tool\":\"run_sql\",\"args\":{}}\n```")?.name == "run_sql")
        // Trailing prose after the JSON.
        #expect(LocalAgentLoop.parseToolCall("{\"tool\":\"run_sql\",\"args\":{}}\n\nThis runs it.")?.name == "run_sql")
        // Braces inside a SQL string literal must not close the object early.
        let call = LocalAgentLoop.parseToolCall("{\"tool\":\"run_sql\",\"args\":{\"sql\":\"SELECT '{x}' FROM t\"}}")
        #expect(call?.args["sql"] as? String == "SELECT '{x}' FROM t")
    }

    @MainActor
    @Test func proseBeforeToolCallNeverLeaksTheJSON() async {
        let provider = ScriptedLocal([
            "Let me check that.\n{\"tool\":\"get_schema\",\"args\":{}}",
            "You have one table: t.",
        ])
        let loop = LocalAgentLoop(provider: provider, executor: EchoExecutor())
        var streamed = ""
        let final = await loop.run(
            userText: "what tables?",
            tools: [AIToolSpec(name: "get_schema", description: "schema", parametersJSON: "{}")],
            onDelta: { streamed += $0 }
        )
        // The tool ran and the final answer showed — but the tool-call JSON never did.
        #expect(final.contains("You have one table: t."))
        #expect(!streamed.contains("\"tool\""))
        #expect(!streamed.contains("get_schema"))
    }

    @Test func promptListsTheTools() {
        let prompt = LocalAgentLoop.buildPrompt(
            tools: [AIToolSpec(name: "get_schema", description: "Return DDL", parametersJSON: "{}")],
            transcript: "User: hi\n"
        )
        #expect(prompt.contains("get_schema: Return DDL"))
        #expect(prompt.contains("User: hi"))
    }

    /// Scripted local model: reply N is `replies[N]`, then "done".
    private final class ScriptedLocal: LocalCompletionProvider, @unchecked Sendable {
        let replies: [String]
        var index = 0
        init(_ replies: [String]) { self.replies = replies }
        static func isAvailable() -> Bool { true }
        func complete(prompt: String) async throws -> String {
            defer { index += 1 }
            return index < replies.count ? replies[index] : "done"
        }
    }

    private struct EchoExecutor: AIToolExecutor {
        func execute(_ call: AIToolCall) async -> ToolOutcome { .ok(#"{"ran":true}"#) }
    }

    @MainActor
    @Test func runsAToolRoundThenReturnsTheAnswer() async {
        let provider = ScriptedLocal([
            #"{"tool":"get_schema","args":{}}"#,
            "You have one table: t.",
        ])
        let loop = LocalAgentLoop(provider: provider, executor: EchoExecutor())
        var streamed = ""
        let final = await loop.run(
            userText: "what tables?",
            tools: [AIToolSpec(name: "get_schema", description: "schema", parametersJSON: "{}")],
            onDelta: { streamed += $0 }
        )
        #expect(final == "You have one table: t.")
        #expect(streamed == "You have one table: t.")
    }

    @MainActor
    @Test func clarificationSuspendsLocallyAndResumesWithoutExposingProtocol() async {
        let provider = ScriptedLocal([
            #"{"tool":"clarify_request","args":{"question":"Which database?","reason":"Target required","choices":["staging","production"],"allow_free_text":true}}"#,
            "Using staging.",
        ])
        let loop = LocalAgentLoop(provider: provider, executor: EchoExecutor())
        let first = await loop.runUntilInteraction(
            userText: "inspect it", tools: [], priorTranscript: "",
            resumeAction: nil, onDelta: { _ in }
        )
        #expect(first == .clarification(LocalClarification(
            question: "Which database?", reason: "Target required",
            choices: ["staging", "production"], allowFreeText: true
        )))

        var shown = ""
        let resumed = await loop.runUntilInteraction(
            userText: "staging", tools: [],
            priorTranscript: "User: inspect it\nAssistant: Which database?\n",
            resumeAction: .answered, onDelta: { shown += $0 }
        )
        #expect(resumed == .completed("Using staging."))
        #expect(shown == "Using staging.")
        #expect(!shown.contains("answered"))
        #expect(!shown.contains("\"tool\""))
    }

    @Test func localPromptOffersClarificationButNeverReportSubmission() {
        let prompt = LocalAgentLoop.buildPrompt(tools: [], transcript: "User: /report broken\n")
        #expect(prompt.contains("clarify_request"))
        #expect(prompt.contains("Report submission is unavailable"))
        #expect(!prompt.contains("report_draft_ready"))
    }

    @Test func appleProviderReportsUnavailableWithoutFramework() {
        // In CI/toolchains without FoundationModels this is false; on a real
        // Apple Intelligence device the #if branch decides.
        _ = AppleFoundationProvider.isAvailable()
    }

    /// Records every prompt it was called with, so a test can inspect what
    /// the NEXT round actually sends — `ScriptedLocal` above only cares about
    /// what comes back out.
    private final class CapturingScriptedLocal: LocalCompletionProvider, @unchecked Sendable {
        let replies: [String]
        var prompts: [String] = []
        var index = 0
        init(_ replies: [String]) { self.replies = replies }
        static func isAvailable() -> Bool { true }
        func complete(prompt: String) async throws -> String {
            prompts.append(prompt)
            defer { index += 1 }
            return index < replies.count ? replies[index] : "done"
        }
    }

    private struct LargeResultExecutor: AIToolExecutor {
        static let blob = String(repeating: "x", count: 5000)
        func execute(_ call: AIToolCall) async -> ToolOutcome { .ok(Self.blob) }
    }

    /// Reproduces the live report: a real tool call's result (schema/query,
    /// unlike this suite's other tests which use a 2-char `EchoExecutor`
    /// stub) joined the on-device transcript RAW. Apple's on-device model has
    /// a much smaller context window than the backend's cloud models, so a
    /// non-trivial result already blows it in round 2 — `provider.stream`
    /// throws there with nothing shown yet, which `AISession.sendLocal`
    /// reports as "The on-device model didn't return an answer.", giving no
    /// hint that the actual cause was an oversized prompt.
    @MainActor
    @Test func largeToolResultIsTruncatedBeforeJoiningTheLocalTranscript() async {
        let provider = CapturingScriptedLocal([
            #"{"tool":"get_schema","args":{}}"#,
            "Done.",
        ])
        let loop = LocalAgentLoop(provider: provider, executor: LargeResultExecutor())
        _ = await loop.run(
            userText: "what tables?",
            tools: [AIToolSpec(name: "get_schema", description: "schema", parametersJSON: "{}")],
            onDelta: { _ in }
        )
        #expect(provider.prompts.count == 2)
        let secondRoundPrompt = provider.prompts[1]
        #expect(!secondRoundPrompt.contains(LargeResultExecutor.blob))
        #expect(secondRoundPrompt.contains("truncated"))
    }

    /// Mirrors the real `LocalCapabilityHost.execute` behavior for a tool
    /// name that was never advertised — the exact shape of the live bug.
    private struct AdvertisedOnlyExecutor: AIToolExecutor {
        let advertised: Set<String>
        func execute(_ call: AIToolCall) async -> ToolOutcome {
            guard advertised.contains(call.name) else {
                return .failed("Capability was not advertised for this turn")
            }
            return .ok(#"{"ran":true}"#)
        }
    }

    /// Reported live: a plain "which model do you use" question made the
    /// weak on-device model hallucinate a tool call for a tool that was
    /// never offered. The loop fed the raw capability-host error back into
    /// the model's own context as the "tool result", and the model then
    /// echoed that internal error string back verbatim as its answer on the
    /// next round — the user saw "Capability was not advertised for this
    /// turn" as the reply to an ordinary question.
    @MainActor
    @Test func hallucinatedToolNameIsCorrectedNotEchoedFromAnInternalError() async {
        let provider = CapturingScriptedLocal([
            #"{"tool":"get_model_info","args":{}}"#, // hallucinated — never advertised
            "I use an on-device model.",
        ])
        let loop = LocalAgentLoop(
            provider: provider,
            executor: AdvertisedOnlyExecutor(advertised: ["get_schema"])
        )
        var streamed = ""
        let final = await loop.run(
            userText: "which model do you use",
            tools: [AIToolSpec(name: "get_schema", description: "schema", parametersJSON: "{}")],
            onDelta: { streamed += $0 }
        )
        #expect(final == "I use an on-device model.")
        #expect(provider.prompts.count == 2)
        let secondRoundPrompt = provider.prompts[1]
        // The correction must name the bad tool in plain language, not just
        // relay the capability host's internal error string back into the
        // model's own context.
        #expect(secondRoundPrompt.contains("get_model_info"))
        #expect(!secondRoundPrompt.contains("Capability was not advertised"))
    }
}
