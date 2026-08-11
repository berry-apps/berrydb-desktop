import Foundation
import Testing
@testable import BerryStore

@Suite("Semantic Database Search sqlite-vec store (docs/feature/07 §13)")
struct SchemaObjectEmbeddingTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func rejectsAnEmbeddingWithTheWrongDimension() throws {
        let store = try makeStore()
        #expect(throws: (any Error).self) {
            try store.saveSchemaObjectEmbedding(profileID: UUID(), name: "users", vector: [0.1, 0.2])
        }
    }

    @Test func missingEmbeddingsAreRestrictedToTheGivenCandidateNames() throws {
        let store = try makeStore()
        let profileID = UUID()
        let vector = Array(repeating: Float(0.1), count: BerryStore.schemaObjectEmbeddingDimension)
        try store.saveSchemaObjectEmbedding(profileID: profileID, name: "users", vector: vector)

        let missing = try store.schemaObjectNamesMissingEmbeddings(
            profileID: profileID, candidateNames: ["users", "orders", "audit_log"]
        )
        #expect(missing == ["orders", "audit_log"])
    }

    /// The actual proof that the vendored sqlite-vec extension is wired up
    /// and functioning at runtime for this table (not just compiling) —
    /// creates real embeddings, and confirms the vec0 KNN query ranks the
    /// closer vector first and correctly isolates by profile.
    @Test func nearestSchemaObjectsRanksByCosineDistanceAndIsolatesByProfile() throws {
        let store = try makeStore()
        let profileA = UUID()
        let profileB = UUID()

        var close = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        close[0] = 1.0
        var near = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        near[0] = 0.9
        near[1] = 0.1
        var far = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        far[0] = -1.0

        try store.saveSchemaObjectEmbedding(profileID: profileA, name: "users", vector: near)
        try store.saveSchemaObjectEmbedding(profileID: profileA, name: "audit_log", vector: far)
        // Same vector as profileA's "users", but scoped to profileB — must not leak in.
        try store.saveSchemaObjectEmbedding(profileID: profileB, name: "customers", vector: close)

        let results = try store.nearestSchemaObjects(profileID: profileA, to: close, limit: 8)

        #expect(results.map(\.name) == ["users", "audit_log"])
        #expect(results[0].distance < results[1].distance)
    }
}
