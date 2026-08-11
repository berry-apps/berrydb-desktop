import Foundation
import Testing
@testable import BerryStore

@Suite("AI chat history + sqlite-vec RAG (Q17)")
struct AIChatTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndFetchesThreadsNewestFirst() throws {
        let store = try makeStore()
        let t1 = AIThreadRecord(dialect: "postgres", title: "First", createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000))
        let t2 = AIThreadRecord(dialect: "mongodb", title: "Second", createdAt: Date(timeIntervalSince1970: 2000), updatedAt: Date(timeIntervalSince1970: 3000))
        try store.saveAIThread(t1)
        try store.saveAIThread(t2)

        let all = try store.aiThreads()
        #expect(all.map(\.id) == [t2.id, t1.id])

        let postgresOnly = try store.aiThreads(dialect: "postgres")
        #expect(postgresOnly.map(\.id) == [t1.id])
    }

    @Test func threadsAreScopedByConnectionKeyNotJustDialect() throws {
        let store = try makeStore()
        let a = AIThreadRecord(dialect: "postgres", connectionKey: "profile-a", title: "A", createdAt: Date(), updatedAt: Date())
        let b = AIThreadRecord(dialect: "postgres", connectionKey: "profile-b", title: "B", createdAt: Date(), updatedAt: Date())
        let legacy = AIThreadRecord(dialect: "postgres", title: "Pre-v28, no connectionKey", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(a)
        try store.saveAIThread(b)
        try store.saveAIThread(legacy)

        #expect(try store.aiThreads(dialect: "postgres", connectionKey: "profile-a").map(\.id) == [a.id])
        #expect(try store.aiThreads(dialect: "postgres", connectionKey: "profile-b").map(\.id) == [b.id])
        #expect(try store.aiThreads(dialect: "postgres", connectionKey: nil).map(\.id) == [legacy.id])
    }

    @Test func appendsAndFetchesMessagesInSeqOrder() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)

        let m2 = AIMessageRecord(threadID: thread.id, seq: 2, role: "assistant", content: "second", createdAt: Date())
        let m1 = AIMessageRecord(threadID: thread.id, seq: 1, role: "user", content: "first", createdAt: Date())
        try store.appendAIMessage(m2)
        try store.appendAIMessage(m1)

        let messages = try store.aiMessages(threadID: thread.id)
        #expect(messages.map(\.seq) == [1, 2])
        #expect(messages.map(\.content) == ["first", "second"])
    }

    /// AI-31 (docs/draft/09.md, v26): a message's artifact links must
    /// round-trip so a chat bubble's link survives a history reload/restart —
    /// nil for a message that never touched an artifact.
    @Test func artifactsJSONRoundTripsAndDefaultsToNilForOlderRows() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)

        let withArtifacts = AIMessageRecord(
            threadID: thread.id, seq: 1, role: "assistant", content: "here you go", createdAt: Date(),
            artifactsJSON: #"[{"artifactID":"\#(UUID().uuidString)","versionNumber":1,"title":"t","kind":"editorTab"}]"#
        )
        let withoutArtifacts = AIMessageRecord(
            threadID: thread.id, seq: 2, role: "assistant", content: "no tools here", createdAt: Date()
        )
        try store.appendAIMessage(withArtifacts)
        try store.appendAIMessage(withoutArtifacts)

        let messages = try store.aiMessages(threadID: thread.id)
        #expect(messages[0].artifactsJSON == withArtifacts.artifactsJSON)
        #expect(messages[1].artifactsJSON == nil)
    }

    /// docs/feature/08 perf plan (item A2): the async counterparts used on
    /// `AISession`'s main-actor send path must return identical data to
    /// their sync originals.
    @Test func asyncThreadAndMessageMethodsMatchTheirSyncCounterparts() async throws {
        let store = try makeStore()
        let t1 = AIThreadRecord(dialect: "postgres", title: "First", createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000))
        try await store.saveAIThreadAsync(t1)

        let fetched = try await store.aiThreadAsync(id: t1.id)
        #expect(fetched == t1)
        #expect(try store.aiThread(id: t1.id) == t1)

        let m2 = AIMessageRecord(threadID: t1.id, seq: 2, role: "assistant", content: "second", createdAt: Date())
        let m1 = AIMessageRecord(threadID: t1.id, seq: 1, role: "user", content: "first", createdAt: Date())
        try await store.appendAIMessageAsync(m2)
        try await store.appendAIMessageAsync(m1)

        let messages = try await store.aiMessagesAsync(threadID: t1.id)
        #expect(messages.map(\.seq) == [1, 2])
        #expect(messages.map(\.content) == ["first", "second"])
        #expect(try messages == store.aiMessages(threadID: t1.id))
    }

    /// `AISession.buildContext`'s bounded fetch (docs/feature/08 perf follow-up):
    /// the last N non-interaction messages, oldest first, without touching
    /// anything older — the whole point is never reading a long thread's full
    /// history just for its tail.
    @Test func recentMessagesReturnsOnlyTheLastNOldestFirst() async throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        for seq in 0..<10 {
            try store.appendAIMessage(AIMessageRecord(
                threadID: thread.id, seq: seq, role: "user", content: "\(seq)", createdAt: Date()
            ))
        }

        let recent = try await store.aiRecentMessagesAsync(threadID: thread.id, limit: 3)
        #expect(recent.map(\.content) == ["7", "8", "9"])
    }

    /// Interaction rows must not consume a slot in the bounded window or count
    /// toward `sinceSeq` filtering — otherwise a clarify_request/report_draft
    /// exchange sitting near the tail would silently shrink the real recent
    /// window or leak into the fold delta.
    @Test func recentMessagesAndSinceSeqExcludeInteractionMarkedRows() async throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        for seq in 0..<6 {
            let isInteraction = seq == 2 || seq == 4
            try store.appendAIMessage(AIMessageRecord(
                threadID: thread.id, seq: seq, role: isInteraction ? "assistant" : "user",
                content: "\(seq)", toolCalls: isInteraction ? "local:interaction" : nil, createdAt: Date()
            ))
        }

        let recent = try await store.aiRecentMessagesAsync(threadID: thread.id, limit: 3)
        #expect(recent.map(\.content) == ["1", "3", "5"]) // 2 and 4 are interaction rows, skipped

        let sinceOne = try await store.aiMessagesAsync(threadID: thread.id, sinceSeq: 1)
        #expect(sinceOne.map(\.content) == ["3", "5"]) // 2 skipped (interaction), 4 skipped (interaction)
    }

    @Test func sinceSeqReturnsOnlyStrictlyNewerMessages() async throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        for seq in 0..<5 {
            try store.appendAIMessage(AIMessageRecord(
                threadID: thread.id, seq: seq, role: "user", content: "\(seq)", createdAt: Date()
            ))
        }

        let since2 = try await store.aiMessagesAsync(threadID: thread.id, sinceSeq: 2)
        #expect(since2.map(\.seq) == [3, 4])

        let sinceAll = try await store.aiMessagesAsync(threadID: thread.id, sinceSeq: 4)
        #expect(sinceAll.isEmpty)
    }

    @Test func deletingAThreadCascadesMessagesAndEmbeddings() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        try store.appendAIMessage(AIMessageRecord(threadID: thread.id, seq: 1, role: "user", content: "hi", createdAt: Date()))
        try store.saveAIMessageEmbedding(threadID: thread.id, seq: 1, vector: Array(repeating: 0.1, count: 1536))

        try store.deleteAIThread(id: thread.id)

        #expect(try store.aiThread(id: thread.id) == nil)
        #expect(try store.aiMessages(threadID: thread.id).isEmpty)
        let nearest = try store.nearestAIMessages(threadID: thread.id, to: Array(repeating: 0.1, count: 1536))
        #expect(nearest.isEmpty)
    }

    @Test func atomicEmbeddingSaveRequiresAnExistingMessageAndValidDimension() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        let vector = Array(repeating: Float(0.1), count: BerryStore.aiMessageEmbeddingDimension)

        #expect(try store.saveAIMessageEmbeddingIfMessageExists(
            threadID: thread.id, seq: 0, vector: vector
        ) == false)
        try store.appendAIMessage(AIMessageRecord(
            threadID: thread.id, seq: 0, role: "user",
            content: "hello", createdAt: Date()
        ))
        #expect(try store.saveAIMessageEmbeddingIfMessageExists(
            threadID: thread.id, seq: 0, vector: Array(vector.dropLast())
        ) == false)
        #expect(try store.saveAIMessageEmbeddingIfMessageExists(
            threadID: thread.id, seq: 0, vector: vector
        ) == true)
        #expect(try store.aiMessagesMissingEmbeddings(threadID: thread.id).isEmpty)
    }

    @Test func missingEmbeddingsCanBeRestrictedToTheOlderWindow() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)
        for seq in 0..<4 {
            try store.appendAIMessage(AIMessageRecord(
                threadID: thread.id, seq: seq, role: "user",
                content: "\(seq)", createdAt: Date()
            ))
        }
        let vector = Array(repeating: Float(0.1), count: BerryStore.aiMessageEmbeddingDimension)
        try store.saveAIMessageEmbedding(threadID: thread.id, seq: 0, vector: vector)

        let missing = try store.aiMessagesMissingEmbeddings(
            threadID: thread.id, beforeSeq: 3
        )
        #expect(missing.map(\.seq) == [1, 2])
    }

    /// The actual proof that the vendored sqlite-vec extension is wired up
    /// and functioning at runtime (not just compiling) — creates real
    /// embeddings, and confirms the vec0 KNN query ranks the closer vector
    /// first and correctly excludes another thread's data.
    @Test func nearestAIMessagesRanksByCosineDistanceAndIsolatesByThread() throws {
        let store = try makeStore()
        let threadA = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        let threadB = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(threadA)
        try store.saveAIThread(threadB)

        var close = Array(repeating: Float(0), count: 1536)
        close[0] = 1.0
        var near = Array(repeating: Float(0), count: 1536)
        near[0] = 0.9
        near[1] = 0.1
        var far = Array(repeating: Float(0), count: 1536)
        far[0] = -1.0

        try store.saveAIMessageEmbedding(threadID: threadA.id, seq: 1, vector: near)
        try store.saveAIMessageEmbedding(threadID: threadA.id, seq: 2, vector: far)
        // Same vector as threadA's seq 1, but scoped to threadB — must not leak in.
        try store.saveAIMessageEmbedding(threadID: threadB.id, seq: 1, vector: close)

        let results = try store.nearestAIMessages(threadID: threadA.id, to: close, limit: 8)

        #expect(results.map(\.seq) == [1, 2])
        #expect(results[0].distance < results[1].distance)
    }
}
