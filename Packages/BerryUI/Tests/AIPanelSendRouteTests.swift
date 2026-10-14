import BerryLicense
import Testing

@testable import BerryUI

/// `AIPanelController.sendRoute` is the one gate the panel's composer and the
/// command palette both ask before anything is sent.
@Suite("AI send route")
struct AIPanelSendRouteTests {
    private typealias Controller = AIPanelController

    private static let installed: [LicenseStatus] = [
        .trial(daysLeft: 3), .active(plan: "topup", daysLeft: 3650), .grace(plan: "pro", daysOver: 2),
        .trialExpired(version: "1.0"), .fallback(version: "1.0"),
    ]

    @Test func aClosedGateSendsNothingAnywhere() {
        let closed: [Controller.Availability] = [.noConnection, .unlicensed, .disabledForConnection, .needsConsent]
        for availability in closed {
            for license in [LicenseStatus.none] + Self.installed {
                for onDevice in [false, true] {
                    #expect(
                        Controller.sendRoute(availability: availability, license: license, onDevicePreferred: onDevice)
                            == .closed(availability)
                    )
                }
            }
        }
    }

    @Test func thePreferredOnDeviceModelIsUsedWithOrWithoutALicense() {
        for license in [LicenseStatus.none] + Self.installed {
            #expect(Controller.sendRoute(availability: .ready, license: license, onDevicePreferred: true) == .onDevice)
        }
    }

    @Test func withoutALicenseOrTrialNothingGoesToTheBackend() {
        #expect(Controller.sendRoute(availability: .ready, license: .none, onDevicePreferred: false) == .noCloudAccess)
    }

    /// An expired trial or plan still goes to the backend, whose refusal
    /// carries the top-up prompt the panel shows; stopping it on the client
    /// would leave the user without that way forward.
    @Test func anyInstalledLicenseGoesToTheBackend() {
        for license in Self.installed {
            #expect(Controller.sendRoute(availability: .ready, license: license, onDevicePreferred: false) == .backend)
        }
    }
}
