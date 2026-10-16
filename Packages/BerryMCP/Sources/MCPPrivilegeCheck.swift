import BerryDriverKit
import Foundation

/// What a database role could change, found before a user turns live reads
/// on: each finding is a category, never a grant line.
public enum MCPPrivilegeCheck {
    /// Runs the check on `connection`, which the caller opened for this
    /// check alone and closes afterwards: the MySQL check runs SET ROLE ALL,
    /// which changes the session. Empty for drivers without roles to check
    /// (SQLite); every other driver throws.
    public static func findings(on connection: any DriverConnection, driver: DriverID) async throws -> [String] {
        switch driver {
        case .postgres:
            let rows = try await collect(connection.execute(postgresQuery))
            return try postgresFindings(row: rows.first?.first)
        case .mysql:
            return try await mysqlFindings(on: connection)
        case .sqlite:
            // A SQLite database is a file with no accounts or roles.
            return []
        default:
            // An empty result means "verified read-only", so a driver the
            // check cannot inspect must fail rather than look clean.
            throw DriverError.unsupported("The privilege check covers PostgreSQL, MySQL and MariaDB.")
        }
    }

    /// The checks are documented, with the reasoning behind each condition,
    /// in `docs/mcp-server-compatibility.md` (section "Exact checks used");
    /// the two must change together. One row, one column: the failed
    /// conditions as a comma list, or NULL when none failed. Verified against
    /// PostgreSQL 16.15.
    static let postgresQuery = """
SELECT string_agg(reason, ',' ORDER BY reason) FROM (
SELECT 'superuser' AS reason WHERE (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
UNION ALL SELECT 'rds_superuser' WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_superuser')
  AND pg_has_role(current_user, 'rds_superuser', 'MEMBER')
UNION ALL SELECT 'owner' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND pg_has_role(current_user, c.relowner, 'MEMBER'))
UNION ALL SELECT 'table_write' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
  AND has_table_privilege(current_user, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE'))
UNION ALL SELECT 'column_write' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
  AND has_any_column_privilege(current_user, c.oid, 'INSERT,UPDATE'))
UNION ALL SELECT 'schema_create' WHERE EXISTS (SELECT 1 FROM pg_namespace n
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND has_schema_privilege(current_user, n.oid, 'CREATE'))
UNION ALL SELECT 'db_create' WHERE has_database_privilege(current_user, current_database(), 'CREATE')
UNION ALL SELECT 'sequence_usage' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind = 'S'
  AND has_sequence_privilege(current_user, c.oid, 'USAGE,UPDATE'))
UNION ALL SELECT 'setrole_writer' WHERE EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
  WHERE pg_has_role(current_user, m.roleid, 'MEMBER') AND r.rolname <> current_user
  AND (r.rolsuper OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
     AND (has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(r.oid, c.oid, 'INSERT,UPDATE')))))
) x;
"""

    /// The query, an aggregate without GROUP BY, answers one row: NULL for a
    /// role with no findings and text otherwise (verified against
    /// PostgreSQL 16.15). Any other answer throws rather than reading as no
    /// findings, which would report a role that can write as one that
    /// cannot.
    static func postgresFindings(row: BerryValue?) throws -> [String] {
        switch row {
        case let .text(list)?: return list.split(separator: ",").map(String.init)
        case .null?: return []
        default: throw unreadableAnswer
        }
    }

    private static let unreadableAnswer = DriverError.unsupported(
        "The privilege check could not read the database's answer."
    )

    /// Privilege names that read data and nothing else; every other name on a
    /// grant line is a write, a schema change or an administrative right.
    private static let readOnlyPrivileges: Set<String> = ["SELECT", "SHOW VIEW", "USAGE"]

    static func mysqlFindings(grantLines: [String]) -> [String] {
        var found: Set<String> = []
        for line in grantLines {
            guard let privileges = privilegeList(ofGrantLine: line) else { continue }
            for name in splitOutsideParentheses(privileges) {
                let privilege = withoutColumnList(name).uppercased()
                if !privilege.isEmpty, !readOnlyPrivileges.contains(privilege) { found.insert(privilege) }
            }
            // The option is matched anywhere in the line, not only at its end:
            // MariaDB 11.8.9 follows it with the account's resource limits on
            // a global grant line (SHOW GRANTS printed `GRANT SELECT ON *.* TO
            // ... WITH GRANT OPTION MAX_QUERIES_PER_HOUR 10`), while MySQL
            // 8.4.11 ended the same line with the option.
            if line.uppercased().contains(" WITH GRANT OPTION") {
                found.insert("GRANT OPTION")
            }
        }
        return found.sorted()
    }

    /// The text between `GRANT ` and the first ` ON ` outside parentheses, or
    /// nil for a line that grants no privileges (a role-membership line,
    /// `GRANT <role> TO <account>`, has no ` ON `).
    private static func privilegeList(ofGrantLine line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.uppercased().hasPrefix("GRANT ") else { return nil }
        let body = text.dropFirst("GRANT ".count)
        var depth = 0
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
            if depth == 0, character == " ", body[index...].uppercased().hasPrefix(" ON ") {
                return String(body[..<index])
            }
            index = body.index(after: index)
        }
        return nil
    }

    private static func splitOutsideParentheses(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 } else if character == ")" { depth = max(0, depth - 1) }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func withoutColumnList(_ privilege: String) -> String {
        guard let open = privilege.firstIndex(of: "(") else { return privilege }
        return privilege[..<open].trimmingCharacters(in: .whitespaces)
    }

    private static func mysqlFindings(on connection: any DriverConnection) async throws -> [String] {
        var rolesNotChecked = false
        do {
            _ = try await collect(connection.execute("SET ROLE ALL"))
        } catch {
            // Verified against MariaDB 11.8.9: SET ROLE ALL fails with a syntax error
            // ("You have an error in your SQL syntax ... near 'ALL' at line 1").
            // MariaDB lists roles as membership lines instead, which are not
            // expanded, so a write granted through a role is not seen.
            rolesNotChecked = true
        }
        let grants = try await collect(connection.execute(
            rolesNotChecked ? "SHOW GRANTS" : "SHOW GRANTS FOR CURRENT_USER()"
        ))
        // A line that cannot be read could hold any privilege, so it throws
        // instead of being left out of the findings.
        let lines = try grants.map { row in
            guard let line = row.first.flatMap(text(of:)) else { throw unreadableAnswer }
            return line
        }
        var found = mysqlFindings(grantLines: lines)
        if rolesNotChecked, lines.contains(where: isRoleMembershipLine) {
            found.append("roles_not_checked")
        }
        return found
    }

    private static func isRoleMembershipLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.uppercased().hasPrefix("GRANT ") && privilegeList(ofGrantLine: text) == nil
    }

    private static func text(of value: BerryValue) -> String? {
        switch value {
        case let .text(string): string
        case let .bytes(data): String(data: data, encoding: .utf8)
        default: nil
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }
}
