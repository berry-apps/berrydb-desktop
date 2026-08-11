import BerryDriverKit
import Foundation

public struct SQLiteDriver: DatabaseDriver {
    public static let id: DriverID = .sqlite
    public static let displayName = "SQLite"

    // Capability matrix: docs/architecture/05 §4.
    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: true,          // sqlite3_interrupt
        multipleDatabases: false,   // attach considered later
        schemas: false,
        explain: true,
        processList: false,
        serverSideCursor: false,    // in-process, not needed
        keyValueBrowser: false
    )

    public static let dialect: any SQLDialect = SQLiteDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let path = config.filePath else {
            throw DriverError.connectionFailed("Missing SQLite file path")
        }
        return try SQLiteConnection(path: path)
    }
}

public struct SQLiteDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func limitClause(_ limit: Int) -> String {
        "LIMIT \(limit)"
    }

    public func boolLiteral(_ value: Bool) -> String {
        value ? "1" : "0"
    }

    /// SQLite's readable plan variant; plain EXPLAIN dumps VM opcodes.
    public func explainPrefix(analyze: Bool) -> String {
        "EXPLAIN QUERY PLAN"
    }

    /// SQLite has no `TRUNCATE TABLE` statement — `DELETE FROM` with no
    /// WHERE clause is its equivalent (SQLite's own query planner already
    /// takes the fast "truncate optimization" path for this exact shape).
    public func truncateSQL(_ table: TableRef) -> String {
        "DELETE FROM \(quoteIdentifier(table.name));"
    }
}
