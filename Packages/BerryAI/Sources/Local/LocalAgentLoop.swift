import Foundation

/// A local (on-device) text-completion source — the Apple Foundation Models path
/// (docs/agents/architecture/10, AI-20). No API key, no backend, no network.
public protocol LocalCompletionProvider: Sendable {
    /// Whether this device can run the local model (Apple Intelligence available).
    static func isAvailable() -> Bool
    /// One completion for the given prompt; returns the model's full text.
    func complete(prompt: String) async throws -> String
    /// Streamed completion — yields text DELTAS as they generate, so the panel
    /// can show the reply progressively (AI-20). Default: one delta = full text.
    func stream(prompt: String) -> AsyncThrowingStream<String, Error>
}

public extension LocalCompletionProvider {
    func stream(prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await complete(prompt: prompt))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public struct LocalClarification: Sendable, Equatable {
    public let question: String
    public let reason: String?
    public let choices: [String]
    public let allowFreeText: Bool
}

public enum LocalAgentOutcome: Sendable, Equatable {
    case completed(String)
    case clarification(LocalClarification)
}

/// Runs the agent loop entirely on-device (docs/agents/architecture/10 §2).
///
/// Foundation Models' native tool API needs compile-time `@Generable` argument
/// types, not the dynamic JSON Schema our `AIToolSpec` carries (§4). So this uses
/// **prompt-based tool-calling**: the tools are described in the prompt and the
/// model replies with a bare `{"tool","args"}` object we dispatch — the same
/// shape the backend's `parse_tool_call` fallback understands. Reuses the
/// existing `AIToolExecutor`s, so tools still run locally under approval (N1).
///
/// This is a first pass (AI-20, P3): single tool per round, no planner/sub-agent.
@MainActor
public final class LocalAgentLoop {
    public static let maxRounds = 6

    private let provider: any LocalCompletionProvider
    private let executor: any AIToolExecutor

    public init(provider: any LocalCompletionProvider, executor: any AIToolExecutor) {
        self.provider = provider
        self.executor = executor
    }

    /// Runs one user turn; streams the assistant text via `onDelta` and returns
    /// everything shown. Tool rounds run silently. A tool call emitted as text —
    /// even after some prose — is dispatched, never shown, via `StreamGate`
    /// (mirrors the backend fix, AI-09).
    public func run(userText: String, tools: [AIToolSpec], onDelta: @escaping (String) -> Void) async -> String {
        let outcome = await runUntilInteraction(
            userText: userText, tools: tools, priorTranscript: "",
            resumeAction: nil, onDelta: onDelta
        )
        switch outcome {
        case let .completed(text): return text
        case .clarification: return ""
        }
    }

    public func runUntilInteraction(
        userText: String,
        tools: [AIToolSpec],
        priorTranscript: String,
        resumeAction: AIInteractionResume.Action?,
        onDelta: @escaping (String) -> Void
    ) async -> LocalAgentOutcome {
        var transcript = priorTranscript
        if !userText.isEmpty { transcript += "User: \(userText)\n" }
        var shown = ""
        let emit: (String) -> Void = { piece in shown += piece; onDelta(piece) }

        for _ in 0..<Self.maxRounds {
            let prompt = Self.buildPrompt(
                tools: tools, transcript: transcript,
                resumeAction: resumeAction
            )

            var gate = StreamGate()
            do {
                for try await delta in provider.stream(prompt: prompt) {
                    if let prose = gate.push(delta) { emit(prose) }
                }
            } catch {
                // Swallowed into a generic "didn't return an answer" by the
                // caller (AISession.sendLocal) — the underlying FoundationModels
                // error (guardrail refusal, context window exceeded, unsupported
                // locale, ...) is the only thing that explains WHY, so it must
                // be visible in Console.app rather than guessed at blind.
                NSLog("[AILocal] on-device stream failed, held tail=%d chars: %@", gate.heldTail().count, String(describing: error))
                let tail = gate.heldTail()
                if Self.parseToolCall(tail) == nil,
                   !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    emit(tail)
                }
                return .completed(shown)
            }

            // The gate held everything from the first `{`/``` onward; a tool call
            // (pure or trailing a preamble) lives there.
            let tail = gate.heldTail()
            if let call = Self.parseToolCall(tail) {
                if call.name == "clarify_request",
                   let question = call.args["question"] as? String,
                   !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return .clarification(LocalClarification(
                        question: question,
                        reason: call.args["reason"] as? String,
                        choices: call.args["choices"] as? [String] ?? [],
                        allowFreeText: call.args["allow_free_text"] as? Bool ?? true
                    ))
                }
                // A weak model can hallucinate a tool name that was never
                // offered — left to reach `executor.execute`, the resulting
                // "not advertised" error re-enters the model's own context
                // as a fake tool result, and it can echo that error back
                // verbatim as its answer. Name the bad tool in plain
                // language instead, something it can act on.
                guard tools.contains(where: { $0.name == call.name }) else {
                    let validNames = tools.map(\.name).joined(separator: ", ")
                    transcript += "There is no tool named \"\(call.name)\". Valid tools: \(validNames). If no tool is needed, just reply in plain text.\n"
                    continue
                }
                let toolCall = AIToolCall(
                    id: "local-\(UUID().uuidString.prefix(8))",
                    name: call.name,
                    args: Self.flatten(call.args)
                )
                let outcome = await executor.execute(toolCall)
                let resultText = Self.truncatedForLocalContext(outcome.resultJSON ?? outcome.status)
                transcript += "Assistant used tool \(call.name); result: \(resultText)\n"
                continue
            }

