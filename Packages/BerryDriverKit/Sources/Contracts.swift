import Foundation

/// Driver contract
public protocol DatabaseDriver: Sendable {
    static var id: DriverID { get }
    static var displayName: String { get }
    static var capabilities: Capabilities { get }
    static var dialect: any SQLDialect { get }

    init()
    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection
}

/// One physical connection. Actor: one connection = one sequential command
/// queue — matching the nature of DB protocols.
public protocol DriverConnection: Actor {
    nonisolated var id: UUID { get }

    /// ALWAYS returns a stream — even for DDL/UPDATE (stream has only `.complete`).
    /// The single SQL execution path (principle N1). `nonisolated` because it only
    /// creates and returns the stream; the real work runs in a Task on the actor.
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error>

 /// Cancel the running query — mechanism is DBMS-specific.
    /// `nonisolated` because it must be callable WHILE the actor is busy running a query.
    nonisolated func cancelCurrentQuery()

    func setDatabase(_ name: String) async throws
    nonisolated var introspector: any Introspector { get }
    func ping() async -> Bool
    func close() async
}

/// A connection that can bound each statement it runs by a timeout of that
/// statement alone, leaving no setting on the session. A connection pooler
/// in transaction mode hands the server session to another client between
/// transactions, so a session setting would not stay with this connection
/// and would follow the session to whoever gets it next.
public protocol StatementBoundingConnection: DriverConnection {
    /// From now on, every statement this connection runs inside a catalog
    /// read scope (`CatalogReadScoping`), and on a server that bounds
    /// statements one by one every statement it runs, ends with an error
    /// once it has run longer than `timeout`. Returns false, changing
    /// nothing, when the server offers no such form.
    func boundEachStatement(by timeout: Duration) async -> Bool
}

/// The catalog reads of one harvest pass or statistics refresh, which a
/// connection can run together, in one transaction.
public struct CatalogReadScope: Hashable, Sendable {
    public let id = UUID()

    public init() {}

    /// The scope the current task reads in. `Task {}` copies it to the task
    /// it starts and `Task.detached` does not (SE-0311, "Task-local value and
    /// tasks which outlive their scope", where `Task {}` is spelled
    /// `async {}`:
    /// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md),
    /// so a read made from a detached task inside a scope waits until the
    /// scope ends. A statistics refresh relies on the first, through the task
    /// a connection's `execute` starts, and a test pins it.
    @TaskLocal public static var current: CatalogReadScope?
}

/// A connection, or an introspector reading through one, whose catalog
/// reads can share one scope.
public protocol CatalogReadScoping: Sendable {
    /// Opens a scope, or returns nil when the reads need none. A scope that
    /// was opened must be ended.
    func beginCatalogReads() async throws -> CatalogReadScope?
    /// Ends `scope`, committing when `commit` and rolling back otherwise,
    /// whether or not the calling task was cancelled.
    func endCatalogReads(_ scope: CatalogReadScope, commit: Bool) async
}

extension CatalogReadScoping {
    /// Runs `body` with the catalog reads it makes in one scope, which ends
    /// with a commit when `body` returns and with a rollback when it throws,
    /// cancellation included.
    public func withCatalogReads<T>(_ body: () async throws -> T) async throws -> T {
        guard let scope = try await beginCatalogReads() else { return try await body() }
        do {
            let value = try await CatalogReadScope.$current.withValue(scope) { try await body() }
            await endCatalogReads(scope, commit: true)
            return value
        } catch {
            await endCatalogReads(scope, commit: false)
            throw error
        }
    }
}

/// Introspection metadata — the source for SchemaCatalog.
public protocol Introspector: Sendable {
    func databases() async throws -> [DatabaseInfo]
    func objects(in database: String?) async throws -> [SchemaObject]
    func tableDetail(_ ref: TableRef) async throws -> TableDetail
 /// Quick-info panel stats — separate from `tableDetail` since it's
    /// a distinct, best-effort query (or REST call) per driver, not part of
 /// the column/index/FK introspection every other feature needs.
    func tableStats(_ ref: TableRef) async throws -> TableStats
    func ddl(of object: SchemaObject) async throws -> String

    /// An opaque version of the catalog in `scope`: equal values mean no
    /// table, view, column, index or foreign key changed. Nil when the
    /// engine has nothing cheaper than listing every object, so the caller
    /// lists every time.
    func schemaVersionToken(scope: SchemaScope) async throws -> String?
    /// Every table and view in `scope` with its fingerprint, in one or two
    /// queries, so a caller can tell which objects to fetch in full.
    func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary]
    /// Every foreign key in `scope`, one element per column pair.
    func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation]
    /// Columns and indexes of `refs` (at most a few hundred per call) in a
    /// few queries; the result may omit a ref that vanished meanwhile.
    func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail]
    /// False while the driver only has the per-table members; the caller
    /// then re-fetches every table on each catalog change.
    var bulkIntrospection: Bool { get }
}

/// The per-table path as defaults, so a driver without bulk queries keeps
/// its previous behaviour: list, then one `tableDetail` per table.
extension Introspector {
    public func schemaVersionToken(scope: SchemaScope) async throws -> String? { nil }

    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        try await objects(in: nil)
            .filter { $0.kind == .table || $0.kind == .view }
            .map { SchemaObjectSummary(ref: TableRef(database: $0.database, name: $0.name), kind: $0.kind, fingerprint: nil) }
    }

    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        let tables = try await objectSummaries(scope: scope).filter { $0.kind == .table }.map(\.ref)
        return try await tableDetails(tables).flatMap { detail in
            detail.foreignKeys.map { fk in
                ForeignKeyRelation(
                    source: detail.ref, column: fk.column,
                    target: TableRef(database: fk.referencedSchema ?? detail.ref.database, name: fk.referencedTable),
                    referencedColumn: fk.referencedColumn
                )
            }
        }
    }

    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        var details: [TableDetail] = []
        details.reserveCapacity(refs.count)
        var listed: Set<TableRef>?
        for ref in refs {
            try Task.checkCancellation()
            do {
                details.append(try await tableDetail(ref))
            } catch {
                // A table dropped between listing and detail is skipped, not
                // fatal: the pass runs against a database that other sessions
                // change. Any other failure, a lost connection or a cancelled
                // statement among them, must reach the caller, or a broken pass
                // would look complete; so a failure is excused only when a fresh
                // listing, read once per call, no longer has the table.
                try Task.checkCancellation()
                if listed == nil {
                    listed = Set(try await objects(in: nil).filter(\.kind.isRelational).map {
                        TableRef(database: $0.database, name: $0.name)
                    })
                }
                if listed?.contains(ref) ?? true { throw error }
            }
        }
        return details
    }

    public var bulkIntrospection: Bool { false }
}
