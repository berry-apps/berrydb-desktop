import BerryDriverKit
import BerryDriverTestKit
import BerryKeyValueKit
import Foundation
import Testing

@testable import BerryDriverRedis

/// Runs against a real Redis/Valkey from `BERRYDB_TEST_REDIS`
/// (see Tests/docker/compose.yml); skipped when the env var is unset.
///
/// `RedisConnection` requires macOS 15+, but
/// Swift Testing's `@Suite`/`@Test` macros reject being combined directly
/// with `@available` — so this suite (and every test in it) stays
/// unannotated, and each test guards its macOS-15-only body with
/// `if #available` instead. In practice this suite only ever runs where
/// `BERRYDB_TEST_REDIS` is set, i.e. a real dev/CI machine already on 15+.
@Suite("Redis driver conformance", .enabled(if: RedisTestServer.redis != nil))
struct RedisConformanceTests {
    @available(macOS 15, *)
    private func makeConnection() async throws -> RedisConnection {
        let server = RedisTestServer.redis!
        return try await RedisConnection(config: ConnectionConfig(
            driver: .redis,
            name: "test",
            host: server.host,
            port: server.port,
            // The conformance container has no TLS listener — ConnectionConfig's
            // default (.prefer) would otherwise try a TLS handshake and fail,
            // since Redis's wire protocol has no Postgres-style "try TLS, fall
            // back to plaintext" byte (same limitation already documented for
 // Mongo, point 1).
            tlsMode: .disable
        ))
    }

    @Test func pingSucceeds() async throws {
        guard #available(macOS 15, *) else { return }
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        #expect(await conn.ping())
    }

    @Test func stringSetGetDeleteRoundTrip() async throws {
        guard #available(macOS 15, *) else { return }
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let key = "berry:conformance:string:\(UUID().uuidString)"

        try await conn.write(.set(key: key, value: "xin chào", ttl: nil))
        let value = try await conn.get(key)
        #expect(value == .string("xin chào"))

        try await conn.write(.delete(key: key))
        let afterDelete = try await conn.get(key)
        #expect(afterDelete == .none)
    }

    @Test func expireSetsATTLThatTtlReportsBack() async throws {
        guard #available(macOS 15, *) else { return }
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let key = "berry:conformance:ttl:\(UUID().uuidString)"

        try await conn.write(.set(key: key, value: "v", ttl: nil))
        #expect(try await conn.ttl(key) == nil, "a key with no TTL must report nil")

        try await conn.write(.expire(key: key, ttl: 120))
        let ttl = try await conn.ttl(key)
        #expect(ttl != nil && ttl! > 0 && ttl! <= 120)

        try await conn.write(.delete(key: key))
    }

    @Test func scanFindsAKeyByPatternAndPaginatesToCompletion() async throws {
        guard #available(macOS 15, *) else { return }
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let unique = UUID().uuidString
        let key = "berry:conformance:scan:\(unique)"
        try await conn.write(.set(key: key, value: "v", ttl: nil))

        var found = false
        var cursor: String?
        repeat {
            let page = try await conn.scan(pattern: "berry:conformance:scan:\(unique)*", cursor: cursor)
            if page.entries.contains(where: { $0.key == key && $0.type == .string }) {
                found = true
            }
            cursor = page.nextCursor
        } while cursor != nil

        #expect(found, "SCAN must eventually surface the key, and pagination must terminate (nextCursor becomes nil)")
        try await conn.write(.delete(key: key))
    }

