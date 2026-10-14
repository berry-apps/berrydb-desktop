import Foundation
import GRDB
import Testing

@testable import BerryStore

/// The statements a store runs while a trace is installed, collected from
/// SQLite's trace callback.
final class SQLLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var statements: [String] { lock.withLock { recorded } }

    func append(_ sql: String) { lock.withLock { recorded.append(sql) } }
}

@Suite("Schema graph writes")
struct SchemaGraphWriteTests {
    let profile = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)

    static let emptyDefinition = #"{"columns":[],"indexes":[]}"#
    static let idThenTotal = #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"},{"name":"total","nullable":true,"primaryKey":false,"type":"numeric"}],"indexes":[]}"#
    static let totalThenId = #"{"columns":[{"name":"total","nullable":true,"primaryKey":false,"type":"numeric"},{"name":"id","nullable":false,"primaryKey":true,"type":"int"}],"indexes":[]}"#
    static let idChangedThenTotal = #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"bigint"},{"name":"total","nullable":true,"primaryKey":false,"type":"numeric"}],"indexes":[]}"#
    /// `idThenTotal` as a harvest reads it when both columns have a default,
    /// which the per-node graph never recorded.
    static let idThenTotalWithDefaults = #"{"columns":[{"defaultValue":"nextval('orders_id_seq'::regclass)","name":"id","nullable":false,"primaryKey":true,"type":"int"},{"defaultValue":"0","name":"total","nullable":true,"primaryKey":false,"type":"numeric"}],"indexes":[]}"#
    static let idThenTotalWithDefaultsAndNote = #"{"columns":[{"defaultValue":"nextval('orders_id_seq'::regclass)","name":"id","nullable":false,"primaryKey":true,"type":"int"},{"defaultValue":"0","name":"total","nullable":true,"primaryKey":false,"type":"numeric"},{"name":"note","nullable":true,"primaryKey":false,"type":"text"}],"indexes":[]}"#

    func listed(_ name: String, schema: String = "shop", fingerprint: String? = "fp1") -> SchemaListedObject {
        SchemaListedObject(database: schema, name: name, kind: "table", fingerprint: fingerprint)
    }
    func detail(
        _ name: String, schema: String = "shop", hash: String = "h1", fingerprint: String? = "fp1",
        definition: String = SchemaGraphWriteTests.emptyDefinition
    ) -> SchemaDetailWrite {
        SchemaDetailWrite(database: schema, name: name, kind: "table", fingerprint: fingerprint,
                          definitionHash: hash, definition: definition, columnText: "id", indexText: name.lowercased() + "_pkey")
    }

    /// What a store upgraded from the per-node graph holds for a table: one
    /// current version with a definition, but no fingerprint, no previous
    /// version and no change row.
    func insertMigratedRow(_ store: BerryStore, name: String = "orders", definition: String) throws {
        try store.write { db in
            var row = SchemaObjectRecord(
                profileID: profile, database: "shop", name: name, kind: "table",
                definitionHash: "legacy", definition: definition, firstSeen: t1
            )
            try row.insert(db)
        }
    }

    func objectRows(_ store: BerryStore) throws -> [SchemaObjectRecord] {
        try store.read { try SchemaObjectRecord.filter(Column("profileID") == profile).order(Column("id")).fetchAll($0) }
    }

    @Test func firstListingInsertsSkeletonsAndAsksForEveryDetail() throws {
        let store = try BerryStore(path: ":memory:")
        let outcome = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: [], now: t1)
        #expect(outcome.added == 2)
        #expect(outcome.changeID != nil)
        #expect(Set(outcome.detailNeeded.map(\.name)) == ["orders", "customers"])
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.objectCount == 2)
        #expect(state?.detailedCount == 0)
    }

    @Test func detailsCreateVersionsAndUnchangedHashOnlyRefreshesFingerprint() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        let first = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        #expect(first.completed == 1 && first.changed == 0)
        let again = try store.applySchemaDetails(profileID: profile, details: [detail("orders", fingerprint: "fp2")], now: t2, changeID: nil)
        #expect(again.changed == 0 && again.unchanged == 1 && again.changeID == nil)
        let rows = try store.read { try SchemaObjectRecord.filter(Column("profileID") == profile).fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows.first?.fingerprint == "fp2")
        #expect(rows.first?.removedAt == nil)
    }

    @Test func changedHashClosesOldVersionAndLinksTheNew() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2")], now: t2, changeID: nil)
        #expect(outcome.changed == 1)
        #expect(outcome.changeID != nil)
        let rows = try store.read { try SchemaObjectRecord.filter(Column("profileID") == profile).order(Column("id")).fetchAll($0) }
        #expect(rows.count == 2)
        #expect(rows[0].removedAt == t2)
        #expect(rows[0].removedByChangeID == outcome.changeID)
        #expect(rows[1].previousID == rows[0].id)
        #expect(rows[1].changeID == outcome.changeID)
        #expect(rows[1].firstSeen == t2)
    }

    @Test func listingMarksRemovalsRightAwayAndDiffsRelations() throws {
        let store = try BerryStore(path: ":memory:")
        let relation = SchemaListedRelation(srcDatabase: "shop", srcName: "orders", srcColumn: "customer_id",
                                            dstDatabase: "shop", dstName: "customers", dstColumn: "id", constraintName: "fk")
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: [relation], now: t1)
        let second = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t2)
        #expect(second.removed == 1 && second.relationsRemoved == 1 && second.added == 0)
        let customers = try store.read { try SchemaObjectRecord.filter(Column("name") == "customers").fetchOne($0) }
        #expect(customers?.removedAt == t2)
        #expect(customers?.removedByChangeID == second.changeID)
        let relations = try store.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(relations.first?.removedAt == t2)
    }

    @Test func listingWithoutRelationsLeavesTheStoredRelationsCurrent() throws {
        let store = try BerryStore(path: ":memory:")
        let relation = relation(from: ("shop", "orders"), to: ("shop", "customers"))
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: [relation], now: t1)
        let second = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: nil, now: t2)
        #expect(second.relationsAdded == 0 && second.relationsRemoved == 0 && second.changeID == nil)
        let relations = try store.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(relations.count == 1 && relations.first?.removedAt == nil)
    }

    @Test func relationsAppliedOnTheirOwnAreDiffedAndStamped() throws {
        let store = try BerryStore(path: ":memory:")
        let kept = relation(from: ("shop", "orders"), to: ("shop", "customers"))
        let dropped = relation(from: ("shop", "orders"), to: ("shop", "regions"))
        let listing = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders"), listed("customers"), listed("regions")], relations: nil, now: t1
        )
        let first = try store.applySchemaRelations(profileID: profile, relations: [kept, dropped], now: t1, changeID: listing.changeID)
        #expect(first == SchemaRelationOutcome(added: 2, removed: 0, changeID: listing.changeID))
        #expect(try store.read { try SchemaRelationRecord.fetchAll($0) }.map(\.changeID) == [listing.changeID, listing.changeID])

        let second = try store.applySchemaRelations(profileID: profile, relations: [kept], now: t2, changeID: nil)
        #expect(second.added == 0 && second.removed == 1)
        let stamp = try #require(second.changeID)
        #expect(stamp != listing.changeID)
        let closed = try store.read { try SchemaRelationRecord.filter(Column("dstName") == "regions").fetchOne($0) }
        #expect(closed?.removedAt == t2 && closed?.removedByChangeID == stamp)

        let unchanged = try store.applySchemaRelations(profileID: profile, relations: [kept], now: t2, changeID: nil)
        #expect(unchanged == SchemaRelationOutcome(added: 0, removed: 0, changeID: nil))
        #expect(try store.schemaChangeMarks(profileID: profile).count == 2)
    }

    @Test func sameNameInTwoSchemasAreTwoObjects() throws {
        let store = try BerryStore(path: ":memory:")
        let outcome = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("orders", schema: "archive")], relations: [], now: t1
        )
        #expect(outcome.added == 2)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", schema: "shop", hash: "a"), detail("orders", schema: "archive", hash: "b")], now: t1, changeID: outcome.changeID)
        let hashes = try store.read { try String.fetchAll($0, sql: "SELECT definitionHash FROM schema_object WHERE name = 'orders' ORDER BY database") }
        #expect(hashes == ["b", "a"])
    }

    @Test func mismatchedFingerprintAsksForDetailAgain() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        let same = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: "fp1")], relations: [], now: t2)
        #expect(same.detailNeeded.isEmpty && same.changeID == nil)
        let moved = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: "fp9")], relations: [], now: t2)
        #expect(moved.detailNeeded.map(\.name) == ["orders"])
    }

    /// The scope and the deletion it implies are one transaction. A pass
    /// that started between two separate writes listed the new scope while
    /// the rows outside it still stood, recorded them as removed, and left a
    /// change row whose counts outlived the deleted rows.
    @Test func savingAScopeAndDeletingOutsideItIsOneTransaction() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders"), listed("old_orders", schema: "archive")], relations: [], now: t1
        )
        let log = SQLLog()
        let queue = try #require(store.dbQueue)
        queue.inDatabase { db in db.trace { if case let .statement(statement) = $0 { log.append(statement.sql) } } }
        defer { queue.inDatabase { $0.trace(options: .statement, nil) } }

        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)

        #expect(log.statements.filter { $0.hasPrefix("BEGIN") }.count == 1, "\(log.statements)")
        #expect(try store.schemaGraphState(profileID: profile)?.selectedSchemas == #"["shop"]"#)
        #expect(try store.currentSchemaObjectNames(profileID: profile).map(\.name) == ["orders"])

        // Widening to the default scope deletes nothing.
        try store.saveSchemaScope(profileID: profile, selectedSchemas: nil, now: t2)
        #expect(try store.schemaGraphState(profileID: profile)?.selectedSchemas == nil)
        #expect(try store.currentSchemaObjectNames(profileID: profile).map(\.name) == ["orders"])
    }

    @Test func scopeShrinkDeletesEveryVersionOutsideTheKeptSchemas() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders", schema: "shop"), listed("old", schema: "archive")], relations: [], now: t1)
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        let names = try store.read { try String.fetchAll($0, sql: "SELECT name FROM schema_object") }
        #expect(names == ["orders"])
    }

    func relation(from src: (String?, String), to dst: (String?, String)) -> SchemaListedRelation {
        SchemaListedRelation(srcDatabase: src.0, srcName: src.1, srcColumn: "ref",
                             dstDatabase: dst.0, dstName: dst.1, dstColumn: "id", constraintName: nil)
    }

    @Test func scopeShrinkAlsoDropsRelationsAndStatisticsOfTheRemovedSchemas() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("old", schema: "archive")],
            relations: [relation(from: ("archive", "old"), to: ("shop", "orders"))], now: t1
        )
        _ = try store.applySchemaDetails(
            profileID: profile, details: [detail("orders", schema: "shop"), detail("old", schema: "archive", hash: "h2")],
            now: t1, changeID: listing.changeID
        )
        try store.write { db in
            try SchemaStatsRecord(profileID: profile, database: "shop", name: "orders", rows: 10, updatedAt: t1).insert(db)
            try SchemaStatsRecord(profileID: profile, database: "archive", name: "old", rows: 5, updatedAt: t1).insert(db)
        }
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        #expect(try objectRows(store).map(\.name) == ["orders"])
        #expect(try store.read { try SchemaRelationRecord.fetchCount($0) } == 0)
        let stats = try store.read { try SchemaStatsRecord.fetchAll($0) }
        #expect(stats.map(\.database) == ["shop"])
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.objectCount == 1)
        #expect(state?.detailedCount == 1)
    }

    @Test func scopeShrinkKeepsARelationWhoseEndsAreBothInTheKeptSchemas() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: [listed("orders", schema: "shop"), listed("customers", schema: "shop"), listed("old", schema: "archive")],
            relations: [relation(from: ("shop", "orders"), to: ("shop", "customers"))], now: t1
        )
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        let relations = try store.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(relations.count == 1)
        #expect(relations.first?.removedAt == nil)
        #expect(try store.schemaGraphState(profileID: profile)?.objectCount == 2)
    }

    /// A cache of the stored graph is keyed on the revision, so every
    /// committed write that changes the stored objects, definitions or
    /// relations moves it, and a write that changes none of them leaves it.
    @Test func everyWriteThatChangesTheStoredSchemaMovesTheRevision() throws {
        let store = try BerryStore(path: ":memory:")
        func revision() throws -> Int? { try store.schemaGraphState(profileID: profile)?.revision }
        let objects = [listed("orders"), listed("customers"), listed("old", schema: "archive")]

        let first = try store.applySchemaListing(profileID: profile, objects: objects, relations: [], now: t1)
        let afterListing = try #require(try revision())
        #expect(afterListing > 0)
        _ = try store.applySchemaListing(profileID: profile, objects: objects, relations: [], now: t1)
        #expect(try revision() == afterListing)

        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: first.changeID)
        let afterCompletion = try #require(try revision())
        #expect(afterCompletion > afterListing)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t2, changeID: nil)
        #expect(try revision() == afterCompletion)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2")], now: t2, changeID: nil)
        let afterVersion = try #require(try revision())
        #expect(afterVersion > afterCompletion)

        let key = relation(from: ("shop", "orders"), to: ("shop", "customers"))
        _ = try store.applySchemaRelations(profileID: profile, relations: [key], now: t2, changeID: nil)
        let afterRelation = try #require(try revision())
        #expect(afterRelation > afterVersion)
        _ = try store.applySchemaRelations(profileID: profile, relations: [key], now: t2, changeID: nil)
        #expect(try revision() == afterRelation)

        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        #expect(try #require(try revision()) > afterRelation)
    }

    /// A foreign key belongs to the scope of its own table: listing the keys
    /// of a scope reads the keys of its tables wherever they point. A key from
    /// a kept schema into a removed one stays, so the next listing of the
    /// narrower scope, which returns it again, records no change.
    @Test func scopeShrinkKeepsARelationFromAKeptSchemaIntoARemovedOne() throws {
        let store = try BerryStore(path: ":memory:")
        let intoArchive = relation(from: ("shop", "orders"), to: ("archive", "old"))
        _ = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("old", schema: "archive")],
            relations: [intoArchive], now: t1
        )

        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)

        let relations = try store.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(relations.map(\.dstName) == ["old"])
        #expect(relations.first?.removedAt == nil)
        let next = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop")], relations: [intoArchive], now: t2.addingTimeInterval(60)
        )
        #expect(next.relationsAdded == 0)
        #expect(next.relationsRemoved == 0)
        #expect(next.changeID == nil)
    }

    @Test func scopeShrinkKeepsObjectsWithoutANamespaceOnlyWhenTheEmptyNamespaceIsKept() throws {
        let store = try BerryStore(path: ":memory:")
        let bare = SchemaListedObject(database: nil, name: "events", kind: "table", fingerprint: "fp1")
        _ = try store.applySchemaListing(profileID: profile, objects: [bare, listed("orders")], relations: [], now: t1)
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop", ""], now: t2)
        #expect(Set(try objectRows(store).map(\.name)) == ["events", "orders"])
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        #expect(try objectRows(store).map(\.name) == ["orders"])
    }

    @Test func scopeShrinkAlsoDeletesTheClosedVersions() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("old", schema: "archive")], relations: [], now: t1
        )
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("old", schema: "archive")], now: t1, changeID: listing.changeID)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("old", schema: "archive", hash: "h2")], now: t2, changeID: nil)
        try #require(try objectRows(store).filter { $0.name == "old" }.count == 2)
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        #expect(try objectRows(store).map(\.name) == ["orders"])
    }

    @Test func anObjectWithoutAFingerprintIsReadAgainOnEveryListing() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: nil)], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", fingerprint: nil)], now: t1, changeID: listing.changeID)
        let again = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: nil)], relations: [], now: t2)
        #expect(again.detailNeeded.map(\.name) == ["orders"])
        #expect(again.changeID == nil)
    }

    @Test func aNewVersionInheritsTheQueuedFlagAndTheClosedRowIsNeverQueued() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        try store.write { try $0.execute(sql: "UPDATE schema_object SET embeddingAttempts = 2") }
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2")], now: t2, changeID: nil)
        let rows = try objectRows(store)
        try #require(rows.count == 2)
        #expect(rows[0].needsEmbedding == false)
        #expect(rows[0].embeddingAttempts == 0)
        #expect(rows[1].needsEmbedding == true)
        #expect(rows[1].embeddingAttempts == 0)
    }

    @Test func anEmbeddedObjectStaysEmbeddedAcrossVersions() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        try store.write { try $0.execute(sql: "UPDATE schema_object SET needsEmbedding = 0") }
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2")], now: t2, changeID: nil)
        let rows = try objectRows(store)
        try #require(rows.count == 2)
        #expect(rows[1].needsEmbedding == false)
    }

    @Test func aRemovedObjectIsNoLongerQueuedForEmbedding() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: [], now: t1)
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t2)
        let rows = try objectRows(store)
        let customers = try #require(rows.first { $0.name == "customers" })
        #expect(customers.removedAt == t2)
        #expect(customers.needsEmbedding == false)
        #expect(rows.first { $0.name == "orders" }?.needsEmbedding == true)
    }

    private var unitVector: [Float] {
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        return values
    }

    private func embeddedNames(_ store: BerryStore, profile: UUID? = nil) throws -> Set<String> {
        let prefix = "\((profile ?? self.profile).uuidString)#"
        return try store.read {
            Set(try String.fetchAll($0, sql: "SELECT objectKey FROM schema_object_embedding").compactMap {
                $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil
            })
        }
    }

    @Test func removingAnObjectDeletesItsEmbeddingAndOnlyThatProfilesOwn() throws {
        let store = try BerryStore(path: ":memory:")
        let other = UUID()
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders"), listed("customers")], relations: [], now: t1)
        for name in ["orders", "customers"] {
            try store.embed(name, profileID: profile, vector: unitVector)
        }
        try store.embed("orders", profileID: other, vector: unitVector)

        _ = try store.applySchemaListing(profileID: profile, objects: [listed("customers")], relations: [], now: t2)

        #expect(try embeddedNames(store) == ["customers"])
        #expect(try embeddedNames(store, profile: other) == ["orders"])
    }

    @Test func aNameStillCurrentInAnotherSchemaKeepsItsEmbedding() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("orders", schema: "archive")], relations: [], now: t1
        )
        try store.embed("orders", profileID: profile, vector: unitVector)

        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders", schema: "archive")], relations: [], now: t2)
        #expect(try embeddedNames(store) == ["orders"])

        _ = try store.applySchemaListing(profileID: profile, objects: [], relations: [], now: Date(timeIntervalSince1970: 3_000))
        #expect(try embeddedNames(store).isEmpty)
    }

    /// Whether a removed name is still current is answered from the listing,
    /// which after the write holds exactly the current objects. Asked of the
    /// store once per removal, it read every current row of the profile each
    /// time: a pass dropping 200 of 20,000 tables took 5 to 14 seconds.
    @Test func aListingReadsTheStoredObjectsOnceWhateverItRemoves() throws {
        let store = try BerryStore(path: ":memory:")
        let names = (0..<50).map { "t\($0)" }
        _ = try store.applySchemaListing(profileID: profile, objects: names.map { listed($0) }, relations: [], now: t1)
        for name in names { try store.embed(name, profileID: profile, vector: unitVector) }

        let log = SQLLog()
        let queue = try #require(store.dbQueue)
        queue.inDatabase { db in db.trace { if case let .statement(statement) = $0 { log.append(statement.sql) } } }
        defer { queue.inDatabase { $0.trace(options: .statement, nil) } }
        _ = try store.applySchemaListing(profileID: profile, objects: names.prefix(10).map { listed($0) }, relations: [], now: t2)

        let objectReads = log.statements.filter { $0.hasPrefix("SELECT") && $0.contains("FROM schema_object ") }
        #expect(objectReads.count == 1, "\(objectReads)")
        #expect(try embeddedNames(store) == Set(names.prefix(10)))
    }

    @Test func aNewVersionKeepsTheEmbedding() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t1, changeID: listing.changeID)
        try store.embed("orders", profileID: profile, vector: unitVector)

        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2")], now: t2, changeID: nil)

        #expect(try embeddedNames(store) == ["orders"])
    }

    /// A definition is stored compressed, written whole by a new version and
    /// in place by a completed pending row alike, and every read returns the
    /// canonical text it was written as. A 20-column definition of about
    /// 2 KB as text filled a 4 KB page on its own.
    @Test func definitionsAreStoredCompressedAndReadBackAsWritten() throws {
        let columns = (0..<20).map { #"{"name":"column_\#($0)_created_at","nullable":true,"primaryKey":false,"type":"timestamp without time zone"}"# }
        let wide = #"{"columns":[\#(columns.joined(separator: ","))],"indexes":[]}"#
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", definition: wide)], now: t1, changeID: listing.changeID)
        _ = try store.applySchemaDetails(
            profileID: profile, details: [detail("orders", hash: "h2", definition: Self.idThenTotal)], now: t2, changeID: nil
        )

        let stored = try store.read {
            try Row.fetchAll($0, sql: "SELECT typeof(definition) AS type, length(definition) AS bytes FROM schema_object ORDER BY id")
        }
        #expect(stored.map { $0["type"] as String } == ["blob", "blob"])
        let wideBytes: Int = stored[0]["bytes"]
        #expect(wideBytes < wide.utf8.count / 4, "\(wideBytes) of \(wide.utf8.count) bytes")
        #expect(try objectRows(store).map(\.definition) == [wide, Self.idThenTotal])
    }

    /// Reading definitions keeps nothing per row once the read returns. The
    /// compression methods of NSData return autoreleased objects, and no
    /// autorelease pool drains on the threads a store reads and writes on,
    /// so each one stayed alive: paging a hundred pages of changes kept
    /// 117 MB in a release build.
    ///
    /// The allocator's count of bytes in use covers the whole process, where
    /// other suites allocate and free at the same time. So the reads run in
    /// five batches, each measured on its own, and the median batch is
    /// judged: a leak grows every batch by the same amount, while another
    /// suite's allocations would have to land in three of the five batches
    /// to fail the test, or its frees in three to hide a leak.
    @Test func readingDefinitionsKeepsNoMemory() throws {
        let columns = (0..<400).map { #"{"name":"column_\#($0)","nullable":true,"primaryKey":false,"type":"text"}"# }
        let large = #"{"columns":[\#(columns.joined(separator: ","))],"indexes":[]}"#
        let store = try BerryStore(path: ":memory:")
        let names = (0..<200).map { "t\($0)" }
        let listing = try store.applySchemaListing(profileID: profile, objects: names.map { listed($0) }, relations: [], now: t1)
        _ = try store.applySchemaDetails(
            profileID: profile, details: names.map { detail($0, definition: large) }, now: t1, changeID: listing.changeID
        )
        func inUse() -> Int {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            return statistics.size_in_use
        }
        var growth: [Int] = []
        for _ in 0..<5 {
            let before = inUse()
            for _ in 0..<10 {
                #expect(try store.currentSchemaObjects(profileID: profile).count == 200)
            }
            growth.append(inUse() - before)
        }
        // Ten reads of 200 definitions of 26 KB each keep about 90 MB when
        // nothing is released.
        let median = growth.sorted()[2]
        #expect(median < 16 << 20, "median batch kept \(median >> 20) MB, batches \(growth.map { $0 >> 20 }) MB")
    }

    @Test func firstDetailOfAListedObjectCompletesTheRowInPlace() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("orders", definition: Self.idThenTotal)], now: t2, changeID: listing.changeID)
        #expect(outcome.completed == 1 && outcome.changed == 0 && outcome.unchanged == 0)
        let rows = try objectRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.definition == Self.idThenTotal)
        #expect(rows.first?.definitionHash == "h1")
        #expect(rows.first?.fingerprint == "fp1")
        #expect(rows.first?.columnText == "id" && rows.first?.indexText == "orders_pkey")
        #expect(rows.first?.removedAt == nil)
        #expect(rows.first?.needsEmbedding == true)
        let changes = try store.read { try SchemaChangeRecord.fetchAll($0) }
        #expect(changes.count == 1)
        #expect(changes.first?.id == listing.changeID)
        #expect(try store.schemaGraphState(profileID: profile)?.detailedCount == 1)
    }

    @Test func migratedRowWithOnlyReorderedColumnsIsCompletedInPlace() throws {
        let store = try BerryStore(path: ":memory:")
        try insertMigratedRow(store, definition: Self.totalThenId)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2", definition: Self.idThenTotal)], now: t2, changeID: nil)
        #expect(outcome.completed == 1 && outcome.changed == 0 && outcome.changeID == nil)
        let rows = try objectRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.definition == Self.idThenTotal)
        #expect(rows.first?.definitionHash == "h2")
        #expect(rows.first?.fingerprint == "fp1")
        #expect(rows.first?.removedAt == nil)
        #expect(rows.first?.needsEmbedding == false)
        #expect(try store.read { try SchemaChangeRecord.fetchCount($0) } == 0)
    }

    @Test func migratedRowWithAChangedColumnGetsANewVersion() throws {
        let store = try BerryStore(path: ":memory:")
        try insertMigratedRow(store, definition: Self.totalThenId)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2", definition: Self.idChangedThenTotal)], now: t2, changeID: nil)
        #expect(outcome.changed == 1 && outcome.completed == 0)
        let rows = try objectRows(store)
        try #require(rows.count == 2)
        #expect(rows[0].removedAt == t2)
        #expect(rows[1].previousID == rows[0].id)
        #expect(rows[1].definition == Self.idChangedThenTotal)
    }

    /// The per-node graph recorded no column default, so the first detail of
    /// an upgraded table with a `serial` key or a `DEFAULT now()` column
    /// differs from the copy by its defaults alone. That is not a change of
    /// the table: the row is completed in place and keeps the defaults, and
    /// the change feed lists nothing.
    @Test func migratedRowWhoseColumnsGainTheirDefaultsIsCompletedInPlace() throws {
        let store = try BerryStore(path: ":memory:")
        try insertMigratedRow(store, definition: Self.totalThenId)
        let outcome = try store.applySchemaDetails(
            profileID: profile, details: [detail("orders", hash: "h2", definition: Self.idThenTotalWithDefaults)], now: t2, changeID: nil
        )
        #expect(outcome.completed == 1 && outcome.changed == 0 && outcome.changeID == nil)
        let rows = try objectRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.definition == Self.idThenTotalWithDefaults)
        #expect(rows.first?.definitionHash == "h2")
        #expect(try store.read { try SchemaChangeRecord.fetchCount($0) } == 0)
    }

    /// Forgiving the defaults forgives nothing else: a column added since the
    /// upgrade is a new version.
    @Test func migratedRowWithAnAddedColumnGetsANewVersionWhateverItsDefaults() throws {
        let store = try BerryStore(path: ":memory:")
        try insertMigratedRow(store, definition: Self.totalThenId)
        let outcome = try store.applySchemaDetails(
            profileID: profile, details: [detail("orders", hash: "h2", definition: Self.idThenTotalWithDefaultsAndNote)],
            now: t2, changeID: nil
        )
        #expect(outcome.changed == 1 && outcome.completed == 0)
        #expect(try objectRows(store).count == 2)
    }

    @Test func aChangedDefaultIsARealChangeOnceTheRowIsNotFromTheUpgrade() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: nil)], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", fingerprint: nil, definition: Self.idThenTotal)], now: t1, changeID: listing.changeID)
        let outcome = try store.applySchemaDetails(
            profileID: profile, details: [detail("orders", hash: "h2", fingerprint: nil, definition: Self.idThenTotalWithDefaults)],
            now: t2, changeID: nil
        )
        #expect(outcome.changed == 1 && outcome.completed == 0)
        #expect(try objectRows(store).count == 2)
    }

    @Test func reorderedColumnsAreARealChangeOnceTheRowIsNotFromTheUpgrade() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [listed("orders", fingerprint: nil)], relations: [], now: t1)
        _ = try store.applySchemaDetails(profileID: profile, details: [detail("orders", fingerprint: nil, definition: Self.idThenTotal)], now: t1, changeID: listing.changeID)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("orders", hash: "h2", fingerprint: nil, definition: Self.totalThenId)], now: t2, changeID: nil)
        #expect(outcome.changed == 1 && outcome.completed == 0)
        #expect(try objectRows(store).count == 2)
    }

    @Test func detailForAnObjectTheListingDoesNotHaveIsDropped() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [listed("orders")], relations: [], now: t1)
        let outcome = try store.applySchemaDetails(profileID: profile, details: [detail("dropped")], now: t2, changeID: nil)
        #expect(outcome == SchemaDetailOutcome(changed: 0, unchanged: 0, completed: 0, changeID: nil))
        #expect(try objectRows(store).map(\.name) == ["orders"])
    }

    /// A shrink moves the change time, so a cache keyed on it rebuilds, and
    /// drops the version token, so the next pass lists the new scope instead
    /// of stopping at a token read under the old one.
    @Test func scopeShrinkMovesTheChangeTimeAndDropsTheVersionToken() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders", schema: "shop"), listed("old", schema: "archive")], relations: [], now: t1
        )
        try store.updateSchemaGraphState(profileID: profile) {
            $0.versionToken = "42"
            $0.lastChangedAt = t1
        }
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)
        let state = try #require(try store.schemaGraphState(profileID: profile))
        #expect(state.lastChangedAt == t2)
        #expect(state.versionToken == nil)
    }

    @Test func scopeShrinkDeletesTheEmbeddingsOfNamesNoLongerCurrent() throws {
        let store = try BerryStore(path: ":memory:")
        let other = UUID()
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: [listed("orders", schema: "shop"), listed("old", schema: "archive"), listed("orders", schema: "archive")],
            relations: [], now: t1
        )
        for name in ["orders", "old"] {
            try store.embed(name, profileID: profile, vector: unitVector)
        }
        try store.embed("old", profileID: other, vector: unitVector)

        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: t2)

        // `orders` is still current in `shop`, so its name keeps its vector.
        #expect(try embeddedNames(store) == ["orders"])
        #expect(try embeddedNames(store, profile: other) == ["old"])
    }

    @Test func changingTheSelectedSchemasDropsTheVersionToken() throws {
        let store = try BerryStore(path: ":memory:")
        try store.updateSchemaGraphState(profileID: profile) { $0.versionToken = "42" }
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t1 }
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == "42")

        try store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop"]"# }
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == nil)

        try store.updateSchemaGraphState(profileID: profile) { $0.versionToken = "43" }
        try store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = nil }
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == nil)
    }

    /// A pass's writes carry the scope it started with. Once the stored scope
    /// is another, each of them writes nothing.
    @Test func aWriteForAnotherScopeChangesNothing() throws {
        let store = try BerryStore(path: ":memory:")
        let started = PassScope(selectedSchemas: nil)
        let listing = try store.applySchemaListing(
            profileID: profile, objects: [listed("orders")], relations: [], now: t1, scope: started
        )
        try store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["archive"]"# }

        #expect(throws: ScopeChanged.self) {
            try store.applySchemaListing(profileID: profile, objects: [], relations: [], now: t2, scope: started)
        }
        #expect(throws: ScopeChanged.self) {
            try store.applySchemaDetails(profileID: profile, details: [detail("orders")], now: t2, changeID: listing.changeID, scope: started)
        }
        #expect(throws: ScopeChanged.self) {
            try store.applySchemaRelations(profileID: profile, relations: [], now: t2, changeID: nil, scope: started)
        }
        #expect(throws: ScopeChanged.self) {
            try store.updateSchemaGraphState(profileID: profile, scope: started) { $0.versionToken = "stale" }
        }
        let rows = try objectRows(store)
        #expect(rows.map(\.name) == ["orders"] && rows.allSatisfy { $0.removedAt == nil && $0.definition == nil })
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == nil)

        let current = PassScope(selectedSchemas: #"["archive"]"#)
        try store.updateSchemaGraphState(profileID: profile, scope: current) { $0.versionToken = "fresh" }
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == "fresh")
    }
}
