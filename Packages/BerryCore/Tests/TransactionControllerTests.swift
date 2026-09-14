import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

@Suite("Transaction controller")
@MainActor
struct TransactionControllerTests {
    private func makeSession() async throws -> (ConnectionManager, Session, String) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-tx-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))
        return (manager, session, path)
    }

    private func exec(_ sql: String, on session: Session) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(sql, on: session, autoLimit: nil) {
            if case .rows(let batch) = event { rows += batch }
        }
        return rows
    }

    @Test func rollbackUndoesUncommittedWork() async throws {
        let (_, session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: session)

        let tx = TransactionController()
        tx.autoCommit = false
        #expect(await tx.beginIfNeeded(session: session))
        #expect(tx.isActive)

        _ = try await exec("INSERT INTO t VALUES (1)", on: session)
        #expect(await tx.rollback(session: session))
        #expect(!tx.isActive)

        let rows = try await exec("SELECT id FROM t", on: session)
        #expect(rows.isEmpty, "rollback must discard the insert")
    }

    @Test func commitPersistsWork() async throws {
        let (_, session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: session)

        let tx = TransactionController()
        tx.autoCommit = false
        _ = await tx.beginIfNeeded(session: session)
        _ = try await exec("INSERT INTO t VALUES (7)", on: session)
        #expect(await tx.commit(session: session))
        #expect(!tx.isActive)

        let rows = try await exec("SELECT id FROM t", on: session)
        #expect(rows == [[.int(7)]])
    }

    @Test func autoCommitModeOpensNoTransaction() async throws {
        let (_, session, _) = try await makeSession()
        let tx = TransactionController()
        // Default is auto-commit on: beginIfNeeded is a no-op that still
        // reports success so the run proceeds.
        #expect(await tx.beginIfNeeded(session: session))
        #expect(!tx.isActive)
    }

    @Test func switchingAutoCommitOnCommitsOpenTransaction() async throws {
        let (_, session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: session)

        let tx = TransactionController()
        tx.autoCommit = false
        _ = await tx.beginIfNeeded(session: session)
        _ = try await exec("INSERT INTO t VALUES (5)", on: session)
        // Flipping auto-commit back on commits the pending transaction.
        await tx.setAutoCommit(true, session: session)
        #expect(!tx.isActive)

        let rows = try await exec("SELECT id FROM t", on: session)
        #expect(rows == [[.int(5)]], "switching to auto-commit must commit, not roll back")
    }
}
