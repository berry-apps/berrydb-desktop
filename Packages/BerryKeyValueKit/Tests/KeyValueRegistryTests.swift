import BerryDriverKit
import Foundation
import Testing

@testable import BerryKeyValueKit

private struct FakeKeyValueDriver: KeyValueDriver {
    static let id: DriverID = .redis
    static let displayName = "Fake"
    static let capabilities = KeyValueCapabilities()
    init() {}
    func connect(_ config: ConnectionConfig) async throws -> any KeyValueConnection {
        fatalError("not exercised by these tests")
    }
}

@Suite("KeyValueRegistry")
struct KeyValueRegistryTests {
    @Test func registeredDriverIsFindableByID() {
        KeyValueRegistry.register(FakeKeyValueDriver.self)
        #expect(KeyValueRegistry.registered.contains(.redis))
        #expect(KeyValueRegistry.driverType(for: .redis) is FakeKeyValueDriver.Type)
    }

    @Test func unregisteredDriverReturnsNil() {
        #expect(KeyValueRegistry.driverType(for: .mongodb) == nil)
    }
}
