import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// follow-up: a Mac with Apple Intelligence available can use AI
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
@Suite("Apple Intelligence access bypass", .serialized)
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

    private func makeController() throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(
            license: license, backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
    }

    @Test func noAccessWithoutAGrantEvenWhenAppleIntelligenceIsAvailable() throws {
        try withCleanGrant {
            let controller = try makeController()
            // A fresh LicenseManager starts at `.none` (nothing persisted) —
            // exactly the "never activated" state this bypass exists for.
            #expect(controller.appleIntelligenceGranted == false)
        }
    }

    @Test func accessOnceGrantedTracksLiveAppleIntelligenceAvailability() throws {
        try withCleanGrant {
            let controller = try makeController()
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            // This machine's real on-device availability, not a mock — the
            // same ground truth `AppleFoundationProvider.isAvailable()`
 // itself reports elsewhere in this suite (smoke test).
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

    private func makeLicense() -> LicenseManager {
        LicenseManager(client: LicenseClient(baseURL: URL(string: "https://example.invalid")!))
    }

    /// A controller bound to a real (but license-less) connection, with
    /// consent given unless `consent` is false — the only way `availability`
    /// can still reach `.ready` from here is the Apple Intelligence bypass,
    /// since `license.status` stays `.none` throughout (no request ever
    /// succeeds against `example.invalid`). The on-device model counts as
    /// available, so these tests run the same on a Mac without Apple
    /// Intelligence, which includes the CI runners.
    private func makeBoundController(
        license: LicenseManager? = nil, consent: Bool = true
    ) async throws -> AIPanelController {
        let controller = AIPanelController(
            license: license ?? makeLicense(), backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
        controller.onDeviceModelAvailable = { true }
        let session = try await makeSQLiteSession()
        controller.bind(session: session, catalog: nil, objects: [], profileID: nil)
        if consent { controller.giveConsentAndEnable() }
        return controller
    }

    /// Runs `body` with the on-device toggle set to `on`, then restores it.
    private func withOnDeviceToggle(_ on: Bool, _ body: () async throws -> Void) async rethrows {
        let previous = UserDefaults.standard.bool(forKey: "berry.ai.onDevice")
        UserDefaults.standard.set(on, forKey: "berry.ai.onDevice")
        defer { UserDefaults.standard.set(previous, forKey: "berry.ai.onDevice") }
        try await body()
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

    /// Sending with the on-device toggle off once returned `nil` from
    /// `prepareSend()`, and the message vanished with no bubble and no error.
    /// It must show like any other send, with a reply that says why it went
    /// nowhere.
    ///
    /// It must not start a trial either. The grant's email was captured for
    /// on-device access and is documented as never leaving the Mac; using it
    /// to start a cloud trial posted it to the license server on an ordinary
    /// send that never mentioned a trial. A trial starts only from the
    /// License sheet's trial button.
    @Test func togglingOnDeviceOffBlocksSendingWithoutStartingATrial() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            try await withOnDeviceToggle(false) {
                let license = makeLicense()
                let controller = try await makeBoundController(license: license)
                #expect(controller.availability == .ready, "the panel/settings menu must stay reachable so the toggle can be turned back on")
                controller.draft = "hello"
                let prepared = try #require(controller.prepareSend(), "must not silently discard the message")
                guard case .handled = prepared else {
                    Issue.record("expected .handled (shown, sent nowhere), got \(prepared)")
                    return
                }
                await controller.send(prepared)

                #expect(controller.transcript.count == 2, "the user's message and a reply must both appear")
                #expect(controller.transcript.first?.text == "hello")
                #expect(controller.transcript.last?.text == L("On-device AI is off, and there's no trial or license for cloud AI. Turn on-device back on above, or add a trial, license, or credit in License settings to use cloud AI instead."))
                #expect(license.lastError == nil, "no trial request may have been attempted")
                #expect(license.status == .none)
            }
        }
    }

    @Test func reenablingTheToggleRestoresSending() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let previousToggle = UserDefaults.standard.bool(forKey: "berry.ai.onDevice")
            UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
            defer { UserDefaults.standard.set(previousToggle, forKey: "berry.ai.onDevice") }
            let controller = try await makeBoundController()
            #expect(controller.availability == .ready)
            controller.draft = "hello"
            let blocked = try #require(controller.prepareSend())
            guard case .handled = blocked else {
                Issue.record("expected .handled while the toggle is off, got \(blocked)")
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

    /// With a license and the on-device model preferred, an edit would re-run
    /// the conversation on BerryDB's AI service, its on-device messages
    /// included, although the toggle still reads on-device. It is blocked
    /// with a message instead, like an edit without a license.
    @Test func editingWhileOnDeviceIsPreferredSendsNothing() async throws {
        try await withCleanGrant {
            try await withOnDeviceToggle(true) {
                let controller = try await makeBoundController()
                controller.licenseStatus = { .trial(daysLeft: 5) }
                controller.makeOnDeviceProvider = { ScriptedOnDeviceModel(reply: "Two tables.") }
                #expect(controller.availability == .ready)
                controller.draft = "what tables?"
                let first = try #require(controller.prepareSend())
                await controller.send(first)
                let messageID = try #require(controller.transcript.first?.messageID)

                controller.editingMessageID = messageID
                controller.draft = "what views?"
                let edit = try #require(controller.prepareSend(), "must not silently discard the edit")
                guard case .handled = edit else {
                    Issue.record("expected .handled (shown, sent nowhere), got \(edit)")
                    return
                }
                #expect(!controller.isStreaming)
                #expect(controller.transcript.last?.text == L("Editing uses cloud AI. Turn off the on-device model in AI settings to edit this message."))
            }
        }
    }

    /// Guard for the test above: with the on-device model turned off, a
    /// licensed user's edit still goes to the backend.
    @Test func editingWithALicenseOnTheCloudRouteGoesToTheBackend() async throws {
        try await withCleanGrant {
            try await withOnDeviceToggle(true) {
                let controller = try await makeBoundController()
                controller.licenseStatus = { .trial(daysLeft: 5) }
                controller.makeOnDeviceProvider = { ScriptedOnDeviceModel(reply: "Two tables.") }
                controller.draft = "what tables?"
                await controller.send(try #require(controller.prepareSend()))
                let messageID = try #require(controller.transcript.first?.messageID)

                UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
                controller.editingMessageID = messageID
                controller.draft = "what views?"
                let edit = try #require(controller.prepareSend())
                guard case .backend = edit else {
                    Issue.record("expected .backend, got \(edit)")
                    return
                }
            }
        }
    }

    /// A cloud turn that failed offline is retried when connectivity returns.
    /// The panel lets that happen only while the route is still the backend.
    @Test func networkRetryIsAllowedOnlyWhileTheRouteIsTheBackend() async throws {
        try await withCleanGrant {
            try await withOnDeviceToggle(true) {
                let controller = try await makeBoundController()
                controller.licenseStatus = { .trial(daysLeft: 5) }
                let allowsRetry = try #require(controller.aiSession?.allowsNetworkRetry)
                #expect(!allowsRetry(), "the on-device model is preferred")

                UserDefaults.standard.set(false, forKey: "berry.ai.onDevice")
                #expect(allowsRetry(), "a licensed cloud route")

                controller.enabledForConnection = false
                #expect(!allowsRetry(), "AI is off for the connection")
            }
        }
    }

    // MARK: - The command palette's "Ask AI" passes the same gate as a send

    // A palette query that reaches the network waits on `example.invalid`
    // until the system gives up, so the time limit turns a query that should
    // never have been sent into a failure instead of a stalled run.

    private struct ScriptedOnDeviceModel: LocalCompletionProvider {
        let reply: String
        static func isAvailable() -> Bool { true }
        func complete(prompt: String) async throws -> String { reply }
    }

    @Test(.timeLimit(.minutes(1))) func paletteWithNoConnectionOpensThePanelInsteadOfSending() async throws {
        let controller = try makeController()
        #expect(await controller.routeCommandPaletteQuery("show slow queries") == .gateClosed(.noConnection))
    }

    @Test(.timeLimit(.minutes(1))) func paletteWithoutLicenseOrAccessOpensThePanel() async throws {
        try await withCleanGrant {
            let controller = try await makeBoundController()
            #expect(await controller.routeCommandPaletteQuery("show slow queries") == .gateClosed(.unlicensed))
        }
    }

    @Test(.timeLimit(.minutes(1))) func paletteAsksForConsentLikeThePanel() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let controller = try await makeBoundController(consent: false)
            #expect(await controller.routeCommandPaletteQuery("show slow queries") == .gateClosed(.needsConsent))
        }
    }

    @Test(.timeLimit(.minutes(1))) func paletteRespectsAIBeingOffForTheConnection() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            let controller = try await makeBoundController()
            controller.enabledForConnection = false
            #expect(await controller.routeCommandPaletteQuery("show slow queries") == .gateClosed(.disabledForConnection))
        }
    }

    @Test(.timeLimit(.minutes(1))) func paletteUsesTheOnDeviceModelWhenItIsPreferred() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            try await withOnDeviceToggle(true) {
                let controller = try await makeBoundController()
                controller.makeOnDeviceProvider = { ScriptedOnDeviceModel(reply: "Nothing to open for that.") }
                #expect(await controller.routeCommandPaletteQuery("show slow queries") == .reply("Nothing to open for that."))
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func paletteWithOnDeviceOffAndNoLicenseSendsNothing() async throws {
        try await withCleanGrant {
            AppleIntelligenceAccess.grant(email: "dev@example.com")
            try await withOnDeviceToggle(false) {
                let license = makeLicense()
                let controller = try await makeBoundController(license: license)
                let outcome = await controller.routeCommandPaletteQuery("show slow queries")
                #expect(outcome == .reply(L("On-device AI is off, and there's no trial or license for cloud AI. Turn on-device back on in AI settings, or add a trial, license, or credit in License settings.")))
                #expect(license.lastError == nil, "no trial request may have been attempted")
            }
        }
    }
}
