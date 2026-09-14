import BerryDriverKit
import Foundation
import PostgresNIO

public struct PostgresDriver: DatabaseDriver {
    public static let id: DriverID = .postgres
    public static let displayName = "PostgreSQL"

 // Capability matrix:
    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: true,          // pg_cancel_backend on a secondary connection
        multipleDatabases: true,
        schemas: true,
        explain: true,
        processList: true,
        serverSideCursor: true,
        keyValueBrowser: false,
        userManagement: true
    )

    public static let dialect: any SQLDialect = PostgresDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await PostgresDriverConnection(config: config)
    }
}

public struct PostgresDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func limitClause(_ limit: Int) -> String {
        "LIMIT \(limit)"
    }

 /// Adds BUFFERS to the default ANALYZE prefix
 /// — buffer hit/read counts land as extra detail lines under each
    /// plan node, which `ExplainTreeParser`'s indented-text parser already
    /// handles generically (no parser changes needed). Plain EXPLAIN is
    /// unaffected (still the default from `SQLDialect`).
    public func explainPrefix(analyze: Bool) -> String {
        analyze ? "EXPLAIN (ANALYZE, BUFFERS)" : "EXPLAIN"
    }

    public func blobLiteral(_ data: Data) -> String {
        "'\\x" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    public func processListSQL() -> String? {
 // Normalized columns: pid, user, db, state, query, seconds.
        // Excludes our own backend so the user never kills the viewing session.
        """
        SELECT pid, usename AS user, datname AS db, state, query,
               EXTRACT(EPOCH FROM (now() - query_start))::int AS seconds
        FROM pg_stat_activity
        WHERE pid <> pg_backend_pid() AND query IS NOT NULL
        ORDER BY query_start DESC NULLS LAST
        """
    }

    public func killSessionSQL(id: String) -> String? {
        guard Self.isValidSessionID(id) else { return nil }
        return "SELECT pg_terminate_backend(\(id))"
    }

 // MARK: User management — roles are global (not per-database);
    // a login-capable role is what this app calls a "user". `host` is
    // ignored: Postgres roles have no host-scoping concept.

    public func listUsersSQL() -> String? {
        """
        SELECT rolname AS user, NULL AS host, rolsuper AS superuser, rolcanlogin AS can_login
        FROM pg_roles
        WHERE rolname NOT LIKE 'pg\\_%'
        ORDER BY rolname
        """
    }

    public func createUserSQL(username: String, password: String, host: String?) -> String? {
        "CREATE ROLE \(quoteIdentifier(username)) WITH LOGIN PASSWORD \(stringLiteral(password))"
    }

    public func alterUserPasswordSQL(username: String, password: String, host: String?) -> String? {
        "ALTER ROLE \(quoteIdentifier(username)) WITH PASSWORD \(stringLiteral(password))"
    }

    public func dropUserSQL(username: String, host: String?) -> String? {
        "DROP ROLE \(quoteIdentifier(username))"
    }

    public func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String? {
        "GRANT \(privilege) ON DATABASE \(quoteIdentifier(target)) TO \(quoteIdentifier(username))"
    }

    public func revokeSQL(privilege: String, on target: String, from username: String, host: String?) -> String? {
        "REVOKE \(privilege) ON DATABASE \(quoteIdentifier(target)) FROM \(quoteIdentifier(username))"
    }

    public func listGrantsSQL(for username: String, host: String?) -> String? {
        """
        SELECT datname AS target, privilege_type AS privilege
        FROM pg_database, aclexplode(coalesce(datacl, acldefault('d', datdba))) AS acl
        JOIN pg_roles ON pg_roles.oid = acl.grantee
        WHERE pg_roles.rolname = \(stringLiteral(username))
        ORDER BY datname, privilege_type
        """
    }
}
