import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// `WorkspaceViewModel.beginConnect()` — the synchronous reentrancy guard a
/// tap handler calls before creating the `Task` that awaits `connect`/
/// `connectDataSource`/`openSQLiteFile`. Without it, a second click before
/// the first `Task` gets its MainActor turn could start a second, fully
/// concurrent connection attempt (see its doc comment in
/// `WorkspaceViewModel.swift`).
@MainActor
@Suite("WorkspaceViewModel.beginConnect (reentrancy guard)")
struct WorkspaceViewModelConnectTests {
    private func makeViewModel() throws -> WorkspaceViewModel {
        try WorkspaceViewModel(storePath: NSTemporaryDirectory() + "berry-connect-\(UUID().uuidString).sqlite")
    }

    @Test func beginConnectSucceedsOnceThenGuardsAgainstAReentrantCall() throws {
        let vm = try makeViewModel()
        #expect(vm.isConnecting == false)

        #expect(vm.beginConnect() == true)
        #expect(vm.isConnecting == true)

        // A second tap before the in-flight attempt finishes must not start
        // another one.
        #expect(vm.beginConnect() == false)
    }

    @Test func beginConnectClearsAPriorErrorMessage() async throws {
        let vm = try makeViewModel()
        // No public setter for errorMessage — connecting to an unregistered
        // driver is the simplest way to populate it without a real connection.
        await vm.connect(profile: ConnectionProfile(driverID: "not-a-real-driver", name: "x"))
        #expect(vm.errorMessage != nil)

        #expect(vm.beginConnect() == true)
        #expect(vm.errorMessage == nil)
    }

    /// `connect(profile:)` self-guards when called directly (every existing
    /// test in this package calls it this way) — `alreadyBegun` only matters
    /// for a caller that already called `beginConnect()` itself.
    @Test func connectSelfGuardsWhenCalledDirectlyWithoutAlreadyBegun() async throws {
        let vm = try makeViewModel()
        _ = vm.beginConnect() // simulate an already-in-flight attempt
        await vm.connect(profile: ConnectionProfile(driverID: "not-a-real-driver", name: "x"))
        // Bailed out immediately (guard failed) — never reached the point of
        // setting an error for the unregistered driver.
        #expect(vm.errorMessage == nil)
    }
}
