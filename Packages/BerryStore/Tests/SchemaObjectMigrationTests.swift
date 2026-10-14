import BerryDriverKit
import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("v34 copies the v7 graph into per-table versions")
struct SchemaObjectMigrationTests {
    let profile = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)
    let t3 = Date(timeIntervalSince1970: 3_000)

    /// A v30 store with: orders (seen t1..t3, columns id + total, index
    /// orders_pkey), customers (seen t1..t3, column id), recent (a view seen
    /// t1..t3 with no columns), legacy (seen t1..t2 = dropped, no columns),
    /// orders -> customers reference, snapshots at t1, t2, t3.
    func seededQueue() throws -> DatabaseQueue {
        // An earlier migration creates a vec0 table, so the connection needs the
        // extension installed the way BerryStore installs it.
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(configuration: configuration)
        try BerryStore.migrator.migrate(queue, upTo: "v30-mcp-project")
        try queue.write { db in
            try savedProfile(db, profile)
            try node(db, "table:shop.orders", "table", "orders", "{}", t1, t3)
            try node(db, "table:shop.customers", "table", "customers", "{}", t1, t3)
            try node(db, "table:shop.legacy", "table", "legacy", "{}", t1, t2)
            try node(db, "view:shop.recent", "view", "recent", "{}", t1, t3)
            try node(db, "column:shop.customers.id", "column", "id", #"{"type":"int","nullable":"false","primaryKey":"true"}"#, t1, t3)
            try node(db, "column:shop.orders.id", "column", "id", #"{"type":"int","nullable":"false","primaryKey":"true"}"#, t1, t3)
            try node(db, "column:shop.orders.total", "column", "total", #"{"type":"numeric","nullable":"true","primaryKey":"false"}"#, t2, t3)
            try node(db, "index:shop.orders.orders_pkey", "index", "orders_pkey", #"{"unique":"true","columns":"id"}"#, t1, t3)
            try edge(db, "table:shop.orders", "column:shop.orders.id", "hasColumn", t1, t3)
            try edge(db, "table:shop.customers", "column:shop.customers.id", "hasColumn", t1, t3)
            try edge(db, "table:shop.orders", "column:shop.orders.total", "hasColumn", t2, t3)
            try edge(db, "table:shop.orders", "index:shop.orders.orders_pkey", "hasIndex", t1, t3)
            try edge(db, "table:shop.orders", "table:shop.customers", "references", t1, t3)
            for (at, count) in [(t1, 5), (t2, 6), (t3, 5)] {
                try db.execute(
                    sql: "INSERT INTO graph_snapshot (id, profileID, takenAt, nodeCount, edgeCount, digest) VALUES (?, ?, ?, ?, 4, ?)",
                    arguments: [UUID(), profile, at, count, "d\(count)"]
                )
            }
        }
        return queue
    }

    /// The profile row a saved connection has, its id stored as GRDB stores
    /// a UUID.
    private func savedProfile(_ db: Database, _ id: UUID) throws {
        try db.execute(
            sql: "INSERT INTO connection_profile (id, driverID, name, createdAt) VALUES (?, 'postgres', 'Shop', ?)",
            arguments: [id, t1]
        )
    }

    private func node(_ db: Database, _ id: String, _ kind: String, _ name: String, _ attrs: String, _ first: Date, _ last: Date) throws {
        try db.execute(
            sql: "INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen) VALUES (?, ?, ?, ?, 'shop', ?, ?, ?)",
            arguments: [profile, id, kind, name, attrs, first, last]
        )
    }

    private func edge(_ db: Database, _ src: String, _ dst: String, _ kind: String, _ first: Date, _ last: Date) throws {
        try db.execute(
            sql: "INSERT INTO graph_edge (profileID, src, dst, kind, weight, attrs, firstSeen, lastSeen) VALUES (?, ?, ?, ?, 1, '{}', ?, ?)",
            arguments: [profile, src, dst, kind, first, last]
        )
    }

    /// Before deleting a profile removed its graph, a deleted connection's
    /// graph rows stayed behind. Copied, they would be rows no profile
    /// deletion reaches, queued for embedding, so only the graphs of saved
    /// profiles are copied.
    @Test func aGraphOfADeletedProfileIsNotCopied() throws {
        let queue = try seededQueue()
        let deleted = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen)
                    VALUES (?, 'table:shop.gone', 'table', 'gone', 'shop', '{}', ?, ?)
                    """,
                arguments: [deleted, t1, t3]
            )
            try db.execute(
                sql: "INSERT INTO graph_snapshot (id, profileID, takenAt, nodeCount, edgeCount, digest) VALUES (?, ?, ?, 1, 0, 'g')",
                arguments: [UUID(), deleted, t3]
            )
        }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let copied = try queue.read { db in
            (
                objects: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_object WHERE profileID = ?", arguments: [deleted]),
                states: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_graph_state WHERE profileID = ?", arguments: [deleted]),
                changes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_change WHERE profileID = ?", arguments: [deleted]),
                kept: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_object WHERE profileID = ?", arguments: [profile])
            )
        }
        #expect(copied.objects == 0 && copied.states == 0 && copied.changes == 0)
        #expect(copied.kept == 4)
    }

    @Test func currentTablesBecomeOneVersionEachWithFoldedDefinition() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let rows = try queue.read { try SchemaObjectRecord.filter(Column("removedAt") == nil).order(Column("name")).fetchAll($0) }
        #expect(rows.map(\.name) == ["customers", "orders", "recent"])
        let orders = try #require(rows.first { $0.name == "orders" })
        #expect(orders.firstSeen == t1)
        #expect(orders.fingerprint == nil)
        #expect(orders.definition == #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"},{"name":"total","nullable":true,"primaryKey":false,"type":"numeric"}],"indexes":[{"columns":["id"],"name":"orders_pkey","unique":true}]}"#)
        #expect(orders.definitionHash?.count == 16)
        #expect(orders.columnText == "id\ntotal" && orders.indexText == "orders_pkey")
        #expect(orders.needsEmbedding == false)
        let customers = try #require(rows.first { $0.name == "customers" })
        #expect(customers.definition == #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"}],"indexes":[]}"#)
    }

    /// The copy stores definitions in the same compressed form a harvest
    /// writes, so a migrated row takes no more room than a harvested one.
    @Test func copiedDefinitionsAreStoredCompressed() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let stored = try queue.read {
            try String.fetchAll($0, sql: "SELECT DISTINCT typeof(definition) FROM schema_object WHERE definition IS NOT NULL")
        }
        #expect(stored == ["blob"])
    }

    /// The copy folds a name the way a harvest does, so a migrated table is
    /// found by a needle written in another case, including the folds that
    /// lower-casing misses.
    @Test func copiedNamesAreFoldedForSearch() throws {
        let queue = try seededQueue()
        try queue.write { db in try node(db, "table:shop.Straße_ﬁle", "table", "Straße_ﬁle", "{}", t1, t3) }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let store = BerryStore(dbQueue: queue)
        #expect(try store.searchSchemaObjectNames(profileID: profile, needle: "STRASSE_FILE", limit: 10).map(\.name) == ["Straße_ﬁle"])
        #expect(try store.schemaSearchTextContains(profileID: profile, needle: "strasse_file"))
    }

    @Test func nodesWithoutColumnsAreMigratedAsPending() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let recent = try queue.read { try SchemaObjectRecord.filter(Column("name") == "recent").fetchOne($0) }
        #expect(recent?.kind == "view")
        #expect(recent?.definition == nil)
        #expect(recent?.definitionHash == nil)
        #expect(recent?.columnText == "" && recent?.indexText == "")
        #expect(recent?.removedAt == nil)
    }

    @Test func droppedTablesAreClosedAtTheNextHarvest() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let legacy = try queue.read { try SchemaObjectRecord.filter(Column("name") == "legacy").fetchOne($0) }
        #expect(legacy?.removedAt == t3)
    }

    @Test func aTableSeenInOneHarvestIsVisibleAtThatHarvest() throws {
        let queue = try seededQueue()
        try queue.write { try node($0, "table:shop.flash", "table", "flash", "{}", t1, t1) }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let flash = try queue.read { try SchemaObjectRecord.filter(Column("name") == "flash").fetchOne($0) }
        #expect(flash?.firstSeen == t1)
        #expect(flash?.removedAt == t2)
    }

    @Test func droppedReferencesAreClosedAtTheNextHarvest() throws {
        let queue = try seededQueue()
        try queue.write { try edge($0, "table:shop.legacy", "table:shop.customers", "references", t1, t2) }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let relations = try queue.read { try SchemaRelationRecord.order(Column("srcName")).fetchAll($0) }
        #expect(relations.map(\.srcName) == ["legacy", "orders"])
        #expect(relations.map(\.removedAt) == [t3, nil])
    }

    @Test func referencesBecomeRelationsAndSnapshotsBecomeChanges() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let relations = try queue.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(relations.count == 1)
        #expect(relations.first?.srcName == "orders")
        #expect(relations.first?.dstName == "customers")
        #expect(relations.first?.removedAt == nil)
        let changes = try queue.read { try SchemaChangeRecord.order(Column("at")).fetchAll($0) }
        #expect(changes.map(\.at) == [t1, t2, t3])
        let state = try queue.read { try SchemaGraphStateRecord.fetchOne($0, key: profile) }
        #expect(state?.lastChangedAt == t3)
        #expect(state?.objectCount == 3)
        #expect(state?.detailedCount == 2)
    }

    /// The per-node graph builder added a bare table node for every foreign
    /// key target missing from the listing, so a reference could point
    /// somewhere: no column, no index, only the reference into it. Copied, it
    /// would be a pending table the next pass records as removed. It is left
    /// out, at its last sighting as before it, and the reference into it is
    /// copied as a relation to an object the store does not hold, as a key
    /// into an unlisted schema is.
    @Test func stubNodesForForeignKeyTargetsAreNotCopied() throws {
        let queue = try seededQueue()
        try queue.write { db in
            try node(db, "table:shop.payments", "table", "payments", "{}", t1, t3)
            try edge(db, "table:shop.orders", "table:shop.payments", "references", t1, t3)
            try node(db, "table:shop.vendors", "table", "vendors", "{}", t1, t2)
            try edge(db, "table:shop.orders", "table:shop.vendors", "references", t1, t2)
        }

        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")

        let names = try queue.read { try String.fetchAll($0, sql: "SELECT name FROM schema_object ORDER BY name") }
        #expect(names == ["customers", "legacy", "orders", "recent"])
        let targets = try queue.read {
            try String.fetchAll($0, sql: "SELECT dstName FROM schema_relation WHERE removedAt IS NULL ORDER BY dstName")
        }
        #expect(targets == ["customers", "payments"])
        let state = try queue.read { try SchemaGraphStateRecord.fetchOne($0, key: profile) }
        #expect(state?.objectCount == 3)
    }

    @Test func v34LeavesTheLegacyTablesInPlace() throws {
        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        for table in ["graph_node", "graph_edge", "graph_snapshot"] {
            #expect(try queue.read { try $0.tableExists(table) }, "\(table) was dropped")
        }
    }

    @Test func theLegacyTablesAreDroppedByAFullMigrationAfterTheCopy() throws {
        let migrations = BerryStore.migrator.migrations
        let copy = try #require(migrations.firstIndex(of: "v34-schema-object-versions"))
        let partition = try #require(migrations.firstIndex(of: "v35-schema-embedding-partition"))
        let drop = try #require(migrations.firstIndex(of: "v36-drop-per-node-graph-tables"))
        #expect(drop > copy)
        #expect(drop > partition)

        let queue = try seededQueue()
        try BerryStore.migrator.migrate(queue)
        for table in ["graph_node", "graph_edge", "graph_snapshot"] {
            #expect(try !queue.read { try $0.tableExists(table) }, "\(table) still exists")
        }
        let objects = try queue.read { try SchemaObjectRecord.fetchCount($0) }
        #expect(objects == 4, "the copy must survive the drop")
    }

    /// Pins the measured fix: when the planner drives the child lookup from the
    /// lastSeen index it walks nearly every node for every table, and the copy
    /// grows quadratically with the number of tables.
    @Test func theChildLookupDoesNotDriveFromTheLastSeenIndex() throws {
        let queue = try seededQueue()
        let plan = try queue.read { db in
            try Row.fetchAll(
                db, sql: "EXPLAIN QUERY PLAN " + BerryStore.legacyChildrenSQL,
                arguments: [profile, "table:shop.orders", "hasColumn", t3]
            ).map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("graph_edge") })
        #expect(!plan.contains { $0.contains("graph_node_on_lastSeen") }, "plan: \(plan)")
    }

    @Test func oneCurrentRowPerObjectIsEnforced() throws {
        let store = try BerryStore(path: ":memory:")
        try store.write { db in
            var row = SchemaObjectRecord(profileID: profile, database: "shop", name: "orders", kind: "table", firstSeen: t1)
            try row.insert(db)
            var duplicate = SchemaObjectRecord(profileID: profile, database: "shop", name: "orders", kind: "table", firstSeen: t2)
            #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
        }
    }

    @Test func oneCurrentRowPerObjectIsEnforcedWithoutANamespace() throws {
        let store = try BerryStore(path: ":memory:")
        try store.write { db in
            var row = SchemaObjectRecord(profileID: profile, database: nil, name: "orders", kind: "table", firstSeen: t1)
            try row.insert(db)
            var duplicate = SchemaObjectRecord(profileID: profile, database: nil, name: "orders", kind: "table", firstSeen: t2)
            #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
        }
    }

    @Test func aMissingNamespaceIsStoredAsEmptyAndReadBackAsNil() throws {
        let store = try BerryStore(path: ":memory:")
        try store.write { db in
            var row = SchemaObjectRecord(profileID: profile, database: nil, name: "orders", kind: "table", firstSeen: t1)
            try row.insert(db)
            let fetched = try SchemaObjectRecord.fetchOne(db, key: row.id)
            #expect(fetched?.database == nil)
            #expect(try String.fetchOne(db, sql: "SELECT database FROM schema_object") == "")
            var named = SchemaObjectRecord(profileID: profile, database: "shop", name: "orders", kind: "table", firstSeen: t1)
            try named.insert(db)
            #expect(try SchemaObjectRecord.fetchOne(db, key: named.id)?.database == "shop")
        }
    }

    @Test func oneCurrentRelationPerColumnPairIsEnforcedWithoutANamespace() throws {
        let store = try BerryStore(path: ":memory:")
        try store.write { db in
            func relation(_ firstSeen: Date) -> SchemaRelationRecord {
                SchemaRelationRecord(
                    profileID: profile, srcDatabase: nil, srcName: "orders", srcColumn: "customer_id",
                    dstDatabase: nil, dstName: "customers", dstColumn: "id", firstSeen: firstSeen
                )
            }
            var first = relation(t1)
            try first.insert(db)
            var duplicate = relation(t2)
            #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
            let fetched = try SchemaRelationRecord.fetchOne(db, key: first.id)
            #expect(fetched?.srcDatabase == nil)
            #expect(fetched?.dstDatabase == nil)
            #expect(try String.fetchOne(db, sql: "SELECT srcDatabase || '|' || dstDatabase FROM schema_relation") == "|")
        }
    }

    @Test func statsWithoutANamespaceAreOverwrittenInPlace() throws {
        let store = try BerryStore(path: ":memory:")
        try store.write { db in
            try SchemaStatsRecord(profileID: profile, database: nil, name: "orders", rows: 10, updatedAt: t1).save(db)
            try SchemaStatsRecord(profileID: profile, database: nil, name: "orders", rows: 20, updatedAt: t2).save(db)
            let all = try SchemaStatsRecord.fetchAll(db)
            #expect(all.count == 1)
            #expect(all.first?.rows == 20)
            #expect(all.first?.database == nil)
        }
    }

    @Test func tablesWithoutANamespaceAreCopiedWithAnEmptyOne() throws {
        let queue = try seededQueue()
        try queue.write { db in
            for (id, name) in [("table:flat.orders", "orders"), ("table:flat.customers", "customers")] {
                try db.execute(
                    sql: "INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen) VALUES (?, ?, 'table', ?, NULL, '{}', ?, ?)",
                    arguments: [profile, id, name, t1, t3]
                )
            }
            try db.execute(
                sql: "INSERT INTO graph_edge (profileID, src, dst, kind, weight, attrs, firstSeen, lastSeen) VALUES (?, 'table:flat.orders', 'table:flat.customers', 'references', 1, ?, ?, ?)",
                arguments: [profile, #"{"column":"customer_id","referencedColumn":"id"}"#, t1, t3]
            )
            // A referenced table that was listed had its detail read, so it
            // has at least the referenced column; one without any is the
            // builder's stub for an unlisted target.
            try db.execute(
                sql: "INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen) VALUES (?, 'column:flat.customers.id', 'column', 'id', NULL, ?, ?, ?)",
                arguments: [profile, #"{"type":"int"}"#, t1, t3]
            )
            try edge(db, "table:flat.customers", "column:flat.customers.id", "hasColumn", t1, t3)
        }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let flat = try queue.read { try SchemaObjectRecord.filter(Column("database") == "").order(Column("name")).fetchAll($0) }
        #expect(flat.map(\.name) == ["customers", "orders"])
        #expect(flat.allSatisfy { $0.database == nil })
        let relation = try queue.read { try SchemaRelationRecord.filter(Column("srcDatabase") == "").fetchOne($0) }
        #expect(relation?.dstDatabase == nil)
        #expect(relation?.srcColumn == "customer_id")
        #expect(relation?.dstColumn == "id")
    }

    @Test func columnsAndIndexesDroppedBeforeTheLastPassAreLeftOut() throws {
        let queue = try seededQueue()
        try queue.write { db in
            try node(db, "column:shop.orders.note", "column", "note", #"{"type":"text","nullable":"true","primaryKey":"false"}"#, t1, t2)
            try edge(db, "table:shop.orders", "column:shop.orders.note", "hasColumn", t1, t2)
            try node(db, "index:shop.orders.orders_note_idx", "index", "orders_note_idx", #"{"unique":"false","columns":"note"}"#, t1, t2)
            try edge(db, "table:shop.orders", "index:shop.orders.orders_note_idx", "hasIndex", t1, t2)
        }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let orders = try queue.read { try SchemaObjectRecord.filter(Column("name") == "orders").fetchOne($0) }
        #expect(orders?.columnText == "id\ntotal" && orders?.indexText == "orders_pkey")
    }

    @Test func withoutAnySnapshotEveryTableIsCurrent() throws {
        let queue = try seededQueue()
        try queue.write { try $0.execute(sql: "DELETE FROM graph_snapshot") }
        try BerryStore.migrator.migrate(queue, upTo: "v34-schema-object-versions")
        let current = try queue.read { try SchemaObjectRecord.filter(Column("removedAt") == nil).fetchCount($0) }
        #expect(current == 4)
        let state = try queue.read { try SchemaGraphStateRecord.fetchOne($0, key: profile) }
        #expect(state?.lastChangedAt == nil)
        #expect(state?.objectCount == 4)
        #expect(state?.detailedCount == 2)
    }

    /// Pins the hash to the bytes `SchemaDefinition.hash` produces for the same
    /// JSON, so a migrated row is not re-versioned by the first harvest after
    /// the upgrade.
    @Test func definitionHashMatchesTheCanonicalFNV1a() {
        let json = #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"},{"defaultValue":"0","name":"total","nullable":true,"primaryKey":false,"type":"numeric"}],"indexes":[{"columns":["id"],"name":"orders_pkey","unique":true}]}"#
        #expect(ContentHash.fnv1a64(json) == "d13af0ae444dc9ea")
    }
}
