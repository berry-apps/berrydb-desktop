import BerryStore
import Foundation
import Testing
@testable import BerryAI

private final class StubTransport: AITransport, @unchecked Sendable {
    var embedReply: [Float] = []
    var embedReplies: [String: [Float]] = [:]
    private let lock = NSLock()
    private var _embedInputs: [String] = []

    func createThread(dialect: String, schemaDigest: String) async throws -> String { "unused" }
    func postMessage(threadID: String, text: String, tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func postToolResult(
        threadID: String, callID: String, dispatchNonce: String,
        capabilitySetDigest: String, status: String, resultJSON: String?
    ) async throws {}
    func rankSkills(skills: [SkillRankInput], query: String) async -> [String] { [] }
    func embed(text: String) async -> [Float] {
        lock.withLock {
            _embedInputs.append(text)
            return embedReplies[text] ?? embedReply
        }
    }
    func embedInputs() -> [String] { lock.withLock { _embedInputs } }
}

@Suite("search_conversation client tool")
struct SearchConversationToolExecutorTests {
    private func makeStore() -> BerryStore {
        try! BerryStore(path: ":memory:")
    }

 /// `SearchConversationToolExecutor` now reads the ACTIVE path
    /// unlike `AISession.send`'s real flow, these tests seed messages
    /// directly via `appendAIMessage`, so this chains each one's `parentID`
    /// and advances the thread's `activeLeafMessageID` the same way
    /// `persistTurn` does, or every message here would look orphaned.
    @discardableResult
    private func appendAndActivate(_ store: BerryStore, threadID: UUID, _ messages: [AIMessageRecord]) -> [AIMessageRecord] {
        var previous: UUID?
        var chained: [AIMessageRecord] = []
        for message in messages {
            var next = message
            next.parentID = previous
            try! store.appendAIMessage(next)
            previous = next.id
            chained.append(next)
        }
        try! store.setActiveLeafMessage(threadID: threadID, messageID: previous)
        return chained
    }

    @MainActor
    @Test func returnsEmptyMatchesWhenNoThreadIsActive() async {
        let executor = SearchConversationToolExecutor(store: makeStore(), transport: StubTransport(), currentThreadID: { nil })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_conversation", args: ["query": "emails"]))
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON == #"{"matches":[]}"#)
    }

    @MainActor
    @Test func rejectsAMissingQueryArgument() async {
        let executor = SearchConversationToolExecutor(store: makeStore(), transport: StubTransport(), currentThreadID: { UUID().uuidString })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_conversation", args: [:]))
        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func findsTheClosestStoredMessageByEmbedding() async {
        let store = makeStore()
        let threadID = UUID()
        try! store.saveAIThread(AIThreadRecord(id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()))
        appendAndActivate(store, threadID: threadID, [
            AIMessageRecord(threadID: threadID, seq: 0, role: "user", content: "what's the users table schema?", createdAt: Date()),
            AIMessageRecord(threadID: threadID, seq: 1, role: "assistant", content: "It has id, email, created_at.", createdAt: Date()),
        ] + (2..<10).map { seq in
            AIMessageRecord(
                threadID: threadID, seq: seq,
                role: seq.isMultiple(of: 2) ? "user" : "assistant",
                content: "recent \(seq)", createdAt: Date()
            )
        })

        // vec0's embedding column is fixed at 1536 dims (BerryStore's
        // ai_message_embedding table, migration v17) — matches OpenAI's
        // text-embedding-3-small, the only dimension this store accepts.
        var close = Array(repeating: Float(0), count: 1536)
        close[0] = 1
        var far = Array(repeating: Float(0), count: 1536)
        far[0] = -1
        try! store.saveAIMessageEmbedding(threadID: threadID, seq: 0, vector: close)
        try! store.saveAIMessageEmbedding(threadID: threadID, seq: 1, vector: far)

        let transport = StubTransport()
        transport.embedReply = close
        let executor = SearchConversationToolExecutor(store: store, transport: transport, currentThreadID: { threadID.uuidString })

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_conversation", args: ["query": "users table"]))
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("users table schema") == true)
    }

