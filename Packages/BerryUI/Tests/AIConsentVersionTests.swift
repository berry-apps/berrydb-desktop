import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// An acceptance of the consent screen covers the text it was given for.
/// When that text changes in a way users must see, connections that accepted
/// an older text show the screen again.
@MainActor
@Suite("AI consent version")
struct AIConsentVersionTests {
    private final class SavedSettings {
        var value: AIPanelController.AIConnectionSettings?
    }

    private static let accepted = AIPanelController.AIConnectionSettings(
        enabled: true, allowSampleRows: false, autoApproveSelects: true, consentGiven: true
    )

    private func makeSQLiteSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-ai-consent-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        return try await ConnectionManager().open(.sqlite(path: path))
    }

    /// A licensed controller bound to `profileID`, whose stored settings are
    /// `saved` and whose saves land in `saves`.
    private func makeController(
        profileID: UUID, saved: AIPanelController.AIConnectionSettings?, saves: SavedSettings = SavedSettings()
    ) async throws -> AIPanelController {
        let controller = AIPanelController(
            license: LicenseManager(client: LicenseClient(baseURL: URL(string: "https://example.invalid")!)),
            backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
        controller.licenseStatus = { .trial(daysLeft: 5) }
        controller.useOfflineAccount()
        controller.loadSettings = { _ in saved }
        controller.saveSettings = { _, settings in saves.value = settings }
        controller.bind(session: try await makeSQLiteSession(), catalog: nil, objects: [], profileID: profileID)
        return controller
    }

    /// Runs `body` with a fresh profile id and removes its consent version
    /// from the defaults afterwards.
    private func withProfile(_ body: (UUID) async throws -> Void) async rethrows {
        let profileID = UUID()
        defer { UserDefaults.standard.removeObject(forKey: AIPanelController.consentVersionKey(profileID)) }
        try await body(profileID)
    }

    @Test func anAcceptanceWithNoRecordedVersionAsksAgain() async throws {
        try await withProfile { profileID in
            let controller = try await makeController(profileID: profileID, saved: Self.accepted)
            #expect(controller.availability == .needsConsent)
        }
    }

    @Test func anAcceptanceOfAnOlderVersionAsksAgain() async throws {
        try await withProfile { profileID in
            UserDefaults.standard.set(AIPanelController.consentVersion - 1, forKey: AIPanelController.consentVersionKey(profileID))
            let controller = try await makeController(profileID: profileID, saved: Self.accepted)
            #expect(controller.availability == .needsConsent)
        }
    }

    @Test func anAcceptanceOfTheCurrentVersionIsKept() async throws {
        try await withProfile { profileID in
            UserDefaults.standard.set(AIPanelController.consentVersion, forKey: AIPanelController.consentVersionKey(profileID))
            let controller = try await makeController(profileID: profileID, saved: Self.accepted)
            #expect(controller.availability == .ready)
        }
    }

    @Test func acceptingAgainRecordsTheCurrentVersion() async throws {
        try await withProfile { profileID in
            let saves = SavedSettings()
            let controller = try await makeController(profileID: profileID, saved: Self.accepted, saves: saves)
            #expect(controller.availability == .needsConsent)

            controller.giveConsentAndEnable()

            #expect(controller.availability == .ready)
            #expect(saves.value?.consentGiven == true)
            #expect(UserDefaults.standard.integer(forKey: AIPanelController.consentVersionKey(profileID)) == AIPanelController.consentVersion)
            let reopened = try await makeController(profileID: profileID, saved: saves.value)
            #expect(reopened.availability == .ready)
        }
    }
}
