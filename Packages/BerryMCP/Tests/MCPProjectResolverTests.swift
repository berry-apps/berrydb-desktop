import BerryCredentials
import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP project resolver")
struct MCPProjectResolverTests {

    @Test func liveAccessCarriesTheVerifiedRedactions() async throws {
        let id = UUID()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: id, liveRead: true, redactedColumns: ["Email"]),
        ])
        let resolver = MCPProjectResolver(
            loadProject: { MCPVerifiedProject(project: project, liveReadProfileIDs: [id]) },
            profile: { _ in MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
        )
        #expect(try await resolver.resolve(profileID: id, access: .liveRead).redactedColumns == ["email"])
    }

    @Test func theStoreLoaderMarksAProductionProfile() async throws {
        let store = try BerryStore(path: ":memory:")
        let profile = ConnectionProfile(driverID: "sqlite", name: "Prod", envColor: "production", filePath: "/tmp/x.db")
        try store.save(profile)
        let loader = MCPProjectResolver.storeProfileLoader(
            store: store, credentialResolver: MCPCredentialResolver { _ in ConnectionSecrets() }
        )
        #expect(try await loader(profile.id)?.isProduction == true)
    }
    let a = UUID()
    let b = UUID()
    let outsider = UUID()

    func resolver(enabled: Bool = true, live: Set<UUID> = []) -> MCPProjectResolver {
        let project = MCPProject(name: "P", isEnabled: enabled, profiles: [
            MCPProfileAccess(profileID: a, liveRead: true),
            MCPProfileAccess(profileID: b),
        ])
        let verified = MCPVerifiedProject(project: project, liveReadProfileIDs: live)
        return MCPProjectResolver(
            loadProject: { verified },
            profile: { id in MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
        )
    }

    @Test func metadataAccessForAnyAssignedProfile() async throws {
        #expect(try await resolver().resolve(profileID: b, access: .metadata).id == b)
    }

    @Test func liveAccessRequiresVerifiedLiveRead() async throws {
        await #expect(throws: MCPProjectResolutionError.liveReadNotEnabled(a)) {
            try await resolver(live: []).resolve(profileID: a, access: .liveRead)
        }
        #expect(try await resolver(live: [a]).resolve(profileID: a, access: .liveRead).id == a)
    }

    @Test func unassignedProfileLooksTheSameWhetherItExistsOrNot() async {
        await #expect(throws: MCPProjectResolutionError.unauthorizedProfile(outsider)) {
            try await resolver().resolve(profileID: outsider, access: .metadata)
        }
    }

    @Test func disabledProjectRefusesEverything() async {
        await #expect(throws: MCPProjectResolutionError.projectDisabled) {
            try await resolver(enabled: false, live: [a]).resolve(profileID: a, access: .metadata)
        }
    }

    @Test func projectIsReloadedPerCallSoRevocationIsImmediate() async throws {
        final class Flag: @unchecked Sendable {
            var live: Set<UUID>
            init(live: Set<UUID>) { self.live = live }
        }
        let flag = Flag(live: [a])
        let project = MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: a, liveRead: true)])
        let resolver = MCPProjectResolver(
            loadProject: { MCPVerifiedProject(project: project, liveReadProfileIDs: flag.live) },
            profile: { id in MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
        )
        _ = try await resolver.resolve(profileID: a, access: .liveRead)
        flag.live = []
        await #expect(throws: MCPProjectResolutionError.liveReadNotEnabled(a)) {
            try await resolver.resolve(profileID: a, access: .liveRead)
        }
    }
}
