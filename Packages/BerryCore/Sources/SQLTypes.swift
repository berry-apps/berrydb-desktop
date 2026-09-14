import BerryDriverKit

/// Column type names offered in the table designer picker, per engine.
/// The type field stays free-text (any DBMS type works); this list is the
/// convenience menu, now dialect-aware so pgvector/jsonb/enum/unsigned/… show up
/// for the right database instead of one generic list.
public enum SQLTypes {
    public static func types(for driver: DriverID) -> [String] {
        switch driver {
        case .sqlite: sqlite
        case .postgres: postgres
        case .mysql: mysql
        default: generic
        }
    }

    private static let generic = [
        "INTEGER", "BIGINT", "TEXT", "VARCHAR(255)", "REAL", "NUMERIC",
        "BOOLEAN", "DATE", "TIMESTAMP", "BLOB", "JSON", "UUID",
    ]

    private static let sqlite = [
        "INTEGER", "REAL", "TEXT", "BLOB", "NUMERIC", "BOOLEAN",
        "DATE", "DATETIME",
    ]

    private static let postgres = [
        "integer", "bigint", "smallint", "serial", "bigserial",
        "numeric(10,2)", "real", "double precision", "money",
        "text", "varchar(255)", "char(10)", "boolean",
        "date", "time", "timestamp", "timestamptz", "interval",
        "uuid", "json", "jsonb", "bytea",
        "inet", "cidr", "macaddr", "tsvector",
        "vector", "vector(1536)", "halfvec", // pgvector — AI/embedding
        "integer[]", "text[]", "geometry", "geography",
    ]

    private static let mysql = [
        "int", "int unsigned", "bigint", "bigint unsigned", "smallint",
        "mediumint", "tinyint(1)", "decimal(10,2)", "float", "double",
        "char(10)", "varchar(255)", "text", "mediumtext", "longtext",
        "date", "datetime", "timestamp", "time", "year", "boolean",
        "json", "enum('a','b')", "set('a','b')",
        "blob", "mediumblob", "longblob", "binary(16)", "varbinary(255)",
        "geometry", "point",
    ]
}
