import BerryDriverKit

/// Decides whether a statement the assistant proposes may run without an
/// approval card.
///
/// Only text proven read-only from its first token to its last qualifies.
/// Anything else needs approval, including every form the classifier cannot
/// read with certainty: a read sent to the card by mistake costs one click,
/// a write that slips through runs unreviewed. A leading `SELECT` proves
/// little on its own: a PostgreSQL data-modifying CTE
/// (https://www.postgresql.org/docs/current/queries-with.html#QUERIES-WITH-MODIFYING),
/// `EXPLAIN ANALYZE`, which runs the statement it explains
/// (https://www.postgresql.org/docs/current/sql-explain.html), `SELECT ...
/// INTO`, a locking read, and a second statement all begin like a read.
///
/// The check is lexical. A read that calls a side-effecting function
/// (`nextval`, `pg_terminate_backend`, `dblink_exec`) still passes it; only a
/// database-enforced read-only transaction closes that gap.
enum ReadOnlyStatement {
    // MARK: - SQL

    /// Text that begins with one of these, contains no listed keyword and is a
    /// single statement is read-only. SQL Server has no EXPLAIN or SHOW
    /// statement, and runs an unknown word that opens a batch as a stored
    /// procedure call
    /// (https://learn.microsoft.com/en-us/sql/t-sql/language-elements/execute-transact-sql).
    private static func readLeads(for driver: DriverID?) -> Set<String> {
        driver == .sqlserver ? ["SELECT", "WITH"] : ["SELECT", "WITH", "EXPLAIN", "SHOW"]
    }

    /// Keywords that disqualify a statement wherever they appear outside a
    /// literal or comment. Some do their damage inside a read: a modifying
    /// CTE, `EXPLAIN ANALYZE`, `SELECT ... INTO`, the locks of `FOR UPDATE`,
    /// `LOCK IN SHARE MODE` and SQL Server's `UPDLOCK`, `XLOCK` and `TABLOCKX`.
    /// The rest begin a statement of their own. SQL Server runs a batch whose
    /// statements need no separator
    /// (https://learn.microsoft.com/en-us/sql/t-sql/language-elements/transact-sql-syntax-conventions-transact-sql),
    /// so its statement keywords that write or change session state are all
    /// listed. Statements of the other dialects need a `;` between them,
    /// which already fails the single-statement rule; their keywords are
    /// listed as a second line of defense. A read that names a column after
    /// one of them (`comment`, `load`) goes to the approval card. Not listed:
    /// keywords that only shape a read (`DECLARE`, `FETCH`, `OPEN`, `CLOSE`,
    /// `WAITFOR`), because `OFFSET ... FETCH` paging and `open` and `close`
    /// price columns are common in reads that should keep running.
    private static let disqualifyingKeywords: Set<String> = [
        // Writes, DDL and privileges.
        "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "REPLACE", "CREATE", "ALTER", "DROP",
        "TRUNCATE", "GRANT", "REVOKE", "DENY", "INTO", "WRITETEXT", "UPDATETEXT", "BULK", "COPY",
        // Statements a read runs or wraps.
        "ANALYZE", "ANALYSE", "CALL", "EXEC", "EXECUTE", "DO", "PREPARE", "DEALLOCATE",
        // Locks.
        "LOCK", "UPDLOCK", "XLOCK", "TABLOCKX",
        // Session and transaction state, which persists on the shared connection.
        "SET", "RESET", "DISCARD", "USE", "BEGIN", "COMMIT", "ROLLBACK", "SAVE", "SETUSER", "REVERT",
        // Maintenance, server control, queues and notifications.
        "VACUUM", "REINDEX", "CLUSTER", "REFRESH", "COMMENT", "PRAGMA", "ATTACH", "DETACH", "LOAD",
        "LISTEN", "NOTIFY", "UNLISTEN", "CHECKPOINT", "DBCC", "BACKUP", "RESTORE", "KILL", "SHUTDOWN",
        "RECONFIGURE", "TRIGGER", "SEND", "RECEIVE", "CONVERSATION", "SIGNATURE",
    ]

