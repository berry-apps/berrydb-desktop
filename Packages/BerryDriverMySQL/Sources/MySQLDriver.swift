import BerryDriverKit
import Foundation
import MySQLNIO

public struct MySQLDriver: DatabaseDriver {
    public static let id: DriverID = .mysql
    public static let displayName = "MySQL / MariaDB"

    // Capability matrix: docs/architecture/05 §4.
    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: true,          // KILL QUERY <id> on a secondary connection
        multipleDatabases: true,    // database = schema in MySQL
        schemas: false,
        explain: true,
        processList: true,
        serverSideCursor: false,
        keyValueBrowser: false,
        userManagement: true
    )

    public static let dialect: any SQLDialect = MySQLDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await MySQLDriverConnection(config: config)
    }
}

public struct MySQLDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    public func limitClause(_ limit: Int) -> String {
        "LIMIT \(limit)"
    }

    public func boolLiteral(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    public func processListSQL() -> String? {
        // Normalized columns: pid, user, db, state, query, seconds (TI-01).
        """
        SELECT Id AS pid, User AS user, db AS db, State AS state,
               Info AS query, Time AS seconds
        FROM information_schema.PROCESSLIST
        ORDER BY Time DESC
        """
    }

    public func killSessionSQL(id: String) -> String? {
        guard Self.isValidSessionID(id) else { return nil }
        return "KILL \(id)"
    }

    // MARK: User management (TI-03) — MySQL identity is `'user'@'host'`;
    // `host` defaults to `%` (any host) when nil, matching the common case.

    public func listUsersSQL() -> String? {
        """
        SELECT User AS user, Host AS host, (Super_priv = 'Y') AS superuser,
               (account_locked = 'N') AS can_login
        FROM mysql.user
        WHERE User NOT IN ('mysql.sys', 'mysql.session', 'mysql.infoschema')
        ORDER BY User, Host
        """
    }

    public func createUserSQL(username: String, password: String, host: String?) -> String? {
        let at = quotedUserAt(username, host)
        return "CREATE USER \(at) IDENTIFIED BY \(stringLiteral(password))"
    }

    public func alterUserPasswordSQL(username: String, password: String, host: String?) -> String? {
        let at = quotedUserAt(username, host)
        return "ALTER USER \(at) IDENTIFIED BY \(stringLiteral(password))"
    }

    public func dropUserSQL(username: String, host: String?) -> String? {
        "DROP USER \(quotedUserAt(username, host))"
    }

    public func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String? {
        "GRANT \(privilege) ON \(quoteIdentifier(target)).* TO \(quotedUserAt(username, host))"
    }

    public func revokeSQL(privilege: String, on target: String, from username: String, host: String?) -> String? {
        "REVOKE \(privilege) ON \(quoteIdentifier(target)).* FROM \(quotedUserAt(username, host))"
    }

    public func listGrantsSQL(for username: String, host: String?) -> String? {
        // information_schema, not SHOW GRANTS, to match the shared
        // "target, privilege" column contract every dialect normalizes to
        // (SHOW GRANTS returns one free-text "GRANT ... ON ... TO ..." column
        // instead). GRANTEE is stored pre-formatted as "'user'@'host'"
        // (quotes included in the value) — build that exact string, then
        // let stringLiteral escape IT for use as the comparison literal.
        let grantee = "'\(username)'@'\(host?.isEmpty == false ? host! : "%")'"
        return """
        SELECT TABLE_SCHEMA AS target, PRIVILEGE_TYPE AS privilege
        FROM information_schema.SCHEMA_PRIVILEGES
        WHERE GRANTEE = \(stringLiteral(grantee))
        ORDER BY TABLE_SCHEMA, PRIVILEGE_TYPE
        """
    }

    /// `'user'@'host'` — single-quoted per MySQL's own account-name literal
    /// syntax (distinct from backtick-quoted identifiers). Reuses
    /// `stringLiteral`'s '' escaping since the same injection risk applies.
    private func quotedUserAt(_ username: String, _ host: String?) -> String {
        "\(stringLiteral(username))@\(stringLiteral(host?.isEmpty == false ? host! : "%"))"
    }
}
