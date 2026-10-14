/// The statements a read-only connection runs: a text whose first word,
/// after whitespace and comments, is one a read starts with. The server's
/// read-only mode refuses a write wherever it occurs inside a statement, but
/// some statements change the mode or end the read-only transaction before
/// they write, such as a procedure call, a PostgreSQL `DO` block or a
/// MariaDB compound statement; each `ReadOnlyExecuting` driver says which
/// ones it has seen. Everything else is refused before the server sees it.
///
/// The comment rules follow each server's own scanner, because a comment
/// read differently would let the first word this check sees differ from the
/// first word the server runs.
public struct ReadOnlyAllowlist: Sendable {
    /// The first words of the statements that run, in the order the refusal
    /// lists them.
    let leads: [String]
    /// `#` starts a comment to the end of the line.
    let hashComments: Bool
    /// `--` starts a comment only before whitespace or a control character.
    let dashCommentNeedsSpace: Bool
    /// A carriage return ends a `--` comment, not only a line feed.
    let carriageReturnEndsComment: Bool
    /// A `/*` inside a block comment opens a nested one.
    let nestedBlockComments: Bool
    /// `/*!` and `/*M!` run their text as SQL wherever they appear.
    let executableComments: Bool

    private static let readLeads = ["SELECT", "WITH", "SHOW", "EXPLAIN", "TABLE", "VALUES"]

    /// `--` ends at a line feed or a carriage return and block comments nest
    /// (https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-COMMENTS);
    /// verified against PostgreSQL 16.15, where `-- x` followed by a
    /// carriage return and `SELECT 1` returns 1.
    public static let postgres = ReadOnlyAllowlist(
        leads: readLeads, hashComments: false, dashCommentNeedsSpace: false,
        carriageReturnEndsComment: true, nestedBlockComments: true, executableComments: false
    )

    /// `#` and `-- ` comments end at a line feed alone, block comments do
    /// not nest, and an executable comment runs its text
    /// (https://dev.mysql.com/doc/refman/8.4/en/comments.html,
    /// https://mariadb.com/kb/en/comment-syntax/). Verified against MySQL
    /// 8.4.11 and MariaDB 11.8.9, where MariaDB also runs `/*M!` and reads
    /// `/*m!` as a plain comment.
    public static let mysql = ReadOnlyAllowlist(
        leads: readLeads + ["DESCRIBE", "DESC"], hashComments: true, dashCommentNeedsSpace: true,
        carriageReturnEndsComment: false, nestedBlockComments: false, executableComments: true
    )

    /// `--` ends at a line feed alone, block comments do not nest, and an
    /// unterminated one runs to the end of the text
    /// (https://www.sqlite.org/lang_comment.html); verified against SQLite
    /// 3.51.0.
    public static let sqlite = ReadOnlyAllowlist(
        leads: readLeads, hashComments: false, dashCommentNeedsSpace: false,
        carriageReturnEndsComment: false, nestedBlockComments: false, executableComments: false
    )

    /// Nil when `sql` may run on a read-only connection; otherwise the error
    /// the statement finishes with, without running. A failed query with no
    /// server code, like the SQLite read-only path's refusal of a text of
    /// several statements.
    public func refusal(of sql: String) -> DriverError? {
        let bytes = Array(sql.utf8)
        if executableComments, Self.containsExecutableComment(bytes) {
            return .queryFailed(
                message: "The read-only connection does not run a text with an executable comment (/*! or /*M!).",
                code: nil
            )
        }
        if let word = firstWord(of: bytes), leads.contains(word) { return nil }
        let listed = leads.dropLast().joined(separator: ", ") + " or " + (leads.last ?? "")
        return .queryFailed(message: "The read-only connection runs only a statement that starts with \(listed).", code: nil)
    }

    private static func containsExecutableComment(_ bytes: [UInt8]) -> Bool {
        let bang = Array("/*!".utf8)
        let mariaDB = Array("/*M!".utf8)
        for start in bytes.indices {
            if bytes[start...].starts(with: bang) || bytes[start...].starts(with: mariaDB) { return true }
        }
        return false
    }

    /// The first word of `bytes` in upper case, or nil when the text holds
    /// none or starts with something else. A word is a run of ASCII letters,
    /// digits, `_`, `$` and non-ASCII bytes, so a word that only begins like
    /// a lead (`SELECTX`, `SELECTé`) is another word.
    private func firstWord(of bytes: [UInt8]) -> String? {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if Self.isSpace(byte) {
                index += 1
            } else if isLineComment(bytes, at: index) {
                index = endOfLine(bytes, from: index)
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "*") {
                index = endOfBlockComment(bytes, from: index)
            } else {
                break
            }
        }
        let word = bytes[index...].prefix(while: Self.isWordByte)
        guard !word.isEmpty, let text = String(bytes: word, encoding: .utf8) else { return nil }
        return text.uppercased()
    }

    private func isLineComment(_ bytes: [UInt8], at index: Int) -> Bool {
        if hashComments, bytes[index] == UInt8(ascii: "#") { return true }
        guard bytes[index] == UInt8(ascii: "-"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "-") else {
            return false
        }
        guard dashCommentNeedsSpace, index + 2 < bytes.count else { return true }
        let next = bytes[index + 2]
        return next <= 0x20 || next == 0x7F
    }

    private func endOfLine(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\n") || (carriageReturnEndsComment && byte == UInt8(ascii: "\r")) { return index + 1 }
            index += 1
        }
        return index
    }

    /// The index after the comment that opens at `start`, or the end of the
    /// text when it never closes.
    private func endOfBlockComment(_ bytes: [UInt8], from start: Int) -> Int {
        var depth = 0
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "/"), bytes[index + 1] == UInt8(ascii: "*") {
                if depth == 0 || nestedBlockComments { depth += 1 }
                index += 2
            } else if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return bytes.count
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09...0x0D).contains(byte)
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "$"), 0x80...0xFF:
            true
        default:
            false
        }
    }
}
