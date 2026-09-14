import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Connection grouping + drag-reorder.
@MainActor
@Suite("Connection groups")
struct ConnectionGroupsTests {
    private func tempPath(_ tag: String) -> String {
        NSTemporaryDirectory() + "berry-\(tag)-\(UUID().uuidString).sqlite"
    }

    private func makeVM() throws -> WorkspaceViewModel {
        let vm = try WorkspaceViewModel(storePath: tempPath("store"))
        vm.save(profile: ConnectionProfile(driverID: "sqlite", name: "prod-a", groupName: "Prod", sortOrder: 0), secrets: ConnectionSecrets())
        vm.save(profile: ConnectionProfile(driverID: "sqlite", name: "prod-b", groupName: "Prod", sortOrder: 1), secrets: ConnectionSecrets())
        vm.save(profile: ConnectionProfile(driverID: "sqlite", name: "loose", groupName: nil, sortOrder: 0), secrets: ConnectionSecrets())
        return vm
    }

    @Test func partitionsByGroupUngroupedFirst() throws {
        let vm = try makeVM()
        let groups = vm.connectionGroups
        #expect(groups.count == 2)
        #expect(groups.first?.name == nil)                 // ungrouped sorts first
        #expect(groups.first?.profiles.map(\.name) == ["loose"])
        #expect(groups.last?.name == "Prod")
        #expect(groups.last?.profiles.map(\.name) == ["prod-a", "prod-b"])
    }

    @Test func reorderWithinGroupPersistsSortOrder() throws {
        let vm = try makeVM()
        // Move prod-b (index 1) above prod-a within the Prod group.
        vm.moveProfiles(group: "Prod", from: IndexSet(integer: 1), to: 0)
        let prod = vm.connectionGroups.first { $0.name == "Prod" }
        #expect(prod?.profiles.map(\.name) == ["prod-b", "prod-a"])
    }
}
