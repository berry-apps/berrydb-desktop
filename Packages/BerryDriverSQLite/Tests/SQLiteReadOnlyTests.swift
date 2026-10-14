import BerryDriverKit
import Foundation
import SQLite3
import Testing

@testable import BerryDriverSQLite

/// The read-only path of the SQLite driver against a temporary file, the way
/// the app opens a second connection to the file a session already has open.
@Suite("SQLite read-only connection")
struct SQLiteReadOnlyTests {
    /// Runs `body` with a file holding one table with one row, its session
    /// connection, and a second connection prepared for read-only statements;
    /// closes both and removes the file afterwards.
    private func withOpened(
        _ body: (_ main: SQLiteConnection, _ readOnly: SQLiteConnection) async throws -> Void
    ) async throws {
        let path = NSTemporaryDirectory() + "berrydb-readonly-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let main = try SQLiteConnection(path: path)
        let readOnly = try SQLiteConnection(path: path)
        do {
            try await drain(main.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
            try await drain(main.execute("INSERT INTO t (id) VALUES (1)"))
            try await readOnly.prepareReadOnly()
            try await body(main, readOnly)
        } catch {
            await main.close()
            await readOnly.close()
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
        await main.close()
        await readOnly.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    private func count(on connection: SQLiteConnection) async throws -> [[BerryValue]] {
        try await drain(connection.execute("SELECT count(*) FROM t"))
    }

    @Test func prepareTurnsQueryOnlyOnAndReadsItBack() async throws {
        try await withOpened { _, readOnly in
            let mode = try await drain(readOnly.executeReadOnly("PRAGMA query_only", timeout: .seconds(5)))

            #expect(mode == [[.int(1)]])
        }
    }

    @Test func aReadReturnsItsRows() async throws {
        try await withOpened { _, readOnly in
            let rows = try await drain(readOnly.executeReadOnly("SELECT id FROM t", timeout: .seconds(5)))

            #expect(rows == [[.int(1)]])
        }
    }

    @Test func aWriteIsRefusedByTheDatabase() async throws {
        try await withOpened { main, readOnly in
            let error = await #expect(throws: DriverError.self) {
                try await drain(readOnly.executeReadOnly("INSERT INTO t (id) VALUES (2)", timeout: .seconds(5)))
            }

            guard case let .queryFailed(_, code)? = error else {
                Issue.record("expected queryFailed, got \(String(describing: error))")
                return
            }
            #expect(code == SQLITE_READONLY)
            let remaining = try await count(on: main)
            #expect(remaining == [[.int(1)]])
        }
    }

    /// `PRAGMA query_only = OFF` is itself allowed while the mode is on
    /// (https://www.sqlite.org/pragma.html#pragma_query_only), so a statement
    /// can turn the mode off; the next statement must still run read-only.
    @Test func turningTheModeOffDoesNotCarryToTheNextStatement() async throws {
        try await withOpened { main, readOnly in
            _ = try? await drain(readOnly.executeReadOnly("PRAGMA query_only = OFF", timeout: .seconds(5)))
            await #expect(throws: DriverError.self) {
                try await drain(readOnly.executeReadOnly("INSERT INTO t (id) VALUES (3)", timeout: .seconds(5)))
            }

            let remaining = try await count(on: main)
            #expect(remaining == [[.int(1)]])
        }
    }

    /// The session's own driver runs every statement in a text; the read-only
    /// path runs one, and refuses a text with more rather than run the first.
    @Test func aTextWithASecondStatementIsRefusedAndNothingRuns() async throws {
        try await withOpened { main, readOnly in
            await #expect(throws: DriverError.self) {
                try await drain(readOnly.executeReadOnly("SELECT 1; SELECT 2", timeout: .seconds(5)))
            }
            await #expect(throws: DriverError.self) {
                try await drain(readOnly.executeReadOnly(
                    "SELECT 1; PRAGMA query_only = OFF; INSERT INTO t (id) VALUES (4)", timeout: .seconds(5)
                ))
            }

            let remaining = try await count(on: main)
            #expect(remaining == [[.int(1)]])
        }
    }

    /// Auto-LIMIT keeps a trailing semicolon, and an editor statement can end
    /// in a comment; neither is a second statement.
    @Test func aTrailingSemicolonOrCommentIsOneStatement() async throws {
        try await withOpened { _, readOnly in
            let limited = try await drain(readOnly.executeReadOnly("SELECT id FROM t LIMIT 1000;", timeout: .seconds(5)))
            let lineComment = try await drain(readOnly.executeReadOnly("SELECT id FROM t; -- first row\n", timeout: .seconds(5)))
            let blockComment = try await drain(readOnly.executeReadOnly("SELECT id FROM t /* done */", timeout: .seconds(5)))

            #expect(limited == [[.int(1)]])
            #expect(lineComment == [[.int(1)]])
            #expect(blockComment == [[.int(1)]])
        }
    }
}
