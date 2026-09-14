import BerryDriverKit
import Foundation

/// Third driver-contract family, alongside
/// `DatabaseDriver` (BerryDriverKit, SQL-shaped) and `DataSourceDriver`
/// (BerryDataSourceKit, document/vector-shaped). Neither existing contract
/// fits a schemaless key-value store: `DatabaseDriver.execute` takes raw SQL
/// text and `Introspector` is table/column-shaped; `DataSourceQuery`/
/// `DataSourceChangeSet` are closed enums with Mongo/Qdrant-named cases with
/// no natural "collection" mapping for numbered Redis databases. Splitting by
/// actual query shape mirrors the exact reasoning
/// already used to keep Mongo/Qdrant out of `DatabaseDriver`.
///
/// Deliberately has NO dependency on any concrete Redis/Valkey client
/// library — stays buildable and usable at the app's real deployment target
/// (macOS 14) so the connection picker can safely query
/// `KeyValueRegistry.registered` unconditionally. Only the concrete
/// `BerryDriverRedis` package (which actually imports a client library) is
/// `@available(macOS 15, *)` — see that package's own doc comment.
public protocol KeyValueDriver: Sendable {
    static var id: DriverID { get }
    static var displayName: String { get }
    static var capabilities: KeyValueCapabilities { get }
    init()
    func connect(_ config: ConnectionConfig) async throws -> any KeyValueConnection
}

public protocol KeyValueConnection: Actor {
    nonisolated var id: UUID { get }
    /// Switches the numbered database in use (Redis/Valkey: 0–15) — nil for
    /// drivers where `capabilities.numberedDatabases == false`.
    func selectDatabase(_ index: Int) async throws
    /// Cursor-paginated key listing via `SCAN` — never `KEYS`, which blocks
 /// the server (N3). `cursor: nil` starts a new
    /// scan; a `nil` `nextCursor` in the result means the scan is complete.
    func scan(pattern: String, cursor: String?) async throws -> KeyValueScanPage
    func get(_ key: String) async throws -> KeyValueValue
    /// `nil` means no TTL is set (the key doesn't expire).
    func ttl(_ key: String) async throws -> TimeInterval?
    /// Always called only after the caller has already shown the user the
    /// native command this will run (N1, mirrors `DataSourceConnection.write`).
    func write(_ change: KeyValueChangeSet) async throws
    nonisolated func cancelCurrentQuery()
    func ping() async -> Bool
    func close() async
}
