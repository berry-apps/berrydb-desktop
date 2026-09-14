import BerryDataSourceKit
import BerryDriverKit
import Testing

@testable import BerryUI

@Suite("QuickOpenItem.filter (global ⌘P quick-open)")
struct QuickOpenItemTests {
    private let objects = [
        SchemaObject(kind: .table, name: "users", database: "public"),
        SchemaObject(kind: .view, name: "active_users", database: "public"),
    ]
    private let collections = [CollectionRef(name: "orders")]

    @Test func emptyQueryReturnsEverythingObjectsFirst() {
        let items = QuickOpenItem.filter(objects: objects, collections: collections, query: "")
        #expect(items.map(\.name) == ["users", "active_users", "orders"])
    }

    @Test func queryMatchesCaseInsensitiveSubstringAcrossBoth() {
        let items = QuickOpenItem.filter(objects: objects, collections: collections, query: "US")
        #expect(items.map(\.name) == ["users", "active_users"])
    }

    @Test func queryMatchesCollections() {
        let items = QuickOpenItem.filter(objects: objects, collections: collections, query: "ord")
        #expect(items.map(\.name) == ["orders"])
    }

    @Test func noMatchReturnsEmpty() {
        let items = QuickOpenItem.filter(objects: objects, collections: collections, query: "zzz")
        #expect(items.isEmpty)
    }
}
