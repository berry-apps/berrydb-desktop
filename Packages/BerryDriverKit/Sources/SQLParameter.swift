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

extension DriverError {
    /// A statement refused before it runs because it was given a different
    /// number of parameters than it has placeholders. A `queryFailed` with
    /// no server code, so a caller handles it as any other failed
    /// statement, worded the same by every driver that counts.
    public static func placeholderCountMismatch(placeholders: Int, parameters: Int) -> DriverError {
        let has = placeholders == 1 ? "1 placeholder" : "\(placeholders) placeholders"
        let given = parameters == 1 ? "1 parameter was given" : "\(parameters) parameters were given"
        return .queryFailed(message: "The statement has \(has) and \(given).", code: nil)
    }
}
