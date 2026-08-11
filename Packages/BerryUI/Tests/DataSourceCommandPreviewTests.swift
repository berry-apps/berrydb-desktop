import BerryDataSourceKit
import Testing

@testable import BerryUI

/// Pure native-command preview rendering (docs/architecture/12 §6/§7) — no
/// Docker, always runs.
@Suite("DataSourceCommandPreview")
struct DataSourceCommandPreviewTests {
    @Test func mongoInsertRendersInsertOne() {
        let change = DataSourceChangeSet.insert(
            collection: "users", document: .object([("name", .string("ada"))])
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.hasPrefix("db.users.insertOne("))
        #expect(preview.contains("\"name\""))
    }

    @Test func mongoUpdateRendersUpdateOneWithSet() {
        let change = DataSourceChangeSet.update(
            collection: "users", id: .string("abc"), patch: .object([("age", .int(30))])
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.hasPrefix("db.users.updateOne("))
        #expect(preview.contains("$set"))
    }

    @Test func mongoDeleteByIDRendersDeleteOne() {
        let change = DataSourceChangeSet.delete(collection: "users", id: .string("abc"))
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.hasPrefix("db.users.deleteOne("))
    }

    @Test func mongoDeleteWithEmptyIDRendersDeleteManyEverything() {
        let change = DataSourceChangeSet.delete(collection: "users", id: .null)
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview == "db.users.deleteMany({})")
    }

    @Test func qdrantInsertRendersPutPoints() {
        let change = DataSourceChangeSet.insert(
            collection: "vecs", document: .object([("vector", .vector([1, 0]))])
        )
        let preview = DataSourceCommandPreview.render(change, kind: .vector)
        #expect(preview.hasPrefix("PUT /collections/vecs/points"))
    }

    @Test func qdrantDeleteByIDRendersPointsDeleteWithIDList() {
        let change = DataSourceChangeSet.delete(collection: "vecs", id: .int(5))
        let preview = DataSourceCommandPreview.render(change, kind: .vector)
        #expect(preview.contains("POST /collections/vecs/points/delete"))
        #expect(preview.contains("\"points\""))
    }

    @Test func qdrantDeleteWithEmptyIDRendersFilterDeleteEverything() {
        let change = DataSourceChangeSet.delete(collection: "vecs", id: .object([]))
        let preview = DataSourceCommandPreview.render(change, kind: .vector)
        #expect(preview.contains("\"filter\": {}"))
    }

    @Test func mongoUpdateByFilterRendersUpdateOneWithFilter() {
        let change = DataSourceChangeSet.updateByFilter(
            collection: "users",
            filter: .object([("email", .string("test@example.com"))]),
            update: .object([("$set", .object([("age", .int(30))]))]),
            multi: false
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.contains("db.users.updateOne("))
        #expect(preview.contains("email"))
        #expect(preview.contains("$set"))
    }

    @Test func mongoUpdateByFilterWithMultiRendersUpdateMany() {
        let change = DataSourceChangeSet.updateByFilter(
            collection: "users",
            filter: .object([("status", .string("inactive"))]),
            update: .object([("$set", .object([("active", .int(0))]))]),
            multi: true
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.contains("db.users.updateMany("))
    }

    @Test func mongoDeleteByFilterRendersDeleteOne() {
        let change = DataSourceChangeSet.deleteByFilter(
            collection: "users",
            filter: .object([("email", .string("old@example.com"))]),
            multi: false
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.contains("db.users.deleteOne("))
        #expect(preview.contains("email"))
    }

    @Test func mongoDeleteByFilterWithMultiRendersDeleteMany() {
        let change = DataSourceChangeSet.deleteByFilter(
            collection: "users",
            filter: .object([("status", .string("archived"))]),
            multi: true
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.contains("db.users.deleteMany("))
    }

    @Test func qdrantUpdateByFilterRendersFilterUpdate() {
        let change = DataSourceChangeSet.updateByFilter(
            collection: "vecs",
            filter: .object([("status", .string("active"))]),
            update: .object([("payload", .object([("updated", .int(1))]))]),
            multi: false
        )
        let preview = DataSourceCommandPreview.render(change, kind: .vector)
        #expect(preview.contains("PUT /collections/vecs/points (filter)"))
        #expect(preview.contains("\"status\""))
        #expect(preview.contains("\"updated\""))
    }

    @Test func qdrantDeleteByFilterRendersDeleteWithFilter() {
        let change = DataSourceChangeSet.deleteByFilter(
            collection: "vecs",
            filter: .object([("status", .string("old"))]),
            multi: false
        )
        let preview = DataSourceCommandPreview.render(change, kind: .vector)
        #expect(preview.contains("POST /collections/vecs/points/delete"))
        #expect(preview.contains("\"filter\""))
    }

    @Test func mongoDropRendersDropCall() {
        let preview = DataSourceCommandPreview.render(.dropCollection(collection: "users"), kind: .document)
        #expect(preview == "db.users.drop()")
    }

    @Test func mongoCreateIndexRendersWithKeysAndOptions() {
        let change = DataSourceChangeSet.createIndex(
            collection: "users", keys: .object([("email", .int(1))]), options: .object([("unique", .bool(true))])
        )
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview.hasPrefix("db.users.createIndex("))
        #expect(preview.contains("email"))
        #expect(preview.contains("unique"))
    }

    @Test func mongoCreateIndexWithoutOptionsOmitsTheSecondArgument() {
        let change = DataSourceChangeSet.createIndex(collection: "users", keys: .object([("email", .int(1))]), options: nil)
        let preview = DataSourceCommandPreview.render(change, kind: .document)
        #expect(preview == "db.users.createIndex({\"email\":1})")
    }

    @Test func mongoDropIndexRendersIndexName() {
        let preview = DataSourceCommandPreview.render(.dropIndex(collection: "users", indexName: "email_1"), kind: .document)
        #expect(preview == "db.users.dropIndex(\"email_1\")")
    }

    @Test func mongoRenameCollectionRendersNewName() {
        let preview = DataSourceCommandPreview.render(.renameCollection(collection: "users", newName: "people"), kind: .document)
        #expect(preview == "db.users.renameCollection(\"people\")")
    }
}
