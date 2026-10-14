import BerryDriverKit
import Foundation
import Testing

@testable import BerryGraph

@Suite("Schema definition canonical form")
struct SchemaDefinitionTests {
    func column(_ name: String, type: String = "int", nullable: Bool = true, pk: Bool = false) -> ColumnInfo {
        ColumnInfo(name: name, declaredType: type, isNullable: nullable, defaultValue: nil, isPrimaryKey: pk)
    }

    func detail(columns: [ColumnInfo], indexes: [IndexInfo] = []) -> TableDetail {
        TableDetail(ref: TableRef(database: "shop", name: "orders"), columns: columns, indexes: indexes, foreignKeys: [])
    }

    @Test func sameDefinitionSameHash() {
        let a = SchemaDefinition(detail: detail(columns: [column("id", pk: true), column("total")]))
        let b = SchemaDefinition(detail: detail(columns: [column("id", pk: true), column("total")]))
        #expect(a.hash == b.hash)
        #expect(a.hash.count == 16)
    }

    @Test func columnOrderIsSignificant() {
        let a = SchemaDefinition(detail: detail(columns: [column("id"), column("total")]))
        let b = SchemaDefinition(detail: detail(columns: [column("total"), column("id")]))
        #expect(a.hash != b.hash)
    }

    @Test func indexOrderIsNotSignificant() {
        let i1 = IndexInfo(name: "orders_a", isUnique: false, columns: ["a"])
        let i2 = IndexInfo(name: "orders_b", isUnique: true, columns: ["b"])
        let a = SchemaDefinition(detail: detail(columns: [column("id")], indexes: [i1, i2]))
        let b = SchemaDefinition(detail: detail(columns: [column("id")], indexes: [i2, i1]))
        #expect(a.hash == b.hash)
        #expect(a.indexes.map(\.name) == ["orders_a", "orders_b"])
    }

    @Test func typeChangeChangesHash() {
        let a = SchemaDefinition(detail: detail(columns: [column("total", type: "int")]))
        let b = SchemaDefinition(detail: detail(columns: [column("total", type: "bigint")]))
        #expect(a.hash != b.hash)
    }

    @Test func jsonRoundTripsAndIsStable() throws {
        let a = SchemaDefinition(detail: detail(columns: [column("id", pk: true)], indexes: [IndexInfo(name: "pk", isUnique: true, columns: ["id"])]))
        let json = try a.json()
        #expect(json == #"{"columns":[{"name":"id","nullable":true,"primaryKey":true,"type":"int"}],"indexes":[{"columns":["id"],"name":"pk","unique":true}]}"#)
        #expect(try SchemaDefinition.decode(json) == a)
    }

    @Test func columnAndIndexTextListEveryNameFolded() {
        let a = SchemaDefinition(detail: detail(
            columns: [column("CustomerID"), column("Straße")],
            indexes: [IndexInfo(name: "IX_Orders", isUnique: false, columns: ["CustomerID"])]
        ))
        #expect(a.columnText == "customerid\nstrasse")
        #expect(a.indexText == "ix_orders")
    }

