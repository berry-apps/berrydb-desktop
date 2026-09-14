import Foundation

/// Redis/Valkey's type tags (`TYPE` command) — schemaless key space, so this
/// is the closest thing to a "kind" a key has.
public enum KeyValueType: String, Sendable, Equatable, Hashable {
    case string, hash, list, set, sortedSet, stream, none
}

/// One `SCAN` result row — key + its type, so the browser can pick a value
/// viewer before fetching the value itself.
public struct KeyValueEntry: Sendable, Equatable {
    public let key: String
    public let type: KeyValueType

    public init(key: String, type: KeyValueType) {
        self.key = key
        self.type = type
    }
}

/// One page of a cursor-paginated `SCAN` (N3: never `KEYS`).
public struct KeyValueScanPage: Sendable, Equatable {
    public let entries: [KeyValueEntry]
    /// `nil` cursor means the scan is complete — matches Redis's own SCAN
    /// convention (cursor "0" signals completion; the driver translates that
    /// to nil so callers never special-case the sentinel string).
    public let nextCursor: String?

    public init(entries: [KeyValueEntry], nextCursor: String?) {
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

/// One member of a sorted set (`ZRANGE ... WITHSCORES`).
public struct SortedSetMember: Sendable, Equatable {
    public let member: String
    public let score: Double

    public init(member: String, score: Double) {
        self.member = member
        self.score = score
    }
}

/// One stream entry (`XRANGE`) — an append-only log record.
public struct KeyValueStreamEntry: Sendable, Equatable {
    public let id: String
    public let fields: [String: String]

    public init(id: String, fields: [String: String]) {
        self.id = id
        self.fields = fields
    }
}

/// A key's value, typed per Redis/Valkey's own data model — deliberately
/// separate from `BerryValue` (BerryDriverKit), which is built for SQL cells,
/// not Redis's small closed set of container types.
public enum KeyValueValue: Sendable, Equatable {
    /// The key does not exist (`GET` returned nil / `TYPE` returned "none").
    case none
    case string(String)
    case hash([String: String])
    case list([String])
    case set([String])
    case sortedSet([SortedSetMember])
    case stream([KeyValueStreamEntry])
}

/// A single write, always previewed before it runs (N1, mirrors
/// `DataSourceChangeSet`) — one field/member/element at a time, mirroring
/// `NewKeyValueSheet`'s own one-value-at-a-time scope for the string case.
public enum KeyValueChangeSet: Sendable, Equatable {
    case set(key: String, value: String, ttl: TimeInterval?)
    case delete(key: String)
    case expire(key: String, ttl: TimeInterval)
    case hashFieldSet(key: String, field: String, value: String)
    case hashFieldDelete(key: String, field: String)
    case listPush(key: String, value: String, end: ListEnd)
    /// `LREM key 0 value` — removes every occurrence, not just one; matches
    /// the "remove this item" affordance a browser row offers (no index/count
    /// picker in v1).
    case listRemove(key: String, value: String)
    case setAdd(key: String, member: String)
    case setRemove(key: String, member: String)
    case sortedSetAdd(key: String, member: String, score: Double)
    case sortedSetRemove(key: String, member: String)
    /// `XADD key * field value` — a single field/value pair per append, same
    /// one-at-a-time scope as the hash case; multi-field appends are
 /// deferred.
    case streamAdd(key: String, field: String, value: String)
}

/// Which end of a list to push a new element onto (`LPUSH`/`RPUSH`).
public enum ListEnd: String, Sendable, Equatable {
    case head, tail
}