    private static let sharedLockWords: Set<String> = ["SHARE", "KEY"]

    static func isReadOnlySQL(_ sql: String, driver: DriverID?) -> Bool {
        guard let tokens = sqlTokens(sql), case .word(let lead)? = tokens.first,
              readLeads(for: driver).contains(lead)
        else { return false }
        if let separator = tokens.firstIndex(of: .punctuation(";")), separator != tokens.count - 1 {
            return false
        }
        for (index, token) in tokens.enumerated() {
            guard case .word(let word) = token else { continue }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            // `replace(...)` is the string function every dialect has; the
            // REPLACE statement never takes a parenthesis right after it.
            if word == "REPLACE", next == .punctuation("(") { continue }
            if disqualifyingKeywords.contains(word) { return false }
            // FOR SHARE / FOR KEY SHARE; FOR [NO KEY] UPDATE is caught by UPDATE.
            if word == "FOR", case .word(let following)? = next, sharedLockWords.contains(following) { return false }
        }
        return true
    }

    private enum SQLToken: Equatable {
        case word(String)
        case punctuation(Unicode.Scalar)
        case quoted
        case number
    }

    /// Tokens outside literals and comments, or nil when the text uses a form
    /// two supported engines would split into statements differently. Every
    /// SQL driver shares this one lexer, so it accepts only what PostgreSQL,
    /// MySQL, SQLite, SQL Server and DynamoDB PartiQL read alike, and rejects:
    /// - a backslash: MySQL strings and PostgreSQL `E''` strings treat it as
    ///   an escape (https://dev.mysql.com/doc/refman/8.4/en/string-literals.html,
    ///   https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-STRINGS-ESCAPE);
    /// - `--` not followed by whitespace, `#`, and `/*!` or `/*M!`: MySQL
    ///   reads these differently from the others
    ///   (https://dev.mysql.com/doc/refman/8.4/en/comments.html);
    /// - `/*` inside a block comment: PostgreSQL nests block comments
    ///   (https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-COMMENTS);
    /// - a `$` that opens a token: a PostgreSQL dollar quote, a MySQL
    ///   identifier or a SQL Server money literal;
    /// - `[` whose contents could quote or comment: a SQL Server or SQLite
    ///   identifier ends at the first `]`, a PostgreSQL subscript does not;
    /// - `@name(` and `:name(`: SQLite reads a parameter's parenthesized
    ///   suffix up to the first `)` regardless of quotes
    ///   (https://www.sqlite.org/c3ref/bind_blob.html);
    /// - a carriage return without a line feed, which ends a `--` comment
    ///   only in PostgreSQL, Unicode line separators, control characters, and
    ///   non-ASCII characters outside literals that are not letters, marks
    ///   or digits, where an engine could see a separator the lexer did not.
    /// A number is split from letters that follow it, so `1DELETE` still
    /// exposes the keyword.
    private static func sqlTokens(_ sql: String) -> [SQLToken]? {
        let scalars = Array(sql.unicodeScalars)
        func at(_ index: Int) -> Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x09, 0x0A: continue
            case 0x0D where at(index + 1) == "\n": continue
            case 0x00...0x1F, 0x7F, 0x85, 0x2028, 0x2029: return nil
            default: continue
            }
        }

        var tokens: [SQLToken] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case " ", "\t", "\n", "\r":
                index += 1
            case "-" where at(index + 1) == "-":
                // MySQL needs whitespace or a control character after `--`.
                if let follower = at(index + 2), !" \t\n\r".unicodeScalars.contains(follower) { return nil }
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            case "/" where at(index + 1) == "*":
                let marker = at(index + 2).map { String($0) } ?? ""
                if marker == "!" { return nil }
                if marker.lowercased() == "m", at(index + 3) == "!" { return nil }
                index += 2
                while true {
                    guard index + 1 < scalars.count else { return nil }
                    if scalars[index] == "/", scalars[index + 1] == "*" { return nil }
                    if scalars[index] == "*", scalars[index + 1] == "/" { break }
                    index += 1
                }
                index += 2
            case "'", "\"", "`":
                index += 1
                while true {
                    guard index < scalars.count, scalars[index] != "\\" else { return nil }
                    if scalars[index] == scalar {
                        if at(index + 1) == scalar {
                            index += 2
                            continue
                        }
                        break
                    }
                    index += 1
                }
                index += 1
                tokens.append(.quoted)
            case "[":
                guard let close = scalars[index...].firstIndex(of: "]"), at(close + 1) != "]" else { return nil }
                if bracketContentsCanQuoteOrComment(Array(scalars[(index + 1)..<close])) { return nil }
                tokens.append(.punctuation(scalar))
                index += 1
            case "@", ":":
                if opensSQLiteParameterSuffix(scalars, at: index) { return nil }
                tokens.append(.punctuation(scalar))
                index += 1
            case "#", "$", "\\":
                return nil
            case "0"..."9":
                while index < scalars.count, isASCIIDigit(scalars[index]) { index += 1 }
                tokens.append(.number)
            default:
                if isWordCharacter(scalar), !isASCIIDigit(scalar) {
                    let start = index
                    while index < scalars.count, isWordCharacter(scalars[index]) || scalars[index] == "$" {
                        index += 1
                    }
                    tokens.append(.word(String(String.UnicodeScalarView(scalars[start..<index])).uppercased()))
                } else if scalar.isASCII {
                    tokens.append(.punctuation(scalar))
                    index += 1
                } else {
                    return nil
                }
            }
        }
        return tokens
    }

    private static let bracketBreakers: Set<Unicode.Scalar> = ["'", "\"", "`", "[", "#", "$", "\\", ";"]

    private static func bracketContentsCanQuoteOrComment(_ contents: [Unicode.Scalar]) -> Bool {
        var previous: Unicode.Scalar = " "
        for scalar in contents {
            if bracketBreakers.contains(scalar) { return true }
            let pair = String(String.UnicodeScalarView([previous, scalar]))
            if pair == "--" || pair == "/*" { return true }
            previous = scalar
        }
        return false
    }

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    /// ASCII letters, digits and `_`, and non-ASCII letters, marks and digits.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: return true
            default: return false
            }
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Mirrors SQLite's tokenizer for `@`/`:` parameters: a name of
    /// identifier characters (any non-ASCII byte among them, `::` allowed
    /// inside) followed directly by `(`.
    private static func opensSQLiteParameterSuffix(_ scalars: [Unicode.Scalar], at start: Int) -> Bool {
        var index = start + 1
        var nameLength = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if !scalar.isASCII || isWordCharacter(scalar) || scalar == "$" {
                nameLength += 1
                index += 1
            } else if scalar == "(" {
                return nameLength > 0
            } else if scalar == ":", index + 1 < scalars.count, scalars[index + 1] == ":" {
                index += 2
            } else {
                return false
            }
        }
        return false
    }

    // MARK: - Mongo shell

    /// Methods the shell resolver turns into a query, never a write.
    private static let mongoReadMethods: Set<String> = [
        "find", "findOne", "aggregate", "count", "countDocuments", "estimatedDocumentCount", "distinct",
    ]
    /// Cursor modifiers the resolver accepts after `find`.
    private static let mongoCursorMethods: Set<String> = ["sort", "limit"]
    /// Pipeline stages that write their output to a collection
    /// (https://www.mongodb.com/docs/manual/reference/operator/aggregation/out/,
    /// https://www.mongodb.com/docs/manual/reference/operator/aggregation/merge/).
    private static let mongoWritingStages: Set<String> = ["$out", "$merge"]

    /// True for one `db.<collection>.<read method>(...)` call, optionally
    /// followed by cursor modifiers, that names no writing pipeline stage.
    /// The method actually called decides, not a substring anywhere in the
    /// text. Elasticsearch and Qdrant scripts arrive on the same path and
    /// never match, so they always need approval.
    static func isReadOnlyMongoShell(_ text: String) -> Bool {
        guard var tokens = mongoTokens(text) else { return false }
        if tokens.last == .punctuation(";") { tokens.removeLast() }
        guard !tokens.contains(.punctuation(";")), tokens.count > 5,
              tokens[0] == .word("db"), tokens[1] == .punctuation("."), tokens[3] == .punctuation("."),
              case .word = tokens[2], case .word(let method) = tokens[4], mongoReadMethods.contains(method),
              let close = mongoClosingIndex(tokens, open: 5)
        else { return false }
        var index = close + 1
        while index < tokens.count {
            guard tokens[index] == .punctuation("."), index + 2 < tokens.count,
                  case .word(let modifier) = tokens[index + 1], mongoCursorMethods.contains(modifier),
                  let modifierClose = mongoClosingIndex(tokens, open: index + 2)
            else { return false }
            index = modifierClose + 1
        }
        return !tokens.contains { token in
            switch token {
            case .word(let value), .string(let value): mongoWritingStages.contains(value.lowercased())
            case .punctuation, .number: false
            }
        }
    }

    private enum MongoToken: Equatable {
        case word(String)
        case string(String)
        case punctuation(Character)
        case number
    }

    /// Tokens as the executor's Mongo shell lexer reads them, Character by
    /// Character, or nil for anything it would reject or read differently.
    /// Comments and backslashes are rejected: the statement splitter that runs
    /// before that lexer skips neither, so a quote or `;` inside a comment
    /// splits the script differently than the lexer reads it.
    private static func mongoTokens(_ text: String) -> [MongoToken]? {
        let characters = Array(text)
        var tokens: [MongoToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            switch character {
            case "\\", "/":
                return nil
            case "'", "\"":
                guard let close = characters[(index + 1)...].firstIndex(of: character) else { return nil }
                let value = String(characters[(index + 1)..<close])
                // A control character could end a NUL-terminated BSON key
                // early and turn it into a stage name.
                guard !value.unicodeScalars.contains(where: { isEscapeOrControl($0) }) else { return nil }
                tokens.append(.string(value))
                index = close + 1
            case "(", ")", "{", "}", "[", "]", ",", ":", ".", ";":
                tokens.append(.punctuation(character))
                index += 1
            default:
                let start = index
                if character == "-" || character.isNumber {
                    index += 1
                    while index < characters.count, characters[index].isNumber || characters[index] == "." {
                        index += 1
                    }
                    guard Double(String(characters[start..<index])) != nil else { return nil }
                    tokens.append(.number)
                } else if isMongoIdentifierCharacter(character), !character.isNumber {
                    index += 1
                    while index < characters.count, isMongoIdentifierCharacter(characters[index]) { index += 1 }
                    tokens.append(.word(String(characters[start..<index])))
                } else {
                    return nil
                }
            }
        }
        return tokens
    }

    /// What the shell lexer reads as part of an identifier: letters,
    /// numbers, `_` and `$`.
    private static func isMongoIdentifierCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character == "_" || character == "$"
    }

    private static func isEscapeOrControl(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\\" { return true }
        return scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func mongoClosingIndex(_ tokens: [MongoToken], open: Int) -> Int? {
        guard tokens[open] == .punctuation("(") else { return nil }
        var depth = 0
        for index in open..<tokens.count {
            switch tokens[index] {
            case .punctuation("("), .punctuation("["), .punctuation("{"):
                depth += 1
            case .punctuation(")"), .punctuation("]"), .punctuation("}"):
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }
}
