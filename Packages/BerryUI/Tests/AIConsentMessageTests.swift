@testable import BerryAI
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// The consent screen is the one place that tells a user what the assistant
/// does with their database before AI is turned on, so its wording has to
/// match the defaults the executor actually runs with. Main-actor isolated
/// because the message is a static of a SwiftUI view.
@MainActor
@Suite("AI consent message")
struct AIConsentMessageTests {
    /// The text for `key` in one localization of the BerryUI resource bundle,
    /// or nil when that localization has no entry for it.
    private func localized(_ key: String, in language: String) -> String? {
        guard let path = berryModuleBundle.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else { return nil }
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    @Test func saysReadOnlyQueriesRunWithoutAskingWhileThatIsTheDefault() throws {
        let message = AIPanelView.consentMessage
        let controller = AIPanelController(
            license: LicenseManager(client: LicenseClient(baseURL: URL(string: "https://example.invalid")!)),
            backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
        #expect(controller.autoApproveSelects, "the default a connection without saved settings gets")
        #expect(QueryToolExecutor.Options().autoApproveSelects)
        #expect(message.contains("without asking"))
        #expect(message.contains("Auto-run safe SELECTs"), "names the switch that turns it off")
    }

    @Test func saysHowManyResultRowsTheAssistantSees() {
        #expect(AIPanelView.consentMessage.contains("up to \(QueryToolExecutor.sampleLimit) rows"))
    }

    /// Whether a statement needs approval rests on a read-only check of its
    /// text, so the screen promises approval only for what that check does
    /// not pass, not for every other statement.
    @Test func promisesApprovalOnlyForWhatTheReadOnlyCheckDoesNotPass() {
        #expect(!AIPanelView.consentMessage.contains("always need"))
        #expect(AIPanelView.consentMessage.contains("can't tell are read-only"))
    }

    @Test func noLongerClaimsRowDataStaysLocal() {
        #expect(!AIPanelView.consentMessage.contains("never sent"))
        #expect(!AIPanelView.consentMessage.contains("only after you approve"))
    }

    @Test func isTranslatedForEveryShippedLanguage() throws {
        let key = AIPanelView.consentMessage
        #expect(localized(key, in: "en") == key)
        let vietnamese = try #require(localized(key, in: "vi"), "vi.lproj has no entry for the consent message")
        #expect(vietnamese != key)
        #expect(vietnamese.contains("100"))
    }
}
