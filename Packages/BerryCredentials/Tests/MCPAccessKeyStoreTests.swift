import CryptoKit
import Foundation
import Testing

@testable import BerryCredentials

@Suite("MCP access key store")
struct MCPAccessKeyStoreTests {
    final class Box: @unchecked Sendable {
        var data: Data?
        var writeCalled = false
    }

    private struct InjectedReadFailure: Error {}

    @Test func createsOnceThenReturnsTheSameKey() throws {
        let box = Box()
        let store = MCPAccessKeyStore(
            read: { box.data },
            write: { data in
                box.data = data
                return true
            }
        )
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) })
        #expect(box.data?.count == 32)
    }

    @Test func helperLoadNeverCreates() {
        let box = Box()
        let store = MCPAccessKeyStore(
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
        let store = MCPAccessKeyStore(
            read: { Data(repeating: 1, count: 16) },
            write: { _ in true }
        )
        #expect(store.load() == nil)
        #expect(throws: MCPAccessKeyStore.KeyError.invalidStoredKey) { try store.loadOrCreate() }
    }

    @Test func serviceNameIsPinned() {
        #expect(MCPAccessKeyStore.service == "dev.berrydb.mcp.access-key")
    }

    @Test func accountIsPinned() {
        #expect(MCPAccessKeyStore.account == "berrydb.mcp")
    }

    @Test func readFailurePropagatesAndWriteIsNeverCalled() {
        let box = Box()
        let store = MCPAccessKeyStore(
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

    @Test func replaceStoresTheKeyAndLoadReturnsIt() throws {
        let box = Box()
        let store = MCPAccessKeyStore(
            read: { box.data },
            write: { data in
                box.data = data
                return true
            }
        )
        let newKey = SymmetricKey(size: .bits256)
        try store.replace(with: newKey)
        let loaded = try #require(store.load())
        #expect(loaded.withUnsafeBytes { Data($0) } == newKey.withUnsafeBytes { Data($0) })
    }

    @Test func loadForRotationReturnsTheKeyWhenPresentAndWellFormed() throws {
        let box = Box()
        box.data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let store = MCPAccessKeyStore(read: { box.data }, write: { _ in true })
        let key = try store.loadForRotation()
        #expect(key?.withUnsafeBytes { Data($0) } == box.data)
    }

    @Test func loadForRotationReturnsNilWhenNotFound() throws {
        let store = MCPAccessKeyStore(read: { nil }, write: { _ in true })
        #expect(try store.loadForRotation() == nil)
    }

    @Test func loadForRotationThrowsInvalidStoredKeyForWrongLength() {
        let store = MCPAccessKeyStore(read: { Data(repeating: 1, count: 16) }, write: { _ in true })
        #expect(throws: MCPAccessKeyStore.KeyError.invalidStoredKey) { try store.loadForRotation() }
    }

    @Test func loadForRotationPropagatesAReadFailureInsteadOfTreatingItAsNoKey() {
        let store = MCPAccessKeyStore(read: { throw InjectedReadFailure() }, write: { _ in true })
        #expect(throws: InjectedReadFailure.self) { try store.loadForRotation() }
    }
}