    @Test func diffReportsAddedRemovedChangedColumnsAndIndexes() {
        let before = SchemaDefinition(detail: detail(
            columns: [column("id", pk: true), column("total", type: "int"), column("note")],
            indexes: [IndexInfo(name: "old_idx", isUnique: false, columns: ["note"])]
        ))
        let after = SchemaDefinition(detail: detail(
            columns: [column("id", pk: true), column("total", type: "bigint"), column("created_at", type: "timestamp")],
            indexes: [IndexInfo(name: "new_idx", isUnique: false, columns: ["created_at"])]
        ))
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.columnsAdded == ["created_at"])
        #expect(diff.columnsRemoved == ["note"])
        #expect(diff.columnsChanged.map(\.name) == ["total"])
        #expect(diff.columnsChanged.first?.from.type == "int")
        #expect(diff.columnsChanged.first?.to.type == "bigint")
        #expect(diff.indexesAdded == ["new_idx"])
        #expect(diff.indexesRemoved == ["old_idx"])
        #expect(!diff.isEmpty)
        #expect(SchemaDefinition.diff(from: before, to: before).isEmpty)
    }

    @Test func indexChangedInPlaceIsReportedNotAddedOrRemoved() {
        let before = SchemaDefinition(detail: detail(
            columns: [column("id"), column("email")],
            indexes: [IndexInfo(name: "email_idx", isUnique: false, columns: ["email"])]
        ))
        let after = SchemaDefinition(detail: detail(
            columns: [column("id"), column("email")],
            indexes: [IndexInfo(name: "email_idx", isUnique: true, columns: ["email"])]
        ))
        #expect(before.hash != after.hash)
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.indexesChanged.map(\.name) == ["email_idx"])
        #expect(diff.indexesChanged.first?.from == SchemaDefinition.Index(name: "email_idx", unique: false, columns: ["email"]))
        #expect(diff.indexesChanged.first?.to == SchemaDefinition.Index(name: "email_idx", unique: true, columns: ["email"]))
        #expect(diff.indexesAdded.isEmpty)
        #expect(diff.indexesRemoved.isEmpty)
        #expect(!diff.isEmpty)
    }

    @Test func indexColumnListChangeIsReported() {
        let before = SchemaDefinition(detail: detail(
            columns: [column("a"), column("b")],
            indexes: [IndexInfo(name: "ab_idx", isUnique: false, columns: ["a"])]
        ))
        let after = SchemaDefinition(detail: detail(
            columns: [column("a"), column("b")],
            indexes: [IndexInfo(name: "ab_idx", isUnique: false, columns: ["a", "b"])]
        ))
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.indexesChanged.map(\.name) == ["ab_idx"])
        #expect(!diff.isEmpty)
    }

    @Test func swappedColumnsAreReportedAsReordered() {
        let before = SchemaDefinition(detail: detail(columns: [column("id"), column("total")]))
        let after = SchemaDefinition(detail: detail(columns: [column("total"), column("id")]))
        #expect(before.hash != after.hash)
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.columnsReordered)
        #expect(diff.columnsAdded.isEmpty)
        #expect(diff.columnsRemoved.isEmpty)
        #expect(diff.columnsChanged.isEmpty)
        #expect(!diff.isEmpty)
    }

    @Test func addingAColumnWithoutReorderingIsNotReordered() {
        let before = SchemaDefinition(detail: detail(columns: [column("id"), column("total")]))
        let after = SchemaDefinition(detail: detail(columns: [column("id"), column("note"), column("total")]))
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.columnsAdded == ["note"])
        #expect(!diff.columnsReordered)
    }

    @Test func removingAColumnWithoutReorderingIsNotReordered() {
        let before = SchemaDefinition(detail: detail(columns: [column("id"), column("note"), column("total")]))
        let after = SchemaDefinition(detail: detail(columns: [column("id"), column("total")]))
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.columnsRemoved == ["note"])
        #expect(!diff.columnsReordered)
    }

    @Test func reorderIsDetectedAlongsideAnAddedColumn() {
        let before = SchemaDefinition(detail: detail(columns: [column("id"), column("total")]))
        let after = SchemaDefinition(detail: detail(columns: [column("total"), column("note"), column("id")]))
        let diff = SchemaDefinition.diff(from: before, to: after)
        #expect(diff.columnsAdded == ["note"])
        #expect(diff.columnsReordered)
    }

    // Stored hashes are compared against freshly computed ones to decide
    // whether a table changed, so this value is a contract with every store
    // that already holds versions. Changing the canonical JSON keys, their
    // order or the FNV constants changes it and would re-version every stored
    // table on the next harvest; make that change deliberately or not at all.
    @Test func hashOfAKnownDefinitionIsPinned() {
        let definition = SchemaDefinition(detail: detail(
            columns: [
                ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                ColumnInfo(name: "total", declaredType: "numeric", isNullable: true, defaultValue: "0", isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "orders_pkey", isUnique: true, columns: ["id"])]
        ))
        #expect(definition.hash == "d13af0ae444dc9ea")
    }

    @Test func decodingCanonicalisesIndexOrder() throws {
        let canonical = SchemaDefinition(detail: detail(
            columns: [column("id")],
            indexes: [
                IndexInfo(name: "orders_a", isUnique: false, columns: ["a"]),
                IndexInfo(name: "orders_b", isUnique: true, columns: ["b"]),
            ]
        ))
        let outOfOrder = #"{"columns":[{"name":"id","nullable":true,"primaryKey":false,"type":"int"}],"indexes":[{"columns":["b"],"name":"orders_b","unique":true},{"columns":["a"],"name":"orders_a","unique":false}]}"#
        let decoded = try SchemaDefinition.decode(outOfOrder)
        #expect(decoded.indexes.map(\.name) == ["orders_a", "orders_b"])
        #expect(decoded.hash == canonical.hash)
        #expect(decoded == canonical)
    }
}
