import CryptoKit
import Foundation
import Testing

@testable import BerryCredentials

@Suite("MCP access key store")
struct MCPAccessKeyStoreTests {
    final class Box: @unchecked Sendable { var data: Data? }

    @Test func createsOnceThenReturnsTheSameKey() throws {
        let box = Box()
        let store = MCPAccessKeyStore(read: { box.data }, write: { box.data = $0; return true })
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) })
        #expect(box.data?.count == 32)
    }

    @Test func helperLoadNeverCreates() {
        let box = Box()
        let store = MCPAccessKeyStore(read: { box.data }, write: { box.data = $0; return true })
        #expect(store.load() == nil)
        #expect(box.data == nil)
    }

    @Test func wrongLengthStoredValueIsRejected() {
        let store = MCPAccessKeyStore(read: { Data(repeating: 1, count: 16) }, write: { _ in true })
        #expect(store.load() == nil)
        #expect(throws: MCPAccessKeyStore.KeyError.invalidStoredKey) { try store.loadOrCreate() }
    }

    @Test func serviceNameIsPinned() {
        #expect(MCPAccessKeyStore.service == "dev.berrydb.mcp.access-key")
    }
}
