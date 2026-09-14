import Foundation
import Testing

@testable import BerryDataSourceKit

@Suite("DataSourceDangerGuard")
struct DataSourceDangerGuardTests {
    @Test func deleteWithNullIDNeedsConfirm() {
        let change = DataSourceChangeSet.delete(collection: "points", id: .null)
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter))
    }

    @Test func deleteWithEmptyObjectIDNeedsConfirm() {
        let change = DataSourceChangeSet.delete(collection: "points", id: .object([]))
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter))
    }

    @Test func deleteWithEmptyStringIDNeedsConfirm() {
        let change = DataSourceChangeSet.delete(collection: "points", id: .string(""))
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter))
    }

    @Test func deleteWithRealIDIsSafe() {
        let change = DataSourceChangeSet.delete(collection: "points", id: .string("abc-123"))
        #expect(DataSourceDangerGuard.classify(change) == .safe)

        let intID = DataSourceChangeSet.delete(collection: "points", id: .int(42))
        #expect(DataSourceDangerGuard.classify(intID) == .safe)
    }

    @Test func insertAndUpdateAreAlwaysSafe() {
        let insert = DataSourceChangeSet.insert(collection: "points", document: .object([]))
        #expect(DataSourceDangerGuard.classify(insert) == .safe)

        let update = DataSourceChangeSet.update(collection: "points", id: .null, patch: .object([]))
        #expect(DataSourceDangerGuard.classify(update) == .safe)
    }

    @Test func deleteByFilterWithEmptyFilterNeedsConfirm() {
        let change = DataSourceChangeSet.deleteByFilter(collection: "users", filter: .object([]), multi: true)
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter))
    }

    @Test func deleteByFilterWithRealFilterIsSafe() {
        let change = DataSourceChangeSet.deleteByFilter(
            collection: "users", filter: .object([("email", .string("a@example.com"))]), multi: false
        )
        #expect(DataSourceDangerGuard.classify(change) == .safe)
    }

    @Test func updateByFilterWithEmptyFilterNeedsConfirm() {
        let change = DataSourceChangeSet.updateByFilter(
            collection: "users", filter: .object([]),
            update: .object([("$set", .object([("age", .int(1))]))]), multi: true
        )
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.updateWithoutFilter))
    }

    @Test func updateByFilterWithRealFilterIsSafe() {
        let change = DataSourceChangeSet.updateByFilter(
            collection: "users", filter: .object([("email", .string("a@example.com"))]),
            update: .object([("$set", .object([("age", .int(29))]))]), multi: false
        )
        #expect(DataSourceDangerGuard.classify(change) == .safe)
    }

    @Test func dropCollectionAlwaysNeedsTypedConfirm() {
        let change = DataSourceChangeSet.dropCollection(collection: "users")
        #expect(DataSourceDangerGuard.classify(change) == .typedConfirm(objectName: "users", reason: .dropCollection))
    }

    @Test func createIndexIsSafe() {
        let change = DataSourceChangeSet.createIndex(collection: "users", keys: .object([("email", .int(1))]), options: nil)
        #expect(DataSourceDangerGuard.classify(change) == .safe)
    }

    @Test func dropIndexNeedsPlainConfirm() {
        let change = DataSourceChangeSet.dropIndex(collection: "users", indexName: "email_1")
        #expect(DataSourceDangerGuard.classify(change) == .confirm(.dropIndex))
    }

    @Test func renameCollectionIsSafe() {
        let change = DataSourceChangeSet.renameCollection(collection: "users", newName: "people")
        #expect(DataSourceDangerGuard.classify(change) == .safe)
    }
}
