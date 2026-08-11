import BerryDriverKit

/// Built-in function names per engine for completion (docs/ui P1.4). Static
/// lists — common, high-traffic functions, not exhaustive references.
public enum SQLBuiltins {
    /// Shared ANSI-ish core every engine supports.
    private static let common = [
        "COALESCE", "NULLIF", "CAST", "ABS", "ROUND", "LENGTH", "LOWER",
        "UPPER", "TRIM", "LTRIM", "RTRIM", "REPLACE", "SUBSTR",
    ]

    private static let sqlite = [
        "DATE", "TIME", "DATETIME", "STRFTIME", "JULIANDAY", "UNIXEPOCH",
        "IFNULL", "INSTR", "HEX", "QUOTE", "RANDOM", "TYPEOF", "TOTAL",
        "GROUP_CONCAT", "JSON", "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY",
        "JSON_EACH", "LAST_INSERT_ROWID", "CHANGES", "PRINTF",
    ]

    private static let postgres = [
        "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "AGE", "DATE_TRUNC",
        "DATE_PART", "EXTRACT", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP",
        "TO_NUMBER", "CONCAT", "CONCAT_WS", "SPLIT_PART", "POSITION",
        "STRING_AGG", "ARRAY_AGG", "ARRAY_LENGTH", "UNNEST", "GENERATE_SERIES",
        "JSONB_BUILD_OBJECT", "JSONB_AGG", "JSON_BUILD_OBJECT", "JSONB_SET",
        "JSONB_EXTRACT_PATH", "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG",
        "LEAD", "FIRST_VALUE", "LAST_VALUE", "GREATEST", "LEAST", "RANDOM",
        "GEN_RANDOM_UUID", "MD5", "LEFT", "RIGHT", "LPAD", "RPAD", "INITCAP",
        "REGEXP_REPLACE", "REGEXP_MATCHES",
    ]

    // pgvector functions (pgvector extension) — offered on Postgres since the
    // extension speaks the normal Postgres protocol.
    private static let pgvector = [
        "L2_DISTANCE", "COSINE_DISTANCE", "INNER_PRODUCT", "L1_DISTANCE",
        "VECTOR_DIMS", "VECTOR_NORM", "L2_NORMALIZE", "BINARY_QUANTIZE",
        "SUBVECTOR", "HAMMING_DISTANCE", "JACCARD_DISTANCE",
    ]

    // TimescaleDB hyperfunctions (Postgres extension).
    private static let timescale = [
        "TIME_BUCKET", "TIME_BUCKET_GAPFILL", "FIRST", "LAST", "LOCF",
        "INTERPOLATE", "HISTOGRAM", "APPROX_PERCENTILE", "TIME_WEIGHT",
        "COUNTER_AGG", "STATS_AGG", "CANDLESTICK_AGG",
    ]

    private static let mysql = [
        "NOW", "CURDATE", "CURTIME", "DATE_FORMAT", "STR_TO_DATE", "DATEDIFF",
        "DATE_ADD", "DATE_SUB", "TIMESTAMPDIFF", "UNIX_TIMESTAMP",
        "FROM_UNIXTIME", "CONCAT", "CONCAT_WS", "SUBSTRING_INDEX", "LOCATE",
        "GROUP_CONCAT", "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY",
        "JSON_UNQUOTE", "JSON_CONTAINS", "ROW_NUMBER", "RANK", "DENSE_RANK",
        "LAG", "LEAD", "IFNULL", "IF", "GREATEST", "LEAST", "RAND", "UUID",
        "MD5", "SHA2", "LEFT", "RIGHT", "LPAD", "RPAD", "LAST_INSERT_ID",
        "REGEXP_REPLACE", "FORMAT",
    ]

    // MySQL 9 VECTOR functions — the VECTOR type + these ship on the normal
    // MySQL protocol, so they're offered on any MySQL connection.
    private static let mysqlVector = [
        "VEC_FROMTEXT", "VEC_TOTEXT", "VEC_DIMS", "DISTANCE",
    ]

    public static func functions(for driver: DriverID) -> [String] {
        switch driver {
        case .sqlite: return common + sqlite
        // pgvector + TimescaleDB are Postgres extensions; harmless to offer even
        // when not installed (they just won't resolve server-side).
        case .postgres: return common + postgres + pgvector + timescale
        case .mysql: return common + mysql + mysqlVector
        default: return common
        }
    }
}
