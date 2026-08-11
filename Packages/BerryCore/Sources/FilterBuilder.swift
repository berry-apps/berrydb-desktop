import BerryDriverKit
import Foundation

/// Visual filter builder (DL-02): turns a list of column/operator/value
/// conditions into a WHERE fragment for the grid. Values are emitted as quoted
/// string literals — engines coerce them for numeric comparisons — and every
/// value goes through '' doubling. Anything more expressive (OR, functions,
/// subqueries) still uses the raw WHERE field, which stays the source of truth.
public enum FilterBuilder {
    public enum Operator: String, CaseIterable, Sendable {
        case equals
        case notEquals
        case greater
        case greaterOrEqual
        case less
        case lessOrEqual
        case contains
        case startsWith
        case isNull
        case isNotNull

        /// Operators that compare against a user-entered value.
        public var needsValue: Bool {
            switch self {
            case .isNull, .isNotNull: false
            default: true
            }
        }
    }

    public struct Condition: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var column: String
        public var op: Operator
        public var value: String

        public init(id: UUID = UUID(), column: String, op: Operator = .equals, value: String = "") {
            self.id = id
            self.column = column
            self.op = op
            self.value = value
        }
    }

    /// Render one condition, or nil when it can't form a valid predicate
    /// (no column, or a value operator with an empty value).
    public static func render(_ condition: Condition, dialect: any SQLDialect) -> String? {
        let column = condition.column.trimmingCharacters(in: .whitespaces)
        guard !column.isEmpty else { return nil }
        let ident = dialect.quoteIdentifier(column)

        switch condition.op {
        case .isNull: return "\(ident) IS NULL"
        case .isNotNull: return "\(ident) IS NOT NULL"
        default:
            guard !condition.value.isEmpty else { return nil }
            let escaped = condition.value.replacingOccurrences(of: "'", with: "''")
            switch condition.op {
            case .equals: return "\(ident) = '\(escaped)'"
            case .notEquals: return "\(ident) <> '\(escaped)'"
            case .greater: return "\(ident) > '\(escaped)'"
            case .greaterOrEqual: return "\(ident) >= '\(escaped)'"
            case .less: return "\(ident) < '\(escaped)'"
            case .lessOrEqual: return "\(ident) <= '\(escaped)'"
            case .contains: return "\(ident) LIKE '%\(escaped)%'"
            case .startsWith: return "\(ident) LIKE '\(escaped)%'"
            case .isNull, .isNotNull: return nil   // handled above
            }
        }
    }

    /// Combine every valid condition with AND. Empty when none are valid.
    public static func whereClause(_ conditions: [Condition], dialect: any SQLDialect) -> String {
        conditions.compactMap { render($0, dialect: dialect) }.joined(separator: " AND ")
    }
}
