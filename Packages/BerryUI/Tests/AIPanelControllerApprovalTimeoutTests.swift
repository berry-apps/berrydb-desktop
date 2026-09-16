import BerryCore
import BerryDriverKit
import BerryLicense
import Foundation
import Testing

@testable import BerryUI

@MainActor
@Suite("AIPanelController approval timeout", .serialized)
struct AIPanelControllerApprovalTimeoutTests {
    private func makeController() -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(license: license, backendURL: URL(string: "https://example.invalid")!)
    }

    @Test func unattendedApprovalTimesOutAndClearsPendingApproval() async {
        let controller = makeController()

        // Request approval with a short timeout (50ms)
        let approved = await controller.requestApproval(sql: "DELETE FROM users", danger: .confirm(.deleteData), timeoutSeconds: 0.05)

        #expect(!approved)
        #expect(controller.pendingApproval == nil)
    }

    @Test func resolvingApprovalBeforeTimeoutCancelsTimer() async {
        let controller = makeController()

        let task = Task { @MainActor in
            await controller.requestApproval(sql: "DELETE FROM users", danger: .confirm(.deleteData), timeoutSeconds: 2.0)
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(controller.pendingApproval != nil)

        controller.resolveApproval(true)

        let approved = await task.value
        #expect(approved)
        #expect(controller.pendingApproval == nil)
    }

    @Test func changingConnectionCancelsPendingApprovalAndTimer() async {
        let controller = makeController()

        let task = Task { @MainActor in
            await controller.requestApproval(sql: "DELETE FROM users", danger: .confirm(.deleteData), timeoutSeconds: 2.0)
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(controller.pendingApproval != nil)

        // Switch connection via bind
        controller.bind(session: nil, catalog: nil, objects: [], profileID: UUID())

        let approved = await task.value
        #expect(!approved)
        #expect(controller.pendingApproval == nil)
    }
}
