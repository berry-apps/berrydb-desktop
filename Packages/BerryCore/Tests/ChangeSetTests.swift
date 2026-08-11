import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

private struct TestDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
}

@Suite("ChangeSet (DL-03/04/05, 06 · L3)")
struct ChangeSetTests {
    private let dialect = TestDialect()
    private let table = TableRef(name: "users")

    @Test func generatesUpdateWithEscaping() {
        var changeSet = ChangeSet(table: table, pkColumns: ["id"])
        changeSet.stageUpdate(pk: ["id": .int(42)], column: "name", value: .text("O'Brien; DROP TABLE x"))
        #expect(changeSet.statements(dialect: dialect) == [
            #"UPDATE "users" SET "name" = 'O''Brien; DROP TABLE x' WHERE "id" = 42"#
        ])
    }

    @Test func coalescesRepeatedCellEdits() {
        var changeSet = ChangeSet(table: table, pkColumns: ["id"])
        changeSet.stageUpdate(pk: ["id": .int(1)], column: "name", value: .text("a"))
        changeSet.stageUpdate(pk: ["id": .int(1)], column: "name", value: .text("b"))
        #expect(changeSet.count == 1)
        #expect(changeSet.statements(dialect: dialect)[0].contains("'b'"))
    }

    @Test func multiColumnPrimaryKey() {
        var changeSet = ChangeSet(table: table, pkColumns: ["a", "b"])
        changeSet.stageUpdate(
            pk: ["b": .text("x"), "a": .int(1)],
            column: "v", value: .null
        )
        #expect(changeSet.statements(dialect: dialect) == [
            #"UPDATE "users" SET "v" = NULL WHERE "a" = 1 AND "b" = 'x'"#
        ])
    }

    @Test func insertRendersSortedColumns() {
        var changeSet = ChangeSet(table: table, pkColumns: ["id"])
        changeSet.stageInsert(values: ["name": .text("mai"), "id": .int(7), "note": .null])
        #expect(changeSet.statements(dialect: dialect) == [
            #"INSERT INTO "users" ("id", "name", "note") VALUES (7, 'mai', NULL)"#
        ])
    }

    @Test func deleteDropsPendingUpdatesForRow() {
        var changeSet = ChangeSet(table: table, pkColumns: ["id"])
        changeSet.stageUpdate(pk: ["id": .int(5)], column: "name", value: .text("x"))
        changeSet.stageDelete(pk: ["id": .int(5)])
        changeSet.stageDelete(pk: ["id": .int(5)])   // idempotent
        #expect(changeSet.statements(dialect: dialect) == [
            #"DELETE FROM "users" WHERE "id" = 5"#
        ])
    }

    @Test func tableWithoutPKIsReadOnly() {
        let changeSet = ChangeSet(table: table, pkColumns: [])
        #expect(!changeSet.canEdit)
    }

    @Test func nullSafeWhereClause() {
        var changeSet = ChangeSet(table: table, pkColumns: ["id"])
        changeSet.stageDelete(pk: ["id": .null])
        #expect(changeSet.statements(dialect: dialect) == [
            #"DELETE FROM "users" WHERE "id" IS NULL"#
        ])
    }

    // MARK: - Integration: apply against a real SQLite database

    @Test func appliesTransactionallyToSQLite() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-changeset-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))

        func exec(_ sql: String) async throws -> [[BerryValue]] {
            var rows: [[BerryValue]] = []
            for try await event in QueryService.execute(sql, on: session, autoLimit: nil) {
                if case .rows(let batch) = event { rows += batch }
            }
            return rows
        }

        _ = try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, score REAL)")
        _ = try await exec("INSERT INTO t VALUES (1, 'an', 1.5), (2, 'binh', 2.5)")

        var changeSet = ChangeSet(table: TableRef(name: "t"), pkColumns: ["id"])
        changeSet.stageUpdate(pk: ["id": .int(1)], column: "name", value: .text("an-mới"))
        changeSet.stageInsert(values: ["id": .int(3), "name": .text("chi"), "score": .double(3.5)])
        changeSet.stageDelete(pk: ["id": .int(2)])
        let executed = try await changeSet.apply(on: session)
        #expect(executed == 3)

        let rows = try await exec("SELECT id, name FROM t ORDER BY id")
        #expect(rows == [
            [.int(1), .text("an-mới")],
            [.int(3), .text("chi")],
        ])

        // Failure rolls back: second statement hits a UNIQUE violation.
        var failing = ChangeSet(table: TableRef(name: "t"), pkColumns: ["id"])
        failing.stageUpdate(pk: ["id": .int(1)], column: "name", value: .text("không-được-ghi"))
        failing.stageInsert(values: ["id": .int(1), "name": .text("trùng-pk")])
        await #expect(throws: DriverError.self) {
            try await failing.apply(on: session)
        }
        let after = try await exec("SELECT name FROM t WHERE id = 1")
        #expect(after == [[.text("an-mới")]], "rollback must undo the first statement")

        await manager.close(session.id)
    }
}
