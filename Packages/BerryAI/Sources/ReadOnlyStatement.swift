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
/// The check is lexical. Calls to known side-effecting built-ins
/// (`nextval`, `pg_terminate_backend`, `dblink_exec`) are denied by name, but
/// a user-defined function that writes, or a built-in missing from the list,
/// still passes. Only a database-enforced read-only connection closes that
/// gap; the deny list is defense in depth until one exists.
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
    /// one of them (`comment`, `load`) goes to the approval card. `WAITFOR`
    /// holds the shared connection like the sleep functions below. Not listed:
    /// keywords that only shape a read (`DECLARE`, `FETCH`, `OPEN`, `CLOSE`),
    /// because `OFFSET ... FETCH` paging and `open` and `close` price columns
    /// are common in reads that should keep running.
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
        "RECONFIGURE", "TRIGGER", "SEND", "RECEIVE", "CONVERSATION", "SIGNATURE", "WAITFOR",
    ]

    /// Built-in functions that act outside the rows a read returns: they run
    /// text on another server or connection, signal or reconfigure sessions,
    /// advance sequences, touch large objects or server files, take locks that
    /// outlive the statement, sleep, or load native code. Calling one sends
    /// the statement to the approval card. This is a deny list of known
    /// built-ins, not a guarantee: a database-enforced read-only connection is
    /// the real control. `currval`/`lastval` only read, and `txid_current`
    /// only assigns the transaction its id, so they are not listed.
    /// PostgreSQL: https://www.postgresql.org/docs/current/functions-admin.html,
    /// https://www.postgresql.org/docs/current/functions-sequence.html,
    /// https://www.postgresql.org/docs/current/lo-funcs.html,
    /// https://www.postgresql.org/docs/current/dblink.html,
    /// https://www.postgresql.org/docs/current/postgres-fdw.html#POSTGRES-FDW-FUNCTIONS,
    /// https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-DELAY,
    /// https://www.postgresql.org/docs/current/functions-xml.html#FUNCTIONS-XML-MAPPING,
    /// https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-STATS-FUNCTIONS,
    /// https://www.postgresql.org/docs/16/adminpack.html.
    /// MySQL: https://dev.mysql.com/doc/refman/8.4/en/locking-functions.html,
    /// https://dev.mysql.com/doc/refman/8.4/en/miscellaneous-functions.html#function_sleep,
    /// https://dev.mysql.com/doc/refman/8.4/en/information-functions.html#function_benchmark,
    /// https://dev.mysql.com/doc/refman/8.4/en/string-functions.html#function_load-file,
    /// https://dev.mysql.com/doc/refman/8.4/en/gtid-functions.html,
    /// https://dev.mysql.com/doc/refman/8.4/en/replication-functions-synchronization.html;
    /// MariaDB sequences: https://mariadb.com/kb/en/sequence-functions/.
    /// SQL Server: https://learn.microsoft.com/en-us/sql/t-sql/functions/openquery-transact-sql,
    /// https://learn.microsoft.com/en-us/sql/t-sql/functions/openrowset-transact-sql,
    /// https://learn.microsoft.com/en-us/sql/t-sql/functions/opendatasource-transact-sql,
    /// https://learn.microsoft.com/en-us/sql/t-sql/functions/next-value-for-transact-sql,
    /// https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/xp-cmdshell-transact-sql;
    /// `sp_` and `xp_` name stored procedures, never a read's function.
    /// SQLite: https://www.sqlite.org/lang_corefunc.html#load_extension,
    /// https://www.sqlite.org/cli.html#file_i_o_functions.
    private static let sideEffectFunctions: Set<String> = [
        // Remote and pass-through execution.
        "OPENQUERY", "OPENROWSET", "OPENDATASOURCE",
        // Process and session control.
        "PG_TERMINATE_BACKEND", "PG_CANCEL_BACKEND", "PG_RELOAD_CONF", "PG_ROTATE_LOGFILE",
        "PG_LOG_BACKEND_MEMORY_CONTEXTS", "PG_PROMOTE", "PG_SWITCH_WAL", "PG_START_BACKUP",
        "PG_STOP_BACKUP", "PG_DROP_REPLICATION_SLOT", "PG_REPLICATION_SLOT_ADVANCE",
        "PG_IMPORT_SYSTEM_COLLATIONS", "PG_SYNC_REPLICATION_SLOTS", "PG_NOTIFY", "SET_CONFIG",
        "PG_STAT_STATEMENTS_RESET",
        // Large objects and server files.
        "LOWRITE", "PG_STAT_FILE", "PG_LOGDIR_LS", "LOAD_FILE",
        // Locks and sleeps.
        "GET_LOCK", "RELEASE_LOCK", "RELEASE_ALL_LOCKS", "SLEEP", "BENCHMARK",
        "SOURCE_POS_WAIT", "MASTER_POS_WAIT", "WAIT_FOR_EXECUTED_GTID_SET",
        "WAIT_UNTIL_SQL_THREAD_AFTER_GTIDS",
        // Native code and files outside the database.
        "LOAD_EXTENSION", "WRITEFILE", "READFILE",
    ]

    /// Sequence advances, denied wherever the word appears: MariaDB also
    /// accepts `seq.NEXTVAL` without parentheses.
    private static let sequenceAdvanceFunctions: Set<String> = ["NEXTVAL", "SETVAL"]

    /// Families of the same kinds, matched by name prefix.
    private static let sideEffectFunctionPrefixes: [String] = [
        "DBLINK", "QUERY_TO_XML", "POSTGRES_FDW_DISCONNECT",
        "PG_CREATE_", "PG_COPY_", "PG_LOGICAL_", "PG_REPLICATION_ORIGIN_", "PG_BACKUP_",
        "PG_WAL_REPLAY_", "PG_STAT_RESET", "PG_RESTORE_", "PG_CLEAR_",
        "LO_", "PG_READ_", "PG_LS_", "PG_FILE_",
        "PG_ADVISORY_", "PG_TRY_ADVISORY_", "PG_SLEEP",
        "XP_", "SP_",
    ]

    private static func isSideEffectFunction(_ name: String) -> Bool {
        if sideEffectFunctions.contains(name) { return true }
        return sideEffectFunctionPrefixes.contains { name.hasPrefix($0) }
    }

    /// The `(` at `open` calls the word before it, or the last word of a
    /// bracketed name before it. A quoted name could be any function.
    private static func callsSideEffectFunction(_ tokens: [SQLToken], open: Int) -> Bool {
        guard open > 0 else { return false }
        var nameIndex = open - 1
        if tokens[nameIndex] == .punctuation("]"), nameIndex > 0 { nameIndex -= 1 }
        switch tokens[nameIndex] {
        case .quoted: return true
        case .word(let name): return isSideEffectFunction(name)
        case .punctuation, .number: return false
        }
    }

    private static let sharedLockWords: Set<String> = ["SHARE", "KEY"]

    static func isReadOnlySQL(_ sql: String, driver: DriverID?) -> Bool {
        guard let tokens = sqlTokens(sql), case .word(let lead)? = tokens.first,
              readLeads(for: driver).contains(lead)
        else { return false }
        if let separator = tokens.firstIndex(of: .punctuation(";")), separator != tokens.count - 1 {
            return false
        }
        for (index, token) in tokens.enumerated() {
            if token == .punctuation("("), callsSideEffectFunction(tokens, open: index) { return false }
            guard case .word(let word) = token else { continue }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            // `replace(...)` is the string function every dialect has; the
            // REPLACE statement never takes a parenthesis right after it.
            if word == "REPLACE", next == .punctuation("(") { continue }
            if disqualifyingKeywords.contains(word) { return false }
            if sequenceAdvanceFunctions.contains(word) { return false }
            // NEXT VALUE FOR advances a SQL Server or MariaDB sequence.
            if word == "NEXT", index + 2 < tokens.count, tokens[index + 1] == .word("VALUE"),
               tokens[index + 2] == .word("FOR") {
                return false
            }
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
        var lexer = SQLLexer(sql)
        return lexer.tokens()
    }

    /// Scalars visited while lexing `sql`. Classification runs on the main
    /// actor before any query timeout applies, so tests hold this linear in
    /// the length of the text.
    static func sqlLexingSteps(_ sql: String) -> Int {
        var lexer = SQLLexer(sql)
        _ = lexer.tokens()
        return lexer.steps
    }

    private struct SQLLexer {
        let scalars: [Unicode.Scalar]
        var index = 0
        var steps = 0
        /// Whether SQLite's parameter scan reaches a `(` from each position
        /// with no name characters read yet; see `computeParameterSuffixes`.
        var suffixAfterEmptyName: [Bool]?

        init(_ sql: String) { scalars = Array(sql.unicodeScalars) }

        func at(_ position: Int) -> Unicode.Scalar? { position < scalars.count ? scalars[position] : nil }

        mutating func tokens() -> [SQLToken]? {
            for (position, scalar) in scalars.enumerated() {
                steps += 1
                switch scalar.value {
                case 0x09, 0x0A: continue
                case 0x0D where at(position + 1) == "\n": continue
                case 0x00...0x1F, 0x7F, 0x85, 0x2028, 0x2029: return nil
                default: continue
                }
            }

            var tokens: [SQLToken] = []
            while index < scalars.count {
                steps += 1
                let scalar = scalars[index]
                switch scalar {
                case " ", "\t", "\n", "\r":
                    index += 1
                case "-" where at(index + 1) == "-":
                    // MySQL needs whitespace or a control character after `--`.
                    if let follower = at(index + 2), !" \t\n\r".unicodeScalars.contains(follower) { return nil }
                    while index < scalars.count, scalars[index] != "\n" {
                        steps += 1
                        index += 1
                    }
                case "/" where at(index + 1) == "*":
                    let marker = at(index + 2).map { String($0) } ?? ""
                    if marker == "!" { return nil }
                    if marker.lowercased() == "m", at(index + 3) == "!" { return nil }
                    index += 2
                    while true {
                        steps += 1
                        guard index + 1 < scalars.count else { return nil }
                        if scalars[index] == "/", scalars[index + 1] == "*" { return nil }
                        if scalars[index] == "*", scalars[index + 1] == "/" { break }
                        index += 1
                    }
                    index += 2
                case "'", "\"", "`":
                    index += 1
                    while true {
                        steps += 1
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
                    guard bracketIsUnambiguous(from: index) else { return nil }
                    tokens.append(.punctuation(scalar))
                    index += 1
                case "@", ":":
                    if opensSQLiteParameterSuffix(at: index) { return nil }
                    tokens.append(.punctuation(scalar))
                    index += 1
                case "#", "$", "\\":
                    return nil
                case "0"..."9":
                    while index < scalars.count, ReadOnlyStatement.isASCIIDigit(scalars[index]) {
                        steps += 1
                        index += 1
                    }
                    tokens.append(.number)
                default:
                    if ReadOnlyStatement.isWordCharacter(scalar), !ReadOnlyStatement.isASCIIDigit(scalar) {
                        let start = index
                        while index < scalars.count, isWordContinuation(scalars[index]) {
                            steps += 1
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

        func isWordContinuation(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "$" || ReadOnlyStatement.isWordCharacter(scalar)
        }

        /// True when the `[` at `open` closes before anything inside it could
        /// open a quote or a comment, and not with SQL Server's `]]` escape.
        mutating func bracketIsUnambiguous(from open: Int) -> Bool {
            var position = open + 1
            var previous: Unicode.Scalar = " "
            while position < scalars.count {
                steps += 1
                let scalar = scalars[position]
                if scalar == "]" { return at(position + 1) != "]" }
                if ReadOnlyStatement.bracketBreakers.contains(scalar) { return false }
                if previous == "-", scalar == "-" { return false }
                if previous == "/", scalar == "*" { return false }
                previous = scalar
                position += 1
            }
            return false
        }

        /// Mirrors SQLite's tokenizer for `@`/`:` parameters: a name of
        /// identifier characters (any non-ASCII byte among them, `::` allowed
        /// inside) followed directly by `(`.
        mutating func opensSQLiteParameterSuffix(at start: Int) -> Bool {
            if suffixAfterEmptyName == nil { computeParameterSuffixes() }
            return suffixAfterEmptyName?[start + 1] ?? true
        }

        /// Fills the scan's outcome for every position in one pass from the
        /// end, with no name characters read yet and with some. Scanning
        /// forward from every `:` instead revisits the whole rest of a
        /// `x::a::a…` cast chain once per colon.
        mutating func computeParameterSuffixes() {
            let count = scalars.count
            var afterEmptyName = [Bool](repeating: false, count: count + 2)
            var afterName = [Bool](repeating: false, count: count + 2)
            var position = count - 1
            while position >= 0 {
                steps += 1
                let scalar = scalars[position]
                if !scalar.isASCII || isWordContinuation(scalar) {
                    afterEmptyName[position] = afterName[position + 1]
                    afterName[position] = afterName[position + 1]
                } else if scalar == "(" {
                    afterName[position] = true
                } else if scalar == ":", at(position + 1) == ":" {
                    afterEmptyName[position] = afterEmptyName[position + 2]
                    afterName[position] = afterName[position + 2]
                }
                position -= 1
            }
            suffixAfterEmptyName = afterEmptyName
        }
    }

    private static let bracketBreakers: Set<Unicode.Scalar> = ["'", "\"", "`", "[", "#", "$", "\\", ";"]

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

    // MARK: - Mongo shell

    /// Methods the shell resolver turns into a query, never a write.
    static let mongoReadMethods: Set<String> = [
        "find", "findOne", "aggregate", "countDocuments", "estimatedDocumentCount", "distinct",
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
