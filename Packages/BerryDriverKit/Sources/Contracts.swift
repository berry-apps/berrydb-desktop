import Foundation

/// Driver contract — docs/architecture/05 §1.
public protocol DatabaseDriver: Sendable {
    static var id: DriverID { get }
    static var displayName: String { get }
    static var capabilities: Capabilities { get }
    static var dialect: any SQLDialect { get }

    init()
    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection
}

/// One physical connection. Actor: one connection = one sequential command
/// queue — matching the nature of DB protocols (docs/architecture/04 §4).
public protocol DriverConnection: Actor {
    nonisolated var id: UUID { get }

    /// ALWAYS returns a stream — even for DDL/UPDATE (stream has only `.complete`).
    /// The single SQL execution path (principle N1). `nonisolated` because it only
    /// creates and returns the stream; the real work runs in a Task on the actor.
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error>

    /// Cancel the running query — mechanism is DBMS-specific (docs/architecture/05 §4).
    /// `nonisolated` because it must be callable WHILE the actor is busy running a query.
    nonisolated func cancelCurrentQuery()

    func setDatabase(_ name: String) async throws
    nonisolated var introspector: any Introspector { get }
    func ping() async -> Bool
    func close() async
}

/// Introspection metadata — the source for SchemaCatalog (docs/architecture/05 §5).
public protocol Introspector: Sendable {
    func databases() async throws -> [DatabaseInfo]
    func objects(in database: String?) async throws -> [SchemaObject]
    func tableDetail(_ ref: TableRef) async throws -> TableDetail
    /// Quick-info panel stats (TR-04) — separate from `tableDetail` since it's
    /// a distinct, best-effort query (or REST call) per driver, not part of
    /// the column/index/FK introspection every other TR-01/03 feature needs.
    func tableStats(_ ref: TableRef) async throws -> TableStats
    func ddl(of object: SchemaObject) async throws -> String
}
