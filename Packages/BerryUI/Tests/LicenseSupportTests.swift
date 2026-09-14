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
    @Test func mapsKeySentToAReadableInstruction() {
        #expect(licenseErrorMessage("key_sent").localizedCaseInsensitiveContains("purchase email"))
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
