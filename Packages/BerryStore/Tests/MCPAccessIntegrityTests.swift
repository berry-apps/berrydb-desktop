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
}