    /// Every non-string type get() must decode — the riskiest, least-obvious
    /// part of the driver (ZRANGE WITHSCORES pair-splitting especially).
    /// Values are seeded directly with `redis-cli` rather than through this
    /// driver (which has no per-type write path yet, v1 scope: string
 /// SET/DEL/EXPIRE only) — a real server's own
    /// commands populate the fixtures, this test only exercises reads.
    @Test func getDecodesEveryNonStringType() async throws {
        guard #available(macOS 15, *) else { return }
        let server = try #require(RedisTestServer.redis)
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let suffix = UUID().uuidString

        func redisCLI(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["redis-cli", "-h", server.host, "-p", String(server.port)] + args
            try process.run()
            process.waitUntilExit()
        }

        let hashKey = "berry:conformance:hash:\(suffix)"
        let listKey = "berry:conformance:list:\(suffix)"
        let setKey = "berry:conformance:set:\(suffix)"
        let zsetKey = "berry:conformance:zset:\(suffix)"
        let streamKey = "berry:conformance:stream:\(suffix)"

        try redisCLI("HSET", hashKey, "field1", "value1", "field2", "value2")
        try redisCLI("RPUSH", listKey, "a", "b", "c")
        try redisCLI("SADD", setKey, "x", "y", "z")
        try redisCLI("ZADD", zsetKey, "1", "one", "2", "two")
        try redisCLI("XADD", streamKey, "*", "field", "streamvalue")

        defer {
            Task {
                for key in [hashKey, listKey, setKey, zsetKey, streamKey] {
                    try? await conn.write(.delete(key: key))
                }
            }
        }

        guard case .hash(let hash) = try await conn.get(hashKey) else {
            Issue.record("expected .hash"); return
        }
        #expect(hash == ["field1": "value1", "field2": "value2"])

        guard case .list(let list) = try await conn.get(listKey) else {
            Issue.record("expected .list"); return
        }
        #expect(list == ["a", "b", "c"])

        guard case .set(let set) = try await conn.get(setKey) else {
            Issue.record("expected .set"); return
        }
        #expect(Set(set) == Set(["x", "y", "z"]))

        guard case .sortedSet(let members) = try await conn.get(zsetKey) else {
            Issue.record("expected .sortedSet"); return
        }
        #expect(members == [SortedSetMember(member: "one", score: 1), SortedSetMember(member: "two", score: 2)])

        guard case .stream(let entries) = try await conn.get(streamKey) else {
            Issue.record("expected .stream"); return
        }
        #expect(entries.count == 1)
        #expect(entries.first?.fields == ["field": "streamvalue"])
    }

 /// N3: a driver must never buffer a full
    /// result set. Seeds a hash past the driver's 1000-member batch size and
    /// asserts `get()` returns a bounded page, not the full 1500 members —
    /// this is the regression guard for the HGETALL→HSCAN fix; it would fail
    /// (return 1500) against the pre-fix implementation.
    @Test func getBoundsAHashLargerThanOneBatch() async throws {
        guard #available(macOS 15, *) else { return }
        let server = try #require(RedisTestServer.redis)
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let key = "berry:conformance:hash:oversized:\(UUID().uuidString)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["redis-cli", "-h", server.host, "-p", String(server.port), "HSET", key]
        for i in 0..<1500 { args += ["field\(i)", "value\(i)"] }
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        defer { Task { try? await conn.write(.delete(key: key)) } }

        guard case .hash(let hash) = try await conn.get(key) else {
            Issue.record("expected .hash"); return
        }
        #expect(hash.count <= 1000, "get() must not buffer the full 1500-member hash (N3)")
        #expect(!hash.isEmpty)
    }

    /// The old `scan()` looked up each key's TYPE sequentially — up to 200
    /// round trips per page, fully serialized. This doesn't assert timing
    /// (flaky), but does assert correctness survives concurrent dispatch:
    /// every key of a distinct type must still be labeled with its own
    /// correct type, not a neighbor's (the exact bug class a raced/misordered
    /// concurrent implementation would introduce).
    @Test func scanLabelsConcurrentlyFetchedTypesCorrectly() async throws {
        guard #available(macOS 15, *) else { return }
        let server = try #require(RedisTestServer.redis)
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let suffix = UUID().uuidString

        let stringKey = "berry:conformance:concurrent:\(suffix):string"
        let hashKey = "berry:conformance:concurrent:\(suffix):hash"
        let listKey = "berry:conformance:concurrent:\(suffix):list"
        let setKey = "berry:conformance:concurrent:\(suffix):set"
        let zsetKey = "berry:conformance:concurrent:\(suffix):zset"

        try await conn.write(.set(key: stringKey, value: "v", ttl: nil))
        func redisCLI(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["redis-cli", "-h", server.host, "-p", String(server.port)] + args
            try process.run()
            process.waitUntilExit()
        }
        try redisCLI("HSET", hashKey, "f", "v")
        try redisCLI("RPUSH", listKey, "a")
        try redisCLI("SADD", setKey, "a")
        try redisCLI("ZADD", zsetKey, "1", "a")

        defer {
            Task {
                for key in [stringKey, hashKey, listKey, setKey, zsetKey] {
                    try? await conn.write(.delete(key: key))
                }
            }
        }

        var typeByKey: [String: KeyValueType] = [:]
        var cursor: String?
        repeat {
            let page = try await conn.scan(pattern: "berry:conformance:concurrent:\(suffix):*", cursor: cursor)
            for entry in page.entries { typeByKey[entry.key] = entry.type }
            cursor = page.nextCursor
        } while cursor != nil

        #expect(typeByKey[stringKey] == .string)
        #expect(typeByKey[hashKey] == .hash)
        #expect(typeByKey[listKey] == .list)
        #expect(typeByKey[setKey] == .set)
        #expect(typeByKey[zsetKey] == .sortedSet)
    }

