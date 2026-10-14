import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// The order in which the model stopped the passes and reported a save.
@MainActor
private final class Events {
    var log: [String] = []
}

@MainActor
@Suite("Schema scope sheet")
struct SchemaScopeModelTests {
    let profile = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)

    private var unitVector: [Float] {
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        return values
    }

    /// Two tables in `shop`, two in `archive`, a foreign key from `archive`
    /// into `shop`, statistics and name vectors for both schemas, and a state
    /// with a version token, as a harvest leaves them.
    private func seeded() throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        let objects = [("shop", "orders"), ("shop", "customers"), ("archive", "old_orders"), ("archive", "old_customers")]
        let listing = try store.applySchemaListing(
            profileID: profile,
            objects: objects.map { SchemaListedObject(database: $0.0, name: $0.1, kind: "table", fingerprint: "f") },
            relations: [SchemaListedRelation(
                srcDatabase: "archive", srcName: "old_orders", srcColumn: "order_id",
                dstDatabase: "shop", dstName: "orders", dstColumn: "id", constraintName: nil
            )],
            now: t1
        )
        _ = try store.applySchemaDetails(profileID: profile, details: objects.map {
            SchemaDetailWrite(database: $0.0, name: $0.1, kind: "table", fingerprint: "f", definitionHash: "h",
                              definition: #"{"columns":[],"indexes":[]}"#)
        }, now: t1, changeID: listing.changeID)
        try store.replaceSchemaStats(profileID: profile, rows: objects.map {
            SchemaStatsRecord(profileID: profile, database: $0.0, name: $0.1, rows: 1, updatedAt: t1)
        })
        for row in try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10) {
            _ = try store.storeSchemaEmbedding(id: row.id, profileID: profile, name: row.name, vector: unitVector)
        }
        try store.updateSchemaGraphState(profileID: profile) {
            $0.versionToken = "7"
            $0.lastCheckedAt = t1
            $0.lastChangedAt = t1
        }
        return store
    }

    private func model(_ store: BerryStore, events: Events = Events()) -> SchemaScopeModel {
        SchemaScopeModel(
            profileID: profile, store: store,
            stopPasses: { events.log.append("stop") },
            didSave: { events.log.append("saved") },
            now: { [t2] in t2 }
        )
    }

    private func embeddedNames(_ store: BerryStore) throws -> Set<String> {
        Set(try store.nearestSchemaObjects(profileID: profile, to: unitVector, limit: 8).map(\.name))
    }

    @Test func listsEachSchemaWithItsTablesAndStartsFromAllSchemas() async throws {
        let model = model(try seeded())
        #expect(!model.canSave)

        await model.load()

        #expect(model.schemas == [
            SchemaScopeModel.Schema(name: "archive", count: 2), SchemaScopeModel.Schema(name: "shop", count: 2),
        ])
        #expect(model.allSchemas)
        #expect(model.selected == ["archive", "shop"])
        #expect(model.hasIndexedObjects)
        #expect(!model.suggestsNarrowing)
        #expect(model.canSave)
    }

    @Test func aStoredSelectionIsShownWithItsSchemasEvenWhenEmpty() async throws {
        let store = try seeded()
        try store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop","staging"]"# }
        let model = model(store)

        await model.load()

        #expect(!model.allSchemas)
        #expect(model.selected == ["shop", "staging"])
        #expect(model.schemas.map(\.name) == ["archive", "shop", "staging"])
        #expect(model.schemas.last?.count == 0)
    }

    @Test func aLargeCatalogShowsTheHint() async throws {
        let store = try seeded()
        try store.updateSchemaGraphState(profileID: profile) { $0.hint = "selectSchemas" }
        let model = model(store)

        await model.load()

        #expect(model.suggestsNarrowing)
    }

    @Test func aProfileWithNothingIndexedOffersAllSchemasOnly() async throws {
        let model = model(try BerryStore(path: ":memory:"))

        await model.load()

        #expect(model.schemas.isEmpty)
        #expect(!model.hasIndexedObjects)
        #expect(model.allSchemas)
        #expect(model.canSave)
    }

    @Test func anEmptySelectionIsNeverSaved() async throws {
        let store = try seeded()
        let events = Events()
        let model = model(store, events: events)
        await model.load()

        model.allSchemas = false
        model.selected = []

        #expect(!model.canSave)
        #expect(await model.save() == false)
        #expect(events.log.isEmpty)
        #expect(try store.schemaGraphState(profileID: profile)?.selectedSchemas == nil)
        #expect(try store.schemaGraphState(profileID: profile)?.versionToken == "7")
    }

    /// The passes stop before anything is deleted, so a pass that listed the
    /// wider scope cannot write it back afterwards.
    @Test func narrowingDeletesEverythingOutsideTheKeptSchemas() async throws {
        let store = try seeded()
        let events = Events()
        let model = model(store, events: events)
        await model.load()

        model.allSchemas = false
        model.selected = ["shop"]
        #expect(await model.save())

        #expect(events.log == ["stop", "saved"])
        let state = try #require(try store.schemaGraphState(profileID: profile))
        #expect(state.selectedSchemas == #"["shop"]"#)
        #expect(state.versionToken == nil)
        #expect(state.lastChangedAt == t2)
        #expect(Set(try store.currentSchemaObjectNames(profileID: profile).map(\.name)) == ["orders", "customers"])
        #expect(try store.currentSchemaRelations(profileID: profile).isEmpty)
        #expect(Set(try store.schemaStats(profileID: profile).map(\.name)) == ["orders", "customers"])
        #expect(try embeddedNames(store) == ["orders", "customers"])
    }

    @Test func wideningToAllSchemasKeepsTheRowsAndClearsTheSelection() async throws {
        let store = try seeded()
        try store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop","archive"]"# }
        try store.updateSchemaGraphState(profileID: profile) { $0.versionToken = "8" }
        let events = Events()
        let model = model(store, events: events)
        await model.load()

        model.allSchemas = true
        #expect(await model.save())

        let state = try #require(try store.schemaGraphState(profileID: profile))
        #expect(state.selectedSchemas == nil)
        #expect(state.versionToken == nil)
        #expect(state.lastChangedAt == t1)
        #expect(try store.currentSchemaObjectNames(profileID: profile).count == 4)
        #expect(events.log == ["stop", "saved"])
    }

    /// A selection is written with the same rules whether or not it leaves a
    /// stored schema out, so the change time always moves with it.
    @Test func savingASelectionThatKeepsEverySchemaStillRewritesTheScope() async throws {
        let store = try seeded()
        let model = model(store)
        await model.load()

        model.allSchemas = false
        model.selected = ["archive", "shop"]
        #expect(await model.save())

        let state = try #require(try store.schemaGraphState(profileID: profile))
        #expect(state.selectedSchemas == #"["archive","shop"]"#)
        #expect(state.lastChangedAt == t2)
        #expect(state.versionToken == nil)
        #expect(try store.currentSchemaObjectNames(profileID: profile).count == 4)
    }
}
