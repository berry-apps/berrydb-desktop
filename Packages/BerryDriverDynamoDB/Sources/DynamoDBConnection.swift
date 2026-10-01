import BerryDriverKit
import Foundation

/// Cancellation state reachable from outside the actor — same reasoning as
/// `PostgresCancelBox`/`QdrantCancelBox`:
/// `cancelCurrentQuery()` must work while the actor is busy awaiting HTTP.
private final class DynamoDBCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return task }
        set { lock.lock(); defer { lock.unlock() }; task = newValue }
    }
}

public actor DynamoDBConnection: DriverConnection {
    public nonisolated let id = UUID()

    private let client: DynamoDBHTTPClient
    private nonisolated let cancelBox = DynamoDBCancelBox()
    private var isClosed = false

    /// PartiQL actions AWS denied on this connection. Least-privilege IAM
    /// policies often grant Scan/PutItem/UpdateItem/DeleteItem but not
    /// `dynamodb:PartiQL*`. PartiQL stays the first attempt, so everything
    /// that works today is untouched. After one denial, the statements of that
    /// kind which BerryDB generated go straight to the native item API for the
    /// rest of the connection.
    private var deniedPartiQLActions: Set<PartiQLAction> = []

    /// Partition-key name per table, for native INSERT (one DescribeTable per table).
    private var partitionKeys: [String: String] = [:]

    /// Page-size hint for `ExecuteStatement`'s request-level `Limit` field —
    /// also bounds each `.rows` batch to N3's 500–1000 range. Verified
    /// against dynamodb-local: a page's `Items` count can never exceed this,
    /// since DynamoDB stops evaluating once it hits `Limit`.
    static let batchSize = 1000

    init(config: ConnectionConfig, session: URLSession = URLSession(configuration: .ephemeral)) async throws {
        self.client = try DynamoDBHTTPClient(config: config, session: session)
 // Fail fast ("Test connection" expectation, same reasoning as
        // QdrantDriver.connect()) — an HTTP client has no TCP-handshake-time
        // failure the way Postgres/MySQL do.
        guard await client.ping() else {
            throw DriverError.connectionFailed("Could not reach DynamoDB (check host/region/credentials)")
        }
    }

 // MARK: - Execute

    public nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(sql: sql, continuation: continuation)
            }
            cancelBox.current = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        switch Self.classify(sql) {
        case .transactionControl:
            // TransactWriteItems (≤25 items) is DynamoDB's real atomic
            // mechanism — PartiQL has no BEGIN/COMMIT/ROLLBACK statement at
            // all. `ChangeSet.apply` (BerryCore, untouched) still wraps every
            // run in that text because `capabilities.transactions == true`
 // (required to match's table exactly).
            // Treated as a client-side no-op: no network call, no real
            // atomicity or rollback — a documented gap, not a silent lie.
 // See
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
            continuation.finish()
        case .select:
            await runSelect(sql: sql, continuation: continuation)
        case .write, .other:
            // DDL / anything this driver doesn't specially recognize runs
            // once, unpaginated — DynamoDB's own error surfaces if it isn't
            // valid PartiQL (ExecuteStatement has no DDL surface anyway).
            await runWrite(sql: sql, continuation: continuation)
        }
    }

    /// Streams every page of a SELECT as batches of ≤1000 rows (N3) —
    /// sequential paging, no seek (`serverSideCursor`).
    ///
    /// PartiQL (`ExecuteStatement`, following every `NextToken`) is always
    /// tried first. When IAM denies `dynamodb:PartiQLSelect` and the statement
    /// is the grid's unfiltered `SELECT * FROM "T"`, the same rows come from
    /// `Scan` instead; an unfiltered PartiQL SELECT * is itself a scan, so the
    /// result does not change. Filtered, sorted or projected SELECTs keep the
    /// PartiQL error (see `PartiQLNativeTranslation` for why).
    private func runSelect(
        sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        let scanTable = PartiQLNativeTranslation.scanTable(sql)
        var yielded = false
        do {
            if let scanTable, deniedPartiQLActions.contains(.select) {
                try await streamScan(table: scanTable, continuation: continuation, yielded: &yielded)
            } else {
                do {
                    try await streamPartiQL(sql: sql, continuation: continuation, yielded: &yielded)
                } catch {
                    guard let scanTable, !yielded, Self.isPartiQLAccessDenied(error) else { throw error }
                    deniedPartiQLActions.insert(.select)
                    try await streamScan(table: scanTable, continuation: continuation, yielded: &yielded)
                }
            }
            // rowsAffected is a DML concept (matches SQLite/Postgres: nil for SELECT).
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private func streamPartiQL(
        sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation, yielded: inout Bool
    ) async throws {
        var nextToken: String?
        var finished = false
        try await streamPages(continuation: continuation, yielded: &yielded) {
            guard !finished else { return nil }
            let page = try await self.client.executeStatement(sql, nextToken: nextToken, limit: Self.batchSize)
            nextToken = page.nextToken
            finished = page.nextToken == nil
            return page.items
        }
    }

    private func streamScan(
        table: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation, yielded: inout Bool
    ) async throws {
        var previous: DynamoDBHTTPClient.ScanPage?
        var finished = false
        try await streamPages(continuation: continuation, yielded: &yielded) {
            guard !finished else { return nil }
            let page = try await self.client.scan(table: table, limit: Self.batchSize, after: previous)
            previous = page
            finished = page.lastEvaluatedKey == nil
            return page.items
        }
    }

    /// The page loop shared by PartiQL and Scan. Columns come from the union of
    /// attribute names in the FIRST non-empty page. A later page that
    /// introduces an attribute the first page never had is a known
    /// limitation: items are inherently schema-flexible in DynamoDB, and
    /// `ResultEvent` commits to one `.columns` event up front, so such extra
    /// attributes are dropped from the row rather than corrupting column
    /// alignment. `nextPage` returns nil once exhausted; an empty page is
    /// skipped. `yielded` turns true on the first event sent, after which a
    /// fallback would duplicate rows.
    private func streamPages(
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation,
        yielded: inout Bool,
        nextPage: () async throws -> [[String: Any]]?
    ) async throws {
        var columnOrder: [String]?
        while let items = try await nextPage() {
            guard !items.isEmpty else { continue }
            if columnOrder == nil {
                let order = Set(items.flatMap(\.keys)).sorted()
                columnOrder = order
                continuation.yield(.columns(order.map {
                    ColumnMeta(name: $0, declaredType: DynamoDBWire.declaredType(of: $0, firstBatch: items))
                }))
                yielded = true
            }
            let order = columnOrder!
            continuation.yield(.rows(items.map { DynamoDBWire.row(from: $0, columnOrder: order) }))
        }
    }

    /// Singleton INSERT/UPDATE/DELETE. DynamoDB PartiQL can only ever touch
    /// one item per statement, so there is never a second page to follow.
    ///
    /// The fallback rule is the same as `runSelect`'s: PartiQL first. When IAM
    /// denies the statement's `dynamodb:PartiQL*` action and the text is one
    /// that ChangeSet generated, it is replayed through
    /// PutItem/UpdateItem/DeleteItem, with conditions that keep PartiQL's
    /// semantics (`NativeWriteRequest.make`). History, DangerGuard and the SQL
    /// preview still see the PartiQL text; the native call is an execution
    /// detail of this driver.
    private func runWrite(
        sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        let native = PartiQLNativeTranslation.write(sql)
        do {
            if let native, deniedPartiQLActions.contains(native.partiQLAction) {
                try await performNative(native)
            } else {
                do {
                    let rewritten = PartiQLInsertRewriter.rewrite(sql)
                    _ = try await client.executeStatement(rewritten, nextToken: nil, limit: nil)
                } catch {
                    guard let native, Self.isPartiQLAccessDenied(error) else { throw error }
                    deniedPartiQLActions.insert(native.partiQLAction)
                    try await performNative(native)
                }
            }
            // No rowsAffected: neither ExecuteStatement nor the item API
            // reports a count for writes — same "not exposed" precedent as
            // Postgres; the UI shows "OK" + duration.
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Internal (not private) so `DynamoDBConformanceTests` can check
    /// native/PartiQL parity against dynamodb-local. dynamodb-local enforces
    /// no IAM, so it can never produce the denial that reaches this in production.
    func performNative(_ write: NativeWrite) async throws {
        var partitionKey: String?
        if case .insert(let table, _) = write {
            partitionKey = try await cachedPartitionKey(of: table)
        }
        try await client.nativeWrite(NativeWriteRequest.make(for: write, partitionKey: partitionKey))
    }

    private func cachedPartitionKey(of table: String) async throws -> String {
        if let known = partitionKeys[table] { return known }
        guard let name = try await client.partitionKeyName(of: table) else {
            throw DriverError.queryFailed(message: "DescribeTable returned no HASH key for \(table)", code: nil)
        }
        partitionKeys[table] = name
        return name
    }

    private enum StatementKind {
        case select, write, transactionControl, other
    }

    private static func classify(_ sql: String) -> StatementKind {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstWord = trimmed.prefix(while: { !$0.isWhitespace }).uppercased()
        switch firstWord {
        case "SELECT": return .select
        case "INSERT", "UPDATE", "DELETE": return .write
        case "BEGIN", "COMMIT", "ROLLBACK", "START", "SAVEPOINT", "RELEASE": return .transactionControl
        default: return .other
        }
    }

    /// `DynamoDBHTTPClient.mapError` renders `"<ExceptionType>: <Message>"`.
    /// AWS names the denied action in the message for identity-policy,
    /// explicit-deny and SCP denials alike ("…not authorized to perform:
    /// dynamodb:PartiQLSelect on resource…").
    static func isPartiQLAccessDenied(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .queryFailed(let message, _) = driverError
        else { return false }
        return message.hasPrefix("AccessDeniedException:") && message.contains("dynamodb:PartiQL")
    }

    private static func mapError(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError { return driverError }
        if error is CancellationError { return .cancelled }
        return .queryFailed(message: error.localizedDescription, code: nil)
    }

    // MARK: - Control

    /// Client-side only (capabilities.cancelQuery == false, matching
 /// — DynamoDB has no
    /// server-side query-cancel API. Cancelling the Task stops the
    /// pagination loop / aborts the in-flight HTTP request; it does not (and
    /// architecturally cannot) tell DynamoDB to stop evaluating server-side.
    public nonisolated func cancelCurrentQuery() {
        cancelBox.current?.cancel()
    }

    /// DynamoDB has no database/schema concept (multipleDatabases == false,
 /// — same posture as SQLite's single-database-per-connection.
    public func setDatabase(_ name: String) async throws {
        throw DriverError.unsupported("DynamoDB has no database/schema concept — each table is independent")
    }

    public nonisolated var introspector: any Introspector {
        DynamoDBIntrospector(client: client)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        return await client.ping()
    }

    public func close() async {
        isClosed = true
        cancelBox.current?.cancel()
    }
}
