import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryGraph

/// Query Analyzer end-to-end: runs real EXPLAIN
/// against an in-process SQLite database and confirms the full-scan signal flips
/// once a covering index exists. Deterministic — no Docker.
@Suite("Plan harvester on SQLite")
struct PlanHarvesterTests {
    private func makeSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-plan-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        try await drain("CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT)", on: session)
        try await drain("INSERT INTO users (id, email) VALUES (1, 'a'), (2, 'b')", on: session)
        return session
    }

    private func drain(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    @Test func flagsFullScanUntilIndexed() async throws {
        let session = try await makeSession()
        defer { Task { await session.connection.close() } }

        let query = "SELECT * FROM users WHERE email = 'a'"

        // No index on email → EXPLAIN QUERY PLAN reports a full scan.
        let before = await PlanHarvester.analyze(statements: [query], session: session)
        let scan = before.first { $0.id == "query.full_scan.users" }
        #expect(scan?.severity == .warning)
        #expect(scan?.category == .query)

        // Add the index → the same query now rides it, so no finding.
        try await drain("CREATE INDEX idx_users_email ON users (email)", on: session)
        let after = await PlanHarvester.analyze(statements: [query], session: session)
        #expect(after.first { $0.id == "query.full_scan.users" } == nil)
    }

    @Test func skipsNonSelectWorkload() async throws {
        let session = try await makeSession()
        defer { Task { await session.connection.close() } }

        let insights = await PlanHarvester.analyze(
            statements: ["INSERT INTO users (id, email) VALUES (3, 'c')"], session: session
        )
        #expect(insights.isEmpty)
    }
}
