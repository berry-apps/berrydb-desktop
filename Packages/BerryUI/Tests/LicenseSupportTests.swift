import Foundation
import Testing

@testable import BerryUI

/// `licenseErrorMessage(_:)` maps stable backend error codes to a localized,
/// user-facing string (client renders by code,
/// never the raw backend message). An unmapped code falls back to showing
/// itself verbatim, which is how a user restoring a purchase by email ended
/// up seeing the raw "key_sent"/"no_subscription" codes instead of a
/// readable message.
@Suite("licenseErrorMessage")
struct LicenseSupportTests {
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

    /// Restoring by email answers `key_sent` whatever the address, so that
    /// nobody can learn from it whether an email bought a license, and the
    /// mail can still fail to go out. The message must claim neither.
    private static let keySent = "If a license exists for this email, we've sent its key there. Check your inbox and spam folder."
    /// The server cannot send mail at all.
    private static let restoreUnavailable = "We can't email license keys right now. Contact support at info@berryhub.app."
    private static let rateLimited = "Too many attempts. Try again later."

    @Test func keySentClaimsNeitherALicenseNorADelivery() {
        #expect(licenseErrorMessage("key_sent") == L(String.LocalizationValue(Self.keySent)))
    }

    @Test func restoreUnavailableSaysMailCannotBeSentAndWhoToContact() {
        #expect(licenseErrorMessage("restore_unavailable") == L(String.LocalizationValue(Self.restoreUnavailable)))
    }

    @Test func rateLimitedSaysToTryAgainLater() {
        #expect(licenseErrorMessage("rate_limited") == L(String.LocalizationValue(Self.rateLimited)))
    }

    @Test func restoreMessagesAreTranslatedForEveryShippedLanguage() throws {
        for key in [Self.keySent, Self.restoreUnavailable, Self.rateLimited] {
            #expect(localized(key, in: "en") == key)
            let vietnamese = try #require(localized(key, in: "vi"), "vi.lproj has no entry for \(key)")
            #expect(vietnamese != key)
        }
    }

    @Test func mapsNoSubscriptionToAReadableMessage() {
        #expect(licenseErrorMessage("no_subscription").localizedCaseInsensitiveContains("no subscription"))
    }

    @Test func unmappedCodeFallsBackToTheRawCode() {
        #expect(licenseErrorMessage("some_future_code") == "some_future_code")
    }

    @Test func mapsTransportAndBadResponseToAReadableMessage() {
        #expect(licenseErrorMessage("transport").localizedCaseInsensitiveContains("could not reach"))
        #expect(licenseErrorMessage("badResponse").localizedCaseInsensitiveContains("could not reach"))
    }

 /// the backend rejects a second email's trial on an
    /// already-claimed device with `trial_already_used` — without a mapping
    /// here the user would see that raw code instead of an explanation.
    @Test func mapsTrialAlreadyUsedToAReadableMessage() {
        #expect(licenseErrorMessage("trial_already_used").localizedCaseInsensitiveContains("already used its free trial"))
    }

    /// Reported: a badSignature verify failure showed as Swift's generic
    /// NSError bridging text ("The operation couldn't be completed.
    /// (BerryLicense.LicenseVerifyError error 2.)") — unreadable, and not a
    /// code this switch recognized, so it fell through to the raw-passthrough
    /// default. LicenseManager now maps LicenseVerifyError to these stable
    /// codes before it ever reaches here (same convention as APIError.code).
    @Test func mapsLicenseVerifyBadSignatureToAReadableMessage() {
        #expect(licenseErrorMessage("license_verify_bad_signature").localizedCaseInsensitiveContains("key this app doesn't recognize"))
    }

    @Test func mapsLicenseVerifyMalformedBadBase64AndBadPayloadToTheSameReadableMessage() {
        for code in ["license_verify_malformed", "license_verify_bad_base64", "license_verify_bad_payload"] {
            #expect(licenseErrorMessage(code).localizedCaseInsensitiveContains("could not be read"))
        }
    }
}
