import BerryStore
import Foundation

/// Client-executed replacement for the old gateway-handled `search_conversation`
/// (Q17, docs/agents/architecture/11 §7.5) — RAG over this thread's earlier
/// (summarized-away) messages. Message vectors and cosine-KNN live locally in
/// `BerryStore`; vector creation uses the stateless `/v1/ai/embed` endpoint.
/// Registered the same
/// way as `graph_query`/`get_stats` (docs/architecture/09 §4).
@MainActor
public final class SearchConversationToolExecutor: AIToolExecutor {
    private let store: BerryStore
    private let transport: AITransport
    private let indexer: ConversationEmbeddingIndexer
    /// Resolves lazily each call — the active thread can change between when
    /// this executor is registered and when the model actually calls the tool.
    private let currentThreadID: () -> String?

    public init(store: BerryStore, transport: AITransport, currentThreadID: @escaping () -> String?) {
        self.store = store
        self.transport = transport
        self.indexer = ConversationEmbeddingIndexer(store: store, transport: transport)
        self.currentThreadID = currentThreadID
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "search_conversation",
            description: "Semantically search EARLIER parts of this conversation that are no longer in the recent context (they were summarized). Use it when the user refers to a detail from earlier that you can't see. Returns the most relevant past messages.",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"What to look for in the earlier conversation."}},"required":["query"]}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await executeSearch(call, lease: nil)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return await executeSearch(call, lease: lease)
    }

    private func executeSearch(_ call: AIToolCall, lease: AIExecutionLease?) async -> ToolOutcome {
        guard call.name == "search_conversation" else { return .failed("Unknown tool '\(call.name)'") }
        guard let query = call.args["query"], !query.isEmpty else { return .failed("Missing 'query'") }
        guard let threadIDString = currentThreadID(), let threadID = UUID(uuidString: threadIDString) else {
            return .ok(#"{"matches":[]}"#)
        }

        let messages = ((try? store.aiMessages(threadID: threadID)) ?? [])
            .filter { $0.toolCalls != "local:interaction" }
        guard messages.count > AIConversationPolicy.recentWindow else {
            return .ok(#"{"matches":[]}"#)
        }
        let older = messages.dropLast(AIConversationPolicy.recentWindow)
        guard let beforeSeq = older.last.map({ $0.seq + 1 }) else {
            return .ok(#"{"matches":[]}"#)
        }
        await indexer.backfill(threadID: threadID, beforeSeq: beforeSeq)
        if let lease, !lease.isValid { return .denied }

        let vector = await transport.embed(text: query)
        if let lease, !lease.isValid { return .denied }
        guard vector.count == BerryStore.aiMessageEmbeddingDimension,
              let nearest = try? store.nearestAIMessages(
                threadID: threadID, to: vector, limit: 8, beforeSeq: beforeSeq
              ) else {
            return .ok(#"{"matches":[]}"#)
        }
        let bySeq = Dictionary(uniqueKeysWithValues: messages.map { ($0.seq, $0) })
        let matches = nearest.compactMap { bySeq[$0.seq] }.map { "\($0.role): \($0.content)" }
        if let lease, !lease.isValid { return .denied }

        let json = (try? JSONSerialization.data(withJSONObject: ["matches": matches]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"matches":[]}"#
        return .ok(json)
    }
}
