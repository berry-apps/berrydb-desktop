import CryptoKit
import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("MCP scoped grants")
struct MCPProjectGrantTests {
    private func makeStoreWithProject(path: String = ":memory:") throws -> (BerryStore, MCPProject) {
        let store = try BerryStore(path: path)
        let profile = ConnectionProfile(driverID: "sqlite", name: "Local")
        try store.save(profile)
        let project = MCPProject(name: "Project", profileIDs: [profile.id], enabledCapabilities: [.schema])
        try store.saveMCPProject(project)
        return (store, project)
    }

    @Test func generatesA256BitTokenAndPersistsOnlyItsHash() throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let queue = try DatabaseQueue(path: ":memory:", configuration: configuration)
        try BerryStore.migrator.migrate(queue)
        let store = BerryStore(dbQueue: queue)
        let profile = ConnectionProfile(driverID: "sqlite", name: "Local")
        try store.save(profile)
        let project = MCPProject(name: "Project", profileIDs: [profile.id])
        try store.saveMCPProject(project)

        let issued = try store.createMCPGrant(projectID: project.id, expiresAt: nil)
        let padding = String(repeating: "=", count: (4 - issued.token.count % 4) % 4)
        let base64 = issued.token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        #expect(Data(base64Encoded: base64)?.count == 32)

        let row = try #require(try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM mcp_project_grant WHERE id = ?", arguments: [issued.id])
        })
        let storedHash: Data = row["tokenHash"]
        #expect(storedHash == Data(SHA256.hash(data: Data(issued.token.utf8))))
        #expect(!row.columnNames.contains("token"))
        let serializedCells = row.columnNames.map { String(describing: row[$0] as DatabaseValue) }
        #expect(!serializedCells.contains(where: { $0.contains(issued.token) }))
    }

    @Test func validatesThenRejectsWrongProjectExpirationAndRevocation() throws {
        let (store, project) = try makeStoreWithProject()
        let otherProject = MCPProject(name: "Other")
        try store.saveMCPProject(otherProject)
        let expiration = Date(timeIntervalSince1970: 200)
        let issued = try store.createMCPGrant(projectID: project.id, expiresAt: expiration)

        guard case let .valid(validated) = try store.validateMCPGrant(
            projectID: project.id, token: issued.token, now: Date(timeIntervalSince1970: 100)
        ) else { Issue.record("Expected a valid grant"); return }
        #expect(validated.grantID == issued.id)
        #expect(validated.project.id == project.id)
        #expect(try store.validateMCPGrant(projectID: otherProject.id, token: issued.token, now: .distantPast) == .invalid)
        #expect(try store.validateMCPGrant(projectID: project.id, token: "wrong", now: .distantPast) == .invalid)
        #expect(try store.validateMCPGrant(projectID: project.id, token: issued.token, now: expiration) == .invalid)

        let nonExpiring = try store.createMCPGrant(projectID: project.id, expiresAt: nil)
        try store.revokeMCPGrant(id: nonExpiring.id, revokedAt: Date(timeIntervalSince1970: 300))
        #expect(try store.validateMCPGrant(projectID: project.id, token: nonExpiring.token, now: .distantPast) == .invalid)
    }

    @Test func validationSurvivesReopenAndFiltersAProfileRemovedAfterGrantCreation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-mcp-grant-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var issuedToken = ""
        var projectID = UUID()
        var removedProfileID = UUID()
        do {
            let store = try BerryStore(path: url.path)
            let kept = ConnectionProfile(driverID: "postgres", name: "Kept")
            let removed = ConnectionProfile(driverID: "dynamodb", name: "Removed")
            try store.save(kept)
            try store.save(removed)
            let project = MCPProject(name: "Project", profileIDs: [removed.id, kept.id])
            try store.saveMCPProject(project)
            let issued = try store.createMCPGrant(projectID: project.id, expiresAt: nil)
            issuedToken = issued.token
            projectID = project.id
            removedProfileID = removed.id
            try store.deleteProfile(id: removed.id)
        }

        let reopened = try BerryStore(path: url.path)
        guard case let .valid(validated) = try reopened.validateMCPGrant(
            projectID: projectID, token: issuedToken, now: Date()
        ) else { Issue.record("Expected persisted grant to validate"); return }
        #expect(!validated.project.profileIDs.contains(removedProfileID))
        #expect(validated.project.profileIDs.count == 1)

        let fileBytes = try Data(contentsOf: url)
        #expect(fileBytes.range(of: Data(issuedToken.utf8)) == nil)
    }

    @Test func fixedWidthComparisonChecksAllBytes() {
        let base = Data(repeating: 7, count: 32)
        var firstDiffers = base
        firstDiffers[0] = 8
        var lastDiffers = base
        lastDiffers[31] = 8
        #expect(BerryStore.constantTimeEqual(base, base))
        #expect(!BerryStore.constantTimeEqual(base, firstDiffers))
        #expect(!BerryStore.constantTimeEqual(base, lastDiffers))
        #expect(!BerryStore.constantTimeEqual(base, Data(repeating: 7, count: 31)))
    }

    @Test func deletingProjectCascadesItsGrant() throws {
        let (store, project) = try makeStoreWithProject()
        let issued = try store.createMCPGrant(projectID: project.id, expiresAt: nil)
        try store.deleteMCPProject(id: project.id)
        #expect(try store.validateMCPGrant(projectID: project.id, token: issued.token, now: Date()) == .invalid)
    }
}
