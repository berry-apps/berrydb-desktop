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
        let store = try BerryStore(path: ":memory:")
        let production = ConnectionProfile(driverID: "postgres", name: "Prod", envColor: "production")
        try store.save(production)
        let project = MCPProject(name: "P", isEnabled: false, profiles: [
            MCPProfileAccess(profileID: production.id, liveRead: true),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.productionSealedProfileIDs.isEmpty)
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
                integrityTag BLOB,
                liveReadUntil DATETIME
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

    /// A profile with every endpoint field set, so each edit below changes a
    /// stored value rather than filling in a missing one.
    private static func endpointProfile() -> ConnectionProfile {
        ConnectionProfile(
            driverID: "postgres", name: "Orders", groupName: "team", envColor: "blue",
            filePath: "/data/orders.sqlite", host: "db.internal", port: 5432,
            username: "reader", database: "orders", tlsMode: "require",
            tlsCACertPath: "/certs/ca.pem", tlsClientCertPath: "/certs/client.pem",
            tlsClientKeyPath: "/certs/client.key", mongoAdditionalHosts: "db2.internal:27017",
            mongoReplicaSet: "rs0", elasticsearchAPIKeyEnabled: false, sshEnabled: true,
            sshHost: "bastion.internal", sshPort: 22, sshUsername: "tunnel", sshKeyPath: "/keys/id_ed25519"
        )
    }

    private func sealedLiveEndpointProfile() throws -> (BerryStore, ConnectionProfile, MCPProject) {
        let store = try BerryStore(path: ":memory:")
        let profile = Self.endpointProfile()
        try store.save(profile)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: profile.id, liveRead: true),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let before = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        try #require(before.liveReadProfileIDs == [profile.id])
        return (store, profile, project)
    }

    @Test(arguments: [
        "driverID = 'mysql'",
        "host = 'attacker.example'",
        "port = 15432",
        "username = 'admin'",
        "database = 'other'",
        "tlsMode = 'disable'",
        "tlsCACertPath = '/tmp/ca.pem'",
        "tlsClientCertPath = '/tmp/client.pem'",
        "tlsClientKeyPath = '/tmp/client.key'",
        "filePath = '/tmp/other.sqlite'",
        "mongoAdditionalHosts = 'attacker.example:27017'",
        "mongoReplicaSet = 'rs1'",
        "elasticsearchAPIKeyEnabled = 1",
        "sshEnabled = 0",
        "sshHost = 'attacker.example'",
        "sshPort = 2222",
        "sshUsername = 'root'",
        "sshKeyPath = NULL",
    ])
    func editingTheStoredEndpointRevokesLiveRead(assignment: String) throws {
        let (store, profile, project) = try sealedLiveEndpointProfile()

        try store.executeForTesting("UPDATE connection_profile SET \(assignment) WHERE id = ?", arguments: [profile.id])

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.rejectedLiveReadProfileIDs == [profile.id])
        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.first?.liveRead == false)
    }

    @Test(arguments: [
        "name = 'Renamed'",
        "groupName = 'other team'",
        "sortOrder = 9",
        "historyEnabled = 0",
    ])
    func editingAFieldOutsideTheEndpointKeepsLiveRead(assignment: String) throws {
        let (store, profile, project) = try sealedLiveEndpointProfile()

        try store.executeForTesting("UPDATE connection_profile SET \(assignment) WHERE id = ?", arguments: [profile.id])

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [profile.id])
    }

    @Test func accessRowWhoseProfileNoLongerExistsIsNotLive() throws {
        let (store, profile, project) = try sealedLiveEndpointProfile()

        // Drop the foreign key so the access row can outlive its profile,
        // simulating a foreign process rewriting the store file directly.
        try store.executeForTesting(
            """
            CREATE TABLE mcp_project_profile_tmp (
                projectID BLOB NOT NULL,
                profileID BLOB NOT NULL,
                liveRead BOOLEAN NOT NULL DEFAULT 0,
                redactedColumnsJSON TEXT NOT NULL DEFAULT '[]',
                integrityTag BLOB,
                liveReadUntil DATETIME
            )
            """
        )
        try store.executeForTesting("INSERT INTO mcp_project_profile_tmp SELECT * FROM mcp_project_profile")
        try store.executeForTesting("DROP TABLE mcp_project_profile")
        try store.executeForTesting("ALTER TABLE mcp_project_profile_tmp RENAME TO mcp_project_profile")
        try store.deleteProfile(id: profile.id)

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.rejectedLiveReadProfileIDs == [profile.id])
    }

    @Test func endpointChangeIsNotCarriedForwardByAnotherProjectsSave() throws {
        let (store, profile, project) = try sealedLiveEndpointProfile()
        let other = ConnectionProfile(driverID: "sqlite", name: "Other", filePath: "/data/other.sqlite")
        try store.save(other)
        let otherProject = MCPProject(name: "Q", isEnabled: true, profiles: [MCPProfileAccess(profileID: other.id, liveRead: true)])
        let key2 = SymmetricKey(size: .bits256)

        try store.executeForTesting("UPDATE connection_profile SET host = 'attacker.example' WHERE id = ?", arguments: [profile.id])
        try store.saveMCPProject(otherProject, sealingKey: key2, previousKey: key)
        try store.executeForTesting("UPDATE connection_profile SET host = 'db.internal' WHERE id = ?", arguments: [profile.id])

        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key2))
        #expect(verified.liveReadProfileIDs.isEmpty)
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

    // MARK: - Production label

    /// A fixed row for the byte pins below. The certificate path puts a `/`
    /// in the payload, which the canonical encoding must leave unescaped: an
    /// escaped slash would change the bytes of every SQLite, TLS and SSH
    /// profile's row.
    private func pinnedRow() throws -> (projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile) {
        let projectID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let profileID = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let profile = ConnectionProfile(
            id: profileID, driverID: "postgres", name: "A", envColor: "production",
            host: "db.example", port: 5432, username: "reader", database: "shop",
            tlsCACertPath: "/etc/ssl/ca.pem"
        )
        let access = MCPProfileAccess(profileID: profileID, liveRead: true, redactedColumns: ["Email", "ssn"])
        return (projectID, access, profile)
    }

    private static let pinnedEndpoint = #"""
    "endpoint":{"database":"shop","driverID":"postgres","elasticsearchAPIKeyEnabled":false,"host":"db.example","port":5432,"sshEnabled":false,"tlsCACertPath":"/etc/ssl/ca.pem","tlsMode":"prefer","username":"reader"}
    """#

    /// The exact bytes rows were sealed over before the production label
    /// joined the payload. Rows sealed by earlier builds carry a tag over
    /// these bytes, so they have to stay reproducible for those rows to
    /// keep verifying.
    @Test func thePayloadSealedBeforeTheLabelKeepsItsBytes() throws {
        let row = try pinnedRow()
        let payload = try MCPAccessIntegrity.earlierProfilePayload(
            projectID: row.projectID, access: row.access, profile: row.profile
        )
        #expect(String(decoding: payload, as: UTF8.self) == #"""
        {"domain":"berrydb.mcp.profile-access.v2",\#(Self.pinnedEndpoint),"liveRead":true,"profileID":"22222222-2222-2222-2222-222222222222","projectID":"11111111-1111-1111-1111-111111111111","redactedColumns":["email","ssn"]}
        """#)
    }

    /// The bytes rows were sealed over after the production label joined
    /// the payload and before the live-read expiry did. Rows sealed by
    /// those builds carry a tag over these bytes.
    @Test func thePayloadKeepsItsBytes() throws {
        let row = try pinnedRow()
        let payload = try MCPAccessIntegrity.labelProfilePayload(
            projectID: row.projectID, access: row.access, profile: row.profile, production: true
        )
        #expect(String(decoding: payload, as: UTF8.self) == #"""
        {"domain":"berrydb.mcp.profile-access.v3",\#(Self.pinnedEndpoint),"liveRead":true,"production":true,"profileID":"22222222-2222-2222-2222-222222222222","projectID":"11111111-1111-1111-1111-111111111111","redactedColumns":["email","ssn"]}
        """#)
    }

    /// After an upgrade, a row sealed before the label was covered is not
    /// one whose settings could not be verified, so the settings pane marks
    /// no connection, and its live reads stay on in the editing copy, so the
    /// first save after the upgrade keeps them.
    @Test func aRowSealedBeforeTheLabelWasCoveredIsNeitherMarkedNorSwitchedOff() throws {
        let (store, a, _) = try makeStore()
        let access = MCPProfileAccess(profileID: a.id, liveRead: true)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [access])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let earlierTag = MCPAccessIntegrity.tag(
            try MCPAccessIntegrity.earlierProfilePayload(projectID: project.id, access: access, profile: a), key: key
        )
        try store.executeForTesting("UPDATE mcp_project_profile SET integrityTag = ?", arguments: [earlierTag])
        #expect(try store.unverifiedMCPProfileIDs(projectID: project.id, key: key).isEmpty)
        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.map(\.liveRead) == [true])
    }

    /// The production label is sealed into the access row when the project
    /// is saved. A same-user process that then removes the label from the
    /// profile row does not lift the connection out of the production
    /// limits: the row still verifies, and still reports the sealed label.
    @Test func theSealedProductionLabelOutlivesTheProfilesLabel() throws {
        let store = try BerryStore(path: ":memory:")
        let production = ConnectionProfile(driverID: "postgres", name: "Prod", envColor: "production")
        try store.save(production)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: production.id, liveRead: true),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE connection_profile SET envColor = NULL")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [production.id])
        #expect(verified.productionSealedProfileIDs == [production.id])
    }

    /// Guard: the label is sealed as a field of its own, not as part of the
    /// endpoint fingerprint, so a row sealed without it keeps verifying when
    /// the profile gains the label later; the helper applies the current
    /// label by itself.
    @Test func aRowSealedWithoutTheLabelStaysVerifiableWhenTheProfileGainsIt() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a.id, liveRead: true)])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE connection_profile SET envColor = 'production'")
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
        #expect(verified.productionSealedProfileIDs.isEmpty)
    }

    /// A row sealed by a build that did not cover the label keeps verifying
    /// and counts as production until its project is saved again, since
    /// which label it was sealed under is unknown. Saving the project seals
    /// the label the profile carries then.
    @Test func aRowSealedBeforeTheLabelWasCoveredCountsAsProductionUntilResaved() throws {
        let (store, a, _) = try makeStore()
        let access = MCPProfileAccess(profileID: a.id, liveRead: true)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [access])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let earlierTag = MCPAccessIntegrity.tag(
            try MCPAccessIntegrity.earlierProfilePayload(projectID: project.id, access: access, profile: a), key: key
        )
        try store.executeForTesting("UPDATE mcp_project_profile SET integrityTag = ?", arguments: [earlierTag])
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [a.id])
        #expect(verified.productionSealedProfileIDs == [a.id])

        let key2 = SymmetricKey(size: .bits256)
        try store.saveMCPProject(project, sealingKey: key2, previousKey: key)
        let resaved = try #require(try store.verifiedMCPProject(id: project.id, key: key2))
        #expect(resaved.liveReadProfileIDs == [a.id])
        #expect(resaved.productionSealedProfileIDs.isEmpty)
    }

    /// Rotation re-seals a verifiable row over the bytes it verified
    /// against, so the sealed label, and the absence of one on a row sealed
    /// before the label was covered, carry forward unchanged.
    @Test func rotationCarriesTheSealedLabelForward() throws {
        let store = try BerryStore(path: ":memory:")
        let production = ConnectionProfile(driverID: "postgres", name: "Prod", envColor: "production")
        let earlier = ConnectionProfile(driverID: "mysql", name: "Earlier")
        try store.save(production)
        try store.save(earlier)
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)
        let earlierAccess = MCPProfileAccess(profileID: earlier.id, liveRead: true)
        let projectA = MCPProject(name: "A", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: production.id, liveRead: true),
            earlierAccess,
        ])
        try store.saveMCPProject(projectA, sealingKey: key1, previousKey: nil)
        try store.executeForTesting("UPDATE connection_profile SET envColor = NULL")
        let earlierTag = MCPAccessIntegrity.tag(
            try MCPAccessIntegrity.earlierProfilePayload(projectID: projectA.id, access: earlierAccess, profile: earlier),
            key: key1
        )
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET integrityTag = ? WHERE profileID = ?", arguments: [earlierTag, earlier.id]
        )

        let projectB = MCPProject(name: "B", isEnabled: true, profiles: [])
        try store.saveMCPProject(projectB, sealingKey: key2, previousKey: key1)

        let verified = try #require(try store.verifiedMCPProject(id: projectA.id, key: key2))
        #expect(verified.liveReadProfileIDs == [production.id, earlier.id])
        #expect(verified.productionSealedProfileIDs == [production.id, earlier.id])
    }

    /// The bytes rows are sealed over now, pinned so that the next change
    /// to the payload has its guard ready. The expiry is whole seconds
    /// since 1970.
    @Test func thePayloadWithAnExpiryKeepsItsBytes() throws {
        let row = try pinnedRow()
        var access = row.access
        access.liveReadUntil = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = try MCPAccessIntegrity.profilePayload(
            projectID: row.projectID, access: access, profile: row.profile, production: true
        )
        #expect(String(decoding: payload, as: UTF8.self) == #"""
        {"domain":"berrydb.mcp.profile-access.v4",\#(Self.pinnedEndpoint),"liveRead":true,"liveReadUntil":1800000000,"production":true,"profileID":"22222222-2222-2222-2222-222222222222","projectID":"11111111-1111-1111-1111-111111111111","redactedColumns":["email","ssn"]}
        """#)
    }

    /// A row sealed after the label was covered but before the expiry was
    /// keeps verifying with the label it was sealed under, since it grants
    /// no more than it did when it was sealed.
    @Test func aRowSealedByThePreviousPayloadStillVerifiesWithoutAnExpiry() throws {
        let store = try BerryStore(path: ":memory:")
        let production = ConnectionProfile(driverID: "postgres", name: "Prod", envColor: "production")
        try store.save(production)
        let access = MCPProfileAccess(profileID: production.id, liveRead: true)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [access])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let previousTag = MCPAccessIntegrity.tag(
            try MCPAccessIntegrity.labelProfilePayload(
                projectID: project.id, access: access, profile: production, production: true
            ),
            key: key
        )
        try store.executeForTesting("UPDATE mcp_project_profile SET integrityTag = ?", arguments: [previousTag])
        let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
        #expect(verified.liveReadProfileIDs == [production.id])
        #expect(verified.productionSealedProfileIDs == [production.id])
        #expect(verified.expiredLiveReadProfileIDs.isEmpty)
    }

    /// Payloads older than the expiry do not cover it, so an expiry stored
    /// next to such a tag was not sealed by BerryDB; the row is rejected
    /// rather than verified with the expiry ignored.
    @Test func anExpiryWrittenNextToAnOlderTagDoesNotVerify() throws {
        let (store, a, _) = try makeStore()
        let expiry = Date(timeIntervalSince1970: 4_000_000_000)
        let access = MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: expiry)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [access])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let olderTags = [
            MCPAccessIntegrity.tag(
                try MCPAccessIntegrity.labelProfilePayload(
                    projectID: project.id, access: access, profile: a, production: false
                ),
                key: key
            ),
            MCPAccessIntegrity.tag(
                try MCPAccessIntegrity.earlierProfilePayload(projectID: project.id, access: access, profile: a),
                key: key
            ),
        ]
        for olderTag in olderTags {
            try store.executeForTesting("UPDATE mcp_project_profile SET integrityTag = ?", arguments: [olderTag])
            let verified = try #require(try store.verifiedMCPProject(id: project.id, key: key))
            #expect(verified.liveReadProfileIDs.isEmpty)
            #expect(verified.expiredLiveReadProfileIDs.isEmpty)
            #expect(verified.rejectedLiveReadProfileIDs == [a.id])
        }
    }

    @Test func anExpiredRowIsReportedApartFromLiveAndRejected() throws {
        let store = try BerryStore(path: ":memory:")
        let production = ConnectionProfile(driverID: "postgres", name: "Prod", envColor: "production")
        try store.save(production)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: production.id, liveRead: true, liveReadUntil: expiry),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)

        let after = try #require(try store.verifiedMCPProject(
            id: project.id, key: key, now: expiry.addingTimeInterval(1)
        ))
        #expect(after.expiredLiveReadProfileIDs == [production.id])
        #expect(after.liveReadProfileIDs.isEmpty)
        #expect(after.rejectedLiveReadProfileIDs.isEmpty)
        #expect(after.productionSealedProfileIDs.isEmpty)

        let before = try #require(try store.verifiedMCPProject(
            id: project.id, key: key, now: expiry.addingTimeInterval(-1)
        ))
        #expect(before.liveReadProfileIDs == [production.id])
        #expect(before.productionSealedProfileIDs == [production.id])
        #expect(before.expiredLiveReadProfileIDs.isEmpty)

        let atTheExpiry = try #require(try store.verifiedMCPProject(id: project.id, key: key, now: expiry))
        #expect(atTheExpiry.liveReadProfileIDs == [production.id])
    }

    /// The tag covers the expiry, so moving it later or clearing it leaves
    /// a row that no payload verifies; clearing it must not fall back to
    /// the older payloads, which never covered one.
    @Test func anExpiryExtendedOrRemovedOnASealedRowDoesNotVerify() throws {
        let (store, a, _) = try makeStore()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: expiry),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let now = expiry.addingTimeInterval(-60)

        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveReadUntil = ?", arguments: [expiry.addingTimeInterval(3600)]
        )
        let extended = try #require(try store.verifiedMCPProject(id: project.id, key: key, now: now))
        #expect(extended.rejectedLiveReadProfileIDs == [a.id])
        #expect(extended.liveReadProfileIDs.isEmpty)
        #expect(extended.expiredLiveReadProfileIDs.isEmpty)

        try store.executeForTesting("UPDATE mcp_project_profile SET liveReadUntil = NULL")
        let removed = try #require(try store.verifiedMCPProject(id: project.id, key: key, now: now))
        #expect(removed.rejectedLiveReadProfileIDs == [a.id])
        #expect(removed.liveReadProfileIDs.isEmpty)
        #expect(removed.expiredLiveReadProfileIDs.isEmpty)
    }

    /// The store file can hold any number in the expiry column, and one
    /// beyond whole seconds an `Int` can hold cannot be what BerryDB
    /// sealed; the row is rejected without failing the whole project.
    @Test func anUnrepresentableExpiryRejectsTheRowWithoutCrashing() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: Date(timeIntervalSince1970: 1_800_000_000)),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting("UPDATE mcp_project_profile SET liveReadUntil = 1e300")
        let verified = try #require(try store.verifiedMCPProject(
            id: project.id, key: key, now: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        #expect(verified.rejectedLiveReadProfileIDs == [a.id])
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.expiredLiveReadProfileIDs.isEmpty)
        #expect(try store.unverifiedMCPProfileIDs(projectID: project.id, key: key) == [a.id])
    }

    /// The tag covers the expiry in whole seconds, so a fraction written
    /// next to it still verifies; the expiry compared with `now` is the
    /// sealed whole second, so the fraction does not extend the grant.
    @Test func aFractionalSecondAddedToAStoredExpiryDoesNotExtendIt() throws {
        let (store, a, _) = try makeStore()
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: expiry),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveReadUntil = ?",
            arguments: [Date(timeIntervalSince1970: 1_800_000_000.9)]
        )
        let verified = try #require(try store.verifiedMCPProject(
            id: project.id, key: key, now: Date(timeIntervalSince1970: 1_800_000_000.5)
        ))
        #expect(verified.expiredLiveReadProfileIDs == [a.id])
        #expect(verified.liveReadProfileIDs.isEmpty)
        #expect(verified.rejectedLiveReadProfileIDs.isEmpty)
        #expect(verified.project.profiles.map(\.liveReadUntil) == [expiry])
        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.map(\.liveReadUntil) == [expiry])
    }

    /// Renewing an expired grant starts from the editing copy, so the copy
    /// keeps live reads on and the expiry it had rather than switching the
    /// row off.
    @Test func theEditingCopyKeepsAnExpiredRowOnWithItsExpiry() throws {
        let (store, a, _) = try makeStore()
        let expiry = Date(timeIntervalSince1970: 1_000_000_000)
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: expiry),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let editing = try #require(try store.mcpProjectForEditing(id: project.id, key: key))
        #expect(editing.profiles.map(\.liveRead) == [true])
        #expect(editing.profiles.map(\.liveReadUntil) == [expiry])
    }

    /// An expired row was sealed by BerryDB; the settings pane must not
    /// mark it as settings that could not be verified.
    @Test func anExpiredRowIsNotUnverified() throws {
        let (store, a, _) = try makeStore()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: a.id, liveRead: true, liveReadUntil: Date(timeIntervalSince1970: 1_000_000_000)),
        ])
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        #expect(try store.unverifiedMCPProfileIDs(projectID: project.id, key: key).isEmpty)
    }
}
