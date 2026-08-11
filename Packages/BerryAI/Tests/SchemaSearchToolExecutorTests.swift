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

@Suite("search_schema client tool (docs/feature/07 §13)")
struct SchemaSearchToolExecutorTests {
    private func makeStore() -> BerryStore {
        try! BerryStore(path: ":memory:")
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
        try! store.saveSchemaObjectEmbedding(profileID: profileID, name: "users", vector: close)
        try! store.saveSchemaObjectEmbedding(profileID: profileID, name: "audit_log", vector: far)

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

    @MainActor
    @Test func backfillsOnlyMissingNamesBeforeSearching() async {
        let store = makeStore()
        let profileID = UUID()
        var close = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        close[0] = 1
        let transport = StubTransport()
        transport.embedReplies = ["users": close, "orders": close, "customer": close]
        let executor = SchemaSearchToolExecutor(
            store: store, transport: transport,
            profileID: { profileID }, candidateNames: { ["users", "orders"] }
        )

        _ = await executor.execute(AIToolCall(id: "c1", name: "search_schema", args: ["query": "customer"]))
        #expect(transport.embedInputs().filter { $0 == "users" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "orders" }.count == 1)

        _ = await executor.execute(AIToolCall(id: "c2", name: "search_schema", args: ["query": "customer"]))
        #expect(transport.embedInputs().filter { $0 == "users" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "orders" }.count == 1)
        #expect(transport.embedInputs().filter { $0 == "customer" }.count == 2)
    }

    @MainActor
    @Test func filtersOutEmbeddingsForNamesNoLongerInTheSchema() async {
        let store = makeStore()
        let profileID = UUID()
        var close = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        close[0] = 1
        // "old_customers" was embedded in a previous session but the table
        // has since been dropped/renamed — it must never resurface.
        try! store.saveSchemaObjectEmbedding(profileID: profileID, name: "old_customers", vector: close)
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
