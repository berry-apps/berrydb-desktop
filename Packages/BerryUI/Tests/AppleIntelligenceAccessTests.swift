import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import Foundation
import Testing

@testable import BerryUI

/// AI-20 follow-up: a Mac with Apple Intelligence available can use AI
/// without a paid trial/license (on-device inference costs BerryDB nothing).
/// The risk this guards against: that bypass must only ever unlock the local
/// path — it must never let a device with no real license reach the metered
/// backend, through *any* branch (`prepareSend`'s normal send, its edit
/// branch, or the on-device toggle being off).
///
/// `AppleIntelligenceAccess` itself is a plain UserDefaults flag — cleared
/// before/after each test so runs don't leak state into each other or into
/// a developer's real defaults.
/// Serialized: `AppleIntelligenceAccess`/`"berry.ai.onDevice"` are both
/// shared `UserDefaults.standard` state — concurrent tests in this suite
/// stomp on each other's grant/revoke otherwise.
@MainActor
@Suite("Apple Intelligence access bypass (AI-20 follow-up)", .serialized)
struct AppleIntelligenceAccessTests {
    private func withCleanGrant(_ body: () throws -> Void) rethrows {
        AppleIntelligenceAccess.revoke()
        defer { AppleIntelligenceAccess.revoke() }
        try body()
    }

    private func withCleanGrant(_ body: () async throws -> Void) async rethrows {
        AppleIntelligenceAccess.revoke()
        defer { AppleIntelligenceAccess.revoke() }
        try await body()
    }

    // MARK: - AppleIntelligenceAccess (pure local state)

    @Test func startsUngranted() {
        withCleanGrant {
            #expect(AppleIntelligenceAccess.isGranted == false)
            #expect(AppleIntelligenceAccess.grantedEmail == nil)
        }
    }

