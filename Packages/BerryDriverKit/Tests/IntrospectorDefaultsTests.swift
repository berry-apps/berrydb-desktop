import Foundation
import Testing

@testable import BerryDriverKit

/// Implements only the five pre-existing members, the way a driver that has
/// not been given bulk queries does.
private struct PerTableOnlyIntrospector: Introspector {
    /// Foreign keys reported for `orders`, so a test can supply the shape it
    /// needs without changing what the other tests see.
    var ordersForeignKeys = [
        ForeignKeyInfo(column: "customer_id", referencedSchema: "shop", referencedTable: "customers", referencedColumn: "id"),
    ]
    /// A listed table whose detail read fails, the way a lost connection
    /// fails it.
    var brokenTable: String?

    func databases() async throws -> [DatabaseInfo] { [] }
    func objects(in database: String?) async throws -> [SchemaObject] {
        [
            SchemaObject(kind: .table, name: "orders", database: "shop"),
            SchemaObject(kind: .view, name: "recent", database: "shop"),
            SchemaObject(kind: .function, name: "f()", database: "shop"),
        ]
    }
    func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        // The error a driver raises for a table that was dropped after it was listed.
        if ref.name == "gone" { throw DriverError.queryFailed(message: "relation does not exist", code: nil) }
        if ref.name == brokenTable { throw DriverError.connectionLost("server closed the connection unexpectedly") }
        return TableDetail(
            ref: ref,
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [],
            foreignKeys: ref.name == "orders" ? ordersForeignKeys : []
        )
    }
    func tableStats(_ ref: TableRef) async throws -> TableStats {
        TableStats(estimatedRowCount: nil, sizeBytes: nil, engine: nil, comment: nil)
    }
    func ddl(of object: SchemaObject) async throws -> String { "" }
}

@Suite("Introspector bulk defaults")
struct IntrospectorDefaultsTests {
    private let introspector = PerTableOnlyIntrospector()

    @Test func defaultsDeclareNoBulkSupportAndNoToken() async throws {
        #expect(introspector.bulkIntrospection == false)
        #expect(try await introspector.schemaVersionToken(scope: .allUserSchemas) == nil)
    }

    @Test func summariesComeFromObjectsWithoutFingerprints() async throws {
        let summaries = try await introspector.objectSummaries(scope: .allUserSchemas)
        #expect(summaries.map(\.ref.name) == ["orders", "recent"])
        #expect(summaries.map(\.kind) == [.table, .view])
        #expect(summaries.allSatisfy { $0.fingerprint == nil })
    }

    @Test func detailsLoopOverTableDetailInOrder() async throws {
        let refs = [TableRef(database: "shop", name: "orders"), TableRef(database: "shop", name: "recent")]
        let details = try await introspector.tableDetails(refs)
        #expect(details.map(\.ref) == refs)
    }

    @Test func foreignKeysAreDerivedFromTableDetails() async throws {
        let relations = try await introspector.foreignKeys(scope: .allUserSchemas)
        #expect(relations == [
            ForeignKeyRelation(
                source: TableRef(database: "shop", name: "orders"), column: "customer_id",
                target: TableRef(database: "shop", name: "customers"), referencedColumn: "id"
            ),
        ])
    }

    @Test func detailsSkipATableThatVanishedAfterListing() async throws {
        let orders = TableRef(database: "shop", name: "orders")
        let gone = TableRef(database: "shop", name: "gone")
        let recent = TableRef(database: "shop", name: "recent")
        let details = try await introspector.tableDetails([orders, gone, recent])
        #expect(details.map(\.ref) == [orders, recent])
    }

    @Test func detailsRethrowAFailureForATableThatIsStillListed() async throws {
        let broken = PerTableOnlyIntrospector(brokenTable: "orders")
        let refs = [TableRef(database: "shop", name: "recent"), TableRef(database: "shop", name: "orders")]
        await #expect(throws: DriverError.self) { try await broken.tableDetails(refs) }
    }

    @Test func detailsStopWithCancellationErrorWhenTheTaskIsCancelled() async throws {
        let refs = [TableRef(database: "shop", name: "orders"), TableRef(database: "shop", name: "recent")]
        let task = Task { [introspector] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await introspector.tableDetails(refs)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func foreignKeyWithoutReferencedSchemaTargetsTheSourceDatabase() async throws {
        // A driver with a single namespace reports no referenced schema.
        let sameNamespace = PerTableOnlyIntrospector(ordersForeignKeys: [
            ForeignKeyInfo(column: "region_id", referencedSchema: nil, referencedTable: "regions", referencedColumn: "id"),
        ])
        let relations = try await sameNamespace.foreignKeys(scope: .allUserSchemas)
        #expect(relations.map(\.target) == [TableRef(database: "shop", name: "regions")])
    }

    @Test func foreignKeyWithReferencedSchemaTargetsThatSchema() async throws {
        let crossSchema = PerTableOnlyIntrospector(ordersForeignKeys: [
            ForeignKeyInfo(column: "invoice_id", referencedSchema: "billing", referencedTable: "invoices", referencedColumn: "id"),
        ])
        let relations = try await crossSchema.foreignKeys(scope: .allUserSchemas)
        #expect(relations.map(\.target) == [TableRef(database: "billing", name: "invoices")])
    }
}
