import BerryDriverKit
import Foundation
import SQLite3

/// The db pointer is wrapped separately so `cancelCurrentQuery()` (nonisolated)
/// can call `sqlite3_interrupt` while the actor is busy stepping a query —
/// sqlite3_interrupt is thread-safe by SQLite's design.
final class SQLiteHandle: @unchecked Sendable {
    let db: OpaquePointer
    init(db: OpaquePointer) { self.db = db }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteConnection: DriverConnection {
    public nonisolated let id = UUID()
    nonisolated let handle: SQLiteHandle
    private var isClosed = false

    /// Batch size pushed to the stream (principle N3 — docs/architecture/04 §4).
    static let batchSize = 500

    public init(path: String) throws {
        var db: OpaquePointer?
        // Open read-write (no CREATE — open an existing file); fall back to read-only.
        var rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        if rc != SQLITE_OK {
            sqlite3_close_v2(db)
            db = nil
            rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        }
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open file"
            sqlite3_close_v2(db)
            throw DriverError.connectionFailed(message)
        }
        sqlite3_busy_timeout(db, 3000)
        self.handle = SQLiteHandle(db: db)
    }

    // MARK: - Execute (docs/architecture/06 · L2)

    public nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(sql: sql, continuation: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    self.cancelCurrentQuery()
                }
            }
        }
    }

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        let db = handle.db

        var remaining: UnsafePointer<CChar>? = (sql as NSString).utf8String
        // Run each statement in the SQL string in turn (split via the tail pointer).
        while let cursor = remaining, cursor.pointee != 0 {
            var stmt: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let rc = sqlite3_prepare_v2(db, cursor, -1, &stmt, &tail)
            remaining = tail

            guard rc == SQLITE_OK else {
                continuation.finish(throwing: currentError(db))
                return
            }
            guard let stmt else { continue }   // whitespace/comment
            defer { sqlite3_finalize(stmt) }

            let columnCount = Int(sqlite3_column_count(stmt))
            if columnCount > 0 {
                var metas: [ColumnMeta] = []
                metas.reserveCapacity(columnCount)
                for i in 0..<columnCount {
                    let name = sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                    let type = sqlite3_column_decltype(stmt, Int32(i)).map { String(cString: $0) } ?? ""
                    metas.append(ColumnMeta(name: name, declaredType: type))
                }
                continuation.yield(.columns(metas))
            }

            var batch: [[BerryValue]] = []
            batch.reserveCapacity(Self.batchSize)
            stepLoop: while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW:
                    batch.append(readRow(stmt, columnCount: columnCount))
                    if batch.count >= Self.batchSize {
                        continuation.yield(.rows(batch))
                        batch.removeAll(keepingCapacity: true)
                        // Yield the actor so cancel/close can slip in between batches.
                        await Task.yield()
                    }
                case SQLITE_DONE:
                    break stepLoop
                default:
                    if !batch.isEmpty { continuation.yield(.rows(batch)) }
                    continuation.finish(throwing: currentError(db))
                    return
                }
            }
            if !batch.isEmpty { continuation.yield(.rows(batch)) }

            let affected: Int64? = columnCount == 0 ? sqlite3_changes64(db) : nil
            continuation.yield(.complete(QueryStats(
                rowsAffected: affected,
                duration: clock.now - started
            )))
        }
        continuation.finish()
    }

    private func readRow(_ stmt: OpaquePointer, columnCount: Int) -> [BerryValue] {
        var row: [BerryValue] = []
        row.reserveCapacity(columnCount)
        for i in 0..<columnCount {
            let col = Int32(i)
            switch sqlite3_column_type(stmt, col) {
            case SQLITE_INTEGER:
                row.append(.int(sqlite3_column_int64(stmt, col)))
            case SQLITE_FLOAT:
                row.append(.double(sqlite3_column_double(stmt, col)))
            case SQLITE_TEXT:
                row.append(.text(String(cString: sqlite3_column_text(stmt, col))))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(stmt, col))
                let data = sqlite3_column_blob(stmt, col).map { Data(bytes: $0, count: count) } ?? Data()
                row.append(.bytes(data))
            default:
                row.append(.null)
            }
        }
        return row
    }

    /// SQLITE_INTERRUPT → `.cancelled` so the conformance suite can classify it.
    private func currentError(_ db: OpaquePointer) -> DriverError {
        let code = sqlite3_errcode(db)
        let message = String(cString: sqlite3_errmsg(db))
        if code == SQLITE_INTERRUPT { return .cancelled }
        return .queryFailed(message: message, code: code)
    }

    // MARK: - Control

    public nonisolated func cancelCurrentQuery() {
        sqlite3_interrupt(handle.db)
    }

    public func setDatabase(_ name: String) async throws {
        throw DriverError.unsupported("SQLite has a single database per connection")
    }

    public nonisolated var introspector: any Introspector {
        SQLiteIntrospector(connection: self)
    }

    public func ping() async -> Bool { !isClosed }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        sqlite3_close_v2(handle.db)
    }

    // MARK: - Internal query for introspection (synchronous, small results)

    func queryAll(_ sql: String, binds: [String] = []) throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        let db = handle.db
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw currentError(db)
        }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        let columnCount = Int(sqlite3_column_count(stmt))
        var rows: [[BerryValue]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: rows.append(readRow(stmt, columnCount: columnCount))
            case SQLITE_DONE: return rows
            default: throw currentError(db)
            }
        }
    }
}
