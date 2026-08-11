import BerryDataSourceKit
import Foundation

/// The subset of a `hello` command reply this driver reads — replica-set
/// primary discovery, v1 (docs/architecture/12 §3). Field names/values
/// verified against a real `mongod` (both standalone and a replica-set
/// member) rather than assumed from memory, same discipline as `BSON`/`SCRAM`.
struct MongoHelloResponse: Sendable, Equatable {
    /// `true` on a writable primary AND on a standalone `mongod` (which has
    /// no concept of "not primary" — it answers `true` for its own writes).
    /// `false` only on a secondary/arbiter member of a replica set. `nil`
    /// when the field is absent entirely — treated the same as `true`
    /// (assume the connected node is usable) so this stays additive for
    /// every pre-existing call site/stub that only ever sent `{ok: 1}`.
    let isWritablePrimary: Bool?
    /// "host:port" of the actual primary — only meaningful when
    /// `isWritablePrimary == false`.
    let primary: String?
    /// The replica set this node belongs to; absent on a standalone.
    let setName: String?

    init(_ reply: BerryDocument) {
        if case .bool(let v)? = reply["isWritablePrimary"] {
            isWritablePrimary = v
        } else {
            isWritablePrimary = nil
        }
        if case .string(let v)? = reply["primary"] {
            primary = v
        } else {
            primary = nil
        }
        if case .string(let v)? = reply["setName"] {
            setName = v
        } else {
            setName = nil
        }
    }
}
