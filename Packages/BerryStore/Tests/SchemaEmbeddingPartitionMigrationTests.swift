import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("v35 partitions the name vectors by connection")
struct SchemaEmbeddingPartitionMigrationTests {
    let first = UUID()
    let second = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    private func vector(tilt: Float) -> [Float] {
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        values[1] = tilt
        return values
    }

    private func blob(tilt: Float) -> Data {
        vector(tilt: tilt).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A v34 store the way a build before this migration left it: unpartitioned
    /// vectors for two connections, and current objects whose queue flag the
    /// copy from the earlier graph left cleared whether or not they have one.
    private func seededQueue() throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(configuration: configuration)
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let store = BerryStore(dbQueue: queue)
        for (profile, names) in [
            (first, ["orders", "customers", "reports#2024"]),
            // "audit_log" has a vector, but only the first connection's.
            (second, ["orders", "customers", "audit_log"]),
        ] {
            _ = try store.applySchemaListing(profileID: profile, objects: names.map {
                SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: "f")
            }, relations: nil, now: now)
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE schema_object SET needsEmbedding = 0")
            for (profile, name, tilt) in [
                (first, "orders", Float(0.5)), (first, "audit_log", 4), (first, "reports#2024", 2), (second, "orders", 1),
            ] {
                try db.execute(
                    sql: "INSERT INTO schema_object_embedding(objectKey, embedding) VALUES (?, ?)",
                    arguments: ["\(profile.uuidString)#\(name)", blob(tilt: tilt)]
                )
            }
        }
        return queue
    }

    @Test func everyVectorSurvivesUnderItsConnection() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue)

        let rows = try queue.read {
            try Row.fetchAll($0, sql: "SELECT objectKey, profileID FROM schema_object_embedding")
                .map { "\($0["objectKey"] as String)=\($0["profileID"] as String)" }
        }
        #expect(Set(rows) == [
            "\(first.uuidString)#audit_log=\(first.uuidString)",
            "\(first.uuidString)#orders=\(first.uuidString)",
            "\(first.uuidString)#reports#2024=\(first.uuidString)",
            "\(second.uuidString)#orders=\(second.uuidString)",
        ])
        #expect(rows.count == 4)
        let tables = try queue.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'schema_object_embedding%' ORDER BY name")
        }
        #expect(!tables.contains { $0.hasPrefix("schema_object_embedding_v2") }, "the scratch table must not outlive the migration: \(tables)")
    }

    @Test func theCopiedVectorsAreStillSearchablePerConnection() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue)
        let store = BerryStore(dbQueue: queue)
        let query = vector(tilt: 0)

        #expect(try store.nearestSchemaObjects(profileID: first, to: query, limit: 8).map(\.name) == ["orders", "reports#2024", "audit_log"])
        #expect(try store.nearestSchemaObjects(profileID: second, to: query, limit: 8).map(\.name) == ["orders"])
    }

    /// The earlier copy cleared the flag on every migrated object, and a
    /// search embeds only a bounded number of names itself, so an object
    /// without a vector might otherwise never get one.
    @Test func currentObjectsWithoutAVectorAreQueuedForEmbedding() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue)
        let store = BerryStore(dbQueue: queue)

        // The first connection's vector for "audit_log" does not count for the
        // second connection's object of that name.
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: first, limit: 10).map(\.name) == ["customers"])
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: second, limit: 10).map(\.name) == ["customers", "audit_log"])
    }

    /// A closed row always has its flag cleared, and the queue reads skip it
    /// either way, so the stored flag itself is what has to stay clear.
    @Test func aRemovedObjectKeepsItsFlagCleared() throws {
        let queue = try seededQueue()
        let store = BerryStore(dbQueue: queue)
        try queue.write { db in
            try db.execute(
                sql: "UPDATE schema_object SET removedAt = ? WHERE profileID = ? AND name = 'customers'",
                arguments: [now.addingTimeInterval(60), first]
            )
        }
        try BerryStore.migrator.migrate(queue)

        let flagged = try queue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM schema_object WHERE removedAt IS NOT NULL AND needsEmbedding = 1")
        }
        #expect(flagged == 0)
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: first, limit: 10).isEmpty)
    }
}
