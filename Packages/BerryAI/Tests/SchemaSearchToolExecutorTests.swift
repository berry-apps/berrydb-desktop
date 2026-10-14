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

@Suite("search_schema client tool")
struct SchemaSearchToolExecutorTests {
    private func makeStore() -> BerryStore {
        try! BerryStore(path: ":memory:")
    }

    /// Gives each name its vector the way a drain does: listed as the
    /// profile's current tables, then stored through their queued rows.
    private func embed(_ vectors: [String: [Float]], profileID: UUID, in store: BerryStore) throws {
        _ = try store.applySchemaListing(
            profileID: profileID,
            objects: vectors.keys.map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: nil) },
            relations: nil, now: Date()
        )
        for row in try store.schemaObjectsNeedingEmbedding(profileID: profileID, limit: vectors.count) {
            _ = try store.storeSchemaEmbedding(
                id: row.id, profileID: profileID, name: row.name, vector: try #require(vectors[row.name])
            )
        }
    }

    /// Every search embeds its query on BerryDB's AI service, so the tool
    /// must say so to be kept out of on-device turns.
    @MainActor
    @Test func declaresThatItNeedsTheBackend() {
        let executor = SchemaSearchToolExecutor(
            store: makeStore(), transport: StubTransport(),
            profileID: { nil }, candidateNames: { [] }
        )
        #expect(!executor.toolSpecs.isEmpty)
        #expect(executor.toolSpecs.allSatisfy { $0.requiresBackend })
    }

    @MainActor
    @Test func returnsEmptyMatchesWhenNoProfileIsActive() async {
        let executor = SchemaSearchToolExecutor(
            store: makeStore(), transport: StubTransport(),
            profileID: { nil }, candidateNames: { ["users"] }
        )
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON == #"{"matches":[]}"#)
    }

    @MainActor
    @Test func rejectsAMissingQueryArgument() async {
        let executor = SchemaSearchToolExecutor(
            store: makeStore(), transport: StubTransport(),
            profileID: { UUID() }, candidateNames: { ["users"] }
        )
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: [:]))
        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func returnsEmptyMatchesWhenThereAreNoCandidateNames() async {
        let executor = SchemaSearchToolExecutor(
            store: makeStore(), transport: StubTransport(),
            profileID: { UUID() }, candidateNames: { [] }
        )
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(outcome.resultJSON == #"{"matches":[]}"#)
    }

    @MainActor
    @Test func findsTheClosestTableByEmbedding() async throws {
        let store = makeStore()
        let profileID = UUID()

        // vec0's embedding column is fixed at 1536 dims (BerryStore's
        // schema_object_embedding table, migration v22) — matches OpenAI's
        // text-embedding-3-small, the only dimension this store accepts.
        var close = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        close[0] = 1
        var far = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        far[0] = -1
        try embed(["users": close, "audit_log": far], profileID: profileID, in: store)

        let transport = StubTransport()
        transport.embedReply = close
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { profileID }, candidateNames: { ["users", "audit_log"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(outcome.status == "ok")
        let data = try #require(outcome.resultJSON?.data(using: .utf8))
        let matches = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])["matches"]
        #expect(matches?.first == "users")
    }

    private func unitVector(_ index: Int, sign: Float = 1) -> [Float] {
        var vector = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        vector[index] = sign
        return vector
    }

    private func matches(_ outcome: ToolOutcome) throws -> [String] {
        let data = try #require(outcome.resultJSON?.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: [String]])["matches"] ?? []
    }

    /// No harvest has listed the connection and no drain has run, as for a
    /// connection whose names the background queue never embeds: the search
    /// embeds the names it is given and finds them.
    @MainActor
    @Test func aSearchWithNoHarvestEmbedsItsCandidatesAndFindsThem() async throws {
        let store = makeStore()
        let profileID = UUID()
        let transport = StubTransport()
        transport.embedReplies = ["users": unitVector(0), "audit_log": unitVector(0, sign: -1), "customer": unitVector(0)]
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { profileID }, candidateNames: { ["users", "audit_log"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))

        #expect(try matches(outcome).first == "users")
        #expect(Set(transport.embedInputs()) == ["customer", "users", "audit_log"])
    }

    /// A name is embedded once: the next search embeds only its query.
    @MainActor
    @Test func aNameIsEmbeddedOnceAcrossSearches() async {
        let store = makeStore()
        let profileID = UUID()
        let transport = StubTransport()
        transport.embedReplies = ["users": unitVector(0), "orders": unitVector(1), "customer": unitVector(0)]
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { profileID }, candidateNames: { ["users", "orders"] }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        _ = await executor.execute(AIToolCall(id: "c2", name: "search_schema", args: ["query": "customer"]))

        #expect(transport.embedInputs().filter { $0 == "users" || $0 == "orders" }.count == 2)
        #expect(transport.embedInputs().suffix(1) == ["customer"])
    }

    /// One search embeds at most `backfillLimit` names, so a connection with
    /// thousands of unembedded tables cannot hold an AI turn for thousands of
    /// requests; the next search embeds the next ones.
    @MainActor
    @Test func aSearchEmbedsAtMostItsLimitOfNames() async {
        let store = makeStore()
        let profileID = UUID()
        let names = (0..<(SchemaSearchToolExecutor.backfillLimit + 30)).map { "t\($0)" }
        let transport = StubTransport()
        transport.embedReply = unitVector(0)
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport, profileID: { profileID }, candidateNames: { names }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(transport.embedInputs().count == 1 + SchemaSearchToolExecutor.backfillLimit)

        _ = await executor.execute(AIToolCall(id: "c2", name: "search_schema", args: ["query": "customer"]))
        #expect(transport.embedInputs().count == 2 + names.count)
    }

    /// A name a search embedded leaves the background queue, so the drain
    /// does not send it again.
    @MainActor
    @Test func anEmbeddedNameLeavesTheBackgroundQueue() async throws {
        let store = makeStore()
        let profileID = UUID()
        _ = try store.applySchemaListing(
            profileID: profileID,
            objects: ["users", "orders"].map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: nil) },
            relations: nil, now: Date()
        )
        let transport = StubTransport()
        transport.embedReply = unitVector(0)
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport, profileID: { profileID }, candidateNames: { ["users", "orders"] }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))

        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profileID, limit: 10).isEmpty)
    }

    /// The names are embedded inside the AI turn, so a turn that ends stops
    /// sending them.
    @MainActor
    @Test func anEndedLeaseStopsTheNames() async {
        let store = makeStore()
        let profileID = UUID()
        let names = (0..<40).map { "t\($0)" }
        let transport = StubTransport()
        transport.embedReply = unitVector(0)
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport, profileID: { profileID }, candidateNames: { names }
        )
        var checks = 0
        let lease = AIExecutionLease {
            checks += 1
            return checks <= 2
        }

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]), lease: lease)

        #expect(outcome.status == "denied")
        #expect(transport.embedInputs().count < 1 + names.count)
    }

    /// A store that refuses to save a vector would refuse every other one, so
    /// the search sends no more names after the first round in which it did.
    @MainActor
    @Test func aStoreThatRefusesWritesStopsTheNames() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        _ = try BerryStore(path: path)
        let refusing = try BerryStore.openReadOnly(path: path)
        let names = (0..<40).map { "t\($0)" }
        let transport = StubTransport()
        transport.embedReply = unitVector(0)
        let executor = SchemaSearchToolExecutor(
            store: refusing, transport: transport, profileID: { UUID() }, candidateNames: { names }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))

        #expect(transport.embedInputs().count <= 1 + SchemaSearchToolExecutor.backfillConcurrency)
    }

    /// The names are unqualified, so a table name in two schemas is listed
    /// twice; its vector is one, so it is embedded once.
    @MainActor
    @Test func aNameListedTwiceIsEmbeddedOnce() async {
        let store = makeStore()
        let transport = StubTransport()
        transport.embedReply = unitVector(0)
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport, profileID: { UUID() }, candidateNames: { ["users", "orders", "users"] }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))

        #expect(transport.embedInputs().filter { $0 == "users" }.count == 1)
        #expect(transport.embedInputs().count == 3)
    }

    /// A query that cannot be embedded finds nothing whatever the names, so
    /// none is sent: a provider that is down is not asked once per name.
    @MainActor
    @Test func aQueryThatCannotBeEmbeddedSendsNoName() async {
        let store = makeStore()
        let transport = StubTransport()
        transport.embedReplies = ["users": unitVector(0)]
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport, profileID: { UUID() }, candidateNames: { ["users"] }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))

        #expect(transport.embedInputs() == ["customer"])
    }

    @MainActor
    @Test func filtersOutEmbeddingsForNamesNoLongerInTheSchema() async throws {
        let store = makeStore()
        let profileID = UUID()
        var close = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        close[0] = 1
        // "old_customers" was embedded in a previous session but the table
        // has since been dropped/renamed — it must never resurface.
        try embed(["old_customers": close], profileID: profileID, in: store)
        let transport = StubTransport()
        transport.embedReply = close
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { profileID }, candidateNames: { ["users"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(outcome.resultJSON?.contains("old_customers") == false)
    }

    @MainActor
    @Test func returnsEmptyMatchesWhenEmbeddingFails() async {
        let store = makeStore()
        let transport = StubTransport() // embedReply defaults to []
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { UUID() }, candidateNames: { ["users"] }
        )

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "anything"]))
        #expect(outcome.resultJSON == #"{"matches":[]}"#)
    }
}
