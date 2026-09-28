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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
    }

    @Test func directlyEnabledLiveReadIsIgnored() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project_profile SET liveRead = 1")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func insertedRowWithoutTagGrantsNothing() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.deleteProfile(id: b.id)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
    }

    @Test func tamperedProjectRowDisablesAllLiveReads() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project SET isEnabled = 1")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func missingKeyDisablesAllLiveReads() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: nil))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.project.profiles.count == 1)
    }

    @Test func tagFromAnotherProjectDoesNotTransfer() throws {
        let (store, a, _) = try makeStore()
        let p1 = MCPProject(name: "P1", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let p2 = MCPProject(name: "P2", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: false)])
        try store.saveMCPProject(p1, sealingKey: key, previousKey: nil)
        try store.saveMCPProject(p2, sealingKey: key, previousKey: key)
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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.projectTagValid)
    }

    @Test func duplicateProfileRowIsRejectedAndNotLive() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, redactedColumns: ["ssn"]),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)

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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
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
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting(#"UPDATE mcp_project SET workspaceRootsJSON = '["/other"]'"#)

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(!verified.projectTagValid)
    }

    @Test func projectRowWithNullTagInvalidatesProjectTag() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project SET integrityTag = NULL")

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(!verified.projectTagValid)
    }

    /// Regression guard for HMAC's own key-rotation property (a tag signed
    /// under K1 must not verify under K2) — independent of `reseal`, and not
    /// evidence of the store's resealing behavior, which the tests below
    /// cover directly.
    @Test func staleK1RowsNeverVerifyUnderK2RegressionGuard() throws {
        let (store, a, _) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key1, previousKey: nil)

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
        try store.saveMCPProject(turnedOff, sealingKey: key2, previousKey: key1)

        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveRead = ?, redactedColumnsJSON = ?, integrityTag = ? WHERE projectID = ? AND profileID = ?",
            arguments: [staleLiveRead, staleColumns, staleTag, project.id, a.id]
        )

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key2))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func untamperedRowsSurviveKeyRotation() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        try store.saveMCPProject(projectB, sealingKey: key2, previousKey: key1)

        let verifiedA = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(verifiedA.liveReadProfileIDs == [a.id])
        #expect(verifiedA.projectTagValid)
    }

    @Test func tamperedRowIsNotLaunderedByAnotherProjectsSave() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: false)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        // A same-user process flips A's liveRead directly in the file.
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveRead = 1 WHERE projectID = ? AND profileID = ?",
            arguments: [projectA.id, a.id]
        )

        try store.saveMCPProject(projectB, sealingKey: key2, previousKey: key1)

        let verifiedA = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(verifiedA.liveReadProfileIDs.isEmpty)
        #expect(verifiedA.rejectedLiveReadProfileIDs == [a.id])
    }

    @Test func tamperedProjectRowIsNotLaunderedByAnotherProjectsSave() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        // A same-user process flips A's isEnabled directly in the file.
        try store.executeForTesting("UPDATE mcp_project SET isEnabled = 1 WHERE id = ?", arguments: [projectA.id])

        try store.saveMCPProject(projectB, sealingKey: key2, previousKey: key1)

        let verifiedA = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(!verifiedA.projectTagValid)
    }

    @Test func missingPreviousKeyMakesOtherProjectsRowsUnverifiable() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        try store.saveMCPProject(projectB, sealingKey: key2, previousKey: nil)

        let verifiedA = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(verifiedA.liveReadProfileIDs.isEmpty)
        #expect(!verifiedA.projectTagValid)
    }

    @Test func editingCopyForcesOffATamperedLiveReadRow() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: false)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project_profile SET liveRead = 1")

        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.first?.liveRead == false)
    }

    @Test func editingCopyForcesProjectDisabledWhenProjectTagInvalid() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project SET isEnabled = 1")

        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(!editing.isEnabled)
    }

    @Test func editingCopyKeepsTagVerifiedLiveReadOnADisabledProject() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: false, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)

        // verifiedMCPProject gates liveReadProfileIDs on isEnabled, so a
        // disabled project's editing copy must not derive from that set
        // directly — the row's own tag is still genuinely valid here.
        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.first?.liveRead == true)
        #expect(!editing.isEnabled)
    }

    @Test func editingCopyOfUntamperedProjectRoundTripsUnchanged() throws {
        let (store, a, b) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, redactedColumns: ["email"]),
            MCPProfileAccess(profileID: b.id, liveRead: false),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)

        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        let loaded = try #require(try store.mcpProject(id: project.id))
        #expect(editing == loaded)
    }

    @Test func savingTheEditingCopyOfATamperedProjectDoesNotProduceAnUngrantedLiveRead() throws {
        let (store, a, _) = try makeStore()
        let key2 = SymmetricKey(size: .bits256)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: false)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project_profile SET liveRead = 1")

        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        try store.saveMCPProject(editing, sealingKey: key2, previousKey: key)

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key2))
        #expect(verified.liveReadProfileIDs.isEmpty)
    }

    @Test func deletingAProjectRevokesARestoredCopyAndKeepsOtherProjectsLive() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        let projectRows = try store.fetchForTesting("SELECT * FROM mcp_project WHERE id = ?", arguments: [projectA.id])
        let profileRows = try store.fetchForTesting(
            "SELECT * FROM mcp_project_profile WHERE projectID = ?", arguments: [projectA.id]
        )

        try store.deleteMCPProject(id: projectA.id, sealingKey: key2, previousKey: key1)
        #expect(try store.mcpProject(id: projectA.id) == nil)

        // A same-user process restores the deleted project's rows, tags included.
        for row in projectRows {
            try store.executeForTesting(
                "INSERT INTO mcp_project VALUES (\(Self.placeholders(row)))",
                arguments: StatementArguments(Array(row.databaseValues))
            )
        }
        for row in profileRows {
            try store.executeForTesting(
                "INSERT INTO mcp_project_profile VALUES (\(Self.placeholders(row)))",
                arguments: StatementArguments(Array(row.databaseValues))
            )
        }

        let restored = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(restored.liveReadProfileIDs.isEmpty)
        #expect(!restored.projectTagValid)
        let verifiedB = try #require(try store.verifiedMCPProject(id: projectB.id, key: key2))
        #expect(verifiedB.liveReadProfileIDs == [b.id])
    }

    private static func placeholders(_ row: Row) -> String {
        Array(repeating: "?", count: row.count).joined(separator: ", ")
    }

    @Test func undecodableForeignProfileRowDoesNotBlockSaveAndIsNotLive() throws {
        let (store, a, b) = try makeStore()
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [MCPProfileAccess(profileID: b.id, liveRead: true)])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.saveMCPProject(projectB, sealingKey: key1, previousKey: key1)

        // A same-user process corrupts B's profile row so it cannot decode.
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET redactedColumnsJSON = 'not json' WHERE projectID = ? AND profileID = ?",
            arguments: [projectB.id, b.id]
        )

        try store.saveMCPProject(projectA, sealingKey: key2, previousKey: key1)

        let verifiedA = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(verifiedA.liveReadProfileIDs == [a.id])

        let rows = try store.fetchForTesting(
            "SELECT integrityTag FROM mcp_project_profile WHERE projectID = ? AND profileID = ?",
            arguments: [projectB.id, b.id]
        )
        let tag: Data? = try #require(rows.first)["integrityTag"]
        #expect(tag == nil)
    }
}
