import BerryDriverKit
import Foundation

/// `DatabaseDriver` for SQL Server via FreeTDS DB-Library (docs/architecture/05
/// §4, V2⚠️) — the one deliberate exception to this app's pure-Swift/no-FFI
/// rule (Q8). Bridges to FreeTDS (LGPL, dynamically linked) because TDS has no
/// REST/JSON surface to reuse the way DynamoDB/Qdrant do, and no
/// production-viable pure-Swift TDS implementation exists yet — see
/// docs/architecture/16-sql-server.md for the researched alternatives and why
/// each was rejected.
public struct SQLServerDriver: DatabaseDriver {
    public static let id: DriverID = .sqlserver
    public static let displayName = "SQL Server"

    // Capability matrix: docs/architecture/05 §4 "SQL Server (V2⚠️)" column —
    // kept in lockstep with that table EXCEPT cancelQuery, which the table
    // assumed (✅ "attention signal") before this driver actually existed.
    public static let capabilities = Capabilities(
        transactions: true,
        // ❌, contradicting docs/architecture/05 §4's original assumption —
        // a real finding, not a guess. FreeTDS DB-Library's `execute()` runs
        // fully BLOCKING calls (no async I/O to suspend/interrupt), and the
        // one candidate mechanism (a secondary connection issuing
        // `KILL <spid>`, the same pattern `PostgresDriverConnection` uses)
        // was implemented, tested against a real Dockerized SQL Server, and
        // reproducibly DEADLOCKED the process every time — confirmed via a
        // minimal standalone repro outside the test suite, not just a flaky
        // test. See `SQLServerConnection.cancelCurrentQuery()`'s doc comment
        // for the full investigation. Revisit only with real evidence a safe
        // mechanism exists — this doc comment is exactly the kind of
        // "record the reasoning" CLAUDE.md asks for before re-attempting
        // something already tried and reverted.
        cancelQuery: false,
        multipleDatabases: true,    // USE <db> on the same connection
        schemas: true,
        explain: true,              // SET SHOWPLAN_XML ON — see SQLServerDialect.explainPrefix
        processList: true,
        serverSideCursor: true,
        keyValueBrowser: false,
        userManagement: true
    )

    public static let dialect: any SQLDialect = SQLServerDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await SQLServerConnection(config: config)
    }
}

public struct SQLServerDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "[" + identifier.replacingOccurrences(of: "]", with: "]]") + "]"
    }

    /// `OFFSET...FETCH` (SQL Server 2012+), not `TOP N` — `TOP` is a PREFIX
    /// (`SELECT TOP N * FROM t`), which cannot be expressed through this
    /// method's suffix-only contract (`QueryService.applyAutoLimitIfNeeded`
    /// does plain string concatenation onto the end of the SQL text — see
    /// that file). `OFFSET...FETCH` requires a preceding `ORDER BY`, unlike
    /// every other dialect's `LIMIT` — see `requiresOrderByForLimit()`.
    public func limitClause(_ limit: Int) -> String {
        "OFFSET 0 ROWS FETCH NEXT \(limit) ROWS ONLY"
    }

    public func requiresOrderByForLimit() -> Bool { true }

    public func blobLiteral(_ data: Data) -> String {
        "0x" + data.map { String(format: "%02x", $0) }.joined()
    }

    /// `SET SHOWPLAN_XML ON` is a session-state toggle applied BEFORE the
    /// statement, not a text prefix on the statement itself the way
    /// `EXPLAIN`/`EXPLAIN ANALYZE` are for Postgres/MySQL/SQLite — SQL
    /// Server's actual plan-XML output requires running that SET, then the
    /// original statement, THEN `SET SHOWPLAN_XML OFF` (the statement does
    /// NOT execute while SHOWPLAN_XML is on — it returns the plan instead of
    /// results). This doesn't fit `explainPrefix(analyze:) -> String`'s
    /// single-string-prefix shape at all; returning a prefix here would
    /// silently produce a broken/no-op EXPLAIN rather than a real plan.
    /// `capabilities.explain` stays `true` per the architecture doc's matrix,
    /// but the UI-level EXPLAIN feature (ED-09) needs its own SQL-Server-aware
    /// multi-statement path — tracked as a known v1 gap, not implemented here.
    public func explainPrefix(analyze: Bool) -> String {
        "SET SHOWPLAN_XML ON;\n-- BerryDB: SQL Server's plan output needs a multi-statement SET/run/SET sequence, not a text prefix — see SQLServerDialect.explainPrefix's doc comment. This EXPLAIN is a known v1 gap."
    }

    /// Normalized columns: pid, user, db, state, query, seconds (TI-01).
    /// Excludes our own session so the user never kills the viewing
    /// connection. `sys.dm_exec_sql_text` needs `CROSS APPLY` since it's a
    /// table-valued function keyed by `sql_handle`, not a plain join column.
    public func processListSQL() -> String? {
        """
        SELECT r.session_id AS pid, s.login_name AS user, DB_NAME(r.database_id) AS db,
               r.status AS state, t.text AS query,
               DATEDIFF(SECOND, r.start_time, GETDATE()) AS seconds
        FROM sys.dm_exec_requests r
        JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
        CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
        WHERE r.session_id <> @@SPID AND t.text IS NOT NULL
        ORDER BY r.start_time DESC
        """
    }

    public func killSessionSQL(id: String) -> String? {
        guard Self.isValidSessionID(id) else { return nil }
        return "KILL \(id)"
    }

    // MARK: User management (TI-03) — SQL Server logins are server-level
    // (like Postgres roles, not host-scoped like MySQL) — `host` is ignored.

    public func listUsersSQL() -> String? {
        """
        SELECT name AS user, NULL AS host, IS_SRVROLEMEMBER('sysadmin', name) AS superuser,
               CASE WHEN is_disabled = 0 THEN 1 ELSE 0 END AS can_login
        FROM sys.sql_logins
        WHERE name NOT LIKE '##%'
        ORDER BY name
        """
    }

    public func createUserSQL(username: String, password: String, host: String?) -> String? {
        "CREATE LOGIN \(quoteIdentifier(username)) WITH PASSWORD = \(stringLiteral(password))"
    }

    public func alterUserPasswordSQL(username: String, password: String, host: String?) -> String? {
        "ALTER LOGIN \(quoteIdentifier(username)) WITH PASSWORD = \(stringLiteral(password))"
    }

    public func dropUserSQL(username: String, host: String?) -> String? {
        "DROP LOGIN \(quoteIdentifier(username))"
    }

    /// v1 grant scope, matching Postgres/MySQL's own curated common-grant
    /// set (docs/architecture/14 §Deferred): server-level roles only
    /// (`sysadmin`, `dbcreator`, etc. — `privilege` here IS the role name),
    /// not per-database/per-table GRANT statements.
    public func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String? {
        "ALTER SERVER ROLE \(quoteIdentifier(privilege)) ADD MEMBER \(quoteIdentifier(username))"
    }

    public func revokeSQL(privilege: String, on target: String, from username: String, host: String?) -> String? {
        "ALTER SERVER ROLE \(quoteIdentifier(privilege)) DROP MEMBER \(quoteIdentifier(username))"
    }

    public func listGrantsSQL(for username: String, host: String?) -> String? {
        """
        SELECT sr.name AS target, 'server role' AS privilege
        FROM sys.server_role_members srm
        JOIN sys.server_principals sr ON sr.principal_id = srm.role_principal_id
        JOIN sys.server_principals m ON m.principal_id = srm.member_principal_id
        WHERE m.name = \(stringLiteral(username))
        ORDER BY sr.name
        """
    }
}
