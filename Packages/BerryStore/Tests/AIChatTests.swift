import Foundation
import GRDB
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
        let message = AIMessageRecord(
            threadID: thread.id, seq: 0, role: "user",
            content: "hello", createdAt: Date()
        )
        try store.appendAIMessage(message)
        // AI-35: aiMessagesMissingEmbeddings reads the active path.
        try store.setActiveLeafMessage(threadID: thread.id, messageID: message.id)
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
        // AI-35: aiMessagesMissingEmbeddings now reads the ACTIVE path, so
        // this setup has to chain parentID + advance the thread's leaf the
        // same way persistTurn does, not just insert flat rows.
        var previous: UUID?
        for seq in 0..<4 {
            let message = AIMessageRecord(
                threadID: thread.id, seq: seq, role: "user",
                content: "\(seq)", createdAt: Date(), parentID: previous
            )
            try store.appendAIMessage(message)
            previous = message.id
        }
        try store.setActiveLeafMessage(threadID: thread.id, messageID: previous)
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

    // MARK: - AI-35: message tree (edit/version)

    /// A real pre-v29 → v29 upgrade: builds a database through v28 only,
    /// seeds it exactly like an existing user's thread (no parentID/
    /// activeLeafMessageID — those columns don't exist yet), then runs the
    /// rest of the migrator and asserts the backfill chained every row and
    /// pointed the thread at its last message.
    @Test func v29BackfillsParentIDAndActiveLeafForPreExistingThreads() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-v29-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let dbQueue = try DatabaseQueue(path: tempURL.path, configuration: configuration)
        try BerryStore.migrator.migrate(dbQueue, upTo: "v28-ai-thread-connection-key")

        // Seed via raw SQL naming only the columns that exist at v28 — the
        // current `AIThreadRecord`/`AIMessageRecord` Swift structs already
        // carry the v29 fields, so `.insert(db)` would generate an INSERT
        // listing columns this table doesn't have yet.
        let threadID = UUID(), m0ID = UUID(), m1ID = UUID(), m2ID = UUID()
        let now = Date()
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO ai_thread (id, dialect, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                arguments: [threadID, "postgres", now, now]
            )
            for (id, seq, role, content) in [
                (m0ID, 0, "user", "hi"), (m1ID, 1, "assistant", "hello"), (m2ID, 2, "user", "again"),
            ] {
                try db.execute(
                    sql: "INSERT INTO ai_message (id, threadID, seq, role, content, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [id, threadID, seq, role, content, now]
                )
            }
        }

        try BerryStore.migrator.migrate(dbQueue) // brings it the rest of the way, through v29

        let store = BerryStore(dbQueue: dbQueue)
        let updatedThread = try #require(try store.aiThread(id: threadID))
        #expect(updatedThread.activeLeafMessageID == m2ID)
        #expect(try store.aiMessage(id: m0ID)?.parentID == nil)
        #expect(try store.aiMessage(id: m1ID)?.parentID == m0ID)
        #expect(try store.aiMessage(id: m2ID)?.parentID == m1ID)

        // Parity: the active path for a never-branched thread must read
        // identically to the old flat method.
        let active = try store.activeAIMessages(threadID: threadID)
        #expect(active.map(\.id) == [m0ID, m1ID, m2ID])
        #expect(try active == store.aiMessages(threadID: threadID))
    }

    /// The core edit shape: editing m1 must not touch m1/m2 at all (still
    /// fetchable, still the same content) — only the thread's active tip
    /// moves to the new sibling's own chain.
    @Test func editingAMessageLeavesTheOldSubtreeFullyIntact() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)

        let m0 = AIMessageRecord(
            threadID: thread.id, seq: 0, role: "user", content: "first",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        try store.appendAIMessage(m0)
        let m1 = AIMessageRecord(
            threadID: thread.id, seq: 1, role: "assistant", content: "old reply",
            createdAt: Date(timeIntervalSince1970: 1), parentID: m0.id
        )
        try store.appendAIMessage(m1)
        try store.setActiveLeafMessage(threadID: thread.id, messageID: m1.id)

        // Edit m0: a new sibling m0b sharing m0's parent (nil).
        let m0b = AIMessageRecord(
            threadID: thread.id, seq: 2, role: "user", content: "first (edited)",
            createdAt: Date(timeIntervalSince1970: 2), parentID: nil
        )
        try store.appendAIMessage(m0b)
        try store.setActiveLeafMessage(threadID: thread.id, messageID: m0b.id)

        // Old subtree untouched.
        #expect(try store.aiMessage(id: m0.id)?.content == "first")
        #expect(try store.aiMessage(id: m1.id)?.content == "old reply")
        // Active path now shows only the edited version.
        #expect(try store.activeAIMessages(threadID: thread.id).map(\.content) == ["first (edited)"])
        // Both versions of the first message are siblings under nil.
        let siblings = try store.siblingGroups(threadID: thread.id)
        #expect(Set(siblings[nil] ?? []) == Set([m0.id, m0b.id]))
    }

    @Test func resolveTipFollowsTheMostRecentlyCreatedChildRepeatedly() throws {
        let store = try makeStore()
        let thread = AIThreadRecord(dialect: "postgres", createdAt: Date(), updatedAt: Date())
        try store.saveAIThread(thread)

        let root = AIMessageRecord(threadID: thread.id, seq: 0, role: "user", content: "root", createdAt: Date(timeIntervalSince1970: 0))
        try store.appendAIMessage(root)
        let childOld = AIMessageRecord(
            threadID: thread.id, seq: 1, role: "user", content: "child-old",
            createdAt: Date(timeIntervalSince1970: 1), parentID: root.id
        )
        let childNew = AIMessageRecord(
            threadID: thread.id, seq: 2, role: "user", content: "child-new",
            createdAt: Date(timeIntervalSince1970: 2), parentID: root.id
        )
        try store.appendAIMessage(childOld)
        try store.appendAIMessage(childNew)
        // childNew (the most recent) has its own further child; childOld is a dead end.
        let grandchild = AIMessageRecord(
            threadID: thread.id, seq: 3, role: "assistant", content: "grandchild",
            createdAt: Date(timeIntervalSince1970: 3), parentID: childNew.id
        )
        try store.appendAIMessage(grandchild)

        let tip = try store.resolveTip(threadID: thread.id, from: root.id)
        #expect(tip == grandchild.id)
    }
}