    @Test func grantingRecordsTheEmailLocally() {
        withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            #expect(AppleIntelligenceAccess.isGranted)
            #expect(AppleIntelligenceAccess.grantedEmail == "dev@example.com")
        }
    }

    @Test func revokeClearsTheGrant() {
        withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            AppleIntelligenceAccess.revoke()
            #expect(AppleIntelligenceAccess.isGranted == false)
        }
    }

    // MARK: - AIPanelController.appleIntelligenceGranted

    private func makeController() -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(license: license, backendURL: URL(string: "https://example.invalid")!)
    }

    @Test func noAccessWithoutAGrantEvenWhenAppleIntelligenceIsAvailable() {
        withCleanGrant {
            let controller = makeController()
            // A fresh LicenseManager starts at `.none` (nothing persisted) —
            // exactly the "never activated" state this bypass exists for.
            #expect(controller.appleIntelligenceGranted == false)
        }
    }

    @Test func accessOnceGrantedTracksLiveAppleIntelligenceAvailability() {
        withCleanGrant {
            let controller = makeController()
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            // This machine's real on-device availability, not a mock — the
            // same ground truth `AppleFoundationProvider.isAvailable()`
            // itself reports elsewhere in this suite (AI-20 smoke test).
            #expect(controller.appleIntelligenceGranted == AppleFoundationProvider.isAvailable())
        }
    }

    // MARK: - prepareSend() must never leak into the metered backend

    private func makeSQLiteSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-ai-gate-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        return try await ConnectionManager().open(.sqlite(path: path))
    }

    /// A controller bound to a real (but license-less) connection, with
    /// consent already given — the only way `availability` can still reach
    /// `.ready` from here is the Apple Intelligence bypass, since
    /// `license.status` stays `.none` throughout (no network call is ever
    /// made in this suite).
    private func makeBoundController() async throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        let controller = AIPanelController(license: license, backendURL: URL(string: "https://example.invalid")!)
        let session = try await makeSQLiteSession()
        controller.bind(session: session, catalog: nil, objects: [], profileID: nil)
        controller.giveConsentAndEnable()
        return controller
    }

    @Test func withNoGrantSendingStaysBlocked() async throws {
        try await withCleanGrant {
            let controller = try await makeBoundController()
            #expect(controller.availability == .unlicensed)
            controller.draft = "hello"
            #expect(controller.prepareSend() == nil)
        }
    }

    @Test func bypassGrantedRoutesToLocalNeverBackend() async throws {
        try await withCleanGrant {
            guard AppleFoundationProvider.isAvailable() else { return } // needs a real on-device machine
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let controller = try await makeBoundController()
            #expect(controller.availability == .ready)

            controller.draft = "hello"
            let prepared = try #require(controller.prepareSend())
            guard case .local = prepared else {
                Issue.record("bypass-only access must never route to the backend, got \(prepared)")
                return
            }
        }
    }

    /// Reported live, three times over as each fix uncovered the next:
    /// first that the toggle had no effect on sending; then that gating
    /// `availability` on it locked the user out of the very menu that
    /// controls it; then that once the panel stayed reachable, sending
    /// with the toggle off returned `nil` from `prepareSend()` — the
    /// message vanished with no bubble and no error at all. Nothing should
    /// ever disappear silently: this must show the user's own bubble like
    /// any other send.
    ///
    /// A later clarifying answer added a fourth layer: toggling off must
    /// not just show a static "no trial" message — it must attempt a real
    /// trial for the grant's own email first (`.backendAfterTrial`) and
    /// only fall back to an explanation if that attempt itself fails. This
    /// test pins the synchronous half (`prepareSend()` routes to
    /// `.backendAfterTrial`, bubble appears immediately); the async
    /// attempt-then-fail half is `toggleOffFailsTheBubbleWhenTheTrialAttemptCannotReachTheServer` below.
    @Test func togglingOnDeviceOffBlocksSendingButStillShowsTheBubble() async throws {
        try await withCleanGrant {
            guard AppleFoundationProvider.isAvailable() else { return }
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let previousToggle = UserDefaults.standard.bool(forKey: "berry.ai.onDevice")
            UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
            defer { UserDefaults.standard.set(previousToggle, forKey: "berry.ai.onDevice") }

            let controller = try await makeBoundController()
            #expect(controller.availability == .ready, "the panel/settings menu must stay reachable so the toggle can be turned back on")
            controller.draft = "hello"
            let prepared = try #require(controller.prepareSend(), "must not silently discard the message")
            guard case let .backendAfterTrial(_, email) = prepared else {
                Issue.record("expected .backendAfterTrial (try a real trial before giving up), got \(prepared)")
                return
            }
            #expect(email == "dev@example.com")
            #expect(controller.transcript.count == 2, "the user's message and a placeholder reply must both appear")
            #expect(controller.transcript.first?.text == "hello")
        }
    }

    /// Full async half of the test above: `example.invalid` never resolves,
    /// so `license.startTrial` fails deterministically and `send(_:)` must
    /// fail the already-shown assistant turn in place with an explanation —
    /// never a permanent spinner, never a fall-through to the backend with
    /// no valid token.
    @Test func toggleOffFailsTheBubbleWhenTheTrialAttemptCannotReachTheServer() async throws {
        try await withCleanGrant {
            guard AppleFoundationProvider.isAvailable() else { return }
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let previousToggle = UserDefaults.standard.bool(forKey: "berry.ai.onDevice")
            UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
            defer { UserDefaults.standard.set(previousToggle, forKey: "berry.ai.onDevice") }

            let controller = try await makeBoundController()
            controller.draft = "hello"
            let prepared = try #require(controller.prepareSend())
            guard case .backendAfterTrial = prepared else {
                Issue.record("expected .backendAfterTrial, got \(prepared)")
                return
            }
            await controller.send(prepared)
            #expect(controller.isStreaming == false)
            #expect(controller.transcript.count == 2)
            #expect(controller.transcript.first?.text == "hello")
            // Must be the specific, actionable message mapped from the
            // backend's stable error code (LicenseSupport.licenseErrorMessage
            // — same mapping LicenseView already uses), not a generic
            // catch-all that would bury e.g. "this device already used its
            // trial with a different account" behind "check your connection".
            #expect(controller.transcript.last?.text == licenseErrorMessage("transport"))
        }
    }

    @Test func reenablingTheToggleRestoresSending() async throws {
        try await withCleanGrant {
            guard AppleFoundationProvider.isAvailable() else { return }
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
            let controller = try await makeBoundController()
            #expect(controller.availability == .ready)
            controller.draft = "hello"
            let blocked = try #require(controller.prepareSend())
            guard case .backendAfterTrial = blocked else {
                Issue.record("expected .backendAfterTrial while the toggle is off, got \(blocked)")
                return
            }

            UserDefaults.standard.set(true, forKey: "berry.ai.onDevice")
            controller.draft = "hello"
            let prepared = try #require(controller.prepareSend())
            guard case .local = prepared else {
                Issue.record("expected local, got \(prepared)")
                return
            }
        }
    }

    /// Editing has no on-device implementation at all (v1 scope), so
    /// bypass-only access can never fulfil it — same "must still show the
    /// bubble, never vanish silently" requirement as the plain-send case
    /// above applies here too.
    @Test func editingAMessageIsBlockedButStillShowsTheBubble() async throws {
        try await withCleanGrant {
            guard AppleFoundationProvider.isAvailable() else { return }
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let controller = try await makeBoundController()
            controller.draft = "edited text"
            controller.editingMessageID = UUID() // no such message exists — prepareEdit would fail anyway
            let prepared = try #require(controller.prepareSend())
            guard case .handled = prepared else {
                Issue.record("expected .handled (blocked-but-shown), got \(prepared)")
                return
            }
            #expect(controller.transcript.count == 2)
            #expect(controller.transcript.first?.text == "edited text")
        }
    }
}
