import Foundation

/// Decides whether an editor's query result maps back to a single table's rows,
/// so the grid can offer in-place editing. Only
/// a plain `SELECT … FROM <table>` qualifies — a join, grouping, DISTINCT,
/// UNION, aggregate/function projection, or subquery breaks the 1:1 row→table
/// mapping and keeps the result read-only.
public enum EditableSelect {
    private static let re: NSRegularExpression.Options = [.caseInsensitive]

    /// The base table name when the statement is a simple single-table SELECT,
    /// else nil. The name may be schema-qualified or quoted — the caller matches
    /// it against the known objects.
    public static func baseTable(for sql: String) -> String? {
        var statement = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") {
            statement = String(statement.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !statement.contains(";") else { return nil } // one statement only

        let flat = statement
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        guard flat.range(of: "^\\s*select\\b", options: [.regularExpression, .caseInsensitive]) != nil,
              let selectRange = flat.range(of: "\\bselect\\b", options: [.regularExpression, .caseInsensitive]),
              let fromRange = flat.range(of: "\\bfrom\\b", options: [.regularExpression, .caseInsensitive]),
              selectRange.upperBound <= fromRange.lowerBound
        else { return nil }

        // Set operations combine rows from multiple selects — never editable.
        if flat.range(of: "\\b(union|except|intersect)\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }

        // Projection between SELECT and FROM: a function/aggregate or DISTINCT
        // means the rows aren't raw table rows.
        let projection = flat[selectRange.upperBound..<fromRange.lowerBound].lowercased()
        if projection.contains("(") || projection.contains("distinct") { return nil }

        // FROM clause up to the next clause keyword.
        let afterFrom = flat[fromRange.upperBound...]
        let boundary = afterFrom.range(
            of: "\\b(where|order|group|limit|having|union|window|offset)\\b",
            options: [.regularExpression, .caseInsensitive]
        )
        let fromClause = String(boundary.map { afterFrom[..<$0.lowerBound] } ?? afterFrom)
            .trimmingCharacters(in: .whitespaces)

        // A single plain table — no comma (multi-table), subquery, or JOIN.
        if fromClause.isEmpty || fromClause.contains(",") || fromClause.contains("(")
            || fromClause.range(of: "\\bjoin\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }

        // Keep only the table token (drop a trailing alias like "users u").
        let token = fromClause.split(separator: " ").first.map(String.init) ?? fromClause
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"`[]"))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Like `baseTable`, but additionally requires an edit-safe projection:
    /// `*` or bare (possibly quoted) column names. An alias ("id AS x") would
    /// make the grid stage updates against a column that doesn't exist.
    public static func editableTable(for sql: String) -> String? {
        guard let table = baseTable(for: sql) else { return nil }
        let flat = sql.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard let selectRange = flat.range(of: "\\bselect\\b", options: [.regularExpression, .caseInsensitive]),
              let fromRange = flat.range(of: "\\bfrom\\b", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let projection = flat[selectRange.upperBound..<fromRange.lowerBound]
        for segment in projection.split(separator: ",") {
            let item = segment.trimmingCharacters(in: .whitespaces)
            if item == "*" { continue }
            // A bare identifier has no internal whitespace (no alias) —
            // quoted identifiers with spaces stay editable.
            let unquoted = item.trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            let isQuoted = item.hasPrefix("\"") || item.hasPrefix("`")
            if !isQuoted, item.contains(where: \.isWhitespace) { return nil }
            if unquoted.isEmpty { return nil }
        }
        return table
    }
}
