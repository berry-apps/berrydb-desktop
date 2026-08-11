import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

@Suite("Backup / Restore (feature/04)")
struct BackupServiceTests {
    private func makeSession() async throws -> (Session, String) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-backup-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        return (session, path)
    }

    @discardableResult
    private func exec(_ sql: String, on session: Session) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(sql, on: session, autoLimit: nil, dangerPreconfirmed: true) {
            if case .rows(let batch) = event { rows += batch }
        }
        return rows
    }

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "berry-dump-\(UUID().uuidString).sql")
    }

    @Test func backupThenRestoreIntoAFreshDatabaseRoundTrips() async throws {
        let (source, sp) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: sp) }
        try await exec("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, city TEXT)", on: source)
        try await exec("INSERT INTO people VALUES (1, 'An', 'Hanoi'), (2, 'Binh', NULL)", on: source)

        let dump = tempURL()
        defer { try? FileManager.default.removeItem(at: dump) }
        let count = try await BackupService.backupSQL(session: source, to: dump)
        #expect(count == 1)

        let text = try String(contentsOf: dump, encoding: .utf8)
        #expect(text.contains("CREATE TABLE"))
        #expect(text.localizedCaseInsensitiveContains("INSERT INTO"))

        // Restore into a separate, empty database — no DROP needed.
        let (target, tp) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: tp) }
        let result = try await BackupService.restoreSQL(session: target, from: dump)
        #expect(result.failures.isEmpty, "restore failures: \(result.failures.map(\.message))")

        let rows = try await exec("SELECT id, name, city FROM people ORDER BY id", on: target)
        #expect(rows == [
            [.int(1), .text("An"), .text("Hanoi")],
            [.int(2), .text("Binh"), .null],
        ])
    }

    @Test func structureOnlyOmitsData() async throws {
        let (source, sp) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: sp) }
        try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: source)
        try await exec("INSERT INTO t VALUES (1), (2)", on: source)

        let dump = tempURL()
        defer { try? FileManager.default.removeItem(at: dump) }
        try await BackupService.backupSQL(
            session: source, options: .init(includeStructure: true, includeData: false), to: dump
        )
        let text = try String(contentsOf: dump, encoding: .utf8)
        #expect(text.contains("CREATE TABLE"))
        #expect(!text.localizedCaseInsensitiveContains("INSERT INTO"))
    }

    @Test func dataOnlyOmitsStructure() async throws {
        let (source, sp) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: sp) }
        try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: source)
        try await exec("INSERT INTO t VALUES (1)", on: source)

        let dump = tempURL()
        defer { try? FileManager.default.removeItem(at: dump) }
        try await BackupService.backupSQL(
            session: source, options: .init(includeStructure: false, includeData: true), to: dump
        )
        let text = try String(contentsOf: dump, encoding: .utf8)
        #expect(!text.contains("CREATE TABLE"))
        #expect(text.localizedCaseInsensitiveContains("INSERT INTO"))
    }
}
