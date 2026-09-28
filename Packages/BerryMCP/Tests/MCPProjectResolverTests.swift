import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP project resolver")
struct MCPProjectResolverTests {
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