            // Held tail is not a tool call. A weak model sometimes wraps a plain
            // answer in JSON or emits malformed JSON — salvage it, never dump raw JSON.
            let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                if let answer = Self.plainAnswer(from: trimmed) {
                    emit(answer)
                    return .completed(shown)
                }
                // Couldn't salvage it — ask for plain text and retry.
                transcript += "Reply to the user in plain conversational text. Do NOT output JSON.\n"
                continue
            }
            if !trimmed.isEmpty { emit(tail) } // fenced code / trailing prose the gate held
            return .completed(shown)
        }
        NSLog("[AILocal] hit maxRounds (%d) without a final answer, shown=%d chars", Self.maxRounds, shown.count)
        return .completed(shown)
    }

    /// If a weak model wrapped a human answer inside JSON, pull it back out.
    private static func plainAnswer(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        for key in ["response", "answer", "content", "text", "message", "reply"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func buildPrompt(
        tools: [AIToolSpec],
        transcript: String,
        resumeAction: AIInteractionResume.Action? = nil
    ) -> String {
        let toolLines = tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        let resumeDirective = resumeAction.map {
            "A clarification was resumed with action code \($0.rawValue). Continue from the visible conversation. Do not expose the action code."
        } ?? ""
        return """
        You are BerryDB's on-device SQL assistant. Reply to the user conversationally in \
        plain text. For greetings, small talk, or anything you can answer directly, just \
        write a normal reply — do NOT output JSON. Follow the language of the current \
        user turn; never force a fixed output language.

        ONLY when the request genuinely needs a database tool, reply with a SINGLE JSON \
        object and nothing else: {"tool":"<name>","args":{...}}. Never wrap a normal \
        answer in JSON.

        Tools:
        \(toolLines)
        - clarify_request: Ask one bounded question when a consequential requirement is missing. Args: question, reason, choices, allow_free_text.

        Report submission is unavailable in on-device mode. Never claim that a report was submitted.
        \(resumeDirective)

        \(transcript)
        Assistant:
        """
    }

    /// Extracts a `{"tool":..,"args":..}` object from the reply, even behind a
    /// ``` fence of any language or with surrounding prose (AI-09).
    nonisolated static func parseToolCall(_ text: String) -> (name: String, args: [String: Any])? {
        guard let object = firstJSONObject(text),
              let data = object.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = json["tool"] as? String else { return nil }
        return (name, json["args"] as? [String: Any] ?? [:])
    }

    /// The first balanced `{...}` substring (string- and escape-aware), or nil.
    nonisolated static func firstJSONObject(_ text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            }
            i += 1
        }
        return nil
    }

    /// Apple's on-device model has a much smaller context window than the
    /// backend's cloud models (docs/agents/architecture/10, AI-20) — a tool
    /// result joined into the transcript raw (a schema dump, a query result)
    /// can already exceed it in round 2, throwing from `provider.stream`
    /// with nothing shown yet. That reaches the user as an unexplained "the
    /// on-device model didn't return an answer" (`AISession.sendLocal`), so
    /// this caps what a single tool result contributes rather than trusting
    /// every tool's output to already be on-device-sized.
    nonisolated private static let maxToolResultChars = 2000

    nonisolated static func truncatedForLocalContext(_ text: String) -> String {
        guard text.count > maxToolResultChars else { return text }
        return String(text.prefix(maxToolResultChars)) + "... [truncated, \(text.count) chars total]"
    }

    /// AIToolCall.args is flat [String: String]; stringify nested values.
    private static func flatten(_ args: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in args {
            if let string = value as? String {
                out[key] = string
            } else if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      let string = String(data: data, encoding: .utf8) {
                out[key] = string
            } else {
                out[key] = "\(value)"
            }
        }
        return out
    }
}

/// Streams assistant prose to the UI but withholds any line that opens a `{...}`
/// object or a ``` fence, so a prompt-based tool call — pure or trailing a
/// preamble — is dispatched instead of shown (mirrors the backend `ToolCallGate`,
/// docs/agents/architecture/06). A genuine prose line never starts with `{`/`` ` ``.
struct StreamGate {
    private var full = ""
    private var shown = 0 // count of Characters already emitted

    /// Absorb a delta; return any prose now safe to stream.
    mutating func push(_ delta: String) -> String? {
        full += delta
        let cut = Self.safePrefixEnd(full)
        guard cut > shown else { return nil }
        let chars = Array(full)
        let out = String(chars[shown..<cut])
        shown = cut
        return out.isEmpty ? nil : out
    }

    /// Content not yet shown — a tool call, fenced block, or trailing prose.
    func heldTail() -> String {
        let chars = Array(full)
        return shown < chars.count ? String(chars[shown...]) : ""
    }

    /// Character offset up to which content is certainly prose (safe to stream):
    /// everything before the first line that opens a `{`/`` ` `` block; the
    /// current unterminated line is held until a newline or a non-block first
    /// character proves it prose.
    private static func safePrefixEnd(_ full: String) -> Int {
        let chars = Array(full)
        let n = chars.count
        var boundary = 0
        while true {
            var j = boundary
            while j < n, chars[j].isWhitespace { j += 1 }
            if j >= n { return boundary }                             // whitespace-only tail → hold
            if chars[j] == "{" || chars[j] == "`" { return boundary } // block opener → hold
            var k = boundary
            while k < n, chars[k] != "\n" { k += 1 }
            if k >= n { return n }                                    // prose, no newline yet → stream
            boundary = k + 1
        }
    }
}
