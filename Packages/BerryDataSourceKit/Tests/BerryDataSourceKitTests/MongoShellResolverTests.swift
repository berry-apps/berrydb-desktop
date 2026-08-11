// Packages/BerryDataSourceKit/Tests/BerryDataSourceKitTests/MongoShellResolverTests.swift
import Testing
@testable import BerryDataSourceKit

@Suite("MongoShellResolver")
struct MongoShellResolverTests {
    @Test func resolvesPlainFindToMongoFind() throws {
        let statements = try MongoShellParser.parse(#"db.users.find({ active: true }).limit(5);"#)
        guard case .query(.mongoFind(let collection, let filter, let projection, let limit)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .query(.mongoFind)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("active", .bool(true))]))
        #expect(projection == nil)
        #expect(limit == 5)
    }

    @Test func resolvesFindWithSortToMongoAggregate() throws {
        let statements = try MongoShellParser.parse(
            #"db.users.find({ age: { $gt: 25 } }).sort({ age: -1 }).limit(10);"#
        )
        guard case .query(.mongoAggregate(let collection, let pipeline)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .query(.mongoAggregate) once a .sort() is chained")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [
            .object([("$match", .object([("age", .object([("$gt", .int(25))]))]))]),
            .object([("$sort", .object([("age", .int(-1))]))]),
            .object([("$limit", .int(10))]),
        ])
    }

    @Test func resolvesAggregateDirectly() throws {
        let statements = try MongoShellParser.parse(#"db.users.aggregate([{ "$sort": { "age": -1 } }]);"#)
        guard case .query(.mongoAggregate(let collection, let pipeline)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .query(.mongoAggregate)")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [.object([("$sort", .object([("age", .int(-1))]))])])
    }

    @Test func resolvesInsertOne() throws {
        let statements = try MongoShellParser.parse(#"db.users.insertOne({ name: "A" });"#)
        guard case .write(.insert(let collection, let document)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.insert)")
            return
        }
        #expect(collection == "users")
        #expect(document == .object([("name", .string("A"))]))
    }

    @Test func resolvesInsertManyToWriteMany() throws {
        let statements = try MongoShellParser.parse(#"db.users.insertMany([{ name: "A" }, { name: "B" }]);"#)
        guard case .writeMany(let changes) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .writeMany")
            return
        }
        #expect(changes.count == 2)
    }

    @Test func resolvesUpdateOneWithSetAndPush() throws {
        let statements = try MongoShellParser.parse(
            #"db.users.updateOne({ email: "a@x.com" }, { $set: { age: 29 }, $push: { skills: "x" } });"#
        )
        guard case .write(.updateByFilter(let collection, let filter, let update, let multi)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .write(.updateByFilter)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("email", .string("a@x.com"))]))
        #expect(multi == false)
        #expect(update == .object([
            ("$set", .object([("age", .int(29))])),
            ("$push", .object([("skills", .string("x"))])),
        ]))
    }

    @Test func resolvesUpdateManyWithMultiTrue() throws {
        let statements = try MongoShellParser.parse(#"db.users.updateMany({ role: "guest" }, { $set: { banned: true } });"#)
        guard case .write(.updateByFilter(_, _, _, let multi)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.updateByFilter)")
            return
        }
        #expect(multi == true)
    }

    @Test func rejectsUpdateWithoutAnOperator() throws {
        let statements = try MongoShellParser.parse(#"db.users.updateOne({ email: "a@x.com" }, { age: 29 });"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesDeleteOne() throws {
        let statements = try MongoShellParser.parse(#"db.users.deleteOne({ email: "a@x.com" });"#)
        guard case .write(.deleteByFilter(let collection, let filter, let multi)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .write(.deleteByFilter)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("email", .string("a@x.com"))]))
        #expect(multi == false)
    }

    @Test func resolvesDeleteManyWithMultiTrue() throws {
        let statements = try MongoShellParser.parse(#"db.users.deleteMany({ role: "guest" });"#)
        guard case .write(.deleteByFilter(_, _, let multi)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.deleteByFilter)")
            return
        }
        #expect(multi == true)
    }

    @Test func rejectsSkipAsUnsupportedRatherThanIgnoringIt() throws {
        let statements = try MongoShellParser.parse(#"db.users.find({}).skip(5);"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsChainedCallsOnAggregate() throws {
        let statements = try MongoShellParser.parse(#"db.users.aggregate([{ "$match": {} }]).toArray();"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsChainedCallsOnDeleteOne() throws {
        let statements = try MongoShellParser.parse(#"db.users.deleteOne({ email: "a@x.com" }).exec();"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesFindOneWithLimitOne() throws {
        let statements = try MongoShellParser.parse(#"db.users.findOne({ active: true });"#)
        guard case .query(.mongoFind(let collection, let filter, let projection, let limit)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .query(.mongoFind)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("active", .bool(true))]))
        #expect(projection == nil)
        #expect(limit == 1)
    }

    @Test func resolvesReplaceOne() throws {
        let statements = try MongoShellParser.parse(#"db.users.replaceOne({ email: "a@x.com" }, { name: "New Name" });"#)
        guard case .write(.updateByFilter(let collection, let filter, let update, let multi)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .write(.updateByFilter)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("email", .string("a@x.com"))]))
        #expect(update == .object([("name", .string("New Name"))]))
        #expect(multi == false)
    }

    @Test func rejectsReplaceOneWithOperators() throws {
        let statements = try MongoShellParser.parse(#"db.users.replaceOne({ email: "a@x.com" }, { $set: { name: "x" } });"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesFindOneAndDeleteAsDeleteByFilter() throws {
        let statements = try MongoShellParser.parse(#"db.users.findOneAndDelete({ email: "a@x.com" });"#)
        guard case .write(.deleteByFilter(let collection, let filter, let multi)) =
            try MongoShellResolver.resolve(statements[0])
        else {
            Issue.record("expected .write(.deleteByFilter)")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("email", .string("a@x.com"))]))
        #expect(multi == false)
    }

    @Test func resolvesFindOneAndReplaceAsUpdateByFilter() throws {
        let statements = try MongoShellParser.parse(#"db.users.findOneAndReplace({ email: "a@x.com" }, { name: "New" });"#)
        guard case .write(.updateByFilter(_, _, _, let multi)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.updateByFilter)")
            return
        }
        #expect(multi == false)
    }

    @Test func resolvesFindOneAndUpdateAsUpdateByFilter() throws {
        let statements = try MongoShellParser.parse(#"db.users.findOneAndUpdate({ email: "a@x.com" }, { $set: { age: 30 } });"#)
        guard case .write(.updateByFilter(_, _, _, let multi)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.updateByFilter)")
            return
        }
        #expect(multi == false)
    }

    @Test func resolvesCountDocumentsToAggregateWithCountStage() throws {
        let statements = try MongoShellParser.parse(#"db.users.countDocuments({ active: true });"#)
        guard case .query(.mongoAggregate(let collection, let pipeline)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .query(.mongoAggregate)")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [
            .object([("$match", .object([("active", .bool(true))]))]),
            .object([("$count", .string("count"))]),
        ])
    }

    @Test func resolvesEstimatedDocumentCountWithNoMatchStage() throws {
        let statements = try MongoShellParser.parse(#"db.users.estimatedDocumentCount();"#)
        guard case .query(.mongoAggregate(let collection, let pipeline)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .query(.mongoAggregate)")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [.object([("$count", .string("count"))])])
    }

    @Test func resolvesDistinctToAggregateWithGroupStage() throws {
        let statements = try MongoShellParser.parse(#"db.users.distinct("role", { active: true });"#)
        guard case .query(.mongoAggregate(let collection, let pipeline)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .query(.mongoAggregate)")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [
            .object([("$match", .object([("active", .bool(true))]))]),
            .object([("$group", .object([("_id", .string("$role"))]))]),
        ])
    }

    @Test func resolvesStatsToCollStatsAggregateStage() throws {
        let statements = try MongoShellParser.parse(#"db.users.stats();"#)
        guard case .query(.mongoAggregate(let collection, let pipeline)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .query(.mongoAggregate)")
            return
        }
        #expect(collection == "users")
        #expect(pipeline == [.object([("$collStats", .object([("storageStats", .object([]))]))])])
    }

    @Test func rejectsDistinctWithoutAFieldNameString() throws {
        let statements = try MongoShellParser.parse(#"db.users.distinct(123);"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesGetIndexesToMongoListIndexes() throws {
        let statements = try MongoShellParser.parse(#"db.users.getIndexes();"#)
        guard case .query(.mongoListIndexes(let collection)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .query(.mongoListIndexes)")
            return
        }
        #expect(collection == "users")
    }

    @Test func resolvesDropToDropCollection() throws {
        let statements = try MongoShellParser.parse(#"db.users.drop();"#)
        guard case .write(.dropCollection(let collection)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.dropCollection)")
            return
        }
        #expect(collection == "users")
    }

    @Test func resolvesCreateIndexWithKeysAndOptions() throws {
        let statements = try MongoShellParser.parse(#"db.users.createIndex({ email: 1 }, { unique: true });"#)
        guard case .write(.createIndex(let collection, let keys, let options)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.createIndex)")
            return
        }
        #expect(collection == "users")
        #expect(keys == .object([("email", .int(1))]))
        #expect(options == .object([("unique", .bool(true))]))
    }

    @Test func resolvesCreateIndexWithoutOptions() throws {
        let statements = try MongoShellParser.parse(#"db.users.createIndex({ email: 1 });"#)
        guard case .write(.createIndex(_, _, let options)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.createIndex)")
            return
        }
        #expect(options == nil)
    }

    @Test func resolvesDropIndexWithName() throws {
        let statements = try MongoShellParser.parse(#"db.users.dropIndex("email_1");"#)
        guard case .write(.dropIndex(let collection, let indexName)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.dropIndex)")
            return
        }
        #expect(collection == "users")
        #expect(indexName == "email_1")
    }

    @Test func resolvesRenameCollectionWithNewName() throws {
        let statements = try MongoShellParser.parse(#"db.users.renameCollection("people");"#)
        guard case .write(.renameCollection(let collection, let newName)) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .write(.renameCollection)")
            return
        }
        #expect(collection == "users")
        #expect(newName == "people")
    }

    @Test func rejectsCreateIndexWithoutArguments() throws {
        let statements = try MongoShellParser.parse(#"db.users.createIndex();"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsDropIndexWithoutArguments() throws {
        let statements = try MongoShellParser.parse(#"db.users.dropIndex();"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsDropIndexWithNonStringArgument() throws {
        let statements = try MongoShellParser.parse(#"db.users.dropIndex(123);"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsRenameCollectionWithoutArguments() throws {
        let statements = try MongoShellParser.parse(#"db.users.renameCollection();"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsRenameCollectionWithNonStringArgument() throws {
        let statements = try MongoShellParser.parse(#"db.users.renameCollection(123);"#)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesBulkWriteWithInsertUpdateDelete() throws {
        let script = #"""
        db.users.bulkWrite([
          { insertOne: { document: { name: "A" } } },
          { updateOne: { filter: { name: "A" }, update: { $set: { age: 1 } } } },
          { deleteMany: { filter: { name: "B" } } }
        ]);
        """#
        let statements = try MongoShellParser.parse(script)
        guard case .writeMany(let changes) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .writeMany")
            return
        }
        #expect(changes.count == 3)
        guard case .insert(let collection1, let document) = changes[0] else {
            Issue.record("expected changes[0] to be .insert")
            return
        }
        #expect(collection1 == "users")
        #expect(document == .object([("name", .string("A"))]))
        guard case .updateByFilter(_, let filter, let update, let multi) = changes[1] else {
            Issue.record("expected changes[1] to be .updateByFilter")
            return
        }
        #expect(filter == .object([("name", .string("A"))]))
        #expect(update == .object([("$set", .object([("age", .int(1))]))]))
        #expect(multi == false)
        guard case .deleteByFilter(_, let deleteFilter, let deleteMulti) = changes[2] else {
            Issue.record("expected changes[2] to be .deleteByFilter")
            return
        }
        #expect(deleteFilter == .object([("name", .string("B"))]))
        #expect(deleteMulti == true)
    }

    @Test func resolvesBulkWriteReplaceOne() throws {
        let script = #"db.users.bulkWrite([{ replaceOne: { filter: { name: "A" }, replacement: { name: "B" } } }]);"#
        let statements = try MongoShellParser.parse(script)
        guard case .writeMany(let changes) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .writeMany")
            return
        }
        #expect(changes.count == 1)
        guard case .updateByFilter(_, _, let update, let multi) = changes[0] else {
            Issue.record("expected .updateByFilter")
            return
        }
        #expect(update == .object([("name", .string("B"))]))
        #expect(multi == false)
    }

    @Test func rejectsBulkWriteEntryWithMultipleKeys() throws {
        let script = #"db.users.bulkWrite([{ insertOne: { document: {} }, deleteOne: { filter: {} } }]);"#
        let statements = try MongoShellParser.parse(script)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsBulkWriteEntryWithUnknownOperation() throws {
        let script = #"db.users.bulkWrite([{ frobnicate: {} }]);"#
        let statements = try MongoShellParser.parse(script)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsBulkWriteUpdateWithoutOperator() throws {
        let script = #"db.users.bulkWrite([{ updateOne: { filter: {}, update: { age: 1 } } }]);"#
        let statements = try MongoShellParser.parse(script)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func rejectsBulkWriteReplaceWithOperator() throws {
        let script = #"db.users.bulkWrite([{ replaceOne: { filter: {}, replacement: { $set: { age: 1 } } } }]);"#
        let statements = try MongoShellParser.parse(script)
        #expect(throws: MongoShellResolveError.self) {
            try MongoShellResolver.resolve(statements[0])
        }
    }

    @Test func resolvesBulkWriteUpdateMany() throws {
        let script = #"""
        db.users.bulkWrite([
          { updateMany: { filter: { active: true }, update: { $set: { tier: "gold" } } } }
        ]);
        """#
        let statements = try MongoShellParser.parse(script)
        guard case .writeMany(let changes) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .writeMany")
            return
        }
        #expect(changes.count == 1)
        guard case .updateByFilter(_, let filter, let update, let multi) = changes[0] else {
            Issue.record("expected changes[0] to be .updateByFilter")
            return
        }
        #expect(filter == .object([("active", .bool(true))]))
        #expect(update == .object([("$set", .object([("tier", .string("gold"))]))]))
        #expect(multi == true)
    }

    @Test func resolvesBulkWriteDeleteOne() throws {
        let script = #"db.users.bulkWrite([{ deleteOne: { filter: { name: "A" } } }]);"#
        let statements = try MongoShellParser.parse(script)
        guard case .writeMany(let changes) = try MongoShellResolver.resolve(statements[0]) else {
            Issue.record("expected .writeMany")
            return
        }
        #expect(changes.count == 1)
        guard case .deleteByFilter(_, let filter, let multi) = changes[0] else {
            Issue.record("expected changes[0] to be .deleteByFilter")
            return
        }
        #expect(filter == .object([("name", .string("A"))]))
        #expect(multi == false)
    }
}
