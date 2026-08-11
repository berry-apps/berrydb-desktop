import Foundation

/// SQL dialect of each DBMS — identifier quoting, LIMIT syntax, and SQL
/// generation for ChangeSet/table designer (docs/architecture/05 §1).
public protocol SQLDialect: Sendable {
    func quoteIdentifier(_ identifier: String) -> String
    /// LIMIT clause appended to the end of a SELECT (auto-LIMIT, ED-12).
    func limitClause(_ limit: Int) -> String
    /// True when this dialect's `limitClause` is only valid on a query that
    /// already has an `ORDER BY` — T-SQL's `OFFSET...FETCH` (SQL Server's
    /// `limitClause`) is a hard syntax error without one, unlike every other
    /// dialect's `LIMIT`. Default `false`; `QueryService.applyAutoLimitIfNeeded`
    /// (ED-12) uses this to inject a no-op `ORDER BY` first instead of
    /// blindly appending `limitClause` to arbitrary SQL text and producing a
    /// broken statement.
    func requiresOrderByForLimit() -> Bool
    /// Boolean literal — SQLite/MySQL use 1/0, Postgres TRUE/FALSE.
    func boolLiteral(_ value: Bool) -> String
    /// Blob literal — X'..' for SQLite/MySQL, '\x..' for Postgres.
    func blobLiteral(_ data: Data) -> String
    /// EXPLAIN prefix (ED-09) — "EXPLAIN QUERY PLAN" on SQLite,
    /// "EXPLAIN [ANALYZE]" elsewhere.
    func explainPrefix(analyze: Bool) -> String
    /// Process/activity list query (TI-01) — nil when unsupported. Columns are
    /// normalized to: pid, user, db, state, query, seconds.
    func processListSQL() -> String?
    /// Statement that terminates a server session by id (TI-01) — nil when
    /// unsupported. `id` must be a server-provided numeric process id.
    func killSessionSQL(id: String) -> String?

    // MARK: User management (TI-03, docs/architecture/14)
    //
    // All nil-when-unsupported, same shape as processListSQL/killSessionSQL —
    // SQLite (no user concept) overrides none of these and gets nil for
    // every one via the default implementations below.

    /// Lists this DBMS's users/roles — nil when unsupported. Columns
    /// normalized to: user, host, superuser, can_login. `host` is NULL for a
    /// DBMS without host-scoped users (Postgres); MySQL populates it.
    func listUsersSQL() -> String?
    /// Creates a new login-capable user — nil when unsupported. `host` is
    /// ignored where the DBMS has no host-scoped users (Postgres); MySQL
    /// defaults to `%` when nil.
    func createUserSQL(username: String, password: String, host: String?) -> String?
    /// Changes an existing user's password — nil when unsupported.
    func alterUserPasswordSQL(username: String, password: String, host: String?) -> String?
    /// Drops a user — nil when unsupported. Can fail server-side if the user
    /// still owns objects; that error is surfaced as-is (no automatic
    /// REASSIGN/DROP OWNED).
    func dropUserSQL(username: String, host: String?) -> String?
    /// Grants a named privilege on `target` (a database name, or a
    /// dialect-native "everything" spelling) to a user — nil when
    /// unsupported. `privilege` is a dialect-native keyword from a curated
    /// picker (e.g. "CONNECT", "ALL PRIVILEGES"), not free text typed by the
    /// end user.
    func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String?
    /// Revokes a named privilege — same shape as `grantSQL`, nil when
    /// unsupported.
    func revokeSQL(privilege: String, on target: String, from username: String, host: String?) -> String?
    /// Lists a user's effective grants — nil when unsupported. Columns
    /// normalized to: target, privilege.
    func listGrantsSQL(for username: String, host: String?) -> String?

    /// Statement that removes every row from `table` but keeps the table
    /// itself (schema, indexes, and on Postgres/MySQL its identity/auto-
    /// increment sequence reset too) — SQLite has no `TRUNCATE` statement,
    /// so its dialect overrides this to `DELETE FROM` instead.
    func truncateSQL(_ table: TableRef) -> String
}

extension SQLDialect {
    public func boolLiteral(_ value: Bool) -> String {
        value ? "TRUE" : "FALSE"
    }

    public func explainPrefix(analyze: Bool) -> String {
        analyze ? "EXPLAIN ANALYZE" : "EXPLAIN"
    }

