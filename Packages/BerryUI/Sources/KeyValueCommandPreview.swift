import BerryKeyValueKit

/// Renders a `KeyValueChangeSet` as the literal `redis-cli`-style command it
/// maps to — always shown to the user before a write runs (N1, mirrors
/// `DataSourceCommandPreview.render`).
enum KeyValueCommandPreview {
    static func render(_ change: KeyValueChangeSet) -> String {
        switch change {
        case .set(let key, let value, let ttl):
            var command = "SET \(key) \(value)"
            if let ttl { command += " EX \(Int(ttl))" }
            return command
        case .delete(let key):
            return "DEL \(key)"
        case .expire(let key, let ttl):
            return "EXPIRE \(key) \(Int(ttl))"
        case .hashFieldSet(let key, let field, let value):
            return "HSET \(key) \(field) \(value)"
        case .hashFieldDelete(let key, let field):
            return "HDEL \(key) \(field)"
        case .listPush(let key, let value, let end):
            return "\(end == .head ? "LPUSH" : "RPUSH") \(key) \(value)"
        case .listRemove(let key, let value):
            return "LREM \(key) 0 \(value)"
        case .setAdd(let key, let member):
            return "SADD \(key) \(member)"
        case .setRemove(let key, let member):
            return "SREM \(key) \(member)"
        case .sortedSetAdd(let key, let member, let score):
            return "ZADD \(key) \(score) \(member)"
        case .sortedSetRemove(let key, let member):
            return "ZREM \(key) \(member)"
        case .streamAdd(let key, let field, let value):
            return "XADD \(key) * \(field) \(value)"
        }
    }
}
