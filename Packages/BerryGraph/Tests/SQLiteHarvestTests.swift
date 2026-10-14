import BerryDriverKit
import BerryDriverSQLite
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

/// Whole passes over a real SQLite file, whose catalog can hold objects no
/// scripted introspector would think of.
@Suite("Harvest over SQLite")
struct SQLiteHarvestTests {
    let profile = UUID()

    /// A view over a dropped table cannot be described, and it must not stop
    /// the pass that reads the rest of the file: every other object gets its
    /// definition, the check is recorded, and the view stays pending, so the
    /// next pass tries it again.
    @Test func aViewOverADroppedTableLeavesThePassComplete() async throws {
        let path = NSTemporaryDirectory() + "berrydb-harvest-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let connection = try SQLiteConnection(path: path)
        defer { Task { await connection.close() } }
        for sql in [
            "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)",
            "CREATE TABLE gone (id INTEGER)",
            "CREATE VIEW broken AS SELECT id FROM gone",
            "CREATE VIEW names AS SELECT name FROM customers",
            "DROP TABLE gone",
        ] {
            for try await _ in connection.execute(sql) {}
        }
        let store = try BerryStore(path: ":memory:")
        let introspector = connection.introspector
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in introspector })

        let outcome = await coordinator.request(.userAction, for: profile)

        guard case .updated = outcome else { Issue.record("the pass did not complete: \(outcome)"); return }
        let state = try #require(try store.schemaGraphState(profileID: profile))
        #expect(state.lastCheckedAt != nil && state.lastErrorCode == nil)
        let objects = try store.currentSchemaObjects(profileID: profile)
        #expect(objects.map(\.name) == ["broken", "customers", "names"])
        #expect(objects.filter { $0.definition != nil }.map(\.name) == ["customers", "names"])
    }
}
