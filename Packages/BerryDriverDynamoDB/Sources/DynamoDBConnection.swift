import BerryDriverKit
import Foundation

/// Cancellation state reachable from outside the actor — same reasoning as
/// `PostgresCancelBox`/`QdrantCancelBox` (docs/architecture/05 §4):
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

    private nonisolated let client: DynamoDBHTTPClient
    private nonisolated let cancelBox = DynamoDBCancelBox()
    private var isClosed = false

    /// Page-size hint for `ExecuteStatement`'s request-level `Limit` field —
    /// also bounds each `.rows` batch to N3's 500–1000 range. Verified
    /// against dynamodb-local: a page's `Items` count can never exceed this,
    /// since DynamoDB stops evaluating once it hits `Limit`.
    static let batchSize = 1000

    init(config: ConnectionConfig, session: URLSession = URLSession(configuration: .ephemeral)) async throws {
        self.client = try DynamoDBHTTPClient(config: config, session: session)
        // Fail fast (KN-06 "Test connection" expectation, same reasoning as
        // QdrantDriver.connect()) — an HTTP client has no TCP-handshake-time
        // failure the way Postgres/MySQL do.
        guard await client.ping() else {
            throw DriverError.connectionFailed("Could not reach DynamoDB (check host/region/credentials)")
        }
    }

    // MARK: - Execute (docs/architecture/06 · L2, 12 §4)

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
            // (required to match docs/architecture/05 §4's table exactly).
            // Treated as a client-side no-op: no network call, no real
            // atomicity or rollback — a documented gap, not a silent lie.
            // See docs/architecture/12 §4 "Trạng thái hiện thực".
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

    /// Follows every `NextToken` page (docs/architecture/05 §4
    /// `serverSideCursor` — sequential paging, no seek) and streams batches
    /// of ≤1000 rows (N3). Columns are established from the union of
    /// attribute names in the FIRST non-empty page; a later page introducing
    /// an attribute the first page never had is a known limitation — items
    /// are inherently schema-flexible in DynamoDB, and `ResultEvent` commits
    /// to one `.columns` event up front. Such extra attributes are dropped
    /// from the row rather than corrupting column alignment.
    private func runSelect(
        sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        var columnOrder: [String]?
        var nextToken: String?
        do {
            repeat {
                let page = try await client.executeStatement(sql, nextToken: nextToken, limit: Self.batchSize)
                nextToken = page.nextToken
                guard !page.items.isEmpty else { continue }
                if columnOrder == nil {
                    let order = Set(page.items.flatMap(\.keys)).sorted()
                    columnOrder = order
                    continuation.yield(.columns(order.map {
                        ColumnMeta(name: $0, declaredType: DynamoDBWire.declaredType(of: $0, firstBatch: page.items))
                    }))
                }
                let order = columnOrder!
                continuation.yield(.rows(page.items.map { DynamoDBWire.row(from: $0, columnOrder: order) }))
            } while nextToken != nil
            // rowsAffected is a DML concept (matches SQLite/Postgres: nil for SELECT).
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Singleton INSERT/UPDATE/DELETE — DynamoDB PartiQL can only ever touch
    /// one item per statement (docs/architecture/12 §4), so there is never a
    /// second page to follow.
    private func runWrite(
        sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let rewritten = PartiQLInsertRewriter.rewrite(sql)
            _ = try await client.executeStatement(rewritten, nextToken: nil, limit: nil)
            // No rowsAffected: ExecuteStatement reports no count for writes
            // (Items is only populated by RETURNING, which ChangeSet never
            // requests) — same "not exposed" precedent as Postgres (05 §6);
            // the UI shows "OK" + duration.
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
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

    private static func mapError(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError { return driverError }
        if error is CancellationError { return .cancelled }
        return .queryFailed(message: error.localizedDescription, code: nil)
    }

    // MARK: - Control

    /// Client-side only (capabilities.cancelQuery == false, matching
    /// docs/architecture/05 §4's "❌ chỉ hủy phía client") — DynamoDB has no
    /// server-side query-cancel API. Cancelling the Task stops the
    /// pagination loop / aborts the in-flight HTTP request; it does not (and
    /// architecturally cannot) tell DynamoDB to stop evaluating server-side.
    public nonisolated func cancelCurrentQuery() {
        cancelBox.current?.cancel()
    }

    /// DynamoDB has no database/schema concept (multipleDatabases == false,
    /// 05 §4) — same posture as SQLite's single-database-per-connection.
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
