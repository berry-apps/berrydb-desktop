import CryptoKit
import Foundation
import Testing

@testable import BerryCredentials

@Suite("MCP audit key store")
struct MCPAuditKeyStoreTests {
    final class Box: @unchecked Sendable {
        var data: Data?
        var writeCalled = false
        var writeCount = 0
    }

    private struct InjectedReadFailure: Error {}

    @Test func createsOnceThenReturnsTheSameKey() throws {
        let box = Box()
        let store = MCPAuditKeyStore(
            read: { box.data },
            write: { data in
                box.data = data
                box.writeCount += 1
                return true
            }
        )
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) })
        #expect(box.data?.count == 32)
        #expect(box.writeCount == 1)
    }

    @Test func helperLoadNeverCreates() {
        let box = Box()
        let store = MCPAuditKeyStore(
            read: { box.data },
            write: { data in
                box.data = data
                return true
            }
        )
        #expect(store.load() == nil)
        #expect(box.data == nil)
    }

    @Test func wrongLengthStoredValueIsRejected() {
        let box = Box()
        let store = MCPAuditKeyStore(
            read: { Data(repeating: 1, count: 16) },
            write: { _ in
                box.writeCalled = true
                return true
            }
        )
        #expect(store.load() == nil)
        #expect(throws: MCPAuditKeyStore.KeyError.invalidStoredKey) { try store.loadOrCreate() }
        #expect(!box.writeCalled)
    }

    @Test func serviceNameIsPinned() {
        #expect(MCPAuditKeyStore.service == "dev.berrydb.mcp.audit-key")
    }

    @Test func accountIsPinned() {
        #expect(MCPAuditKeyStore.account == "berrydb.mcp")
    }

    @Test func readFailurePropagatesAndWriteIsNeverCalled() {
        let box = Box()
        let store = MCPAuditKeyStore(
            read: { throw InjectedReadFailure() },
            write: { data in
                box.data = data
                box.writeCalled = true
                return true
            }
        )
        #expect(throws: InjectedReadFailure.self) { try store.loadOrCreate() }
        #expect(!box.writeCalled)
    }

    @Test func writeFailureThrowsKeychainWriteFailed() {
        let store = MCPAuditKeyStore(read: { nil }, write: { _ in false })
        #expect(throws: MCPAuditKeyStore.KeyError.keychainWriteFailed) { try store.loadOrCreate() }
    }
}
