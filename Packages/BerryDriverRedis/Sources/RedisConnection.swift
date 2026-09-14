import BerryDriverKit
import BerryKeyValueKit
import Foundation
import Logging
import NIOSSL
import Valkey

@available(macOS 15, *)
public actor RedisConnection: KeyValueConnection {
    public nonisolated let id = UUID()
    private let client: ValkeyClient
    private let runTask: Task<Void, Never>

    public init(config: ConnectionConfig) async throws {
        let logger = Logger(label: "berrydb.redis")

        var configuration = ValkeyClientConfiguration()
        if let password = config.password, !password.isEmpty {
            configuration.authentication = .init(
                username: config.username?.isEmpty == false ? config.username! : "default",
                password: password
            )
        }
        if let database = config.database, let index = Int(database) {
            configuration.databaseNumber = index
        }
        // Binary on/off, not a spectrum: Redis's wire protocol has no
        // Postgres-style "try TLS, fall back to plaintext on the same
        // connection" byte — TLS (if used) must be the first byte of the
        // socket, same limitation already documented for Mongo
 // (point 1). `.disable` → plaintext; every
        // other `TLSMode` value enables TLS with default trust (no custom
        // CA/client cert yet, same v1 scope as Qdrant/Mongo's own TLS gaps).
        if config.tlsMode != .disable {
            configuration.tls = try .enable(.makeClientConfiguration(), tlsServerName: config.host)
        }

        let client = ValkeyClient(
            .hostname(config.host ?? "127.0.0.1", port: config.port ?? 6379),
            configuration: configuration,
            logger: logger
        )
        self.client = client
        self.runTask = Task { await client.run() }

 // Fail fast on a bad host/port — same "Test connection"
        // expectation every driver follows.
        do {
            _ = try await client.ping()
        } catch {
            runTask.cancel()
            throw error
        }
    }

    public func selectDatabase(_ index: Int) async throws {
        try await client.select(index: index)
    }

 /// Batches over the collection-shaped types (N3,:
    /// "never buffer a full result set" — batches of 500-1000). Applies to
    /// `get()`'s hash/list/set/sortedSet/stream reads AND to `scan()`'s
    /// own page size. A key with more members than this shows only the
    /// first batch — no truncation indicator yet in `KeyValueValue` (v1 gap,
 /// but this is a strict improvement over
    /// pulling an unbounded collection (a hash/list/set/zset/stream can
    /// hold millions of entries in real Redis usage) into memory in one shot.
    private static let maxCollectionMembers = 1000

    public func scan(pattern: String, cursor: String?) async throws -> KeyValueScanPage {
        let cursorInt = cursor.flatMap { Int($0) } ?? 0
        let response = try await client.scan(
            cursor: cursorInt,
            pattern: pattern.isEmpty ? nil : pattern,
            count: 200
        )
        let keys = try response.keys.map { try $0.decode(as: String.self) }
        // Concurrent, not sequential: this used to be 1 TYPE round trip per
        // key, awaited one at a time — up to 200 serialized network round
        // trips for a single page. `client` (a plain Sendable value, not
        // actor-isolated `self`) is captured directly so each child task's
        // network wait can genuinely overlap instead of queuing on this
        // actor's serial executor.
        let client = self.client
        let entries = try await withThrowingTaskGroup(of: (Int, KeyValueEntry).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask {
                    let bulk = try await client.type(ValkeyKey(key))
                    let type = Self.mapRedisTypeName(bulk.map { String(decoding: $0, as: UTF8.self) })
                    return (index, KeyValueEntry(key: key, type: type))
                }
            }
            var ordered = [KeyValueEntry?](repeating: nil, count: keys.count)
            for try await (index, entry) in group {
                ordered[index] = entry
            }
            return ordered.compactMap { $0 }
        }
        let nextCursor = response.cursor == 0 ? nil : String(response.cursor)
        return KeyValueScanPage(entries: entries, nextCursor: nextCursor)
    }

    public func get(_ key: String) async throws -> KeyValueValue {
        switch try await keyType(key) {
        case .none:
            return .none
        case .string:
            guard let bulk = try await client.get(ValkeyKey(key)) else { return .none }
            return .string(String(decoding: bulk, as: UTF8.self))
        case .hash:
            // HSCAN, not HGETALL (N3, see maxCollectionMembers) — bounded to
            // one page instead of the whole hash.
            let response = try await client.hscan(ValkeyKey(key), cursor: 0, count: Self.maxCollectionMembers)
            let decoded = Dictionary(uniqueKeysWithValues: try response.members.withValues().map {
                (String(decoding: $0.field, as: UTF8.self), String(decoding: $0.value, as: UTF8.self))
            })
            return .hash(decoded)
        case .list:
            // Bounded range, not `0 -1` (N3) — a list can hold millions of
            // entries (e.g. an event log).
            let array = try await client.lrange(ValkeyKey(key), start: 0, stop: Self.maxCollectionMembers - 1)
            return .list(try array.decode(as: [String].self))
        case .set:
            // SSCAN, not SMEMBERS (N3) — same reasoning as hash.
            let response = try await client.sscan(ValkeyKey(key), cursor: 0, count: Self.maxCollectionMembers)
            return .set(try response.elements.decode(as: [String].self))
        case .sortedSet:
            // ZSCAN, not `ZRANGE 0 -1` (N3) — same reasoning as hash. Also
            // sidesteps the RESP3 nested-pair decode entirely: ZSCAN's reply
            // shape is the flat cursor-family shape regardless of protocol
            // version, unlike ZRANGE WITHSCORES.
            let response = try await client.zscan(ValkeyKey(key), cursor: 0, count: Self.maxCollectionMembers)
            let members = try response.members.withScores().map {
                SortedSetMember(member: String(decoding: $0.value, as: UTF8.self), score: $0.score)
            }
            return .sortedSet(members)
        case .stream:
            // Bounded count, not `count: nil` (N3) — a stream used as an
            // event log can hold far more than fits in memory at once.
            let messages = try await client.xrange(
                ValkeyKey(key), start: "-", end: "+", count: Self.maxCollectionMembers
            )
            let entries = messages.map { message in
                KeyValueStreamEntry(
                    id: message.id,
                    fields: Dictionary(
                        uniqueKeysWithValues: message.fields.map { ($0.key, String(decoding: $0.value, as: UTF8.self)) }
                    )
                )
            }
            return .stream(entries)
        }
    }

    public func ttl(_ key: String) async throws -> TimeInterval? {
        let seconds = try await client.ttl(ValkeyKey(key))
        // Redis: -1 = no TTL set, -2 = key doesn't exist. Both mean "no TTL"
        // from this app's point of view — the browser shows the key's
        // existence via get()/scan(), not ttl().
        return seconds >= 0 ? TimeInterval(seconds) : nil
    }

    public func write(_ change: KeyValueChangeSet) async throws {
        switch change {
        case .set(let key, let value, let ttl):
            let expiration: SET<String>.Expiration? = ttl.map { .seconds(Int($0)) }
            try await client.set(ValkeyKey(key), value: value, expiration: expiration)
        case .delete(let key):
            _ = try await client.del(keys: [ValkeyKey(key)])
        case .expire(let key, let ttl):
            _ = try await client.expire(ValkeyKey(key), seconds: Int(ttl))
        case .hashFieldSet(let key, let field, let value):
            _ = try await client.hset(ValkeyKey(key), data: [.init(field: field, value: value)])
        case .hashFieldDelete(let key, let field):
            _ = try await client.hdel(ValkeyKey(key), fields: [field])
        case .listPush(let key, let value, let end):
            switch end {
            case .head: _ = try await client.lpush(ValkeyKey(key), elements: [value])
            case .tail: _ = try await client.rpush(ValkeyKey(key), elements: [value])
            }
        case .listRemove(let key, let value):
            _ = try await client.lrem(ValkeyKey(key), count: 0, element: value)
        case .setAdd(let key, let member):
            _ = try await client.sadd(ValkeyKey(key), members: [member])
        case .setRemove(let key, let member):
            _ = try await client.srem(ValkeyKey(key), members: [member])
        case .sortedSetAdd(let key, let member, let score):
            _ = try await client.zadd(ValkeyKey(key), data: [.init(score: score, member: member)])
        case .sortedSetRemove(let key, let member):
            _ = try await client.zrem(ValkeyKey(key), members: [member])
        case .streamAdd(let key, let field, let value):
            _ = try await client.xadd(ValkeyKey(key), idSelector: .autoId, data: [.init(field: field, value: value)])
        }
    }

    public nonisolated func cancelCurrentQuery() {
        // No in-flight query state to cancel — every KeyValueConnection
        // method is a single, already-fast RESP round trip (capabilities
 // table does not claim cancelQuery).
    }

    public func ping() async -> Bool {
        (try? await client.ping()) != nil
    }

    public func close() async {
        runTask.cancel()
    }

    private func keyType(_ key: String) async throws -> KeyValueType {
        let bulk = try await client.type(ValkeyKey(key))
        return Self.mapRedisTypeName(bulk.map { String(decoding: $0, as: UTF8.self) })
    }

    /// Shared by `keyType(_:)` (actor-isolated, used by `get()`) and `scan()`'s
    /// concurrent `TYPE` dispatch (plain child tasks, not actor-isolated) — pure
    /// so both can call it without an actor hop.
    private static func mapRedisTypeName(_ name: String?) -> KeyValueType {
        switch name {
        case "string": return .string
        case "hash": return .hash
        case "list": return .list
        case "set": return .set
        case "zset": return .sortedSet
        case "stream": return .stream
        default: return .none
        }
    }
}
