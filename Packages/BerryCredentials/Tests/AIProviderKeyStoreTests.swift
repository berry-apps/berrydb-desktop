import Foundation
import Testing

@testable import BerryCredentials

@Suite("AI provider key store")
struct AIProviderKeyStoreTests {
    final class Box: @unchecked Sendable {
        var values: [String: Data] = [:]
    }

    private func makeStore(_ box: Box, failWrite: Bool = false) -> AIProviderKeyStore {
        AIProviderKeyStore(
            read: { account in box.values[account] },
            write: { account, data in
                if failWrite { return false }
                box.values[account] = data
                return true
            },
            delete: { account in
                box.values.removeValue(forKey: account) != nil
            }
        )
    }

    @Test func savesAndReadsBackTheKey() throws {
        let box = Box()
        let store = makeStore(box)
        let id = UUID()
        try store.save("sk-test-123", providerID: id)
        #expect(try store.read(providerID: id) == "sk-test-123")
        #expect(Array(box.values.keys) == [id.uuidString.lowercased()])
    }

    @Test func missingKeyReadsAsNil() throws {
        let store = makeStore(Box())
        #expect(try store.read(providerID: UUID()) == nil)
    }

    @Test func writeFailureThrowsAndLeavesPreviousKeyUntouched() {
        let box = Box()
        box.values["existing"] = Data("old".utf8)
        let store = makeStore(box, failWrite: true)
        #expect(throws: AIProviderKeyStore.KeyError.keychainWriteFailed) {
            try store.save("new", providerID: UUID())
        }
        #expect(box.values["existing"] == Data("old".utf8))
    }

    @Test func deleteRemovesOnlyThatProvider() throws {
        let box = Box()
        let store = makeStore(box)
        let a = UUID()
        let b = UUID()
        try store.save("a", providerID: a)
        try store.save("b", providerID: b)

        store.delete(providerID: a)
        #expect(try store.read(providerID: a) == nil)
        #expect(try store.read(providerID: b) == "b")
    }

    @Test func readFailureIsNotMistakenForAbsence() {
        struct ReadFailure: Error {}
        let store = AIProviderKeyStore(
            read: { _ in throw ReadFailure() },
            write: { _, _ in true },
            delete: { _ in true }
        )
        do {
            _ = try store.read(providerID: UUID())
            Issue.record("expected the read to throw, not return nil")
        } catch is ReadFailure {
            // Expected — a Keychain refusal must propagate, never read as "no key".
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
