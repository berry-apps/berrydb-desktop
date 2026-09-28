import CryptoKit
import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("MCP access integrity")
struct MCPAccessIntegrityTests {
    let key = SymmetricKey(size: .bits256)

    func makeStore() throws -> (BerryStore, ConnectionProfile, ConnectionProfile) {
        let store = try BerryStore(path: ":memory:")
        let a = ConnectionProfile(driverID: "postgres", name: "A")
        let b = ConnectionProfile(driverID: "dynamodb", name: "B")
        try store.save(a)
        try store.save(b)
        return (store, a, b)
    }

    @Test func sealedLiveReadVerifies() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true),
            MCPProfileAccess(profileID: b.id, liveRead: false),
        ])
        try store.saveMCPProject(project, sealingKey: key)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
    }

    @Test func directlyEnabledLiveReadIsIgnored() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id)])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting("UPDATE mcp_project_profile SET liveRead = 1")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func insertedRowWithoutTagGrantsNothing() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting(
            "INSERT INTO mcp_project_profile (projectID, profileID, liveRead, redactedColumnsJSON) VALUES (?, ?, 1, '[]')",
            arguments: [project.id, b.id]
        )
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
    }

    @Test func removingRedactionWithoutKeyDisablesThatProfile() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, redactedColumns: ["email"]),
        ])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting("UPDATE mcp_project_profile SET redactedColumnsJSON = '[]'")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func deletingOneProfileKeepsTheOthersValid() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true),
            MCPProfileAccess(profileID: b.id, liveRead: true),
        ])
        try store.saveMCPProject(project, sealingKey: key)
        try store.deleteProfile(id: b.id)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
    }

    @Test func tamperedProjectRowDisablesAllLiveReads() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting("UPDATE mcp_project SET isEnabled = 1")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func missingKeyDisablesAllLiveReads() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: nil))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.project.profiles.count == 1)
    }

    @Test func tagFromAnotherProjectDoesNotTransfer() throws {
        let (store, a, _) = try makeStore()
        let p1 = MCPProject(name: "P1", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let p2 = MCPProject(name: "P2", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: false)])
        try store.saveMCPProject(p1, sealingKey: key)
        try store.saveMCPProject(p2, sealingKey: key)
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveRead = 1, integrityTag = (SELECT integrityTag FROM mcp_project_profile WHERE projectID = ?) WHERE projectID = ?",
            arguments: [p1.id, p2.id]
        )
        let verified = try #require(try store.verifiedMCPProject(id: p2.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func disabledProjectHasEmptyLiveReadsButValidProjectTag() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.projectTagValid)
    }

    @Test func duplicateProfileRowIsRejectedAndNotLive() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, redactedColumns: ["ssn"]),
        ])
        try store.saveMCPProject(project, sealingKey: key)

        // Drop the composite primary key so a second row for the same
        // profile can exist, simulating a foreign process rewriting the
        // store file directly.
        try store.executeForTesting(
            """
            CREATE TABLE mcp_project_profile_tmp (
                projectID BLOB NOT NULL,
                profileID BLOB NOT NULL,
                liveRead BOOLEAN NOT NULL DEFAULT 0,
                redactedColumnsJSON TEXT NOT NULL DEFAULT '[]',
                integrityTag BLOB
            )
            """
        )
        try store.executeForTesting("INSERT INTO mcp_project_profile_tmp SELECT * FROM mcp_project_profile")
        try store.executeForTesting("DROP TABLE mcp_project_profile")
        try store.executeForTesting("ALTER TABLE mcp_project_profile_tmp RENAME TO mcp_project_profile")
        try store.executeForTesting(
            """
            INSERT INTO mcp_project_profile (projectID, profileID, liveRead, redactedColumnsJSON, integrityTag)
            SELECT projectID, profileID, 1, '[]', integrityTag FROM mcp_project_profile WHERE profileID = ?
            """,
            arguments: [a.id]
        )

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.rejectedLiveReadProfileIDs == [a.id])
    }

    @Test func tagCopiedOntoAnotherProfilesRowInSameProjectIsNotLive() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true),
            MCPProfileAccess(profileID: b.id, liveRead: true),
        ])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET integrityTag = (SELECT integrityTag FROM mcp_project_profile WHERE profileID = ?) WHERE profileID = ?",
            arguments: [a.id, b.id]
        )

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
        #expect(verified.rejectedLiveReadProfileIDs == [b.id])
    }

    @Test func workspaceRootsChangedDirectlyInvalidatesProjectTag() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(
            name: "P", isEnabled: true, workspaceRoots: ["/repo"],
            profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)]
        )
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting(#"UPDATE mcp_project SET workspaceRootsJSON = '["/other"]'"#)

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(!verified.projectTagValid)
    }

    @Test func projectRowWithNullTagInvalidatesProjectTag() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key)
        try store.executeForTesting("UPDATE mcp_project SET integrityTag = NULL")

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(!verified.projectTagValid)
    }

    @Test func staleRowsRestoredAfterKeyRotationDoNotVerifyUnderTheNewKey() throws {
        let (store, a, _) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key1)

        let snapshot = try store.fetchForTesting(
            "SELECT liveRead, redactedColumnsJSON, integrityTag FROM mcp_project_profile WHERE projectID = ? AND profileID = ?",
            arguments: [project.id, a.id]
        )
        let row = try #require(snapshot.first)
        let staleLiveRead: Bool = row["liveRead"]
        let staleColumns: String = row["redactedColumnsJSON"]
        let staleTag: Data? = row["integrityTag"]

        var turnedOff = project
        turnedOff.profiles = [MCPProfileAccess(profileID: a.id, liveRead: false)]
        try store.saveMCPProject(turnedOff, sealingKey: key2)

        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveRead = ?, redactedColumnsJSON = ?, integrityTag = ? WHERE projectID = ? AND profileID = ?",
            arguments: [staleLiveRead, staleColumns, staleTag, project.id, a.id]
        )

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key2))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func savingOneProjectReSealsAnotherProjectUnderTheNewKey() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1)
        try store.saveMCPProject(projectB, sealingKey: key1)

        try store.saveMCPProject(projectA, sealingKey: key2)

        let verifiedB = try #require(try store.verifiedMCPProject(id: projectB.id, key: key2))
        #expect(verifiedB.liveReadProfileIDs == [b.id])
        #expect(verifiedB.projectTagValid)
    }
}
