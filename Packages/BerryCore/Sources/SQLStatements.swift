import BerryDriverKit

/// Dialect-specific statement/command keywords for autocompletion (ED-13).
/// Generic statements (SELECT, transactions, DDL, SHOW/ANALYZE…) live in
/// `CompletionProvider.keywords`; this holds only commands unique to one engine,
/// so completion matches the connected DBMS.
public enum SQLStatements {
    public static func statements(for driver: DriverID) -> [String] {
        switch driver {
        case .sqlite: sqlite
        case .postgres: postgres
        case .mysql: mysql
        default: []
        }
    }

    private static let sqlite = [
        "PRAGMA", "VACUUM", "REINDEX", "ATTACH DATABASE", "DETACH DATABASE",
        "ANALYZE", "EXPLAIN QUERY PLAN",
    ]

    private static let postgres = [
        "VACUUM", "VACUUM ANALYZE", "COPY", "CLUSTER", "REINDEX", "LISTEN",
        "NOTIFY", "RESET", "CREATE EXTENSION", "SET SEARCH_PATH", "COMMENT ON",
    ]

    private static let mysql = [
        "USE", "SHOW TABLES", "SHOW DATABASES", "SHOW COLUMNS", "SHOW INDEX",
        "SHOW CREATE TABLE", "SHOW STATUS", "SHOW VARIABLES", "ANALYZE TABLE",
        "OPTIMIZE TABLE", "CHECK TABLE", "REPAIR TABLE", "FLUSH", "LOCK TABLES",
        "UNLOCK TABLES",
    ]
}
