import Foundation

/// Redacts row values by column name before a result is returned to an MCP
/// client. Matching is by exact, case-insensitive column name — never by
/// substring — and redaction runs only on rows `MCPResultLimiter` keeps;
/// an omitted row's values are never inspected or reported. Every redacted
/// column name is reported in `MCPTruncationMetadata.redactedColumns`, so
/// the caller can tell a value was hidden rather than genuinely absent.
///
/// Redaction by result-column name is best effort, not a boundary: the
/// name it sees is whatever the query labels the column, so an alias
/// (`SELECT email AS x`), an expression over the column, or a whole-row
/// value (`SELECT u FROM users u`) carries a sensitive value past it.
/// Database column privileges on the MCP profile's user are the boundary
/// for sensitive columns.
public struct MCPRedactionPolicy: Sendable {
    private let exact: Set<String>
    private let folded: Set<String>
    public let replacement: String

    public init(exact: Set<String> = [], caseInsensitive: Set<String> = [], replacement: String = "[REDACTED]") {
        self.exact = exact
        self.folded = Set(caseInsensitive.map { $0.lowercased() })
        self.replacement = replacement
    }

    /// Whether a result column named `column` is redacted: an exact match
    /// against the case-sensitive set, or a case-insensitive match against
    /// the other; never a substring match.
    public func shouldRedact(column: String) -> Bool {
        exact.contains(column) || folded.contains(column.lowercased())
    }

    /// Replaces the value of every column in `row` that `shouldRedact`
    /// selects with `replacement` (a NULL value included, so NULL-ness does
    /// not leak), and returns the redacted column names sorted, for
    /// reporting.
    public func redact(_ row: [String: String?]) -> (row: [String: String?], columns: [String]) {
        var result = row
        let columns = row.keys.filter(shouldRedact).sorted()
        for column in columns { result[column] = replacement }
        return (result, columns)
    }
}