    /// Every non-string `write()` case, round-tripped through `get()` —
    /// mirrors `getDecodesEveryNonStringType`'s per-type coverage, but for
    /// the write path this driver had none of until now (v1 was
 /// string SET/DEL/EXPIRE only).
    @Test func writeAddsAndRemovesEveryNonStringType() async throws {
        guard #available(macOS 15, *) else { return }
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        let suffix = UUID().uuidString

        let hashKey = "berry:conformance:write:hash:\(suffix)"
        try await conn.write(.hashFieldSet(key: hashKey, field: "f1", value: "v1"))
        try await conn.write(.hashFieldSet(key: hashKey, field: "f2", value: "v2"))
        guard case .hash(let hashAfterAdd) = try await conn.get(hashKey) else {
            Issue.record("expected .hash"); return
        }
        #expect(hashAfterAdd == ["f1": "v1", "f2": "v2"])
        try await conn.write(.hashFieldDelete(key: hashKey, field: "f1"))
        guard case .hash(let hashAfterDelete) = try await conn.get(hashKey) else {
            Issue.record("expected .hash"); return
        }
        #expect(hashAfterDelete == ["f2": "v2"])
        try await conn.write(.delete(key: hashKey))

        let listKey = "berry:conformance:write:list:\(suffix)"
        try await conn.write(.listPush(key: listKey, value: "b", end: .tail))
        try await conn.write(.listPush(key: listKey, value: "a", end: .head))
        guard case .list(let listAfterPush) = try await conn.get(listKey) else {
            Issue.record("expected .list"); return
        }
        #expect(listAfterPush == ["a", "b"])
        try await conn.write(.listRemove(key: listKey, value: "a"))
        guard case .list(let listAfterRemove) = try await conn.get(listKey) else {
            Issue.record("expected .list"); return
        }
        #expect(listAfterRemove == ["b"])
        try await conn.write(.delete(key: listKey))

        let setKey = "berry:conformance:write:set:\(suffix)"
        try await conn.write(.setAdd(key: setKey, member: "x"))
        try await conn.write(.setAdd(key: setKey, member: "y"))
        guard case .set(let setAfterAdd) = try await conn.get(setKey) else {
            Issue.record("expected .set"); return
        }
        #expect(Set(setAfterAdd) == Set(["x", "y"]))
        try await conn.write(.setRemove(key: setKey, member: "x"))
        guard case .set(let setAfterRemove) = try await conn.get(setKey) else {
            Issue.record("expected .set"); return
        }
        #expect(setAfterRemove == ["y"])
        try await conn.write(.delete(key: setKey))

        let zsetKey = "berry:conformance:write:zset:\(suffix)"
        try await conn.write(.sortedSetAdd(key: zsetKey, member: "one", score: 1))
        try await conn.write(.sortedSetAdd(key: zsetKey, member: "two", score: 2))
        guard case .sortedSet(let zsetAfterAdd) = try await conn.get(zsetKey) else {
            Issue.record("expected .sortedSet"); return
        }
        #expect(zsetAfterAdd == [SortedSetMember(member: "one", score: 1), SortedSetMember(member: "two", score: 2)])
        try await conn.write(.sortedSetRemove(key: zsetKey, member: "one"))
        guard case .sortedSet(let zsetAfterRemove) = try await conn.get(zsetKey) else {
            Issue.record("expected .sortedSet"); return
        }
        #expect(zsetAfterRemove == [SortedSetMember(member: "two", score: 2)])
        try await conn.write(.delete(key: zsetKey))

        let streamKey = "berry:conformance:write:stream:\(suffix)"
        try await conn.write(.streamAdd(key: streamKey, field: "field", value: "streamvalue"))
        guard case .stream(let streamAfterAdd) = try await conn.get(streamKey) else {
            Issue.record("expected .stream"); return
        }
        #expect(streamAfterAdd.count == 1)
        #expect(streamAfterAdd.first?.fields == ["field": "streamvalue"])
        try await conn.write(.delete(key: streamKey))
    }
}
