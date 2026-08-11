import Foundation

/// `ChangeSet` (BerryCore, untouched — out of scope to modify per
/// docs/architecture/12 task scope) always generates INSERT as
/// `INSERT INTO <table> ("col1", "col2") VALUES (<lit1>, <lit2>)` — valid
/// generic SQL, but NOT valid DynamoDB PartiQL. Verified against
/// dynamodb-local: that exact shape is rejected with
/// `ValidationException: Statement wasn't well formed`. DynamoDB PartiQL only
/// supports `INSERT INTO <table> VALUE {'col1': lit1, 'col2': lit2}`
/// (singular VALUE, a map/tuple literal — docs/architecture/12 §4).
///
/// This rewriter recognizes ChangeSet's exact deterministic shape (it fully
/// controls what `quoteIdentifier`/`literal` produce, so the shape is known
/// precisely) and translates it into the tuple form DynamoDB accepts. Any
/// statement that doesn't match this exact pattern — including a
/// hand-written `INSERT INTO t VALUE {...}` typed directly into the SQL
/// editor — passes through completely unchanged.
enum PartiQLInsertRewriter {
    static func rewrite(_ sql: String) -> String {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("INSERT INTO ") else { return sql }

        var rest = trimmed[trimmed.index(trimmed.startIndex, offsetBy: "INSERT INTO ".count)...]
        guard let table = consumeIdentifier(&rest) else { return sql }
        rest = consumeWhitespace(rest)
        guard rest.first == "(" else { return sql }
        rest = rest.dropFirst()
        guard let (columnsText, afterColumns) = consumeBalanced(rest) else { return sql }

        rest = consumeWhitespace(afterColumns)
        guard rest.uppercased().hasPrefix("VALUES") else { return sql }
        rest = consumeWhitespace(rest.dropFirst("VALUES".count))
        guard rest.first == "(" else { return sql }
        rest = rest.dropFirst()
        guard let (valuesText, afterValues) = consumeBalanced(rest) else { return sql }
        guard consumeWhitespace(afterValues).isEmpty else { return sql }

        let columns = splitTopLevel(columnsText).map(unquoteIdentifier)
        let values = splitTopLevel(valuesText)
        guard columns.count == values.count, !columns.isEmpty else { return sql }

        let tuple = zip(columns, values).map { "\(singleQuoted($0)): \($1)" }.joined(separator: ", ")
        return "INSERT INTO \(table) VALUE {\(tuple)}"
    }

    // MARK: - Small hand scanner over the deterministic ChangeSet shape

    private static func consumeWhitespace(_ s: Substring) -> Substring {
        var s = s
        while let first = s.first, first.isWhitespace { s = s.dropFirst() }
        return s
    }

    /// Consumes one `"quoted identifier"` (`""` doubling for an embedded
    /// quote) from the front of `s`, returning the source text INCLUDING
    /// quotes (e.g. `"Music"`), with `s` advanced past it.
    private static func consumeIdentifier(_ s: inout Substring) -> String? {
        guard s.first == "\"" else { return nil }
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if s[i] == "\"" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "\"" { i = s.index(after: next); continue }
                let result = String(s[s.startIndex...i])
                s = s[s.index(after: i)...]
                return result
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Consumes content up to (and including) the `)` matching an opening
    /// `(` the caller already stripped — tracks quote state so a `)` or `,`
    /// inside a `'...'`/`"..."` literal doesn't confuse the depth count.
    /// Returns (content before the closing paren, remainder after it).
    private static func consumeBalanced(_ s: Substring) -> (String, Substring)? {
        var depth = 1
        var inSingle = false
        var inDouble = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if inSingle {
                if c == "'" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "'" { i = s.index(after: next); continue }
                    inSingle = false
                }
            } else if inDouble {
                if c == "\"" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == "\"" { i = s.index(after: next); continue }
                    inDouble = false
                }
            } else {
                switch c {
                case "'": inSingle = true
                case "\"": inDouble = true
                case "(": depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 {
                        return (String(s[s.startIndex..<i]), s[s.index(after: i)...])
                    }
                default: break
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Splits on top-level commas only — same quote-awareness as `consumeBalanced`,
    /// so a value like `'Hello, World'` is not split mid-string.
    private static func splitTopLevel(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingle {
                current.append(c)
                if c == "'" {
                    if i + 1 < chars.count, chars[i + 1] == "'" { current.append(chars[i + 1]); i += 2; continue }
                    inSingle = false
                }
            } else if inDouble {
                current.append(c)
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { current.append(chars[i + 1]); i += 2; continue }
                    inDouble = false
                }
            } else if c == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                if c == "'" { inSingle = true }
                if c == "\"" { inDouble = true }
                current.append(c)
            }
            i += 1
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    private static func unquoteIdentifier(_ quoted: String) -> String {
        guard quoted.hasPrefix("\""), quoted.hasSuffix("\""), quoted.count >= 2 else { return quoted }
        return quoted.dropFirst().dropLast().replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// PartiQL tuple keys are single-quoted strings (docs/architecture/12
    /// §4) — same `''` escaping rule as PartiQL string literals generally.
    private static func singleQuoted(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
