import BerryDriverKit
import BerryDriverRedis
import BerryDriverSQLite
import BerryDriverTestKit
import BerryKeyValueKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// End-to-end at the `WorkspaceViewModel` level: connect → write → scan →
/// get → delete. Headless, mirrors
/// `WorkspaceMongoDataSourceTests`'s pattern for the Mongo/Qdrant side. Runs
/// against a real local Redis/Valkey server from `BERRYDB_TEST_REDIS`,
/// skipped cleanly when unset.
///
/// `RedisDriver`/`RedisConnection` require macOS 15+
/// — every test guards with `if #available` rather than annotating the
/// suite/test itself, since Swift Testing's macros reject combining `@Suite`/
/// `@Test` with `@available` directly (same constraint hit in
/// `RedisConformanceTests`).
private func tempStorePath() -> String {
    NSTemporaryDirectory() + "berry-kv-store-\(UUID().uuidString).sqlite"
}

@MainActor
// `.serialized`: both tests below call `KeyValueRegistry.register(RedisDriver.self)`,
// and the second also calls `DriverRegistry.register(SQLiteDriver.self)` —
// same shared-registry race this project already guards against elsewhere
// (see `WorkspaceGraphTests`'s matching trait).
@Suite("Workspace Redis key-value", .enabled(if: RedisTestServer.redis != nil), .serialized)
struct WorkspaceKeyValueTests {
    private var server: RedisTestServer { RedisTestServer.redis! }

    @Test func connectWriteScanGetDeleteRoundTrip() async throws {
        guard #available(macOS 15, *) else { return }
        KeyValueRegistry.register(RedisDriver.self)

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "redis", name: "test-redis",
            host: server.host, port: server.port,
 // The test container has no TLS listener
 // — ConnectionConfig's default (.prefer) would otherwise try
            // a TLS handshake and fail, same reasoning as RedisConformanceTests.
            tlsMode: TLSMode.disable.rawValue
        )

        await vm.connectKeyValue(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.keyValueSession)
        #expect(session.driverDisplayName == "Redis")

        let key = "berry_ui_conf_\(UUID().uuidString.prefix(8))"
        let writeError = await vm.writeKeyValue(.set(key: key, value: "hello", ttl: nil))
        #expect(writeError == nil)

        var found = false
        var cursor: String?
        repeat {
            let page = try await vm.scanKeys(pattern: "\(key)*", cursor: cursor)
            if page.entries.contains(where: { $0.key == key && $0.type == .string }) { found = true }
            cursor = page.nextCursor
        } while cursor != nil
        #expect(found)

        let value = try await vm.getKeyValue(key)
        #expect(value == .string("hello"))

        let deleteError = await vm.writeKeyValue(.delete(key: key))
        #expect(deleteError == nil)
        let afterDelete = try await vm.getKeyValue(key)
        #expect(afterDelete == .none)

        vm.disconnect()
        #expect(vm.keyValueSession == nil)
    }

    /// `KeyValueSession.database` must reflect the DB actually selected at
    /// connect time (not always 0), and `selectKeyValueDatabase` must switch
    /// the connection's live database — a key written on one DB must not be
    /// visible after switching to another, and must reappear after switching
 /// back (live switcher).
    @Test func sessionTracksConnectDatabaseAndSelectKeyValueDatabaseSwitchesLive() async throws {
        guard #available(macOS 15, *) else { return }
        KeyValueRegistry.register(RedisDriver.self)

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let profile = ConnectionProfile(
            driverID: "redis", name: "test-redis-db-switch",
            host: server.host, port: server.port,
            database: "3",
            tlsMode: TLSMode.disable.rawValue
        )

        await vm.connectKeyValue(profile: profile)
        #expect(vm.errorMessage == nil)
        let session = try #require(vm.keyValueSession)
        #expect(session.database == 3)

        let key = "berry_ui_db_switch_\(UUID().uuidString.prefix(8))"
        let writeError = await vm.writeKeyValue(.set(key: key, value: "on-db-3", ttl: nil))
        #expect(writeError == nil)

        let switchError = await vm.selectKeyValueDatabase(4)
        #expect(switchError == nil)
        let onOtherDB = try await vm.scanKeys(pattern: "\(key)*", cursor: nil)
        #expect(!onOtherDB.entries.contains(where: { $0.key == key }), "switching DB must change the live key space")

        let switchBackError = await vm.selectKeyValueDatabase(3)
        #expect(switchBackError == nil)
        let backOnOriginalDB = try await vm.scanKeys(pattern: "\(key)*", cursor: nil)
        #expect(backOnOriginalDB.entries.contains(where: { $0.key == key }))

        let deleteError = await vm.writeKeyValue(.delete(key: key))
        #expect(deleteError == nil)
        vm.disconnect()
    }

    @Test func connectingToRedisTearsDownAnExistingSQLSession() async throws {
        guard #available(macOS 15, *) else { return }
        KeyValueRegistry.register(RedisDriver.self)
        DriverRegistry.register(SQLiteDriver.self)

        let vm = try WorkspaceViewModel(storePath: tempStorePath())
        let sqliteFilePath = tempStorePath()
        FileManager.default.createFile(atPath: sqliteFilePath, contents: nil)
        await vm.openSQLiteFile(at: URL(fileURLWithPath: sqliteFilePath))
        #expect(vm.errorMessage == nil, "precondition: SQLite file open must succeed")
        #expect(vm.session != nil, "precondition: a SQL session must be active before connecting to Redis")

        let profile = ConnectionProfile(
            driverID: "redis", name: "test-redis-xor",
            host: server.host, port: server.port,
            tlsMode: TLSMode.disable.rawValue
        )
        await vm.connectKeyValue(profile: profile)
        #expect(vm.errorMessage == nil)
 #expect(vm.session == nil, "SQL XOR NoSQL XOR key-value")
        #expect(vm.keyValueSession != nil)
    }
}
