import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

@Suite("Session state tracker")
struct SessionStateTrackerTests {
    private typealias State = SessionStateTracker.State

    @Test(arguments: [
        "CREATE TEMP TABLE x (a int)",
        "create temporary table x (a int)",
        "CREATE OR REPLACE TEMP VIEW v AS SELECT 1",
        "CREATE GLOBAL TEMPORARY TABLE x (a int)",
        "SELECT * INTO TEMP t FROM orders",
        "select a into temporary table t from b",
        "SET search_path TO app, public",
        "SET SESSION search_path = app",
        "SET ROLE reporting",
        "SET SESSION AUTHORIZATION alice",
        "USE shop",
        "ATTACH DATABASE 'other.db' AS other",
        "PREPARE q AS SELECT 1",
        "DECLARE c CURSOR FOR SELECT 1",
        "/* setup */ CREATE TEMP TABLE x (a int)",
        "-- scratch\nUSE shop",
        "# scratch\nUSE shop",
        "/* outer /* nested */ still a comment */ USE shop",
    ])
    func aStatementThatLeavesStateOnTheConnectionIsSticky(_ sql: String) {
        let tracker = SessionStateTracker()
        let session = UUID()

        tracker.recordSucceeded(sql, sessionID: session)
        tracker.recordSucceeded("COMMIT", sessionID: session)

        #expect(tracker.state(for: session) == State(hasSessionLocalState: true, hasOpenTransaction: false))
    }

    @Test(arguments: ["BEGIN", "begin;", "BEGIN WORK", "BEGIN IMMEDIATE", "START TRANSACTION", "start transaction read write"])
    func aStatementThatOpensATransactionIsTracked(_ sql: String) {
        let tracker = SessionStateTracker()
        let session = UUID()

        tracker.recordSucceeded(sql, sessionID: session)

        #expect(tracker.state(for: session) == State(hasSessionLocalState: false, hasOpenTransaction: true))
    }

    @Test(arguments: [
        "COMMIT", "commit;", "ROLLBACK", "ROLLBACK WORK", "END", "END TRANSACTION", "ABORT",
        "COMMIT AND NO CHAIN", "ROLLBACK AND NO CHAIN", "ROLLBACK WORK AND NO CHAIN",
    ])
    func aStatementThatEndsTheTransactionClearsIt(_ sql: String) {
        let tracker = SessionStateTracker()
        let session = UUID()
        tracker.recordSucceeded("BEGIN", sessionID: session)

        tracker.recordSucceeded(sql, sessionID: session)

        #expect(tracker.state(for: session) == State())
    }

    /// Rolling back to a savepoint, or ending with AND CHAIN, leaves a
    /// transaction open on the connection.
    @Test(arguments: [
        "ROLLBACK TO SAVEPOINT s1", "ROLLBACK TO s1", "rollback work to savepoint s1",
        "COMMIT AND CHAIN", "ROLLBACK AND CHAIN", "ROLLBACK WORK AND CHAIN",
    ])
    func endingASavepointOrChainingKeepsTheTransactionOpen(_ sql: String) {
        let tracker = SessionStateTracker()
        let session = UUID()
        tracker.recordSucceeded("BEGIN", sessionID: session)

        tracker.recordSucceeded(sql, sessionID: session)

        #expect(tracker.state(for: session).hasOpenTransaction)
    }

    @Test(arguments: [
        "SELECT * FROM orders",
        "SELECT 'create temp table x' AS note",
        "SELECT 'a INTO TEMP b' AS note",
        "/* USE shop */ SELECT 1",
        "-- USE shop\nSELECT 1",
        "SELECT 1 -- INTO TEMP t",
        "SELECT 1 /* INTO TEMP t */",
        "SELECT \"use\" FROM t",
        "SELECT a INTO t2 FROM t",
        "INSERT INTO t VALUES (1)",
        "CREATE TABLE t (a int)",
        "SET TIME ZONE 'UTC'",
        "SAVEPOINT s1",
        "EXPLAIN SELECT 1",
        "",
    ])
    func otherStatementsChangeNothing(_ sql: String) {
        let tracker = SessionStateTracker()
        let session = UUID()

        tracker.recordSucceeded(sql, sessionID: session)

        #expect(tracker.state(for: session) == State())
    }

