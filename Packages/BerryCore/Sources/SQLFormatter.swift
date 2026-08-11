import Foundation

/// Lightweight SQL pretty-printer (ED-08). Token-based, dialect-agnostic:
/// puts major clauses on their own lines, indents parenthesised groups, and
/// preserves strings/comments/identifiers verbatim. Not a full reformatter —
/// it makes hand-written and generated SQL readable without reordering logic.
public enum SQLFormatter {
    private static let newlineBefore: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "ORDER", "HAVING", "LIMIT",
        "OFFSET", "UNION", "INSERT", "UPDATE", "DELETE", "SET", "VALUES",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "ON",
        "RETURNING", "WITH",
    ]
    private static let uppercaseKeywords: Set<String> = {
        var set = newlineBefore
        set.formUnion([
            "AND", "OR", "NOT", "AS", "IN", "IS", "NULL", "LIKE", "BETWEEN",
            "DISTINCT", "INTO", "CREATE", "ALTER", "DROP", "TABLE", "VIEW",
            "INDEX", "BY", "ASC", "DESC", "OUTER",
        ])
        return set
    }()

    /// Multi-character operators that must tokenize as ONE token — splitting
    /// e.g. `>=` into `> =` or `::` into `: :` corrupts the SQL so it no longer
    /// executes. Longest-match first (`->>` before `->`).
    private static let operators: [String] = [
        "->>", "#>>", "!~*",
        "->", ">=", "<=", "<>", "!=", "||", "::", ":=",
        "<<", ">>", "@>", "<@", "&&", "#>", "?|", "?&", "~*", "!~",
    ]

    /// Operators that bind tightly — no surrounding spaces (cast, JSON path).
    private static let tightOperators: Set<String> = ["::", "->", "->>", "#>", "#>>"]

    public static func format(_ sql: String) -> String {
        let tokens = tokenize(sql)
        guard !tokens.isEmpty else {
            return sql.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var output = ""
        var indent = 0
        var atLineStart = true
        var previous = ""

        func newline(extra: Int = 0) {
            output += "\n" + String(repeating: "    ", count: max(indent + extra, 0))
            atLineStart = true
        }

        for token in tokens {
            let upper = token.uppercased()

            if token == "," {
                output += ","
                previous = ","
                // Indent a top-level list (the SELECT/GROUP BY columns) one step
                // under its clause so columns don't sit flush with the keywords.
                // Items already inside parentheses keep the paren's indent.
                newline(extra: indent == 0 ? 1 : 0)
                continue
            }

            // Clause heads (SELECT/FROM/WHERE/JOIN…) break onto their own line,
            // but keep "LEFT JOIN"/"GROUP BY" adjacency.
            if newlineBefore.contains(upper), upper != "BY", !atLineStart, !output.isEmpty {
                let joinModifiers: Set<String> = ["LEFT", "RIGHT", "INNER", "FULL", "CROSS", "OUTER"]
                if !(upper == "JOIN" && joinModifiers.contains(previous.uppercased())) {
                    newline()
                }
            }

            switch token {
            case "(":
                if !atLineStart, spaceBeforeParen(previous) { output += " " }
                output += "("
                indent += 1
            case ")":
                indent -= 1
                output += ")"
            default:
                if !atLineStart, !output.isEmpty, spaceBetween(previous, token) {
                    output += " "
                }
                output += render(token, upper: upper)
            }
            atLineStart = false
            previous = token
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func render(_ token: String, upper: String) -> String {
        // Keep quoted identifiers, strings, comments, numbers, operators as-is.
        if let first = token.first, "'\"`$".contains(first) || first == "-" || first == "/" {
            return token
        }
        if uppercaseKeywords.contains(upper) { return upper }
        return token
    }

    /// Space before `(`: none after a function name (`count(`), but a space after
    /// a keyword (`IN (`, `VALUES (`).
    private static func spaceBeforeParen(_ previous: String) -> Bool {
        if previous.isEmpty || previous == "(" { return false }
        return uppercaseKeywords.contains(previous.uppercased())
    }

    /// Whether a space goes between two adjacent tokens.
    private static func spaceBetween(_ previous: String, _ current: String) -> Bool {
        if previous == "(" { return false }               // no space after (
        if current == ")" || current == ";" { return false }
        if tightOperators.contains(previous) || tightOperators.contains(current) { return false }
        return true
    }

    /// Tokenizer preserving strings, comments, dollar-quotes; punctuation
    /// `( ) ,` and multi-char operators become their own tokens.
    static func tokenize(_ sql: String) -> [String] {
        var tokens: [String] = []
        let scalars = Array(sql.unicodeScalars)
        var i = 0

        func isWord(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(s) || s == "_" || s == "." || s == "*"
        }

        while i < scalars.count {
            let c = scalars[i]
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
                continue
            }
            switch c {
            case "'", "\"", "`":
                let quote = c
                var token = String(c)
                i += 1
                while i < scalars.count {
                    token.unicodeScalars.append(scalars[i])
                    let ch = scalars[i]
                    i += 1
                    if ch == quote {
                        if quote == "'", i < scalars.count, scalars[i] == "'" {
                            token.unicodeScalars.append(scalars[i]); i += 1; continue
                        }
                        break
                    }
                }
                tokens.append(token)
            case "-" where i + 1 < scalars.count && scalars[i + 1] == "-":
                var token = ""
                while i < scalars.count, scalars[i] != "\n" {
                    token.unicodeScalars.append(scalars[i]); i += 1
                }
                tokens.append(token)
            case "/" where i + 1 < scalars.count && scalars[i + 1] == "*":
                var token = "/*"
                i += 2
                while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") {
                    token.unicodeScalars.append(scalars[i]); i += 1
                }
                token += "*/"; i = min(i + 2, scalars.count)
                tokens.append(token)
            case "(", ")", ",", ";":
                tokens.append(String(c)); i += 1
            default:
                if isWord(c) {
                    var token = ""
                    while i < scalars.count, isWord(scalars[i]) {
                        token.unicodeScalars.append(scalars[i]); i += 1
                    }
                    tokens.append(token)
                } else if let op = matchOperator(scalars, at: i) {
                    // Multi-char operator (>=, ::, ->>, || …) kept intact.
                    tokens.append(op); i += op.unicodeScalars.count
                } else {
                    // Single-char operator / other punctuation.
                    tokens.append(String(c)); i += 1
                }
            }
        }
        return tokens
    }

    /// Longest known multi-char operator starting at `i`, or nil.
    private static func matchOperator(_ scalars: [Unicode.Scalar], at i: Int) -> String? {
        for op in operators {
            let opScalars = Array(op.unicodeScalars)
            if i + opScalars.count <= scalars.count,
               Array(scalars[i ..< i + opScalars.count]) == opScalars {
                return op
            }
        }
        return nil
    }
}
