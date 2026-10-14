import Foundation
import GRDB
import Testing

@testable import BerryStore

/// Earlier definitions of the schema graph migrations were applied to a
/// development store under the identifiers `v31-schema-object-versions`,
/// `v32-schema-embedding-partition` and `v33-drop-legacy-graph-tables`. The
/// current definitions are registered under new identifiers, and a store
/// that recorded the old ones drops what they created and runs the new ones.
@Suite("Withdrawn schema graph migrations")
struct SupersededSchemaGraphMigrationTests {
    let profile = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)

    static let withdrawn = ["v31-schema-object-versions", "v32-schema-embedding-partition", "v33-drop-legacy-graph-tables"]
    static let current = ["v34-schema-object-versions", "v35-schema-embedding-partition", "v36-drop-per-node-graph-tables"]

    /// The tables and indexes the earlier `v31-schema-object-versions`
    /// created: a text definition and one `searchText` column, with none of
    /// the folded-name, column-name, index-name or replaced columns.
    static let earlyObjectVersionSchema = [
        """
        CREATE TABLE "schema_object" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "profileID" BLOB NOT NULL,
            "database" TEXT NOT NULL DEFAULT '', "name" TEXT NOT NULL, "kind" TEXT NOT NULL, "fingerprint" TEXT,
            "definitionHash" TEXT, "definition" TEXT, "searchText" TEXT NOT NULL, "firstSeen" DATETIME NOT NULL,
            "removedAt" DATETIME, "previousID" INTEGER, "changeID" INTEGER, "removedByChangeID" INTEGER,
            "needsEmbedding" BOOLEAN NOT NULL DEFAULT 0, "embeddingAttempts" INTEGER NOT NULL DEFAULT 0)
        """,
        "CREATE UNIQUE INDEX schema_object_current ON schema_object (profileID, database, name, kind) WHERE removedAt IS NULL",
        "CREATE INDEX schema_object_history ON schema_object (profileID, removedAt, firstSeen)",
        "CREATE INDEX schema_object_embedding_queue ON schema_object (profileID) WHERE needsEmbedding = 1",
        "CREATE INDEX schema_object_change ON schema_object (profileID, changeID)",
        "CREATE INDEX schema_object_removed_change ON schema_object (profileID, removedByChangeID)",
        """
        CREATE TABLE "schema_relation" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "profileID" BLOB NOT NULL,
            "srcDatabase" TEXT NOT NULL DEFAULT '', "srcName" TEXT NOT NULL, "srcColumn" TEXT NOT NULL,
            "dstDatabase" TEXT NOT NULL DEFAULT '', "dstName" TEXT NOT NULL, "dstColumn" TEXT NOT NULL,
            "constraintName" TEXT, "firstSeen" DATETIME NOT NULL, "removedAt" DATETIME, "changeID" INTEGER,
            "removedByChangeID" INTEGER)
        """,
        """
        CREATE UNIQUE INDEX schema_relation_current
            ON schema_relation (profileID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn)
            WHERE removedAt IS NULL
        """,
        "CREATE INDEX schema_relation_history ON schema_relation (profileID, removedAt)",
        "CREATE INDEX schema_relation_change ON schema_relation (profileID, changeID)",
        "CREATE INDEX schema_relation_removed_change ON schema_relation (profileID, removedByChangeID)",
        """
        CREATE TABLE "schema_stats" ("profileID" BLOB NOT NULL, "database" TEXT NOT NULL DEFAULT '',
            "name" TEXT NOT NULL, "rows" INTEGER, "sizeBytes" INTEGER, "seqScan" INTEGER, "idxScan" INTEGER,
            "indexStats" TEXT, "updatedAt" DATETIME NOT NULL, PRIMARY KEY ("profileID", "database", "name"))
        """,
        """
        CREATE TABLE "schema_change" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "profileID" BLOB NOT NULL,
            "at" DATETIME NOT NULL, "added" INTEGER NOT NULL DEFAULT 0, "changed" INTEGER NOT NULL DEFAULT 0,
            "removed" INTEGER NOT NULL DEFAULT 0, "relationsAdded" INTEGER NOT NULL DEFAULT 0,
            "relationsRemoved" INTEGER NOT NULL DEFAULT 0)
        """,
        "CREATE INDEX schema_change_profile ON schema_change (profileID, at)",
        """
        CREATE TABLE "schema_graph_state" ("profileID" BLOB PRIMARY KEY NOT NULL, "versionToken" TEXT,
            "lastCheckedAt" DATETIME, "lastChangedAt" DATETIME, "selectedSchemas" TEXT,
            "objectCount" INTEGER NOT NULL DEFAULT 0, "detailedCount" INTEGER NOT NULL DEFAULT 0,
            "lastErrorCode" TEXT, "lastErrorAt" DATETIME, "retryAfter" DATETIME, "hint" TEXT)
        """,
    ]

    /// The vector table the earlier `v32-schema-embedding-partition` rebuilt
    /// in place of the one `v22-schema-object-embedding` created.
    static let earlyPartitionedEmbeddingSchema = [
        "DROP TABLE schema_object_embedding",
        """
        CREATE VIRTUAL TABLE schema_object_embedding USING vec0(
            objectKey TEXT PRIMARY KEY, profileID TEXT PARTITION KEY, embedding FLOAT[1536], chunk_size=64
        )
        """,
    ]

    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        return configuration
    }

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
    }

    private func removeStore(at path: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func vector(tilt: Float) -> Data {
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        values[1] = tilt
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A store migrated by this build up to `v30-mcp-project`, with one saved
    /// connection and the per-node graph of one table.
    private func makeV30Store(at path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        try BerryStore.migrator.migrate(queue, upTo: "v30-mcp-project")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO connection_profile (id, driverID, name, createdAt) VALUES (?, 'postgres', 'Shop', ?)",
                arguments: [profile, t1]
            )
            try db.execute(
                sql: """
                    INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen)
                    VALUES (?, 'table:shop.orders', 'table', 'orders', 'shop', '{}', ?, ?),
                           (?, 'column:shop.orders.id', 'column', 'id', 'shop', '{"type":"int"}', ?, ?)
                    """,
                arguments: [profile, t1, t2, profile, t1, t2]
            )
            try db.execute(
                sql: """
                    INSERT INTO graph_edge (profileID, src, dst, kind, weight, attrs, firstSeen, lastSeen)
                    VALUES (?, 'table:shop.orders', 'column:shop.orders.id', 'hasColumn', 1, '{}', ?, ?)
                    """,
                arguments: [profile, t1, t2]
            )
            try db.execute(
                sql: "INSERT INTO graph_snapshot (id, profileID, takenAt, nodeCount, edgeCount, digest) VALUES (?, ?, ?, 2, 1, 'd')",
                arguments: [UUID(), profile, t2]
            )
            try db.execute(
                sql: "INSERT INTO schema_object_embedding (objectKey, embedding) VALUES (?, ?)",
                arguments: ["\(profile.uuidString)#orders", vector(tilt: 0)]
            )
        }
        return queue
    }

    /// A store as a development build that ran the earlier definitions left
    /// it: the early object version tables with rows in them, the early
    /// partitioned vector table with a vector, no per-node graph tables, and
    /// the three withdrawn identifiers recorded. `withdrawn` says how many of
    /// them it ran, in order.
    private func makeStoreThatRanTheEarlyDefinitions(at path: String, withdrawn: Int = 3) throws {
        let queue = try makeV30Store(at: path)
        try queue.write { db in
            for sql in Self.earlyObjectVersionSchema { try db.execute(sql: sql) }
            try db.execute(
                sql: """
                    INSERT INTO schema_object (profileID, database, name, kind, definition, searchText, firstSeen)
                    VALUES (?, 'shop', 'orders', 'table', '{"columns":[],"indexes":[]}', 'orders', ?)
                    """,
                arguments: [profile, t1]
            )
            try db.execute(
                sql: """
                    INSERT INTO schema_relation (profileID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn, firstSeen)
                    VALUES (?, 'shop', 'orders', 'customer_id', 'shop', 'customers', 'id', ?)
                    """,
                arguments: [profile, t1]
            )
            try db.execute(sql: "INSERT INTO schema_change (profileID, at, added) VALUES (?, ?, 1)", arguments: [profile, t1])
            try db.execute(
                sql: "INSERT INTO schema_graph_state (profileID, objectCount, detailedCount) VALUES (?, 1, 1)",
                arguments: [profile]
            )
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [Self.withdrawn[0]])
            guard withdrawn > 1 else { return }
            for sql in Self.earlyPartitionedEmbeddingSchema { try db.execute(sql: sql) }
            try db.execute(
                sql: "INSERT INTO schema_object_embedding (objectKey, profileID, embedding) VALUES (?, ?, ?)",
                arguments: ["\(profile.uuidString)#orders", profile.uuidString, vector(tilt: 0)]
            )
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [Self.withdrawn[1]])
            guard withdrawn > 2 else { return }
            for table in ["graph_edge", "graph_node", "graph_snapshot"] { try db.execute(sql: "DROP TABLE \(table)") }
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [Self.withdrawn[2]])
        }
    }

    private func inspect<T>(_ path: String, _ body: (Database) throws -> T) throws -> T {
        try DatabaseQueue(path: path, configuration: Self.configuration).read(body)
    }

    @Test func aStoreThatRanTheEarlyDefinitionsOpensWithTheCurrentTables() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheEarlyDefinitions(at: path)

        let store = try BerryStore(path: path)

        let applied = try inspect(path) { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == Set(BerryStore.migrator.migrations))
        #expect(applied.isSuperset(of: Self.current))
        #expect(applied.isDisjoint(with: Self.withdrawn))
        let columns = try inspect(path) { try Set($0.columns(in: "schema_object").map(\.name)) }
        #expect(columns.isSuperset(of: ["searchName", "columnText", "indexText", "replaced"]))
        #expect(!columns.contains("searchText"))
        let definitionType = try inspect(path) {
            try $0.columns(in: "schema_object").first { $0.name == "definition" }?.type
        }
        #expect(definitionType == "BLOB")
        let left = try inspect(path) { db in
            (
                objects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_object"),
                relations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_relation"),
                changes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_change"),
                states: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_graph_state"),
                vectors: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_object_embedding"),
                graphTables: try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('graph_node', 'graph_edge', 'graph_snapshot')"
                )
            )
        }
        #expect(left.objects == 0 && left.relations == 0 && left.changes == 0 && left.states == 0)
        #expect(left.vectors == 0 && left.graphTables == 0)
        #expect(try store.allProfiles().map(\.id) == [profile])

        // A listing write, a name search and a vector write and search work on
        // the rebuilt tables.
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "orders", kind: "table", fingerprint: "f"),
        ], relations: [], now: t2)
        #expect(try store.searchSchemaObjectNames(profileID: profile, needle: "ORD", limit: 10).map(\.name) == ["orders"])
        let queued = try #require(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).first)
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        #expect(try store.storeSchemaEmbedding(id: queued.id, profileID: profile, name: "orders", vector: values))
        #expect(try store.nearestSchemaObjects(profileID: profile, to: values, limit: 4).map(\.name) == ["orders"])
    }

    /// A store that ran only the earlier object version migration still has
    /// the per-node graph, so the current copy reads it.
    @Test func aStoreThatRanOnlyTheEarlyObjectVersionsCopiesTheGraphAgain() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheEarlyDefinitions(at: path, withdrawn: 1)

        let store = try BerryStore(path: path)

        let objects = try store.currentSchemaObjects(profileID: profile)
        #expect(objects.map(\.name) == ["orders"])
        #expect(objects.first?.columnText == "id")
        // The vector table is still the one v22 created, so its vector is
        // partitioned and kept.
        var query = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        query[0] = 1
        #expect(try store.nearestSchemaObjects(profileID: profile, to: query, limit: 4).map(\.name) == ["orders"])
        let graphTables = try inspect(path) {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('graph_node', 'graph_edge', 'graph_snapshot')")
        }
        #expect(graphTables == 0)
        let applied = try inspect(path) { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == Set(BerryStore.migrator.migrations))
        #expect(applied.isDisjoint(with: Self.withdrawn))
    }

    /// A store that ran the earlier object versions and vector partition but
    /// not the drop copies the graph again; its vectors were dropped with the
    /// earlier vector table, so every copied name is queued for embedding.
    @Test func aStoreThatKeptTheGraphQueuesTheCopiedNamesForEmbedding() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheEarlyDefinitions(at: path, withdrawn: 2)

        let store = try BerryStore(path: path)

        #expect(try store.currentSchemaObjects(profileID: profile).map(\.name) == ["orders"])
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).map(\.name) == ["orders"])
        let applied = try inspect(path) { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == Set(BerryStore.migrator.migrations))
    }

    /// sqlite-vec is installed per connection, and a connection without it
    /// cannot drop a vec0 table, so the withdrawal must run on a connection
    /// `init(path:)` prepared.
    @Test func theEarlyVectorTableIsDroppedOnAConnectionWithTheExtension() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheEarlyDefinitions(at: path)
        do {
            let plain = try DatabaseQueue(path: path)
            #expect(throws: DatabaseError.self) {
                try plain.write { try $0.execute(sql: "DROP TABLE schema_object_embedding") }
            }
        }

        _ = try BerryStore(path: path)

        let vectors = try inspect(path) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM schema_object_embedding_rowids") }
        #expect(vectors == 0)
    }

    @Test func theHelperRefusesTheStoreUntilTheAppHasMigratedIt() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheEarlyDefinitions(at: path)

        #expect(throws: BerryStore.ReadOnlyOpenError.self) { _ = try BerryStore.openReadOnly(path: path) }
        _ = try BerryStore(path: path)
        let helper = try BerryStore.openReadOnly(path: path)
        #expect(try helper.allProfiles().map(\.id) == [profile])
    }

    /// A store this build's predecessors left at `v30-mcp-project` is migrated
    /// as before: the per-node graph is copied, the vectors are partitioned
    /// by connection, and the graph tables are dropped.
    @Test func aStoreAtV30CopiesPartitionsAndDropsAsBefore() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        _ = try makeV30Store(at: path)

        let store = try BerryStore(path: path)

        let applied = try inspect(path) { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied.isSuperset(of: Self.current))
        #expect(applied.isDisjoint(with: Self.withdrawn))
        let objects = try store.currentSchemaObjects(profileID: profile)
        #expect(objects.map(\.name) == ["orders"])
        #expect(objects.first?.columnText == "id")
        var query = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        query[0] = 1
        #expect(try store.nearestSchemaObjects(profileID: profile, to: query, limit: 4).map(\.name) == ["orders"])
        let partitioned = try inspect(path) {
            try String.fetchOne($0, sql: "SELECT sql FROM sqlite_master WHERE name = 'schema_object_embedding'")
        }
        #expect(partitioned?.contains("PARTITION KEY") == true)
        let graphTables = try inspect(path) {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('graph_node', 'graph_edge', 'graph_snapshot')")
        }
        #expect(graphTables == 0)
    }
}
