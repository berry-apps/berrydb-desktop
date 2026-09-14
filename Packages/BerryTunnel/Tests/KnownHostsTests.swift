import Foundation
import Testing

@testable import BerryTunnel

/// A fresh, isolated known-hosts store — used by the conformance tests too so a
/// container regenerating its host key between runs never trips the pin.
func makeIsolatedKnownHosts() -> KnownHostsStore {
    KnownHostsStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory() + "berry-kh-\(UUID().uuidString)"))
}

@Suite("KnownHostsStore TOFU")
struct KnownHostsTests {
    @Test func firstUseRecordsAndAccepts() {
        let store = makeIsolatedKnownHosts()
        #expect(store.evaluate(host: "bastion", port: 22, fingerprint: "SHA256:aaa") == .recordedFirstUse)
        #expect(store.storedFingerprint(host: "bastion", port: 22) == "SHA256:aaa")
    }

    @Test func sameKeyIsTrusted() {
        let store = makeIsolatedKnownHosts()
        _ = store.evaluate(host: "h", port: 22, fingerprint: "SHA256:aaa")
        #expect(store.evaluate(host: "h", port: 22, fingerprint: "SHA256:aaa") == .trusted)
    }

    @Test func changedKeyIsRejectedAndNotOverwritten() {
        let store = makeIsolatedKnownHosts()
        _ = store.evaluate(host: "h", port: 22, fingerprint: "SHA256:original")
        #expect(store.evaluate(host: "h", port: 22, fingerprint: "SHA256:evil")
            == .mismatch(stored: "SHA256:original"))
        // The trusted key must NOT be replaced by the rejected one.
        #expect(store.storedFingerprint(host: "h", port: 22) == "SHA256:original")
    }

    @Test func trustOverwritesChangedKey() {
        let store = makeIsolatedKnownHosts()
        _ = store.evaluate(host: "h", port: 22, fingerprint: "SHA256:original")
        store.trust(host: "h", port: 22, fingerprint: "SHA256:new")
        #expect(store.evaluate(host: "h", port: 22, fingerprint: "SHA256:new") == .trusted)
    }

    @Test func persistsAcrossInstances() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "berry-kh-\(UUID().uuidString)")
        _ = KnownHostsStore(fileURL: url).evaluate(host: "h", port: 2222, fingerprint: "SHA256:zzz")
        // A fresh store over the same file sees the recorded key.
        #expect(KnownHostsStore(fileURL: url).evaluate(host: "h", port: 2222, fingerprint: "SHA256:zzz")
            == .trusted)
    }

    @Test func differentPortsAreIndependent() {
        let store = makeIsolatedKnownHosts()
        _ = store.evaluate(host: "h", port: 22, fingerprint: "SHA256:a")
        #expect(store.evaluate(host: "h", port: 2222, fingerprint: "SHA256:b") == .recordedFirstUse)
    }
}
