import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("BerryStore read-only open")
struct BerryStoreReadOnlyTests {
    func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
    }

    @Test func opensAFullyMigratedStoreWithoutWriting() throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = try BerryStore.openReadOnly(path: path)
        _ = try store.mcpProjects()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    @Test func rejectsAStoreMissingMigrations() throws {
        let path = tempPath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)") }
        #expect(throws: BerryStore.ReadOnlyOpenError.self) { try BerryStore.openReadOnly(path: path) }
    }

    @Test func rejectsAStoreFromANewerApp() throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99-from-the-future')") }
        #expect(throws: BerryStore.ReadOnlyOpenError.self) { try BerryStore.openReadOnly(path: path) }
    }

    /// Runs `sql` to take a lock on `path` from a separate connection on a
    /// background thread, holds it for `duration`, then commits. Returns
    /// once the lock is held; `done` is left when it has been released.
    private func holdLock(_ sql: String, on path: String, for duration: TimeInterval, done: DispatchGroup) throws {
        let other = try DatabaseQueue(path: path)
        let held = DispatchSemaphore(value: 0)
        done.enter()
        DispatchQueue.global().async {
            defer { done.leave() }
            do {
                try other.inDatabase { db in
                    try db.execute(sql: sql)
                    _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
                    held.signal()
                    Thread.sleep(forTimeInterval: duration)
                    try db.execute(sql: "COMMIT")
                }
            } catch {
                held.signal()
                Issue.record(error)
            }
        }
        held.wait()
    }

    @Test func appWriteWaitsForAHelperReadInsteadOfFailing() throws {
        let path = tempPath()
        let store = try BerryStore(path: path)
        let released = DispatchGroup()
        try holdLock("BEGIN DEFERRED", on: path, for: 0.5, done: released)

        try store.save(ConnectionProfile(driverID: "sqlite", name: "Saved during a read"))

        released.wait()
        #expect(try store.allProfiles().map(\.name) == ["Saved during a read"])
    }

    @Test func helperReadWaitsForAnAppWriteInsteadOfFailing() throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let released = DispatchGroup()
        try holdLock("BEGIN EXCLUSIVE", on: path, for: 0.5, done: released)

        let helper = try BerryStore.openReadOnly(path: path)
        #expect(try helper.mcpProjects().isEmpty)

        released.wait()
    }

    @Test func missingFileIsAnErrorNotACreation() {
        let path = tempPath()
        #expect(throws: (any Error).self) { try BerryStore.openReadOnly(path: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
