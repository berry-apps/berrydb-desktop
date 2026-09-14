import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

private struct TestDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
}

@Suite("Table designer DDL")
struct TableDesignTests {
    private let dialect = TestDialect()

    @Test func createTableWithColumnsPKAndDefault() {
        let design = TableDesign(
            name: "users",
            columns: [
                ColumnDesign(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                ColumnDesign(name: "name", type: "TEXT", isNullable: false),
                ColumnDesign(name: "score", type: "REAL", isNullable: true, defaultValue: "0"),
            ]
        )
        let sql = design.statements(dialect: dialect)
        #expect(sql.count == 1)
        #expect(sql[0].contains(#"CREATE TABLE "users" ("#))
        #expect(sql[0].contains(#""id" INTEGER NOT NULL"#))
        #expect(sql[0].contains(#""score" REAL DEFAULT 0"#))
        #expect(sql[0].contains(#"PRIMARY KEY ("id")"#))
    }

    @Test func compositePrimaryKey() {
        let design = TableDesign(
            name: "membership",
            columns: [
                ColumnDesign(name: "user_id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                ColumnDesign(name: "group_id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
            ]
        )
        #expect(design.statements(dialect: dialect)[0].contains(#"PRIMARY KEY ("user_id", "group_id")"#))
    }

    @Test func foreignKeyWithActions() {
        let design = TableDesign(
            name: "orders",
            columns: [ColumnDesign(name: "id", type: "INTEGER", isPrimaryKey: true)],
            foreignKeys: [
                ForeignKeyDesign(
                    column: "user_id", referencedTable: "users", referencedColumn: "id",
                    onDelete: .cascade, onUpdate: .noAction
                ),
            ]
        )
        let sql = design.statements(dialect: dialect)[0]
        #expect(sql.contains(#"FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE"#))
        #expect(!sql.contains("ON UPDATE"))
    }

    @Test func indexBecomesSeparateStatement() {
        let design = TableDesign(
            name: "t",
            columns: [ColumnDesign(name: "a", type: "INTEGER"), ColumnDesign(name: "b", type: "INTEGER")],
            indexes: [IndexDesign(name: "idx_ab", columns: ["a", "b"], isUnique: true)]
        )
        let sql = design.statements(dialect: dialect)
        #expect(sql.count == 2)
        #expect(sql[1] == #"CREATE UNIQUE INDEX "idx_ab" ON "t" ("a", "b")"#)
    }

    @Test func blankColumnsAndIndexesAreSkipped() {
        let design = TableDesign(
            name: "t",
            columns: [
                ColumnDesign(name: "id", type: "INTEGER", isPrimaryKey: true),
                ColumnDesign(name: "  ", type: "TEXT"),
            ],
            indexes: [IndexDesign(name: "", columns: ["id"])]
        )
        let sql = design.statements(dialect: dialect)
        #expect(sql.count == 1)
        #expect(!sql[0].contains("\"  \""))
    }

    @Test func validationCatchesEmptyAndDuplicates() {
        #expect(TableDesign(name: "", columns: []).validationErrors.contains("Table name is required"))
        let dup = TableDesign(
            name: "t",
            columns: [ColumnDesign(name: "x", type: "INT"), ColumnDesign(name: "X", type: "INT")]
        )
        #expect(dup.validationErrors.contains("Duplicate column names"))
        #expect(!dup.isValid)
    }

    @Test func appliesToRealSQLite() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-design-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))

        let design = TableDesign(
            name: "widgets",
            columns: [
                ColumnDesign(name: "id", type: "INTEGER", isNullable: false, isPrimaryKey: true),
                ColumnDesign(name: "label", type: "TEXT", isNullable: false),
                ColumnDesign(name: "qty", type: "INTEGER", defaultValue: "0"),
            ],
            indexes: [IndexDesign(name: "idx_label", columns: ["label"], isUnique: true)]
        )
        let executed = try await design.apply(on: session)
        #expect(executed == 2)

        // The table exists and enforces the NOT NULL + default.
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(
            "INSERT INTO widgets (id, label) VALUES (1, 'a')", on: session, autoLimit: nil
        ) where false { if case .rows(let b) = event { rows += b } }
        for try await event in QueryService.execute(
            "SELECT id, label, qty FROM widgets", on: session, autoLimit: nil
        ) {
            if case .rows(let b) = event { rows += b }
        }
        #expect(rows == [[.int(1), .text("a"), .int(0)]])
    }
}