    public func requiresOrderByForLimit() -> Bool { false }

    public func processListSQL() -> String? { nil }

    public func killSessionSQL(id: String) -> String? { nil }

    public func listUsersSQL() -> String? { nil }
    public func createUserSQL(username: String, password: String, host: String?) -> String? { nil }
    public func alterUserPasswordSQL(username: String, password: String, host: String?) -> String? { nil }
    public func dropUserSQL(username: String, host: String?) -> String? { nil }
    public func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String? { nil }
    public func revokeSQL(privilege: String, on target: String, from username: String, host: String?) -> String? { nil }
    public func listGrantsSQL(for username: String, host: String?) -> String? { nil }

    public func truncateSQL(_ table: TableRef) -> String {
        "TRUNCATE TABLE \(qualifiedName(of: table));"
    }

    /// True when `id` is a bare server process id safe to embed in a KILL /
    /// pg_terminate_backend call (TI-01). The value comes from the pid column
    /// of the process list, but guard defensively anyway.
    public static func isValidSessionID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber)
    }

    public func blobLiteral(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    /// Renders a BerryValue as a safe SQL literal. ChangeSet-generated SQL
    /// (docs/architecture/06 · L3) embeds literals because the driver contract
    /// executes plain SQL; every string goes through '' doubling and every
    /// non-obvious type through a typed renderer — nothing is interpolated raw.
    public func literal(_ value: BerryValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .bool(let b):
            return boolLiteral(b)
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .decimal(let s):
            // DECIMAL arrives verbatim from the DBMS; only pass it back raw
            // when it still looks like a number, otherwise quote defensively.
            let numeric = CharacterSet(charactersIn: "0123456789.+-eE")
            return s.unicodeScalars.allSatisfy { numeric.contains($0) } && !s.isEmpty
                ? s
                : stringLiteral(s)
        case .text(let s), .json(let s):
            return stringLiteral(s)
        case .bytes(let data):
            return blobLiteral(data)
        case .date(let components):
            let y = components.year ?? 0, m = components.month ?? 0, d = components.day ?? 0
            return stringLiteral(String(format: "%04d-%02d-%02d", y, m, d))
        case .timestamp(let date, _):
            return stringLiteral(Self.timestampFormatter.string(from: date))
        case .uuid(let uuid):
            return stringLiteral(uuid.uuidString.lowercased())
        case .unknown(let raw, _):
            return blobLiteral(raw)
        }
    }

    /// Quotes and escapes a plain string as a SQL string literal ('' doubling)
    /// — shared by `literal(_:)` and the TI-03 user-management primitives
    /// (`createUserSQL`/`alterUserPasswordSQL` embed a password this way,
    /// since `DatabaseDriver.execute` takes raw SQL text with no separate
    /// parameter-binding path).
    public func stringLiteral(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

/// Space-separated UTC timestamp accepted by SQLite, Postgres, and MySQL.
private let _timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return formatter
}()

extension SQLDialect {
    static var timestampFormatter: DateFormatter { _timestampFormatter }
}

extension SQLDialect {
    /// SELECT an entire table — the single SQL generation path for the grid (principle N1).
    public func selectAll(from table: TableRef, limit: Int?) -> String {
        select(from: table, whereClause: nil, orderBy: nil, limit: limit)
    }

    /// Grid SELECT with optional user filter and column sort (DL-02).
    /// `whereClause` is a raw user-authored fragment — same trust level as the
    /// SQL editor; `orderBy` column names are quoted by the dialect.
    public func select(
        from table: TableRef,
        whereClause: String?,
        orderBy: (column: String, ascending: Bool)?,
        limit: Int?
    ) -> String {
        var sql = "SELECT * FROM \(qualifiedName(of: table))"
        if let whereClause, !whereClause.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " WHERE \(whereClause)"
        }
        if let orderBy {
            sql += " ORDER BY \(quoteIdentifier(orderBy.column)) \(orderBy.ascending ? "ASC" : "DESC")"
        }
        if let limit { sql += " \(limitClause(limit))" }
        return sql
    }

    public func qualifiedName(of table: TableRef) -> String {
        if let db = table.database {
            return "\(quoteIdentifier(db)).\(quoteIdentifier(table.name))"
        }
        return quoteIdentifier(table.name)
    }
}
