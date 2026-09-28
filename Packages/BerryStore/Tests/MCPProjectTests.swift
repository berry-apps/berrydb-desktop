import CryptoKit
import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("MCP projects")
struct MCPProjectTests {
    @Test func roundTripsPerProfileAccessInDeterministicOrder() throws {
        let store = try BerryStore(path: ":memory:")
        let postgres = ConnectionProfile(
            id: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!,
            driverID: "postgres", name: "Orders", groupName: "shared", host: "db.internal"
        )
        let dynamo = ConnectionProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            driverID: "dynamodb", name: "Events", groupName: "shared"
        )
        try store.save(postgres)
        try store.save(dynamo)

        let project = MCPProject(
            name: "Project A",
            isEnabled: true,
            workspaceRoots: ["/z/repo/./Sources/..", "/a/repo"],
            profiles: [
                MCPProfileAccess(profileID: postgres.id, liveRead: true, redactedColumns: ["Email", "email", "ssn"]),
                MCPProfileAccess(profileID: dynamo.id),
            ],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        try store.saveMCPProject(project, sealingKey: SymmetricKey(size: .bits256), previousKey: nil)

        let loaded = try #require(try store.mcpProject(id: project.id))
        #expect(loaded.isEnabled)
        #expect(loaded.workspaceRoots == ["/a/repo", "/z/repo"])
        #expect(loaded.profiles.map(\.profileID) == [dynamo.id, postgres.id])
        #expect(loaded.profiles[0] == MCPProfileAccess(profileID: dynamo.id, liveRead: false, redactedColumns: []))
        #expect(loaded.profiles[1].liveRead)
        #expect(loaded.profiles[1].redactedColumns == ["email", "ssn"])
    }

    @Test func liveReadDefaultsToOffAndProjectsDefaultToDisabled() {
        let access = MCPProfileAccess(profileID: UUID())
        #expect(access.liveRead == false)
        #expect(MCPProject(name: "New").isEnabled == false)
    }

