import BerryDriverKit
import Foundation

/// Sibling contract to `DatabaseDriver` (BerryDriverKit) for data with no SQL
/// shape — document stores and vector stores (docs/architecture/12 §2).
/// DynamoDB does NOT implement this: it has PartiQL, so it implements
/// `DatabaseDriver` instead via a `PartiQLDialect` (docs/architecture/12 §4).
public protocol DataSourceDriver: Sendable {
    static var id: DriverID { get }
    static var displayName: String { get }
    static var kind: DataSourceKind { get }
    static var capabilities: DataSourceCapabilities { get }

    init()
    func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection
}

/// One physical connection — actor, same reasoning as `DriverConnection`
/// (one connection = one sequential command queue).
public protocol DataSourceConnection: Actor {
    nonisolated var id: UUID { get }

    func listCollections() async throws -> [CollectionRef]

    /// Explicit collection/point-set creation (docs/architecture/12 §3/§5) —
    /// NOT gated behind write-confirm like `write`: creating a collection is
    /// schema-ish, not a destructive data change. `options` lets each driver
    /// interpret its own config shape rather than forcing one generic schema
    /// across document/vector stores:
    /// - `MongoConnection`: runs the explicit `create` admin command via
    ///   `runCommand` on the connection's working database (`ref.database` is
    ///   ignored — Mongo has exactly one working database per connection, see
    ///   `MongoConnection.database`). `options` is ignored for v1; an empty
    ///   `.object([])` is the expected caller value.
    /// - `QdrantConnection`: `options` MUST be `.object` with an integer
    ///   `"vectorSize"` field (throws `DataSourceError.queryFailed` if
    ///   missing/non-positive) and an optional `"distance"` string field
    ///   (`"Cosine"`/`"Euclid"`/`"Dot"`, defaults to `"Cosine"` if absent) —
    ///   sent as `PUT /collections/{ref.name}` with
    ///   `{"vectors": {"size": N, "distance": D}}`. Qdrant has no
    ///   implicit-creation-on-insert the way Mongo does, so this is the only
    ///   way to get a Qdrant collection into existence through BerryDB.
    /// - `ElasticsearchConnection`: `PUT /{ref.name}` with an empty body —
    ///   `options` is ignored for v1 (same as Mongo); ES's dynamic mapping
    ///   infers field types from the first document indexed, so no upfront
    ///   mapping is required to get a usable index (docs/architecture/17 §2).
    func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws

    /// ALWAYS returns a stream, batched 500–1000 items (N3) — the
    /// non-SQL analogue of `DriverConnection.execute`. `nonisolated` because
    /// it only creates and returns the stream; the real work runs in a Task
    /// on the actor.
    nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error>

    /// Insert/update/delete — caller has already shown the native-command
    /// preview and gotten confirmation (DL-03/04, docs/architecture/12 §6).
    func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult

    /// `nonisolated` because it must be callable WHILE the actor is busy
    /// running a query (same reasoning as `DriverConnection.cancelCurrentQuery`).
    nonisolated func cancelCurrentQuery()

    nonisolated var introspector: any DataSourceIntrospector { get }
    func ping() async -> Bool
    func close() async

    // MARK: User management (TI-03 Phase C, docs/architecture/14)
    //
    // Default-unsupported via the extension below, same "nil/throw when
    // unsupported" spirit as SQLDialect's TI-03 primitives — only
    // MongoConnection overrides these. A driver whose
    // DataSourceCapabilities.userManagement is false (Qdrant) never has them
    // called (the UI gates on that flag), so the throwing default is
    // reachable only as a defensive backstop, not a real code path.

    /// Lists this connection's users and their roles — matches
    /// `SQLDialect.listUsersSQL()`'s intent for the DataSource family.
    func listUsers() async throws -> [DataSourceUserInfo]
    /// Creates a new user with an initial set of roles (curated built-in
    /// roles, e.g. Mongo's `read`/`readWrite`/`dbAdmin` — no custom-role
    /// definitions in v1).
    func createUser(username: String, password: String, roles: [String]) async throws
    /// Drops a user. Can fail server-side (e.g. insufficient privilege); that
    /// error is surfaced as-is, same as `SQLDialect.dropUserSQL`'s contract.
    func dropUser(username: String) async throws
}

extension DataSourceConnection {
    public func listUsers() async throws -> [DataSourceUserInfo] {
        throw DataSourceError.unsupported("User management")
    }

    public func createUser(username: String, password: String, roles: [String]) async throws {
        throw DataSourceError.unsupported("User management")
    }

    public func dropUser(username: String) async throws {
        throw DataSourceError.unsupported("User management")
    }
}

/// Introspection for schema-less stores — deliberately narrower than
/// `Introspector` (BerryDriverKit): there is no DDL to read, only sample-based
/// inference (docs/architecture/12 §3).
public protocol DataSourceIntrospector: Sendable {
    func collections() async throws -> [CollectionRef]

    /// Best-effort field/type map inferred from up to `sampleSize` recent
    /// documents. NOT a real schema — callers must present it as inferred,
    /// never as authoritative DDL (docs/architecture/12 §3, TR-03).
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String]
}
