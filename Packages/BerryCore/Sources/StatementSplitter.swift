import Foundation

/// Splits an SQL script into statements (run statement at cursor /
/// selection / whole file). Understands enough lexical structure to never
/// split inside: 'strings' (with '' escape), "quoted identifiers",
/// `backtick identifiers`, $$ dollar-quoted bodies $$ (incl. $tag$…$tag$),
/// -- line comments and /* block comments */.
///
/// This is intentionally lexical, not a parser — the network drivers run one
/// statement per execute, and this is the seam
/// that feeds them.
public enum StatementSplitter {
    public struct Statement: Equatable, Sendable {
        public let sql: String
        /// Range in the original script (UTF-16 offsets, matching NSText*).
        public let range: NSRange
    }

    public static func split(_ script: String) -> [Statement] {
        var statements: [Statement] = []
        let chars = Array(script.utf16)
        let scalars = Array(script.unicodeScalars)
        // Work on unicode scalars for logic, track utf16 offsets for ranges.
        var i = 0
        var statementStart = 0
        var utf16Offset = 0
        var statementStartUTF16 = 0

        func utf16Width(_ scalar: Unicode.Scalar) -> Int {
            scalar.value > 0xFFFF ? 2 : 1
        }

        func appendStatement(endScalar: Int, endUTF16: Int) {
            let slice = String(String.UnicodeScalarView(scalars[statementStart..<endScalar]))
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Tighten the range to the trimmed statement.
                let leading = String(slice.prefix(while: { $0.isWhitespace || $0.isNewline })).utf16.count
                let trailing = String(slice.reversed().prefix(while: { $0.isWhitespace || $0.isNewline })).utf16.count
                statements.append(Statement(
                    sql: trimmed,
                    range: NSRange(
                        location: statementStartUTF16 + leading,
                        length: (endUTF16 - statementStartUTF16) - leading - trailing
                    )
                ))
            }
            statementStart = endScalar
            statementStartUTF16 = endUTF16
        }

        func peek(_ offset: Int) -> Unicode.Scalar? {
            i + offset < scalars.count ? scalars[i + offset] : nil
        }

        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "'", "\"", "`":
                // Quoted region: scan to the matching close; '' escapes inside '.
                let quote = c
                utf16Offset += utf16Width(c); i += 1
                while i < scalars.count {
                    let q = scalars[i]
                    utf16Offset += utf16Width(q); i += 1
                    if q == quote {
                        if quote == "'" && peek(0) == "'" {
                            utf16Offset += 1; i += 1   // escaped ''
                        } else {
                            break
                        }
                    }
                }
            case "-" where peek(1) == "-":
                while i < scalars.count, scalars[i] != "\n" {
                    utf16Offset += utf16Width(scalars[i]); i += 1
                }
            case "/" where peek(1) == "*":
                utf16Offset += 2; i += 2
                while i < scalars.count {
                    if scalars[i] == "*" && peek(1) == "/" {
                        utf16Offset += 2; i += 2
                        break
                    }
                    utf16Offset += utf16Width(scalars[i]); i += 1
                }
            case "$":
                // Dollar-quoting: $tag$ … $tag$ (Postgres). Find the opener tag.
                var j = i + 1
                while j < scalars.count,
                      scalars[j] == "_" || CharacterSet.alphanumerics.contains(scalars[j]) {
                    j += 1
                }
                if j < scalars.count, scalars[j] == "$" {
                    let tag = scalars[i...j]
                    let tagLength = tag.count
                    // Advance past opener.
                    for k in i...j { utf16Offset += utf16Width(scalars[k]) }
                    i = j + 1
                    // Scan for the identical closer.
                    while i < scalars.count {
                        if scalars[i] == "$", i + tagLength <= scalars.count,
                           Array(scalars[i..<(i + tagLength)]) == Array(tag) {
                            for k in i..<(i + tagLength) { utf16Offset += utf16Width(scalars[k]) }
                            i += tagLength
                            break
                        }
                        utf16Offset += utf16Width(scalars[i]); i += 1
                    }
                } else {
                    utf16Offset += utf16Width(c); i += 1
                }
            case ";":
                appendStatement(endScalar: i, endUTF16: utf16Offset)
                // Skip the semicolon itself.
                utf16Offset += 1; i += 1
                statementStart = i
                statementStartUTF16 = utf16Offset
            default:
                utf16Offset += utf16Width(c); i += 1
            }
        }
        appendStatement(endScalar: scalars.count, endUTF16: utf16Offset)
        _ = chars
        return statements
    }

 /// Statement containing the cursor (⌘↩). Falls back to the last
    /// statement before the cursor when the cursor sits between statements.
    public static func statement(at utf16Cursor: Int, in script: String) -> Statement? {
        let all = split(script)
        if let hit = all.first(where: { NSLocationInRange(utf16Cursor, $0.range) || utf16Cursor == $0.range.upperBound }) {
            return hit
        }
        return all.last(where: { $0.range.upperBound <= utf16Cursor }) ?? all.first
    }
}
