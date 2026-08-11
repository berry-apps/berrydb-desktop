import BerryDriverKit
import CFreeTDS
import Foundation

/// The raw `DBPROCESS` pointer, wrapped so it can be stored on a `nonisolated
/// let` inside the actor below (`OpaquePointer` needs a `Sendable` wrapper to
/// cross the actor boundary at all — see `SQLServerRuntime.open`'s own doc
/// comment on why it returns this type instead of a raw pointer).
final class SQLServerHandle: @unchecked Sendable {
    let dbproc: OpaquePointer
    init(dbproc: OpaquePointer) { self.dbproc = dbproc }
}

public actor SQLServerConnection: DriverConnection {
    public nonisolated let id = UUID()
    nonisolated let handle: SQLServerHandle
    private let config: ConnectionConfig
    private var isClosed = false

    /// N3 (docs/architecture/04 §4): 500 rows per batch.
    static let batchSize = 500

    public init(config: ConnectionConfig) async throws {
        guard let host = config.host, !host.isEmpty else {
            throw DriverError.connectionFailed("Missing host")
        }
        self.config = config
        let handle = try await SQLServerRuntime.shared.open(
            host: host, port: config.port ?? 1433,
            username: config.username ?? "sa", password: config.password ?? "",
            appName: "BerryDB"
        )
        self.handle = handle
        let dbproc = handle.dbproc

        if let database = config.database, !database.isEmpty {
            try Self.runCommand(dbproc, "USE \(SQLServerDialect().quoteIdentifier(database))")
        }
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
        let dbproc = handle.dbproc

        SQLServerErrorBox.shared.clear(dbproc: dbproc)
        dbcmd(dbproc, sql)
        guard dbsqlexec(dbproc) == SUCCEED else {
            continuation.finish(throwing: Self.currentError(dbproc))
            return
        }

        var totalAffected: Int64 = 0
        var resultSetIndex: Int32 = 0
        while true {
            resultSetIndex = dbresults(dbproc)
            if resultSetIndex == NO_MORE_RESULTS {
                break
            }
            guard resultSetIndex == SUCCEED else {
                continuation.finish(throwing: Self.currentError(dbproc))
                return
            }

            let columnCount = Int(dbnumcols(dbproc))
            if columnCount > 0 {
                var metas: [ColumnMeta] = []
                metas.reserveCapacity(columnCount)
                for i in 1...columnCount {
                    let name = dbcolname(dbproc, Int32(i)).map { String(cString: $0) } ?? "col\(i)"
                    let typeCode = dbcoltype(dbproc, Int32(i))
                    metas.append(ColumnMeta(name: name, declaredType: Self.typeName(typeCode)))
                }
                continuation.yield(.columns(metas))

                var batch: [[BerryValue]] = []
                batch.reserveCapacity(Self.batchSize)
                rowLoop: while true {
                    let rc = dbnextrow(dbproc)
                    switch rc {
                    case Int32(REG_ROW):
                        var row: [BerryValue] = []
                        row.reserveCapacity(columnCount)
                        for i in 1...columnCount {
                            row.append(Self.berryValue(dbproc, column: Int32(i)))
                        }
                        batch.append(row)
                        if batch.count >= Self.batchSize {
                            continuation.yield(.rows(batch))
                            batch.removeAll(keepingCapacity: true)
                            await Task.yield()
                        }
                    case Int32(NO_MORE_ROWS):
                        break rowLoop
                    default:
                        // A buffered/computed row id — not a plain data row
                        // (e.g. a compute-by-row from an old-style query).
                        // Not produced by any statement this app generates;
                        // skip rather than fail the whole result set.
                        continue rowLoop
                    }
                }
                if !batch.isEmpty { continuation.yield(.rows(batch)) }
            } else {
                let affected = dbcount(dbproc)
                if affected >= 0 { totalAffected += Int64(affected) }
            }
        }

        continuation.yield(.complete(QueryStats(
            rowsAffected: totalAffected > 0 ? totalAffected : nil,
            duration: clock.now - started
        )))
        continuation.finish()
    }

    // MARK: - Value mapping

    /// SYBCHAR/VARCHAR/TEXT decode directly (already text bytes); fixed-width
    /// numeric types decode directly from their known TDS wire layout;
    /// everything else (money, numeric/decimal, datetime, binary,
    /// uniqueidentifier) goes through `dbconvert()` to SYBCHAR — FreeTDS's
    /// own, already-correct conversion logic, instead of hand-rolling TDS's
    /// binary decimal/datetime encodings here.
    static func berryValue(_ dbproc: OpaquePointer, column: Int32) -> BerryValue {
        guard let data = dbdata(dbproc, column) else { return .null }
        let len = dbdatlen(dbproc, column)
        guard len > 0 else { return .null }
        let type = dbcoltype(dbproc, column)

        // FreeTDS's SYB* type constants (sybdb.h) import as plain `Int`
        // (unnamed C enum), not `Int32` — `dbcoltype` itself returns `int`
        // (imported as `Int32`), hence the conversion here.
        switch Int(type) {
        case SYBCHAR, SYBVARCHAR, SYBTEXT:
            let bytes = Array(UnsafeBufferPointer(start: data, count: Int(len)))
            return .text(String(decoding: bytes, as: UTF8.self))
        case SYBBIT, SYBBITN:
            return .bool(data.pointee != 0)
        case SYBINT1:
            return .int(Int64(data.pointee))
        case SYBINT2:
            return .int(Int64(data.withMemoryRebound(to: Int16.self, capacity: 1) { $0.pointee }))
        case SYBINT4:
            return .int(Int64(data.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }))
        case SYBINT8:
            return .int(data.withMemoryRebound(to: Int64.self, capacity: 1) { $0.pointee })
        case SYBFLT8:
            return .double(data.withMemoryRebound(to: Double.self, capacity: 1) { $0.pointee })
        case SYBREAL:
            return .double(Double(data.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }))
        case SYBBINARY, SYBVARBINARY, SYBIMAGE:
            return .bytes(Data(bytes: data, count: Int(len)))
        case SYBMONEY, SYBMONEY4, SYBMONEYN, SYBNUMERIC, SYBDECIMAL:
            return .decimal(convertToString(data, len: len, srcType: type) ?? "")
        case SYBDATETIME:
            return .timestamp(Self.decodeDateTime(data), hasTimezone: false)
        case SYBDATETIME4:
            return .timestamp(Self.decodeSmallDateTime(data), hasTimezone: false)
        default:
            let bytes = Data(bytes: data, count: Int(len))
            return .unknown(raw: bytes, typeName: typeName(type))
        }
    }

    /// Converts a raw column value to text using DB-Library's own
    /// `dbconvert` — the safe way to render types (money, numeric/decimal,
    /// datetime) whose on-wire binary layout this driver doesn't decode by
    /// hand.
    private static func convertToString(_ data: UnsafeMutablePointer<UInt8>, len: DBINT, srcType: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 64)
        let written = buffer.withUnsafeMutableBufferPointer { dest -> DBINT in
            dbconvert(nil, srcType, data, len, Int32(SYBCHAR), dest.baseAddress, DBINT(dest.count))
        }
        guard written > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
    }

    /// The TDS `1900-01-01` epoch, computed once — every DATETIME/SMALLDATETIME
    /// decode below is an offset from this instant.
    private static let tdsEpoch: Date = {
        var components = DateComponents()
        components.year = 1900; components.month = 1; components.day = 1
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    /// TDS `DATETIME` (SYBDATETIME) wire format, 8 bytes: a signed 32-bit
    /// little-endian day count since 1900-01-01 (can be negative for dates
    /// before 1900), followed by an unsigned 32-bit little-endian count of
    /// 1/300-second ticks since midnight. Decoded directly rather than via
    /// `dbconvert`'s text format — confirmed via a real conformance test
    /// failure that the text format is locale/version-sensitive
    /// (double-spaced single-digit days, `HH:MM:SS:mmmAM/PM` rather than the
    /// assumed `HH:MMAM/PM`) and not worth chasing when the binary layout is
    /// simple and exactly documented.
    private static func decodeDateTime(_ data: UnsafeMutablePointer<UInt8>) -> Date {
        let days = data.withMemoryRebound(to: Int32.self, capacity: 2) { $0[0] }
        let ticks = data.withMemoryRebound(to: UInt32.self, capacity: 2) { $0[1] }
        let seconds = Double(days) * 86400 + Double(ticks) / 300.0
        return tdsEpoch.addingTimeInterval(seconds)
    }

    /// TDS `SMALLDATETIME` (SYBDATETIME4), 4 bytes: unsigned 16-bit
    /// little-endian day count since 1900-01-01, followed by unsigned 16-bit
    /// little-endian minutes since midnight (no seconds — smalldatetime's
    /// own resolution).
    private static func decodeSmallDateTime(_ data: UnsafeMutablePointer<UInt8>) -> Date {
        let days = data.withMemoryRebound(to: UInt16.self, capacity: 2) { $0[0] }
        let minutes = data.withMemoryRebound(to: UInt16.self, capacity: 2) { $0[1] }
        let seconds = Double(days) * 86400 + Double(minutes) * 60
        return tdsEpoch.addingTimeInterval(seconds)
    }

    private static func typeName(_ type: Int32) -> String {
        switch Int(type) {
        case SYBCHAR: "char"
        case SYBVARCHAR: "varchar"
        case SYBTEXT: "text"
        case SYBBIT, SYBBITN: "bit"
        case SYBINT1: "tinyint"
        case SYBINT2: "smallint"
        case SYBINT4: "int"
        case SYBINT8: "bigint"
        case SYBFLT8: "float"
        case SYBREAL: "real"
        case SYBBINARY: "binary"
        case SYBVARBINARY: "varbinary"
        case SYBIMAGE: "image"
        case SYBMONEY, SYBMONEY4, SYBMONEYN: "money"
        case SYBNUMERIC: "numeric"
        case SYBDECIMAL: "decimal"
        case SYBDATETIME, SYBDATETIME4: "datetime"
        default: "unknown(\(type))"
        }
    }

    static func currentError(_ dbproc: OpaquePointer) -> DriverError {
        .queryFailed(message: SQLServerErrorBox.shared.take(dbproc: dbproc) ?? "Unknown SQL Server error", code: nil)
    }

    // MARK: - Control

    /// No-op — `capabilities.cancelQuery == false` (see `SQLServerDriver`'s
    /// comment for the full story: a real, reproduced-multiple-times
    /// deadlock, not a guess). Two candidate mechanisms were tried and
    /// rejected:
    /// 1. `dbcancel()`/TDS "attention" on the SAME `DBPROCESS` from a second
    ///    thread while the actor's task is blocked inside `dbsqlexec()` —
    ///    DB-Library's own documented contract only guarantees "one thread
    ///    per DBPROCESS," so this was never attempted.
    /// 2. A secondary connection issuing `KILL <spid>` (the same pattern
    ///    `PostgresDriverConnection` uses for `pg_cancel_backend`) — this WAS
    ///    implemented and tested against a real Dockerized SQL Server, and
    ///    reproducibly deadlocked the process on every attempt (confirmed via
    ///    a minimal, dependency-free standalone repro outside Swift Testing,
    ///    not just inside the test suite) as soon as a second `DBPROCESS` was
    ///    opened from a different thread while the first was blocked in a
    ///    long-running query. This driver's `execute()` runs blocking
    ///    DB-Library calls directly (no async I/O to suspend on), so even a
    ///    client-side-only `Task.cancel()` (SQLite/DynamoDB's fallback
    ///    pattern) would not actually interrupt the in-flight blocking call —
    ///    it would just stop delivering results after the call eventually
    ///    returns on its own, which is not a real cancel.
    public nonisolated func cancelCurrentQuery() {}

    /// SQL Server can switch databases on the same connection via `USE`,
    /// unlike Postgres (which requires a reconnect — see
    /// `PostgresDriverConnection.setDatabase`).
    public func setDatabase(_ name: String) async throws {
        guard !isClosed else { throw DriverError.notConnected }
        try Self.runCommand(handle.dbproc, "USE \(SQLServerDialect().quoteIdentifier(name))")
    }

    public nonisolated var introspector: any Introspector {
        SQLServerIntrospector(connection: self)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        return (try? Self.queryScalarInt(handle.dbproc, "SELECT 1")) != nil
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        dbclose(handle.dbproc)
    }

    // MARK: - Internal query for introspection (synchronous, small results)

    func queryAll(_ sql: String) async throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        return try Self.queryAll(handle.dbproc, sql)
    }

    private static func queryAll(_ dbproc: OpaquePointer, _ sql: String) throws -> [[BerryValue]] {
        SQLServerErrorBox.shared.clear(dbproc: dbproc)
        dbcmd(dbproc, sql)
        guard dbsqlexec(dbproc) == SUCCEED else { throw currentError(dbproc) }
        guard dbresults(dbproc) == SUCCEED else { throw currentError(dbproc) }

        let columnCount = Int(dbnumcols(dbproc))
        var rows: [[BerryValue]] = []
        while dbnextrow(dbproc) == Int32(REG_ROW) {
            var row: [BerryValue] = []
            row.reserveCapacity(columnCount)
            for i in 1...columnCount {
                row.append(berryValue(dbproc, column: Int32(i)))
            }
            rows.append(row)
        }
        // Drain any further result sets so the connection is clean for the
        // next command (DB-Library requires the current command's results to
        // be fully consumed before issuing another).
        while dbresults(dbproc) != NO_MORE_RESULTS {}
        return rows
    }

    private static func runCommand(_ dbproc: OpaquePointer, _ sql: String) throws {
        SQLServerErrorBox.shared.clear(dbproc: dbproc)
        dbcmd(dbproc, sql)
        guard dbsqlexec(dbproc) == SUCCEED else { throw currentError(dbproc) }
        while dbresults(dbproc) != NO_MORE_RESULTS {}
    }

    private static func queryScalarInt(_ dbproc: OpaquePointer, _ sql: String) throws -> Int32 {
        let rows = try queryAll(dbproc, sql)
        guard case .int(let value)? = rows.first?.first else {
            throw DriverError.queryFailed(message: "Expected a scalar integer result from: \(sql)", code: nil)
        }
        return Int32(value)
    }
}
