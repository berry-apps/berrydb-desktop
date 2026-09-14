import BerryStore
import Foundation

/// Shared message-window policy for client-owned conversation context and
/// local RAG. Keeping these values in one place prevents report, summary and
/// search behavior from drifting apart.
public enum AIConversationPolicy {
    public static let summaryThreshold = 20
    public static let recentWindow = 8
    /// Backend hard cap on the client-built context sent with `POST
 /// v1/agent/threads/{id}/messages`
 /// 64 messages / 256 KiB. `AISession.buildContext` (Task 7.1) stays
    /// under this with a margin so the turn's own outgoing text/tool schemas
    /// still fit.
    public static let contextMessageHardCap = 64
    public static let contextByteHardCap = 256 * 1024
}

/// Best-effort message indexing for Q17 local RAG.
///
/// New messages are indexed after persistence. Existing local conversations
/// are backfilled only when `search_conversation` needs their older messages,
/// so opening the history sidebar remains fully offline.
public struct ConversationEmbeddingIndexer: Sendable {
    private let store: BerryStore
    private let transport: AITransport
    private let maxConcurrentRequests: Int

    public init(
        store: BerryStore, transport: AITransport,
        maxConcurrentRequests: Int = 4
    ) {
        self.store = store
        self.transport = transport
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func index(_ messages: [AIMessageRecord]) async {
        // Interaction questions/answers remain ordinary local chat records for
        // continuity, but are never sent to embedding or semantic-search
        // services. The metadata contains no resume token or tool arguments.
        let indexable = messages.filter { $0.toolCalls != "local:interaction" }
        guard !indexable.isEmpty else { return }
        var start = indexable.startIndex
        while start < indexable.endIndex {
            let end = indexable.index(
                start, offsetBy: maxConcurrentRequests,
                limitedBy: indexable.endIndex
            ) ?? indexable.endIndex
            let batch = Array(indexable[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for message in batch {
                    group.addTask { await index(message) }
                }
            }
            start = end
        }
    }

    public func backfill(threadID: UUID, beforeSeq: Int) async {
        guard let missing = try? store.aiMessagesMissingEmbeddings(
            threadID: threadID, beforeSeq: beforeSeq
        ) else { return }
        await index(missing)
    }

    private func index(_ message: AIMessageRecord) async {
        guard message.toolCalls != "local:interaction" else { return }
        let vector = await transport.embed(text: message.content)
        guard vector.count == BerryStore.aiMessageEmbeddingDimension else { return }
        _ = try? store.saveAIMessageEmbeddingIfMessageExists(
            threadID: message.threadID, seq: message.seq, vector: vector
        )
    }
}
