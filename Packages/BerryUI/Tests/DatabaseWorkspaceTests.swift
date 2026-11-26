import BerryCredentials
import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

@MainActor
@Suite("Database workspace switching")
struct DatabaseWorkspaceTests {
    @Test func workspaceIdentitySurvivesRestorationAndSeparatesDatabases() throws {
        let profileID = UUID()
        let source = DatabaseWorkspaceTarget(profileID: profileID, database: "source")
        let target = DatabaseWorkspaceTarget(profileID: profileID, database: "target")
        let other = DatabaseWorkspaceTarget(profileID: UUID(), database: source.database)
        let decoded = try JSONDecoder().decode(DatabaseWorkspaceTarget.self, from: JSONEncoder().encode(source))

        #expect(decoded == source)
        #expect(decoded.workspaceProfileID == source.workspaceProfileID)
        #expect(source.workspaceProfileID != profileID)
        #expect(source.workspaceProfileID != target.workspaceProfileID)
        #expect(source.workspaceProfileID != other.workspaceProfileID)
    }

    @Test func onlyAnExplicitOpenAuthorizesOneInitialConnection() throws {
        let target = DatabaseWorkspaceTarget(profileID: UUID(), database: "target")
        let restored = try JSONDecoder().decode(DatabaseWorkspaceTarget.self, from: JSONEncoder().encode(target))

        #expect(!restored.consumeInitialConnectionAuthorization())
        target.authorizeInitialConnection()
        #expect(target.consumeInitialConnectionAuthorization())
        #expect(!restored.consumeInitialConnectionAuthorization())
    }

    @Test(.enabled(if: TestServer.postgres != nil && ProcessInfo.processInfo.environment["BERRYDB_TEST_POSTGRES_SWITCH_DATABASE"] != nil))
    func postgresKeepsQueriesInTheirWorkspace() async throws {
        DriverRegistry.register(PostgresDriver.self)
        try await exerciseSwitch(
            driver: .postgres,
            server: #require(TestServer.postgres),
            destination: #require(ProcessInfo.processInfo.environment["BERRYDB_TEST_POSTGRES_SWITCH_DATABASE"]),
            sql: "SELECT current_database()",
            deleteFromTarget: false
        )
    }

    @Test(.enabled(if: TestServer.mysql != nil && ProcessInfo.processInfo.environment["BERRYDB_TEST_MYSQL_SWITCH_DATABASE"] != nil))
    func mysqlKeepsQueriesInTheirWorkspace() async throws {
        DriverRegistry.register(MySQLDriver.self)
        try await exerciseSwitch(
            driver: .mysql,
            server: #require(TestServer.mysql),
            destination: #require(ProcessInfo.processInfo.environment["BERRYDB_TEST_MYSQL_SWITCH_DATABASE"]),
            sql: "SELECT DATABASE()",
            deleteFromTarget: true
        )
    }

    private func exerciseSwitch(
        driver: DriverID, server: TestServer, destination: String, sql: String, deleteFromTarget: Bool
    ) async throws {
        let sourceDatabase = try #require(server.database)
        #expect(sourceDatabase != destination)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        let store = try BerryStore(path: path)
        let profile = ConnectionProfile(
            driverID: driver.rawValue, name: "Switch test", envColor: "production",
            host: server.host, port: server.port, username: server.username, database: sourceDatabase,
            tlsMode: TLSMode.disable.rawValue, historyEnabled: false
        )
        try store.save(profile)
        if !server.password.isEmpty {
            KeychainService.savePassword(server.password, kind: .database, profileID: profile.id)
        }
        defer { if !server.password.isEmpty { KeychainService.deleteSecrets(profileID: profile.id) } }

        let source = try WorkspaceViewModel(storePath: path)
        let target = try WorkspaceViewModel(storePath: path)
        let reopened = try WorkspaceViewModel(storePath: path)
        defer {
            source.disconnect()
            source.closeWorkspace()
            target.closeWorkspace()
            reopened.closeWorkspace()
        }

        await source.connect(profile: profile)
        let sourceSession = try #require(source.session)
        #expect(source.currentDatabase == sourceDatabase)
        #expect(try await source.availableDatabases().contains(destination))
        source.newEditorTab(text: sql, title: "Source query")
        guard case .editor(let original) = source.activeTab else {
            Issue.record("Expected the original SQL tab")
            return
        }
        source.persistEditor(original)
        source.saveSavedQuery(name: "From source", sql: "SELECT 1", folder: nil, global: false)

        let selection = DatabaseWorkspaceTarget(profileID: profile.id, database: destination)
        await target.connectDatabaseWorkspace(selection)
        let targetSession = try #require(target.session)
        #expect(targetSession.id != sourceSession.id)
        #expect(target.isProductionSession)
        #expect(!targetSession.recordHistory)
        #expect(target.currentDatabase == destination)
        #expect(target.tabs.isEmpty)
        let sourceQueries = target.loadSavedQueries()
        #expect(sourceQueries.map(\.name) == ["From source"])
        target.focusWindow = { true }
        #expect(WorkspaceViewModel.focusDatabaseWorkspace(selection))
        #expect(try store.allProfiles().map(\.database) == [sourceDatabase])

        target.newEditorTab(text: sql, title: "Target query")
        guard case .editor(let selected) = target.activeTab else {
            Issue.record("Expected a SQL tab for the target database")
            return
        }
        target.persistEditor(selected)
        target.runFocusedEditor(all: true)
        source.runFocusedEditor(all: true)
        try await assertDatabase(destination, in: selected)
        try await assertDatabase(sourceDatabase, in: original)

        target.saveSavedQuery(name: "From target", sql: sql, folder: nil, global: false)
        let sharedQuery = try #require(source.loadSavedQueries().first { $0.name == "From target" })
        #expect(sharedQuery.profileID == profile.id)
        selected.text = "SELECT 2"
        let updated = target.updateLinkedSavedQuery()
        #expect(updated)
        target.renameSavedQuery(id: sharedQuery.id, to: "Shared query")
        let updatedSharedQuery = source.loadSavedQueries().first { $0.id == sharedQuery.id }
        #expect(updatedSharedQuery?.name == "Shared query")
        #expect(updatedSharedQuery?.sql == "SELECT 2")

        let detached = source.detachTab("editor:\(original.id.uuidString)")
        #expect(WorkspaceViewModel.workspace(for: detached) === source)

        await reopened.connectDatabaseWorkspace(selection)
        #expect(reopened.tabs.map(\.id) == ["editor:\(selected.id.uuidString)"])

        let missing = DatabaseWorkspaceTarget(profileID: profile.id, database: "missing_\(UUID().uuidString)")
        await reopened.connectDatabaseWorkspace(missing)
        #expect(reopened.errorMessage != nil)
        #expect(source.session?.id == sourceSession.id)
        #expect(target.session?.id == targetSession.id)
        original.run(.all, on: sourceSession)
        try await assertDatabase(sourceDatabase, in: original)

        if deleteFromTarget {
            target.delete(profile: profile)
        } else {
            target.detachTab("editor:\(selected.id.uuidString)")
            target.closeWorkspace()
            source.delete(profile: profile)
        }
        let disconnected = source.session == nil && target.session == nil
        #expect(disconnected)
        await reopened.connectDatabaseWorkspace(selection)
        let reopenedAfterDeletion = reopened.session != nil
        #expect(!reopenedAfterDeletion)
        #expect(try store.allProfiles().isEmpty)
    }

    private func assertDatabase(_ database: String, in document: EditorDocument) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while document.isRunning, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!document.isRunning)
        #expect(document.results.last?.buffer.rows == [[.text(database)]])
    }
}
