import Foundation
import Synchronization
import Testing

@testable import BerryCredentials
@testable import BerryMCP

private final class KeyBox: Sendable {
    private let lock = Mutex<Data?>(nil)
    private let readCount = Mutex(0)
    var data: Data? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
    var reads: Int { readCount.withLock { $0 } }
    var store: MCPAuditKeyStore {
        MCPAuditKeyStore(
            read: { [self] in
                readCount.withLock { $0 += 1 }
                return data
            },
            write: { _ in false })
    }
}

private final class Messages: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

@Suite struct MCPAuditDigesterTests {
    static let pinned = "802e6de50cda3d2fa5eedf68b713e62e"
    static let key = Data(repeating: 0x42, count: 32)

    @Test func digestsThroughTheStoredKey() {
        let box = KeyBox(); box.data = Self.key
        let digester = MCPAuditDigester(keyStore: box.store, diagnostics: { _ in })
        #expect(digester.digest(.sql("select 1")) == Self.pinned)
    }

    @Test func withoutAKeyRecordsCarryNoDigestAndWarnOnce() {
        let messages = Messages()
        let digester = MCPAuditDigester(keyStore: KeyBox().store, diagnostics: messages.add)
        #expect(digester.digest(.sql("select 1")) == nil)
        #expect(digester.digest(.sql("select 1")) == nil)
        #expect(messages.all == ["audit digest key unavailable: records carry no digest"])
    }

    @Test func concurrentFirstCallsWarnOnce() {
        let messages = Messages()
        let digester = MCPAuditDigester(keyStore: KeyBox().store, diagnostics: messages.add)
        let results = Mutex<[String?]>([])
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let digest = digester.digest(.sql("select 1"))
            results.withLock { $0.append(digest) }
        }
        #expect(results.withLock { $0 }.count == 32)
        #expect(results.withLock { $0 }.allSatisfy { $0 == nil })
        #expect(messages.all == ["audit digest key unavailable: records carry no digest"])
    }

    @Test func digesterPicksUpAKeyCreatedLater() {
        let box = KeyBox()
        let digester = MCPAuditDigester(keyStore: box.store, diagnostics: { _ in })
        #expect(digester.digest(.sql("select 1")) == nil)
        box.data = Self.key
        #expect(digester.digest(.sql("select 1")) == Self.pinned)
    }

    @Test func aNilQueryNeverReadsTheKey() {
        let box = KeyBox(); box.data = Self.key
        let digester = MCPAuditDigester(keyStore: box.store, diagnostics: { _ in })
        #expect(digester.digest(nil) == nil)
        #expect(box.reads == 0)
    }
}
