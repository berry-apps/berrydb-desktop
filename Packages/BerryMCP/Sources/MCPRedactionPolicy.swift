import Foundation

/// Redacts row values by column name before a result is returned to an MCP
/// client. Matching is by exact, case-insensitive column name — never by
/// substring — and redaction runs only on rows `MCPResultLimiter` keeps;
/// an omitted row's values are never inspected or reported. Every redacted
/// column name is reported in `MCPTruncationMetadata.redactedColumns`, so
/// the caller can tell a value was hidden rather than genuinely absent.
public struct MCPRedactionPolicy: Sendable {
    private let exact: Set<String>
    private let folded: Set<String>
    public let replacement: String

    public init(exact: Set<String> = [], caseInsensitive: Set<String> = [], replacement: String = "[REDACTED]") {
        self.exact = exact
        self.folded = Set(caseInsensitive.map { $0.lowercased() })
        self.replacement = replacement
    }

    public func shouldRedact(column: String) -> Bool {
        exact.contains(column) || folded.contains(column.lowercased())
    }

    public func redact(_ row: [String: String?]) -> (row: [String: String?], columns: [String]) {
        var result = row
        let columns = row.keys.filter(shouldRedact).sorted()
        for column in columns { result[column] = replacement }
        return (result, columns)
    }
}