    @Test func theStatementsOfOneTextApplyInOrder() {
        let tracker = SessionStateTracker()
        let committed = UUID()
        let reopened = UUID()
        let scratch = UUID()

        tracker.recordSucceeded("BEGIN; INSERT INTO t VALUES (1); COMMIT;", sessionID: committed)
        tracker.recordSucceeded("COMMIT; BEGIN", sessionID: reopened)
        tracker.recordSucceeded("CREATE TEMP TABLE x (a int); SELECT 1", sessionID: scratch)

        #expect(tracker.state(for: committed) == State())
        #expect(tracker.state(for: reopened) == State(hasSessionLocalState: false, hasOpenTransaction: true))
        #expect(tracker.state(for: scratch) == State(hasSessionLocalState: true, hasOpenTransaction: false))
    }

    @Test func sessionsAreTrackedApartAndForgottenWhenTheyClose() {
        let tracker = SessionStateTracker()
        let first = UUID()
        let second = UUID()

        tracker.recordSucceeded("USE shop", sessionID: first)
        #expect(tracker.state(for: second) == State())

        tracker.forget(sessionID: first)
        #expect(tracker.state(for: first) == State())
    }
}

/// `QueryService` is the path every statement on a session's own connection
/// takes, so it is where the tracker learns what that connection holds.
@Suite("QueryService and the session state tracker")
struct QueryServiceSessionStateTests {
    private func withSQLiteSession(_ body: (Session) async throws -> Void) async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-state-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))
        do {
            try await body(session)
        } catch {
            await manager.close(session.id)
            SessionStateTracker.shared.forget(sessionID: session.id)
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        await manager.close(session.id)
        SessionStateTracker.shared.forget(sessionID: session.id)
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func aStatementThatSucceededOnTheSessionConnectionIsRecorded() async throws {
        try await withSQLiteSession { session in
            for try await _ in QueryService.execute("CREATE TEMP TABLE scratch (a INTEGER)", on: session, recordHistory: false) {}

            #expect(SessionStateTracker.shared.state(for: session.id).hasSessionLocalState)
        }
    }

    @Test func aStatementThatFailedIsNotRecorded() async throws {
        try await withSQLiteSession { session in
            await #expect(throws: (any Error).self) {
                for try await _ in QueryService.execute("CREATE TEMP TABLE broken (", on: session, recordHistory: false) {}
            }

            #expect(SessionStateTracker.shared.state(for: session.id) == SessionStateTracker.State())
        }
    }

    /// A statement sent to another connection keeps auto-LIMIT, and leaves
    /// nothing on the session's own connection for the tracker to record.
    @Test func aStatementRunElsewhereKeepsAutoLimitAndIsNotRecorded() async throws {
        try await withSQLiteSession { session in
            let received = ReceivedStatements()
            let elsewhere: QueryService.StatementRunner = { sql in
                received.append(sql)
                return AsyncThrowingStream { continuation in
                    continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                    continuation.finish()
                }
            }

            for try await _ in QueryService.execute("SELECT * FROM t", on: session, recordHistory: false, via: elsewhere) {}
            for try await _ in QueryService.execute("CREATE TEMP TABLE elsewhere (a INTEGER)", on: session, recordHistory: false, via: elsewhere) {}

            #expect(received.values == ["SELECT * FROM t LIMIT 1000", "CREATE TEMP TABLE elsewhere (a INTEGER)"])
            #expect(SessionStateTracker.shared.state(for: session.id) == SessionStateTracker.State())
            await #expect(throws: (any Error).self) {
                for try await _ in session.connection.execute("SELECT * FROM elsewhere") {}
            }
        }
    }
}

private final class ReceivedStatements: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func append(_ sql: String) {
        lock.lock()
        received.append(sql)
        lock.unlock()
    }
}