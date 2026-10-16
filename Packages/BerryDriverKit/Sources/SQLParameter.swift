import Foundation

/// A value bound to a positional placeholder of a read-only statement. Bound
/// by the driver, never spliced into the text, so a value can never change
/// what the statement is. Each driver sends it its own way:
///
/// - PostgreSQL, `$1`, `$2`, …: as text with no type, which the server reads
///   as the type the placeholder's place in the statement gives it
///   (https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PARSE).
///   A placeholder with nothing around it to give it a type is read as
///   text, and needs a cast where text does not fit (`$1::int8 + $2`); a
///   parameter the statement does not use fails it. Verified against
///   PostgreSQL 16.15.
/// - MySQL and MariaDB, `?`: as a typed binary value of the prepared
///   statement protocol
///   (https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_stmt_execute.html):
///   text as VAR_STRING, an integer as LONGLONG, a double as DOUBLE and a
///   boolean as an unsigned TINY of 1 or 0 (MySQLNIO 1.9.1, `MySQLData`).
/// - SQLite, `?` or `?1`, `?2`, …: in its own storage classes, a boolean as
///   the integer 1 or 0, since SQLite has no boolean type
///   (https://www.sqlite.org/datatype3.html#boolean_datatype). A named
///   placeholder is refused, because SQLite numbers it by where it first
///   appears, and so is a `?NNN` numbering that skips a number, which
///   leaves a parameter bound to nothing
///   (https://www.sqlite.org/c3ref/bind_blob.html).
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
