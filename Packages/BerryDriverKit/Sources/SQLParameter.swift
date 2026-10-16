import Foundation

/// A value bound to a positional placeholder of a read-only statement:
/// `$1`, `$2`, … on PostgreSQL and `?` on MySQL, MariaDB and SQLite. Bound by
/// the driver, never spliced into the text, so a value can never change
/// what the statement is.
public enum SQLParameter: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case text(String)
}
