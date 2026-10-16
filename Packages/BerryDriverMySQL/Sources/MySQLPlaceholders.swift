/// Counts the `?` placeholders of a statement the way MySQL and MariaDB read
/// them, so that a statement given a different number of parameters is
/// refused before it runs. MySQLNIO 1.9.1 sends every bind it is given
/// without comparing their number with the placeholders the server
/// prepared (`MySQLQueryCommand`), and the server reads the values by its
/// own count: `SELECT ?` with two integers returned 65544, without an
/// error, on MySQL 8.4.11 and MariaDB 11.8.9.
///
/// A `?` inside a string, a quoted identifier or a comment is not a
/// placeholder. A string is quoted with `'`, or with `"` unless the session
/// reads `"` as an identifier quote, and a doubled quote stands for one
/// (https://dev.mysql.com/doc/refman/8.4/en/string-literals.html). An
/// identifier is quoted with backticks, a doubled backtick stands for one,
/// and a backslash is an ordinary character
/// (https://dev.mysql.com/doc/refman/8.4/en/identifiers.html). Comments end
/// where `ReadOnlyAllowlist.mysql` ends them; an executable comment never
/// gets here, because the allowlist refuses the text. The text is read as
/// UTF-8 bytes, as MySQLNIO 1.9.1 sends it to a utf8mb4 connection, and no
/// byte of a multi-byte UTF-8 character is ASCII.
///
/// Whether a backslash escapes, and what `"` quotes, follow the session's
/// SQL mode (`Quoting`). Counted in the wrong mode, a statement with a
/// mismatch can run: in a session with NO_BACKSLASH_ESCAPES, read with
/// backslash escapes, `SELECT 'a\', '?'` counts one placeholder, holds
/// none, and the parameter given for it was ignored; `SELECT ?, 'a\', '?'`
/// given two returned 65544 (verified against MySQL 8.4.11 and MariaDB
/// 11.8.9).
///
/// MariaDB's ORACLE mode also reads `:1` as a placeholder, which this count
/// does not see. Such a statement holds more placeholders than counted and
/// fails at the server, as one given too few parameters does (verified
/// against MariaDB 11.8.9).
enum MySQLPlaceholders {
    /// How quotes read in a session, from its SQL mode
    /// (https://dev.mysql.com/doc/refman/8.4/en/sql-mode.html). Verified
    /// against MySQL 8.4.11 and MariaDB 11.8.9: with NO_BACKSLASH_ESCAPES a
    /// backslash is an ordinary character in `'…'` and `"…"`; with
    /// ANSI_QUOTES `"…"` is an identifier, in which a backslash is an
    /// ordinary character and `""` stands for `"`, while a backslash still
    /// escapes in `'…'`. A doubled quote stands for one in every mode.
    struct Quoting: Equatable, Sendable {
        /// A backslash escapes the character after it in a string; false
        /// under NO_BACKSLASH_ESCAPES.
        var backslashEscapes = true
        /// `"…"` quotes an identifier rather than a string; true under
        /// ANSI_QUOTES.
        var doubleQuotesIdentifier = false

        /// Neither mode, as the default SQL mode of MySQL 8.4.11 and of
        /// MariaDB 11.8.9 reads.
        static let serverDefault = Quoting()

        init() {}

        /// `sqlMode` as `@@SESSION.sql_mode` reads: its modes joined by
        /// commas, a combination listed with the modes it sets, as MariaDB
        /// 11.8.9 lists ORACLE with ANSI_QUOTES.
        init(sqlMode: String) {
            let modes = Set(sqlMode.split(separator: ",").map(String.init))
            backslashEscapes = !modes.contains("NO_BACKSLASH_ESCAPES")
            doubleQuotesIdentifier = modes.contains("ANSI_QUOTES")
        }
    }

    static func count(in sql: String, quoting: Quoting = .serverDefault) -> Int {
        let bytes = Array(sql.utf8)
        var count = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "?"):
                count += 1
                index += 1
            case UInt8(ascii: "'"):
                index = endOfQuoted(bytes, from: index, backslashEscapes: quoting.backslashEscapes)
            case UInt8(ascii: "\""):
                let escapes = quoting.backslashEscapes && !quoting.doubleQuotesIdentifier
                index = endOfQuoted(bytes, from: index, backslashEscapes: escapes)
            case UInt8(ascii: "`"):
                index = endOfQuoted(bytes, from: index, backslashEscapes: false)
            case UInt8(ascii: "#"):
                index = endOfLine(bytes, from: index)
            case UInt8(ascii: "-") where startsDashComment(bytes, at: index):
                index = endOfLine(bytes, from: index)
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                index = endOfBlockComment(bytes, from: index + 2)
            default:
                index += 1
            }
        }
        return count
    }

    /// The index after the quote that closes the text opened at `start`, or
    /// the end of the text when nothing closes it.
    private static func endOfQuoted(_ bytes: [UInt8], from start: Int, backslashEscapes: Bool) -> Int {
        let quote = bytes[start]
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if backslashEscapes, byte == UInt8(ascii: "\\") {
                index += 2
            } else if byte == quote {
                guard index + 1 < bytes.count, bytes[index + 1] == quote else { return index + 1 }
                index += 2
            } else {
                index += 1
            }
        }
        return bytes.count
    }

    /// `--` opens a comment only before whitespace, a control character or
    /// the end of the text; otherwise it is two minus signs.
    private static func startsDashComment(_ bytes: [UInt8], at index: Int) -> Bool {
        guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "-") else { return false }
        guard index + 2 < bytes.count else { return true }
        let next = bytes[index + 2]
        return next <= 0x20 || next == 0x7F
    }

    /// A line comment ends at a line feed alone.
    private static func endOfLine(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
        return index
    }

    /// Block comments do not nest: the first `*/` after the opening one
    /// ends it.
    private static func endOfBlockComment(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == UInt8(ascii: "*"), bytes[index + 1] == UInt8(ascii: "/") { return index + 2 }
            index += 1
        }
        return bytes.count
    }
}
