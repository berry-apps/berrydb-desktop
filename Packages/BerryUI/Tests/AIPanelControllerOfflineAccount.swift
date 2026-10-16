@testable import BerryUI

extension AIPanelController {
    /// Replaces the API token and balance sources, so a test that binds the
    /// panel reads no item from the login Keychain and sends no request to
    /// the AI service. The token is a fixed string rather than nil, so `bind`
    /// still builds the AI session the way it does on a licensed Mac.
    func useOfflineAccount() {
        apiToken = { "test-token" }
        fetchBalance = { _, _ in nil }
    }
}
