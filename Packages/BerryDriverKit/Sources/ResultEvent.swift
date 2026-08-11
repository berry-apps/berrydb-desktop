import Foundation

/// Metadata for one column of a result set.
public struct ColumnMeta: Sendable, Hashable {
    public let name: String
    /// Type name declared by the DBMS (may be empty for computed expressions).
    public let declaredType: String

    public init(name: String, declaredType: String) {
        self.name = name
        self.declaredType = declaredType
    }
}

/// Statistics after a statement finishes running.
public struct QueryStats: Sendable {
    public let rowsAffected: Int64?
    public let duration: Duration

    public init(rowsAffected: Int64?, duration: Duration) {
        self.rowsAffected = rowsAffected
        self.duration = duration
    }
}

/// Result stream event — docs/architecture/05 §1.
/// Every kind of statement returns this stream (DDL/DML only emit `.complete`).
public enum ResultEvent: Sendable {
    case columns([ColumnMeta])
    /// Batches of 500–1000 rows (principle N3 — stream first, buffer later).
    case rows([[BerryValue]])
    case complete(QueryStats)
}
