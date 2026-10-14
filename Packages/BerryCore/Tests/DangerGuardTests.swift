import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

@Suite("DangerGuard")
struct DangerGuardTests {
    @Test func updateWithoutWhereNeedsConfirm() {
        #expect(DangerGuard.classify("UPDATE users SET a = 1", isProduction: false)
            == .confirm(.updateWithoutWhere))
        #expect(DangerGuard.classify("update users set a = 1 where id = 2", isProduction: false)
            == .safe)
    }

    @Test func whereInsideStringDoesNotCount() {
        // The only WHERE lives inside a string literal — still no real WHERE.
        let sql = "UPDATE users SET note = 'no where here'"
        #expect(DangerGuard.classify(sql, isProduction: false) == .confirm(.updateWithoutWhere))
    }

    @Test func deleteWithoutWhereNeedsConfirm() {
        #expect(DangerGuard.classify("DELETE FROM logs", isProduction: false)
            == .confirm(.deleteWithoutWhere))
 // A targeted DELETE still warns — it removes data, just with
        // the softer, batchable confirm.
        #expect(DangerGuard.classify("DELETE FROM logs WHERE id < 5", isProduction: false)
            == .confirm(.deleteData))
    }

    @Test func leadingCommentsAreSkipped() {
        let sql = "-- cleanup\n/* all rows */ DELETE FROM logs"
        #expect(DangerGuard.classify(sql, isProduction: false) == .confirm(.deleteWithoutWhere))
    }

    @Test func selectAndTransactionControlAreSafe() {
        #expect(DangerGuard.classify("SELECT * FROM users", isProduction: true) == .safe)
        #expect(DangerGuard.classify("BEGIN", isProduction: true) == .safe)
        #expect(DangerGuard.classify("COMMIT", isProduction: true) == .safe)
        #expect(DangerGuard.classify("EXPLAIN SELECT 1", isProduction: true) == .safe)
    }

    @Test func writesOnProductionNeedConfirm() {
        #expect(DangerGuard.classify("INSERT INTO t VALUES (1)", isProduction: true)
            == .confirm(.writeOnProduction))
        #expect(DangerGuard.classify("UPDATE t SET a = 1 WHERE id = 2", isProduction: true)
            == .confirm(.writeOnProduction))
        // No-WHERE stays the sharper warning even on production.
        #expect(DangerGuard.classify("UPDATE t SET a = 1", isProduction: true)
            == .confirm(.updateWithoutWhere))
    }

    @Test func dropAndTruncateOnProductionNeedTypedConfirm() {
        #expect(DangerGuard.classify("DROP TABLE IF EXISTS public.users CASCADE", isProduction: true)
            == .typedConfirm(objectName: "users", reason: .dropOnProduction))
        #expect(DangerGuard.classify(#"DROP VIEW "Số Liệu""#, isProduction: true)
            == .typedConfirm(objectName: "Số Liệu", reason: .dropOnProduction))
        #expect(DangerGuard.classify("TRUNCATE TABLE orders", isProduction: true)
            == .typedConfirm(objectName: "orders", reason: .truncateOnProduction))
        // Off production, destructive DDL gets the soft (batchable) confirm
 // instead of the typed gate.
        #expect(DangerGuard.classify("DROP TABLE tmp", isProduction: false) == .confirm(.dropObject))
        #expect(DangerGuard.classify("TRUNCATE t", isProduction: false) == .confirm(.truncateTable))
    }

    // MARK: A write wrapped in WITH or EXPLAIN ANALYZE

    @Test func dataModifyingCTEIsClassifiedByItsWrite() {
        let targeted = "WITH d AS (DELETE FROM t WHERE id < 100 RETURNING *) SELECT count(*) FROM d"
        #expect(DangerGuard.classify(targeted, isProduction: false) == .confirm(.deleteData))
        #expect(DangerGuard.classify(targeted, isProduction: true) == .confirm(.writeOnProduction))
        #expect(DangerGuard.classify("WITH d AS (DELETE FROM t RETURNING *) SELECT count(*) FROM d", isProduction: false)
            == .confirm(.deleteWithoutWhere))
        // The write can also be the statement the WITH clause leads into.
        #expect(DangerGuard.classify("WITH ids AS (SELECT id FROM t) UPDATE t SET a = 1", isProduction: false)
            == .confirm(.updateWithoutWhere))
        #expect(DangerGuard.classify("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x", isProduction: true)
            == .confirm(.writeOnProduction))
    }

    @Test func explainAnalyzeIsClassifiedByTheStatementItRuns() {
        #expect(DangerGuard.classify("EXPLAIN ANALYZE UPDATE t SET a = 1", isProduction: false)
            == .confirm(.updateWithoutWhere))
        #expect(DangerGuard.classify("EXPLAIN (ANALYZE, BUFFERS) DELETE FROM t WHERE id = 1", isProduction: false)
            == .confirm(.deleteData))
        #expect(DangerGuard.classify("EXPLAIN ANALYSE INSERT INTO t VALUES (1)", isProduction: true)
            == .confirm(.writeOnProduction))
        #expect(DangerGuard.classify("EXPLAIN ANALYZE WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", isProduction: false)
            == .confirm(.deleteWithoutWhere))
    }

    /// Guards for the two tests above: a read that only mentions a write
    /// keyword, or an EXPLAIN that only plans a write, stays safe.
    @Test func readsWrappedInWithOrExplainStaySafe() {
        let reads = [
            "WITH x AS (SELECT replace(name, 'a', 'b') AS n FROM t WHERE id = 1) SELECT * FROM x",
            "WITH x AS (SELECT * FROM t FOR UPDATE) SELECT * FROM x",
            "WITH x AS (SELECT * FROM t FOR NO KEY UPDATE) SELECT * FROM x",
            "WITH x AS (SELECT 'delete' AS note, \"update\" FROM t) SELECT * FROM x",
            "EXPLAIN UPDATE t SET a = 1",
            "EXPLAIN ANALYZE SELECT * FROM t",
        ]
        for sql in reads {
            #expect(DangerGuard.classify(sql, isProduction: true) == .safe, "\(sql)")
        }
    }

    // MARK: Gate integration — denied statement must never reach the driver

    private struct DenyAll: DangerConfirmer {
        func confirm(_ level: DangerLevel, sql: String) async -> Bool { false }
    }

    @Test func deniedStatementDoesNotExecute() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-guard-\(UUID().uuidString).sqlite"
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

        _ = try await exec("CREATE TABLE t (x INTEGER)")
        _ = try await exec("INSERT INTO t VALUES (1), (2)")

        let previousConfirmer = QueryService.dangerConfirmer
        QueryService.dangerConfirmer = DenyAll()
        defer { QueryService.dangerConfirmer = previousConfirmer }

        await #expect(throws: DriverError.self) {
            _ = try await exec("DELETE FROM t")
        }
        QueryService.dangerConfirmer = previousConfirmer
        let rows = try await exec("SELECT count(*) FROM t")
        #expect(rows == [[.int(2)]], "denied DELETE must not touch the data")
        await manager.close(session.id)
    }
}
