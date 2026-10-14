import Foundation
import GRDB
import Testing
@testable import BerryStore

extension BerryStore {
    /// Gives `name` a vector the way a drain does, through
    /// `storeSchemaEmbedding` on a current object of that name, inserted
    /// first when the profile has none.
    func embed(_ name: String, profileID: UUID, vector: [Float]) throws {
        let id = try write { db -> Int64 in
            if let id = try Int64.fetchOne(
                db, sql: "SELECT id FROM schema_object WHERE profileID = ? AND name = ? AND removedAt IS NULL",
                arguments: [profileID, name]
            ) {
                return id
            }
            var row = SchemaObjectRecord(
                profileID: profileID, database: nil, name: name, kind: "table", firstSeen: Date(), needsEmbedding: true
            )
            try row.insert(db)
            return db.lastInsertedRowID
        }
        _ = try storeSchemaEmbedding(id: id, profileID: profileID, name: name, vector: vector)
    }
}

@Suite("Semantic Database Search sqlite-vec store")
struct SchemaObjectEmbeddingTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func rejectsAnEmbeddingWithTheWrongDimension() throws {
        let store = try makeStore()
        #expect(throws: (any Error).self) {
            try store.embed("users", profileID: UUID(), vector: [0.1, 0.2])
        }
    }

    /// Verified against sqlite-vec 0.1.9: a `PARTITION KEY` column is accepted
    /// by `vec0` and a KNN query constrained on it only sees that partition's
    /// vectors (https://alexgarcia.xyz/sqlite-vec/features/vec0.html#partition-keys).
    @Test func vec0AcceptsAPartitionKeyAndFiltersTheKNNQueryByIt() throws {
        let store = try makeStore()
        func blob(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }
        let nearestKey = try store.write { db -> String? in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE probe USING vec0(
                    objectKey TEXT PRIMARY KEY, profileID TEXT PARTITION KEY, embedding FLOAT[4])
                """)
            let rows: [(String, String, [Float])] = [
                ("a#near", "a", [1, 0, 0, 0]),
                ("b#far", "b", [-1, 0, 0, 0]),
            ]
            for (key, profile, vector) in rows {
                try db.execute(
                    sql: "INSERT INTO probe(objectKey, profileID, embedding) VALUES (?, ?, ?)",
                    arguments: [key, profile, blob(vector)]
                )
            }
            return try String.fetchOne(
                db, sql: "SELECT objectKey FROM probe WHERE embedding MATCH ? AND k = 1 AND profileID = ?",
                arguments: [blob([1, 0, 0, 0]), "b"]
            )
        }
        #expect(nearestKey == "b#far")
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

        try store.embed("users", profileID: profileA, vector: near)
        try store.embed("audit_log", profileID: profileA, vector: far)
        // Same vector as profileA's "users", but scoped to profileB — must not leak in.
        try store.embed("customers", profileID: profileB, vector: close)

        let results = try store.nearestSchemaObjects(profileID: profileA, to: close, limit: 8)

        #expect(results.map(\.name) == ["users", "audit_log"])
        #expect(results[0].distance < results[1].distance)
    }

    /// A vector near the query along the first axis, tilted by `tilt` on the
    /// second so each one ranks differently.
    private func vector(tilt: Float) -> [Float] {
        var v = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        v[0] = 1
        v[1] = tilt
        return v
    }

    /// A search that takes the nearest vectors across every connection first
    /// and keeps this connection's afterwards finds nothing here: the large
    /// connection's 300 vectors, all nearer the query, fill the first 256.
    @Test func aSmallConnectionNextToALargeOneStillFindsItsNearestName() throws {
        let store = try makeStore()
        let large = UUID()
        let small = UUID()
        for index in 0..<300 {
            try store.embed("large_\(index)", profileID: large, vector: vector(tilt: Float(index) * 0.0001)
            )
        }
        try store.embed("orders", profileID: small, vector: vector(tilt: 0.5))
        try store.embed("invoices", profileID: small, vector: vector(tilt: 1))
        try store.embed("audit_log", profileID: small, vector: vector(tilt: 4))

        let results = try store.nearestSchemaObjects(profileID: small, to: vector(tilt: 0), limit: 8)

        #expect(results.map(\.name) == ["orders", "invoices", "audit_log"])
        #expect(try store.nearestSchemaObjects(profileID: large, to: vector(tilt: 0), limit: 2).map(\.name) == ["large_0", "large_1"])
    }

    /// A dropped and re-created table is embedded again under the same key, and
    /// vec0 rejects `INSERT OR REPLACE` on an existing key (verified against
    /// sqlite-vec 0.1.9), so storing has to remove the old vector itself.
    @Test func savingANameAgainReplacesItsVector() throws {
        let store = try makeStore()
        let profile = UUID()
        try store.embed("users", profileID: profile, vector: vector(tilt: 4))
        try store.embed("users", profileID: profile, vector: vector(tilt: 0))

        let results = try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8)

        #expect(results.map(\.name) == ["users"])
        #expect(results[0].distance == 0)
    }

    private func listing(_ store: BerryStore, profile: UUID, names: [String], at time: Date) throws {
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: names.map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: "f") },
            relations: nil, now: time
        )
    }

    @Test func storingForACurrentObjectSavesTheVectorAndClearsItsQueueFlag() throws {
        let store = try makeStore()
        let profile = UUID()
        try listing(store, profile: profile, names: ["users"], at: Date(timeIntervalSince1970: 1_000))
        let queued = try #require(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).first)

        let stored = try store.storeSchemaEmbedding(
            id: try #require(queued.id), profileID: profile, name: "users", vector: vector(tilt: 0)
        )

        #expect(stored)
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).isEmpty)
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8).map(\.name) == ["users"])
    }

    /// A drain reads the queue, then waits on the provider; the object can be
    /// removed in between, and writing its vector then would leave one behind
    /// that nothing deletes.
    @Test func storingForARemovedObjectWritesNothing() throws {
        let store = try makeStore()
        let profile = UUID()
        try listing(store, profile: profile, names: ["users"], at: Date(timeIntervalSince1970: 1_000))
        let queued = try #require(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).first)
        try listing(store, profile: profile, names: [], at: Date(timeIntervalSince1970: 2_000))

        let stored = try store.storeSchemaEmbedding(
            id: try #require(queued.id), profileID: profile, name: "users", vector: vector(tilt: 0)
        )

        #expect(!stored)
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8).isEmpty)
    }

    @Test func storingAgainForTheSameObjectReplacesItsVector() throws {
        let store = try makeStore()
        let profile = UUID()
        try listing(store, profile: profile, names: ["users"], at: Date(timeIntervalSince1970: 1_000))
        let id = try #require(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).first?.id)
        _ = try store.storeSchemaEmbedding(id: id, profileID: profile, name: "users", vector: vector(tilt: 4))
        _ = try store.storeSchemaEmbedding(id: id, profileID: profile, name: "users", vector: vector(tilt: 0))

        let results = try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8)

        #expect(results.map(\.name) == ["users"])
        #expect(results[0].distance == 0)
    }

    @Test func storingRejectsAVectorOfTheWrongDimension() throws {
        let store = try makeStore()
        let profile = UUID()
        try listing(store, profile: profile, names: ["users"], at: Date(timeIntervalSince1970: 1_000))
        let id = try #require(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).first?.id)

        #expect(throws: (any Error).self) {
            try store.storeSchemaEmbedding(id: id, profileID: profile, name: "users", vector: [0.1, 0.2])
        }
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).count == 1)
    }

    /// vec0 refuses a `k` above 4096 (verified against sqlite-vec 0.1.9), and a
    /// non-positive limit has nothing to return.
    @Test func theNumberOfNeighboursIsClampedToWhatVec0Accepts() throws {
        let store = try makeStore()
        let profile = UUID()
        try store.embed("users", profileID: profile, vector: vector(tilt: 0))

        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 100_000).map(\.name) == ["users"])
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 0).isEmpty)
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: -3).isEmpty)
    }

    @Test func aHashInAnObjectNameSurvivesTheKeyRoundTrip() throws {
        let store = try makeStore()
        let profile = UUID()
        try store.embed("orders#2024#q1", profileID: profile, vector: vector(tilt: 0))

        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8).map(\.name) == ["orders#2024#q1"])
        try store.deleteProfile(id: profile)
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 8).isEmpty)
    }

    /// The names a search must still embed: those without a vector in the
    /// profile's partition, in the order given, at most `limit`. Another
    /// profile's vector for the same name does not count.
    @Test func namesWithoutAVectorAreListedInOrderUpToTheLimit() throws {
        let store = try makeStore()
        let profile = UUID()
        try store.storeSchemaNameEmbedding(profileID: profile, name: "orders", vector: vector(tilt: 0))
        try store.storeSchemaNameEmbedding(profileID: UUID(), name: "users", vector: vector(tilt: 0))

        let names = ["users", "orders", "audit_log", "o'brien#1", "items"]
        #expect(try store.schemaNamesWithoutEmbedding(profileID: profile, among: names, limit: 10)
            == ["users", "audit_log", "o'brien#1", "items"])
        #expect(try store.schemaNamesWithoutEmbedding(profileID: profile, among: names, limit: 2) == ["users", "audit_log"])
        #expect(try store.schemaNamesWithoutEmbedding(profileID: profile, among: [], limit: 2).isEmpty)
    }

    /// The check is one lookup per name in the unique index on vec0's key
    /// shadow table, never a read of the vectors.
    @Test func theNameCheckSeeksTheKeyIndexOfTheShadowTable() throws {
        let store = try makeStore()
        let plan = try #require(store.dbQueue).read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT value FROM json_each('["a"]')
                WHERE NOT EXISTS (SELECT 1 FROM schema_object_embedding_rowids WHERE id = 'p#' || value)
                """).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("schema_object_embedding_rowids USING COVERING INDEX") && $0.contains("(id=?)") }, "\(plan)")
    }

    /// A name a search embedded leaves the queue on every current object of
    /// that name, and only on those of its profile.
    @Test func storingANameClearsTheQueueFlagOfItsObjects() throws {
        let store = try makeStore()
        let profile = UUID()
        let other = UUID()
        for id in [profile, other] {
            _ = try store.applySchemaListing(profileID: id, objects: [
                SchemaListedObject(database: "a", name: "orders", kind: "table", fingerprint: nil),
                SchemaListedObject(database: "b", name: "orders", kind: "table", fingerprint: nil),
                SchemaListedObject(database: "a", name: "users", kind: "table", fingerprint: nil),
            ], relations: nil, now: Date())
        }

        try store.storeSchemaNameEmbedding(profileID: profile, name: "orders", vector: vector(tilt: 0))

        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).map(\.name) == ["users"])
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: other, limit: 10).count == 3)
        #expect(try store.nearestSchemaObjects(profileID: profile, to: vector(tilt: 0), limit: 4).map(\.name) == ["orders"])
    }
}
