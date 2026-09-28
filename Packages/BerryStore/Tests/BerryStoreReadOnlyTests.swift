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

    @Test func missingFileIsAnErrorNotACreation() {
        let path = tempPath()
        #expect(throws: (any Error).self) { try BerryStore.openReadOnly(path: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
