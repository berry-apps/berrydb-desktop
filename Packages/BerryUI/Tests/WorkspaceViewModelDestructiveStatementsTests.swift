import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryUI

/// `DestructiveStatementRunner.run` — the Truncate/Drop context menu path
/// (`WorkspaceViewModel.runDestructiveStatements`) that runs a fixed
/// statement directly through `QueryService` (native DangerGuard confirm)
/// instead of opening an editor tab to review first, since there's nothing
/// to review (the statement is exactly what the menu item said).
/// The user expects a confirm-then-run flow, not an editor tab.
///
/// Deliberately tests the free function against a bare `Session` (built via
/// `ConnectionManager`, exactly like `DangerGuardTests.deniedStatementDoesNotExecute`)
/// rather than through a `WorkspaceViewModel` — every `WorkspaceViewModel`
/// init resets `QueryService.dangerConfirmer` to the real, NSAlert-based one
/// as a side effect (`wireSinks()`). Doing that here made `make test` hang
/// forever: some other suite's concurrent `WorkspaceViewModel()` construction
/// could reset the confirmer back to the real one between this suite's swap
/// and its consumption, hitting `NSAlert.runModal()` with no one to click it.
/// A bare `Session` never touches that global, so cross-suite collisions
/// (e.g. with `DangerGuardTests`, which does the same swap) are at worst a
/// wrong count from a test-double confirmer — never the real blocking one.
/// `.serialized` here only protects this suite's own 4 tests from each other
/// (they all swap the same global).
@Suite("DestructiveStatementRunner.run", .serialized)
struct WorkspaceViewModelDestructiveStatementsTests {
    private func makeSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berry-destructive-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let manager = ConnectionManager()
        return try await manager.open(.sqlite(path: path))
    }

    private func exec(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    private struct CountingConfirmer: DangerConfirmer {
        let approve: Bool
        let count: CountBox
        func confirm(_ level: DangerLevel, sql: String) async -> Bool {
            count.value += 1
            return approve
        }
    }

    private final class CountBox: @unchecked Sendable {
        var value = 0
    }

    @Test func aSingleStatementAsksOnceAndRunsWhenApproved() async throws {
        let session = try await makeSession()
        try await exec("CREATE TABLE t (x INTEGER)", on: session)
        try await exec("INSERT INTO t VALUES (1), (2)", on: session)

        let previous = QueryService.dangerConfirmer
        let previousConfirms = QueryService.confirmsDataDeletion
        let count = CountBox()
        QueryService.dangerConfirmer = CountingConfirmer(approve: true, count: count)
        QueryService.confirmsDataDeletion = true
        defer {
            QueryService.dangerConfirmer = previous
            QueryService.confirmsDataDeletion = previousConfirms
        }

        let error = await DestructiveStatementRunner.run(["DELETE FROM t"], on: session)

        #expect(error == nil)
        #expect(count.value == 1)
        let rows = try await drain("SELECT count(*) FROM t", on: session)
        #expect(rows == [[.int(0)]], "approved statement must have run")
    }

    @Test func aSingleStatementDoesNotRunWhenDenied() async throws {
        let session = try await makeSession()
        try await exec("CREATE TABLE t (x INTEGER)", on: session)
        try await exec("INSERT INTO t VALUES (1), (2)", on: session)

        let previous = QueryService.dangerConfirmer
        let previousConfirms = QueryService.confirmsDataDeletion
        let count = CountBox()
        QueryService.dangerConfirmer = CountingConfirmer(approve: false, count: count)
        QueryService.confirmsDataDeletion = true
        defer {
            QueryService.dangerConfirmer = previous
            QueryService.confirmsDataDeletion = previousConfirms
        }

        let error = await DestructiveStatementRunner.run(["DELETE FROM t"], on: session)

        #expect(error == nil, "a user cancel is not an error")
        #expect(count.value == 1)
        let rows = try await drain("SELECT count(*) FROM t", on: session)
        #expect(rows == [[.int(2)]], "denied statement must not have run")
    }

    /// Drop Selected Objects (N>1): one summary confirm for the whole batch,
    /// not one per statement — mirrors `EditorDocument.runStatements` exactly.
    @Test func multipleStatementsAskOnceForTheWholeBatch() async throws {
        let session = try await makeSession()
        try await exec("CREATE TABLE a (x INTEGER)", on: session)
        try await exec("CREATE TABLE b (x INTEGER)", on: session)

        let previous = QueryService.dangerConfirmer
        let previousConfirms = QueryService.confirmsDataDeletion
        let count = CountBox()
        QueryService.dangerConfirmer = CountingConfirmer(approve: true, count: count)
        QueryService.confirmsDataDeletion = true
        defer {
            QueryService.dangerConfirmer = previous
            QueryService.confirmsDataDeletion = previousConfirms
        }

        let error = await DestructiveStatementRunner.run(
            ["DROP TABLE IF EXISTS a;", "DROP TABLE IF EXISTS b;"], on: session
        )

        #expect(error == nil)
        #expect(count.value == 1, "N destructive statements must ask once, not N times")
        let remaining = try await drain("SELECT name FROM sqlite_master WHERE type = 'table'", on: session)
        #expect(remaining.isEmpty, "both tables must have been dropped")
    }

    @Test func aFailingStatementReturnsItsErrorMessage() async throws {
        let session = try await makeSession()

        let previous = QueryService.dangerConfirmer
        let previousConfirms = QueryService.confirmsDataDeletion
        QueryService.dangerConfirmer = CountingConfirmer(approve: true, count: CountBox())
        QueryService.confirmsDataDeletion = true
        defer {
            QueryService.dangerConfirmer = previous
            QueryService.confirmsDataDeletion = previousConfirms
        }

        // No "IF EXISTS" — dropping a table that was never created fails.
        let error = await DestructiveStatementRunner.run(["DROP TABLE never_existed;"], on: session)

        #expect(error != nil)
    }

    private func drain(_ sql: String, on session: Session) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(sql, on: session, autoLimit: nil) {
            if case .rows(let batch) = event { rows += batch }
        }
        return rows
    }
}
