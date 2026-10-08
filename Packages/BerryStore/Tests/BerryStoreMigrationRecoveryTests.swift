import CryptoKit
import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("BerryStore migration recovery")
struct BerryStoreMigrationRecoveryTests {
    /// The schema a development build's `v30-mcp-project-grant` migration
    /// created, as read back from `sqlite_master` of a store that ran it.
    static let legacyGrantSchema = [
        #"CREATE TABLE "mcp_project" ("id" BLOB PRIMARY KEY NOT NULL, "name" TEXT NOT NULL, "workspaceRootsJSON" TEXT NOT NULL, "enabledCapabilitiesJSON" TEXT NOT NULL, "productionAccess" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL)"#,
        #"CREATE TABLE "mcp_project_profile" ("projectID" BLOB NOT NULL REFERENCES "mcp_project"("id") ON DELETE CASCADE, "profileID" BLOB NOT NULL REFERENCES "connection_profile"("id") ON DELETE CASCADE, PRIMARY KEY ("projectID", "profileID"))"#,
        #"CREATE TABLE "mcp_project_grant" ("id" BLOB PRIMARY KEY NOT NULL, "projectID" BLOB NOT NULL REFERENCES "mcp_project"("id") ON DELETE CASCADE, "tokenHash" BLOB NOT NULL UNIQUE, "createdAt" DATETIME NOT NULL, "expiresAt" DATETIME, "revokedAt" DATETIME, "lastUsedAt" DATETIME)"#,
        #"CREATE INDEX "mcp_project_grant_on_projectID" ON "mcp_project_grant"("projectID")"#,
    ]

    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        return configuration
    }

    func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
    }

    func removeStore(at path: String) {
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// A store migrated to v29 with one connection profile, as every store
    /// was before the MCP project tables existed.
    func makeV29Store(at path: String, profileID: UUID) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        try BerryStore.migrator.migrate(queue, upTo: "v29-ai-message-tree")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO connection_profile (id, driverID, name, sortOrder, createdAt, tlsMode, sshEnabled, historyEnabled, elasticsearchAPIKeyEnabled) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [profileID, "sqlite", "Survivor", 0, Date(), "prefer", false, true, false]
            )
        }
        return queue
    }

    /// A store in the state the development build left it: v29, the legacy
    /// tables with a row in each, and the withdrawn identifier recorded.
    func makeStoreThatRanTheGrantMigration(at path: String, profileID: UUID) throws {
        let queue = try makeV29Store(at: path, profileID: profileID)
        try queue.write { db in
            for sql in Self.legacyGrantSchema { try db.execute(sql: sql) }
            let projectID = UUID()
            try db.execute(
                sql: "INSERT INTO mcp_project (id, name, workspaceRootsJSON, enabledCapabilitiesJSON, productionAccess, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [projectID, "Legacy", "[]", "[]", "denied", Date(), Date()]
            )
            try db.execute(
                sql: "INSERT INTO mcp_project_profile (projectID, profileID) VALUES (?, ?)",
                arguments: [projectID, profileID]
            )
            try db.execute(
                sql: "INSERT INTO mcp_project_grant (id, projectID, tokenHash, createdAt) VALUES (?, ?, ?, ?)",
                arguments: [UUID(), projectID, Data([1, 2, 3]), Date()]
            )
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v30-mcp-project-grant')")
        }
    }

    func appliedIdentifiers(at path: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        return try queue.read { try String.fetchSet($0, sql: "SELECT identifier FROM grdb_migrations") }
    }

    func schemaObjectNames(at path: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        return try queue.read { try String.fetchSet($0, sql: "SELECT name FROM sqlite_master") }
    }

    func columns(of table: String, at path: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        return try queue.read { try Set($0.columns(in: table).map(\.name)) }
    }

    /// The error `BerryStore(path:)` throws, or nil when the open succeeds.
    func openError(at path: String) -> (any Error)? {
        do {
            _ = try BerryStore(path: path)
            return nil
        } catch {
            return error
        }
    }

    @Test func supersededDevelopmentMigrationIsRetired() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let profileID = UUID()
        try makeStoreThatRanTheGrantMigration(at: path, profileID: profileID)

        let store = try BerryStore(path: path)

        let applied = try appliedIdentifiers(at: path)
        #expect(applied.contains("v30-mcp-project"))
        #expect(!applied.contains("v30-mcp-project-grant"))
        let projectColumns = try columns(of: "mcp_project", at: path)
        #expect(projectColumns.contains("integrityTag"))
        #expect(!projectColumns.contains("enabledCapabilitiesJSON"))
        #expect(try columns(of: "mcp_project_profile", at: path).contains("liveRead"))
        let names = try schemaObjectNames(at: path)
        #expect(!names.contains("mcp_project_grant"))
        #expect(!names.contains("mcp_project_grant_on_projectID"))
        #expect(try store.mcpProjects().isEmpty)
        #expect(try store.allProfiles().map(\.id) == [profileID])
        // The applied set now matches this build, so the read-only helper accepts the store again.
        _ = try BerryStore.openReadOnly(path: path)
    }

    @Test func storeWithoutSupersededMigrationIsUntouched() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let key = SymmetricKey(size: .bits256)
        let profile = ConnectionProfile(driverID: "sqlite", name: "Kept")
        let project = MCPProject(name: "Kept", profiles: [MCPProfileAccess(profileID: profile.id, liveRead: true)])
        do {
            let store = try BerryStore(path: path)
            try store.save(profile)
            try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        }

        let reopened = try BerryStore(path: path)

        #expect(try reopened.allProfiles().map(\.id) == [profile.id])
        #expect(try reopened.mcpProject(id: project.id)?.profiles.map(\.profileID) == [profile.id])
        #expect(try appliedIdentifiers(at: path) == Set(BerryStore.migrator.migrations))
    }

    /// A store a person repaired by hand (dropped the legacy tables, then let
    /// the current build create its own) carries both identifiers. The tables
    /// then hold the replacement's schema and current data, so only the stale
    /// identifier row may go.
    @Test func staleIdentifierBesideItsAppliedReplacementKeepsCurrentTables() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let key = SymmetricKey(size: .bits256)
        let profile = ConnectionProfile(driverID: "sqlite", name: "Kept")
        let project = MCPProject(name: "Current", profiles: [MCPProfileAccess(profileID: profile.id)])
        do {
            let store = try BerryStore(path: path)
            try store.save(profile)
            try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
            try store.executeForTesting("INSERT INTO grdb_migrations (identifier) VALUES ('v30-mcp-project-grant')")
        }

        let reopened = try BerryStore(path: path)

        #expect(try reopened.mcpProject(id: project.id)?.name == "Current")
        #expect(try appliedIdentifiers(at: path) == Set(BerryStore.migrator.migrations))
    }

    @Test func failedMigrationReportsItsIdentifier() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let profileID = UUID()
        do {
            // `v30-mcp-project` creates `mcp_project` first, then trips over
            // this table, so its rollback is observable as `mcp_project` absent.
            let queue = try makeV29Store(at: path, profileID: profileID)
            try queue.write { try $0.execute(sql: "CREATE TABLE mcp_project_profile (unrelated INTEGER)") }
        }

        let error = try #require(openError(at: path) as? BerryStore.OpenError)

        switch error {
        case let .migrationFailed(identifier, reason):
            #expect(identifier == "v30-mcp-project")
            #expect(reason.contains("already exists"))
        }
        #expect(error.localizedDescription == "BerryDB could not upgrade its data store.")
        #expect(error.failureReason?.contains("v30-mcp-project") == true)
        let applied = try appliedIdentifiers(at: path)
        #expect(applied.contains("v29-ai-message-tree"))
        #expect(!applied.contains("v30-mcp-project"))
        #expect(try !schemaObjectNames(at: path).contains("mcp_project"))
        let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
        #expect(try queue.read { try UUID.fetchAll($0, sql: "SELECT id FROM connection_profile") } == [profileID])
    }

    /// v28, v29 and v30 are pending and v29 fails: the step named must be the
    /// one that threw, not the first pending when the open began (v28, which
    /// commits) nor the last registered one (v30, which never runs).
    @Test func failureAmongSeveralPendingMigrationsNamesTheOneThatThrew() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        do {
            let queue = try DatabaseQueue(path: path, configuration: Self.configuration)
            try BerryStore.migrator.migrate(queue, upTo: "v27-elasticsearch-auth-mode")
            // `v29-ai-message-tree` adds this column, so it fails as a duplicate.
            try queue.write { try $0.execute(sql: "ALTER TABLE ai_message ADD COLUMN parentID BLOB") }
        }

        let error = try #require(openError(at: path) as? BerryStore.OpenError)

        switch error {
        case let .migrationFailed(identifier, reason):
            #expect(identifier == "v29-ai-message-tree")
            #expect(reason.contains("duplicate column name"))
        }
        let applied = try appliedIdentifiers(at: path)
        #expect(applied.contains("v28-ai-thread-connection-key"))
        #expect(!applied.contains("v29-ai-message-tree"))
        #expect(!applied.contains("v30-mcp-project"))
    }

    @Test func openFailureOutsideAMigrationKeepsItsOwnError() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: path))

        let error = try #require(openError(at: path))

        #expect(!(error is BerryStore.OpenError))
    }

    /// `migrate` can also fail before any migration starts, while creating or
    /// reading `grdb_migrations`; blaming the first pending migration then
    /// would name a step that never ran.
    @Test func failureOutsideAnyMigrationIsNotAttributedToOne() throws {
        let underlying = DatabaseError(resultCode: .SQLITE_IOERR, message: "disk I/O error")

        let withoutMigrationsTable = try DatabaseQueue(path: ":memory:")
        let fullyMigrated = try DatabaseQueue(path: ":memory:", configuration: Self.configuration)
        try BerryStore.migrator.migrate(fullyMigrated)

        for queue in [withoutMigrationsTable, fullyMigrated] {
            let error = BerryStore.openError(afterFailedMigration: underlying, migrator: BerryStore.migrator, in: queue)
            #expect((error as? DatabaseError)?.resultCode == .SQLITE_IOERR)
            #expect((error as? DatabaseError)?.message == "disk I/O error")
        }
    }

    @Test func readOnlyOpenDoesNotRetire() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        try makeStoreThatRanTheGrantMigration(at: path, profileID: UUID())

        var thrown: (any Error)?
        do { _ = try BerryStore.openReadOnly(path: path) } catch { thrown = error }

        let error = try #require(thrown as? BerryStore.ReadOnlyOpenError)
        switch error {
        case let .schemaMismatch(applied, _):
            #expect(applied.contains("v30-mcp-project-grant"))
        }
        #expect(try appliedIdentifiers(at: path).contains("v30-mcp-project-grant"))
        let names = try schemaObjectNames(at: path)
        #expect(names.isSuperset(of: ["mcp_project", "mcp_project_profile", "mcp_project_grant"]))
    }
}
