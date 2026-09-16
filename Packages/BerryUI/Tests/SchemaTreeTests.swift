import BerryDriverKit
import Testing
@testable import BerryUI

struct SchemaTreeTests {
    @Test func singleSchemaOrSQLiteProducesSingleFlatGroup() {
        let sqliteObjects = [
            SchemaObject(kind: .table, name: "users"),
            SchemaObject(kind: .view, name: "v_users")
        ]
        let groups = SchemaTree.group(objects: sqliteObjects, hasSchemaCapability: false)
        #expect(groups.count == 1)
        #expect(groups[0].name == nil)
        #expect(groups[0].tables.count == 1)
        #expect(groups[0].views.count == 1)
    }

    @Test func multipleSchemasProducesDistinctSchemaGroups() throws {
        let pgObjects = [
            SchemaObject(kind: .table, name: "users", database: "public"),
            SchemaObject(kind: .table, name: "items", database: "public"),
            SchemaObject(kind: .table, name: "items", database: "berry_s2"),
            SchemaObject(kind: .view, name: "summary", database: "berry_s2")
        ]
        let groups = SchemaTree.group(objects: pgObjects, hasSchemaCapability: true)
        #expect(groups.count == 2)
        let s2 = try #require(groups.first { $0.name == "berry_s2" })
        #expect(s2.tables.map(\.name) == ["items"])
        #expect(s2.views.map(\.name) == ["summary"])
        #expect(s2.totalCount == 2)

        let pub = try #require(groups.first { $0.name == "public" })
        #expect(pub.tables.count == 2)
    }

    @Test func singleSchemaWithCapabilityProducesSingleFlatGroup() {
        let pgObjects = [
            SchemaObject(kind: .table, name: "users", database: "public"),
            SchemaObject(kind: .table, name: "items", database: "public")
        ]
        let groups = SchemaTree.group(objects: pgObjects, hasSchemaCapability: true)
        #expect(groups.count == 1)
        #expect(groups[0].name == nil)
        #expect(groups[0].tables.count == 2)
    }

    @Test func singleSchemaWithoutCapabilityProducesSingleFlatGroup() {
        let mysqlObjects = [
            SchemaObject(kind: .table, name: "users", database: "berrydb"),
            SchemaObject(kind: .table, name: "items", database: "berrydb")
        ]
        let groups = SchemaTree.group(objects: mysqlObjects, hasSchemaCapability: false)
        #expect(groups.count == 1)
        #expect(groups[0].name == nil)
        #expect(groups[0].tables.count == 2)
    }

    @Test func allObjectKindsArePartitionedCorrectly() throws {
        let objects = [
            SchemaObject(kind: .table, name: "users", database: "public"),
            SchemaObject(kind: .view, name: "active_users", database: "public"),
            SchemaObject(kind: .function, name: "get_user", database: "public"),
            SchemaObject(kind: .procedure, name: "cleanup_users", database: "public"),
            SchemaObject(kind: .trigger, name: "on_user_update", database: "public"),
            SchemaObject(kind: .table, name: "audit", database: "logging")
        ]
        let groups = SchemaTree.group(objects: objects, hasSchemaCapability: true)
        #expect(groups.count == 2)

        let pub = try #require(groups.first { $0.name == "public" })
        #expect(pub.tables.count == 1)
        #expect(pub.views.count == 1)
        #expect(pub.functions.count == 1)
        #expect(pub.procedures.count == 1)
        #expect(pub.triggers.count == 1)
        #expect(pub.totalCount == 5)

        let logging = try #require(groups.first { $0.name == "logging" })
        #expect(logging.tables.count == 1)
        #expect(logging.totalCount == 1)
    }

    @Test func emptyObjectsProducesSingleFlatGroup() {
        let groups = SchemaTree.group(objects: [], hasSchemaCapability: true)
        #expect(groups.count == 1)
        #expect(groups[0].name == nil)
        #expect(groups[0].totalCount == 0)
    }
}