    @MainActor
    @Test func backfillsOnlyMissingOlderMessagesBeforeSearching() async {
        let store = makeStore()
        let threadID = UUID()
        try! store.saveAIThread(AIThreadRecord(
            id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
        ))
        appendAndActivate(store, threadID: threadID, (0..<10).map { seq in
            AIMessageRecord(
                threadID: threadID, seq: seq,
                role: seq.isMultiple(of: 2) ? "user" : "assistant",
                content: "message \(seq)", createdAt: Date()
            )
        })

        var close = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        close[0] = 1
        var far = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        far[0] = -1
        let transport = StubTransport()
        transport.embedReplies = [
            "message 0": close,
            "message 1": far,
            "old marker": close,
        ]
        let executor = SearchConversationToolExecutor(
            store: store, transport: transport,
            currentThreadID: { threadID.uuidString }
        )

        let first = await executor.execute(AIToolCall(
            id: "c1", name: "search_conversation", args: ["query": "old marker"]
        ))
        #expect(first.resultJSON?.contains("message 0") == true)
        #expect(transport.embedInputs().filter { $0 == "message 0" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "message 1" }.count == 1)

        _ = await executor.execute(AIToolCall(
            id: "c2", name: "search_conversation", args: ["query": "old marker"]
        ))
        #expect(transport.embedInputs().filter { $0 == "message 0" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "message 1" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "old marker" }.count == 2)
    }

    @MainActor
    @Test func directlyExcludesInteractionRecordsEvenIfTheyAlreadyHaveVectors() async {
        let store = makeStore()
        let threadID = UUID()
        try! store.saveAIThread(AIThreadRecord(
            id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()
        ))
        var closest = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        closest[0] = 1
        var far = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        far[0] = -1
        appendAndActivate(store, threadID: threadID, (0..<10).map { seq in
            let interaction = seq == 0
            return AIMessageRecord(
                threadID: threadID, seq: seq,
                role: interaction ? "assistant" : "user",
                content: interaction ? "secret clarification answer" : "ordinary \(seq)",
                toolCalls: interaction ? "local:interaction" : nil,
                createdAt: Date()
            )
        })
        for seq in 0..<10 {
            let interaction = seq == 0
            try! store.saveAIMessageEmbedding(
                threadID: threadID, seq: seq,
                vector: interaction ? closest : far
            )
        }
        let transport = StubTransport()
        transport.embedReply = closest
        let executor = SearchConversationToolExecutor(
            store: store, transport: transport,
            currentThreadID: { threadID.uuidString }
        )

        let outcome = await executor.execute(AIToolCall(
            id: "c", name: "search_conversation", args: ["query": "secret"]
        ))

        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("secret clarification answer") == false)
        #expect(transport.embedInputs().filter { $0 == "secret clarification answer" }.isEmpty)
    }

    @MainActor
    @Test func sentMessagesBecomeSearchableWithoutManualVectorSeeding() async throws {
        var close = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        close[0] = 1
        var far = Array(repeating: Float(0), count: BerryStore.aiMessageEmbeddingDimension)
        far[0] = -1
        let transport = StubTransport()
        transport.embedReply = far
        transport.embedReplies = ["unique old marker": close, "find marker": close]
        let store = makeStore()
        let session = AISession(
            transport: transport,
            executor: NoopToolExecutor(),
            dialect: "postgres", schemaDigest: "d", store: store
        )
        await session.send("unique old marker")
        for index in 1..<10 { await session.send("later message \(index)") }
        let threadID = try #require(session.currentThreadID)
        let executor = SearchConversationToolExecutor(
            store: store, transport: transport,
            currentThreadID: { threadID }
        )

        let outcome = await executor.execute(AIToolCall(
            id: "c1", name: "search_conversation", args: ["query": "find marker"]
        ))

        #expect(outcome.resultJSON?.contains("unique old marker") == true)
    }

    @MainActor
    @Test func returnsEmptyMatchesWhenEmbeddingFails() async {
        let store = makeStore()
        let threadID = UUID()
        try! store.saveAIThread(AIThreadRecord(id: threadID, dialect: "postgres", createdAt: Date(), updatedAt: Date()))
        let transport = StubTransport() // embedReply defaults to []
        let executor = SearchConversationToolExecutor(store: store, transport: transport, currentThreadID: { threadID.uuidString })

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_conversation", args: ["query": "anything"]))
        #expect(outcome.resultJSON == #"{"matches":[]}"#)
    }
}

private struct NoopToolExecutor: AIToolExecutor {
    var toolSpecs: [AIToolSpec] { [] }
    func execute(_ call: AIToolCall) async -> ToolOutcome { .ok("{}") }
}