    @Test func rejectsRelativeWorkspaceRootsAtSaveBoundary() throws {
        let store = try BerryStore(path: ":memory:")
        let project = MCPProject(name: "Relative", workspaceRoots: ["repos/berrydb"])

        #expect(throws: MCPProjectError.workspaceRootMustBeAbsolute("repos/berrydb")) {
            try store.saveMCPProject(project, sealingKey: SymmetricKey(size: .bits256), previousKey: nil)
        }
        #expect(try store.mcpProject(id: project.id) == nil)
    }

    @Test func loadBoundaryCanonicalizesLegacyRootsDeterministically() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        try BerryStore.migrator.migrate(queue)
        let projectID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO mcp_project
                    (id, name, isEnabled, workspaceRootsJSON, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    projectID, "Legacy", false,
                    #"["/z/repo/./Sources/..","/a/repo","/z/repo"]"#,
                    Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 1),
                ]
            )
        }

        let store = BerryStore(dbQueue: queue)
        #expect(try store.mcpProject(id: projectID)?.workspaceRoots == ["/a/repo", "/z/repo"])
    }

    @Test func loadBoundaryRejectsLegacyRelativeRoots() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        try BerryStore.migrator.migrate(queue)
        let projectID = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO mcp_project
                    (id, name, isEnabled, workspaceRootsJSON, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    projectID, "Legacy", false, #"["relative/repo"]"#,
                    Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 1),
                ]
            )
        }

        let store = BerryStore(dbQueue: queue)
        #expect(throws: MCPProjectError.workspaceRootMustBeAbsolute("relative/repo")) {
            _ = try store.mcpProject(id: projectID)
        }
    }

    @Test func projectsHaveStableNameThenIDOrderingAndCanBeUpdatedAndDeleted() throws {
        let store = try BerryStore(path: ":memory:")
        let zID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let a2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let a1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        for project in [
            MCPProject(id: zID, name: "Zed"),
            MCPProject(id: a2ID, name: "alpha"),
            MCPProject(id: a1ID, name: "Alpha"),
        ] { try store.saveMCPProject(project, sealingKey: SymmetricKey(size: .bits256), previousKey: nil) }

        #expect(try store.mcpProjects().map(\.id) == [a1ID, a2ID, zID])
        var updated = try #require(try store.mcpProject(id: zID))
        updated.name = "Beta"
        try store.saveMCPProject(updated, sealingKey: SymmetricKey(size: .bits256), previousKey: nil)
        #expect(try store.mcpProject(id: zID)?.name == "Beta")
        try store.deleteMCPProject(id: zID)
        #expect(try store.mcpProject(id: zID) == nil)
    }

    @Test func groupAndWorkspaceMetadataNeverImplicitlyGrantProfiles() throws {
        let store = try BerryStore(path: ":memory:")
        let explicitlyAllowed = ConnectionProfile(driverID: "sqlite", name: "Allowed", groupName: "team")
        let sameGroup = ConnectionProfile(driverID: "mysql", name: "Not allowed", groupName: "team")
        try store.save(explicitlyAllowed)
        try store.save(sameGroup)
        let project = MCPProject(
            name: "Repo", workspaceRoots: ["/repo"],
            profiles: [MCPProfileAccess(profileID: explicitlyAllowed.id)]
        )
        try store.saveMCPProject(project, sealingKey: SymmetricKey(size: .bits256), previousKey: nil)

        let loaded = try #require(try store.mcpProject(id: project.id))
        #expect(loaded.profiles.map(\.profileID) == [explicitlyAllowed.id])
        #expect(!loaded.profiles.map(\.profileID).contains(sameGroup.id))
    }

    @Test func deletingAProfileRemovesItFromEffectiveProjectAccess() throws {
        let store = try BerryStore(path: ":memory:")
        let first = ConnectionProfile(driverID: "postgres", name: "First")
        let removed = ConnectionProfile(driverID: "mongodb", name: "Removed")
        try store.save(first)
        try store.save(removed)
        let project = MCPProject(
            name: "Project",
            profiles: [MCPProfileAccess(profileID: first.id), MCPProfileAccess(profileID: removed.id)]
        )
        try store.saveMCPProject(project, sealingKey: SymmetricKey(size: .bits256), previousKey: nil)

        try store.deleteProfile(id: removed.id)
        #expect(try store.mcpProject(id: project.id)?.profiles.map(\.profileID) == [first.id])
    }

    @Test func v30ForwardMigrationPreservesV29FixtureAndRollsBackFailedMigration() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        try BerryStore.migrator.migrate(queue, upTo: "v29-ai-message-tree")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO connection_profile (id, driverID, name, sortOrder, createdAt, tlsMode, sshEnabled, historyEnabled, elasticsearchAPIKeyEnabled) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [UUID(), "sqlite", "Fixture", 0, Date(), "prefer", false, true, false]
            )
        }
        try BerryStore.migrator.migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM connection_profile") } == 1)
        #expect(try queue.read { try $0.tableExists("mcp_project") })
        #expect(try queue.read { try $0.tableExists("mcp_project_profile") })
        #expect(try queue.read { try !$0.tableExists("mcp_project_grant") })

        var rollbackMigrator = DatabaseMigrator()
        rollbackMigrator.registerMigration("base") { db in try db.create(table: "base") { $0.autoIncrementedPrimaryKey("id") } }
        rollbackMigrator.registerMigration("fails") { db in
            try db.create(table: "must_rollback") { $0.autoIncrementedPrimaryKey("id") }
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "fixture failure")
        }
        let rollbackQueue = try DatabaseQueue(path: ":memory:")
        #expect(throws: (any Error).self) { try rollbackMigrator.migrate(rollbackQueue) }
        #expect(try rollbackQueue.read { try !$0.tableExists("must_rollback") })
    }
}
