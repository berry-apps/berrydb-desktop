import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryGraph
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Time Machine Timeline — end-to-end through the
/// workspace against an in-process SQLite schema. Serialized: registers
/// `SQLiteDriver` (shared global `DriverRegistry` state), same caveat
/// `WorkspaceGraphTests` documents.
@MainActor
@Suite("Time Machine (WorkspaceViewModel)", .serialized)
struct TimeMachineTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    private func exec(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    private func makeSQLiteDB() -> String {
        DriverRegistry.register(SQLiteDriver.self)
        let path = tempPath("db")
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    @Test func changesAcrossTwoSnapshotsGroupByTableWithCorrectDirection() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        let profile = ConnectionProfile(driverID: "sqlite", name: "twin", filePath: makeSQLiteDB())
        await vm.connect(profile: profile)
        let session = try #require(vm.session)

        try await exec("CREATE TABLE users (id INTEGER PRIMARY KEY)", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        try await exec("ALTER TABLE users ADD COLUMN email TEXT", on: session)
        try await vm.refreshObjects()
        await vm.harvestGraphNow()

        let marks = await vm.timelineSnapshots()
        // One mark per pass that changed the schema: CREATE TABLE, then ALTER
        // TABLE. The pass over the empty schema at connect changes nothing.
        try #require(marks.count == 2)

        let changes = await vm.timelineChanges(from: marks[1].at, to: marks[0].at)
        #expect(changes.count == 1)
        let change = try #require(changes.first)
        #expect(change.isAdded == true)
        #expect(change.kind == .column)
        #expect(change.name == "email")
        #expect(change.tableName == "users")

        vm.disconnect()
    }

    @Test func noSnapshotsWithoutHarvest() async throws {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        #expect(await vm.timelineSnapshots().isEmpty)
        #expect(await vm.timelineChanges(from: Date(), to: Date()).isEmpty)
    }
}
