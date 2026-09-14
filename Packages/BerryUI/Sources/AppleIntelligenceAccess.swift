import Foundation

/// a Mac with Apple Intelligence available can use on-device AI
/// without a paid trial/license — it costs BerryDB nothing to serve. Purely
/// local: no network call, no server-issued trial consumed. The email is
/// captured only as the same commitment step the real trial flow asks for;
/// it never leaves this machine.
///
/// A UI-facing flag, not an entitlement — see
/// `AIPanelController.appleIntelligenceGranted` for the actual gate.
enum AppleIntelligenceAccess {
    private static let emailKey = "berry.ai.appleIntelligenceEmail"

    static var grantedEmail: String? {
        UserDefaults.standard.string(forKey: emailKey)
    }

    static var isGranted: Bool { grantedEmail != nil }

    static func grant(email: String) {
        UserDefaults.standard.set(email, forKey: emailKey)
        // The only thing this access grants is on-device — default the
        // toggle on so it isn't immediately inert.
        UserDefaults.standard.set(true, forKey: "berry.ai.onDevice")
    }

    static func revoke() {
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
