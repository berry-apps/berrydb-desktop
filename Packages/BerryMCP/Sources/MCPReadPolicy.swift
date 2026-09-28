import Foundation

/// SQL dialect a statement is validated against. Grammar, the function
/// allowlist, and identifier-quoting rules (bracket syntax in particular)
/// differ by dialect, so the caller must state which one applies.
public enum MCPSQLDialect: String, Sendable, CaseIterable {
    case postgresql
    case mysql
    case sqlite
}

/// Why `MCPReadPolicy.validate(_:dialect:)` rejected a statement. Every case
/// is a fail-closed decision: the statement was not merely unrecognized, it
/// was judged unsafe to send to a read-only session.
public enum MCPReadPolicyError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case malformed(String)
    case multipleStatements
    case unsupportedStatement(String)
    case prohibitedOperation(String)

    public var description: String {
        switch self {
        case .empty: "Query is empty"
        case .malformed(let reason): "Malformed query: \(reason)"
        case .multipleStatements: "Exactly one statement is required"
        case .unsupportedStatement(let statement): "Unsupported statement: \(statement)"
        case .prohibitedOperation(let operation): "Prohibited operation: \(operation)"
        }
    }
}

/// A statement `MCPReadPolicy` accepted. `normalizedSQL` is the caller's
/// original text, trimmed of surrounding whitespace and a trailing `;` —
/// validation is lexical, but execution must receive the caller's SQL
/// unchanged so placeholders and dialect-specific operators survive.
public struct MCPReadDecision: Equatable, Sendable {
    public let dialect: MCPSQLDialect
    public let statement: String
    public let normalizedSQL: String
}

/// A deliberately small SQL recognizer for the MCP authorization boundary.
/// It accepts an enumerated read grammar and rejects every unknown construct.
/// This is not the UI's lexical danger detector and never asks for confirmation.
public struct MCPReadPolicy: Sendable {
    public init() {}

    /// Accepts `sql` only if it is exactly one statement drawn from an
    /// enumerated read grammar (`SELECT`, `VALUES`, `WITH ... SELECT`,
    /// `EXPLAIN` of one of those, or SQLite `PRAGMA`) using only allowlisted
    /// functions. Everything else — multiple statements, writes, locks,
    /// session/transaction control, unapproved functions — is rejected.
    /// This is defense in depth behind a database-enforced read-only
    /// session, not a substitute for one.
    public func validate(_ sql: String, dialect: MCPSQLDialect) throws -> MCPReadDecision {
        var tokenizer = SQLTokenizer(sql, dialect: dialect)
        let tokens = try tokenizer.tokenize()
        guard !tokens.isEmpty else { throw MCPReadPolicyError.empty }

        let semicolons = tokens.indices.filter { tokens[$0].text == ";" }
        if semicolons.count > 1 || (semicolons.count == 1 && semicolons[0] != tokens.index(before: tokens.endIndex)) {
            throw MCPReadPolicyError.multipleStatements
        }
        let statementTokens = tokens.last?.text == ";" ? Array(tokens.dropLast()) : tokens
        guard !statementTokens.isEmpty else { throw MCPReadPolicyError.empty }
        try validateBalanced(statementTokens)

        let words = statementTokens.filter(\.isWord).map { $0.text.uppercased() }
        guard let first = words.first else { throw MCPReadPolicyError.malformed("missing statement keyword") }
        try rejectProhibitedTokenPatterns(statementTokens, dialect: dialect)
        try rejectProhibited(words, dialect: dialect)
        if first != "PRAGMA" { try validateFunctionCalls(statementTokens, dialect: dialect) }

        switch first {
        case "SELECT": try validateProjection(after: 0, in: statementTokens)
        case "VALUES": try validateValues(after: 0, in: statementTokens)
        case "WITH":
            guard let main = topLevelMainStatementIndex(statementTokens), statementTokens[main].text.uppercased() == "SELECT" else {
                throw MCPReadPolicyError.unsupportedStatement("WITH without a final SELECT")
            }
            try validateProjection(after: main, in: statementTokens)
        case "EXPLAIN":
            try validateExplain(words)
            if let select = statementTokens.lastIndex(where: { $0.isWord && $0.text.uppercased() == "SELECT" }) {
                try validateProjection(after: select, in: statementTokens)
            }
        case "PRAGMA" where dialect == .sqlite:
            try validatePragma(statementTokens)
        default:
            throw MCPReadPolicyError.unsupportedStatement(first)
        }

        return MCPReadDecision(
            dialect: dialect,
            statement: first,
            normalizedSQL: executableSQL(from: sql)
        )
    }

    /// Validation is lexical, but execution must receive the caller's SQL
    /// unchanged. Reconstructing it from tokens corrupts placeholders and
    /// multi-character operators (for example `$1`, `?1`, and `::`).
    private func executableSQL(from sql: String) -> String {
        var executable = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        if executable.last == ";" {
            executable.removeLast()
            executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return executable
    }

    private func validateBalanced(_ tokens: [SQLToken]) throws {
        var depth = 0
        for token in tokens {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            if depth < 0 { throw MCPReadPolicyError.malformed("unbalanced parentheses") }
        }
        if depth != 0 { throw MCPReadPolicyError.malformed("unbalanced parentheses") }
    }

    private func topLevelMainStatementIndex(_ tokens: [SQLToken]) -> Int? {
        var depth = 0
        for index in tokens.indices.dropFirst() {
            let token = tokens[index]
            if token.text == "(" {
                depth += 1
                continue
            }
            if token.text == ")" {
                depth -= 1
                continue
            }
            if depth == 0, token.isWord {
                let word = token.text.uppercased()
                if ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"].contains(word) { return index }
            }
        }
        return nil
    }

    private func validateProjection(after index: Int, in tokens: [SQLToken]) throws {
        guard tokens.indices.contains(index + 1) else { throw MCPReadPolicyError.malformed("SELECT requires a projection") }
        let next = tokens[index + 1]
        if next.isWord, ["FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "FOR"].contains(next.text.uppercased()) {
            throw MCPReadPolicyError.malformed("SELECT requires a projection")
        }
    }

    private func validateValues(after index: Int, in tokens: [SQLToken]) throws {
        guard tokens.indices.contains(index + 1) else { throw MCPReadPolicyError.malformed("VALUES requires at least one row") }
    }

    /// Calls are a side-effect escape hatch in all three SQL dialects. Unknown
    /// calls therefore fail closed; this is intentionally a small read-only
    /// allowlist rather than a blacklist of known-dangerous extensions/UDFs.
    private func validateFunctionCalls(_ tokens: [SQLToken], dialect: MCPSQLDialect) throws {
        var safe = Set([
            "ABS", "AVG", "CAST", "CHAR_LENGTH", "COALESCE", "COUNT", "DATE", "DATETIME",
            "HEX", "LENGTH", "LOWER", "LTRIM", "MAX", "MIN", "NULLIF", "PRINTF", "REPLACE",
            "ROUND", "RTRIM", "SUBSTR", "SUBSTRING", "SUM", "TRIM", "TYPEOF", "UNHEX", "UPPER"
        ])
        switch dialect {
        case .postgresql: safe.formUnion(["CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "DATE_PART", "EXTRACT", "JSON_BUILD_OBJECT", "JSONB_BUILD_OBJECT", "TO_CHAR"])
        case .mysql: safe.formUnion(["DATE_FORMAT", "IFNULL", "JSON_EXTRACT", "JSON_UNQUOTE", "NOW", "UTC_TIMESTAMP"])
        case .sqlite: safe.formUnion(["JULIANDAY", "JSON_EXTRACT", "JSON_TYPE", "STRFTIME"])
        }
        let syntax = Set(["AS", "IN", "EXISTS", "OVER", "FILTER", "VALUES"])
        for index in tokens.indices where (tokens[index].isWord || tokens[index].isQuotedIdentifier) && tokens.indices.contains(index + 1) && tokens[index + 1].text == "(" {
            if tokens[index].isQuotedIdentifier {
                throw MCPReadPolicyError.prohibitedOperation("unapproved quoted function")
            }
            if index > tokens.startIndex, tokens[tokens.index(before: index)].text == "." {
                throw MCPReadPolicyError.prohibitedOperation("unapproved qualified function")
            }
            let name = tokens[index].text.uppercased()
            if syntax.contains(name) || safe.contains(name) || isCTEColumnList(at: index, tokens: tokens) { continue }
            throw MCPReadPolicyError.prohibitedOperation("unapproved function \(name)")
        }
    }

    private func isCTEColumnList(at index: Int, tokens: [SQLToken]) -> Bool {
        guard let close = matchingCloseParen(after: index, tokens: tokens), tokens.indices.contains(close + 1) else { return false }
        let next = tokens[close + 1]
        guard next.isWord, next.text.uppercased() == "AS" else { return false }
        let candidateDepth = nestingDepth(before: index, tokens: tokens)
        guard index > tokens.startIndex else { return false }
        let previous = tokens[index - 1]
        if previous.isWord, previous.text.uppercased() == "WITH" {
            return nestingDepth(before: index - 1, tokens: tokens) == candidateDepth
        }
        if previous.isWord, previous.text.uppercased() == "RECURSIVE", index >= 2,
           tokens[index - 2].isWord, tokens[index - 2].text.uppercased() == "WITH" {
            return nestingDepth(before: index - 2, tokens: tokens) == candidateDepth
        }
        guard previous.text == ",", index >= 2, tokens[index - 2].text == ")",
              nestingDepth(before: index - 1, tokens: tokens) == candidateDepth else { return false }

        // A comma introduces another CTE only after a complete `AS (...)`
        // body at this depth. A comma inside a CTE SELECT must not turn the
        // next function-shaped expression into a column declaration.
        guard let bodyOpen = matchingOpenParen(before: index - 2, tokens: tokens), bodyOpen > 0,
              tokens[bodyOpen - 1].isWord, tokens[bodyOpen - 1].text.uppercased() == "AS",
              nestingDepth(before: bodyOpen, tokens: tokens) == candidateDepth else { return false }
        return tokens[..<bodyOpen].indices.contains { cursor in
            tokens[cursor].isWord && tokens[cursor].text.uppercased() == "WITH"
                && nestingDepth(before: cursor, tokens: tokens) == candidateDepth
        }
    }

    private func nestingDepth(before end: Int, tokens: [SQLToken]) -> Int {
        var depth = 0
        for token in tokens[..<end] {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
        }
        return depth
    }

    private func matchingOpenParen(before close: Int, tokens: [SQLToken]) -> Int? {
        var depth = 0
        for cursor in stride(from: close, through: 0, by: -1) {
            if tokens[cursor].text == ")" { depth += 1 }
            if tokens[cursor].text == "(" {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }

    private func matchingCloseParen(after index: Int, tokens: [SQLToken]) -> Int? {
        var depth = 0
        for cursor in (index + 1)..<tokens.count {
            if tokens[cursor].text == "(" { depth += 1 }
            if tokens[cursor].text == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
        }
        return nil
    }

    private func validateExplain(_ words: [String]) throws {
        if words.contains("ANALYZE") { throw MCPReadPolicyError.prohibitedOperation("EXPLAIN ANALYZE") }
        guard words.dropFirst().contains(where: { $0 == "SELECT" || $0 == "VALUES" }) else {
            throw MCPReadPolicyError.unsupportedStatement("EXPLAIN target")
        }
    }

    private func validatePragma(_ tokens: [SQLToken]) throws {
        let allowed = Set(["TABLE_INFO", "TABLE_XINFO", "INDEX_INFO", "INDEX_XINFO", "INDEX_LIST", "FOREIGN_KEY_LIST", "DATABASE_LIST", "COLLATION_LIST", "COMPILE_OPTIONS", "FUNCTION_LIST", "MODULE_LIST", "PRAGMA_LIST", "JOURNAL_MODE"])
        guard tokens.count >= 2 else { throw MCPReadPolicyError.malformed("missing PRAGMA name") }
        let name = tokens[1].text.uppercased()
        guard allowed.contains(name) else { throw MCPReadPolicyError.prohibitedOperation("PRAGMA \(name)") }
        if tokens.contains(where: { $0.text == "=" }) { throw MCPReadPolicyError.prohibitedOperation("PRAGMA assignment") }
        // journal_mode is only observational without an argument.
        if name == "JOURNAL_MODE", tokens.count > 2 { throw MCPReadPolicyError.prohibitedOperation("PRAGMA journal_mode mutation") }
    }

    private func rejectProhibited(_ words: [String], dialect: MCPSQLDialect) throws {
        let denied = Set([
            "INSERT", "UPDATE", "DELETE", "MERGE", "UPSERT", "CREATE", "ALTER", "DROP", "TRUNCATE",
            "GRANT", "REVOKE", "COMMENT", "VACUUM", "ANALYZE", "ATTACH", "DETACH", "REINDEX",
            "CALL", "EXEC", "EXECUTE", "DO", "COPY", "LOAD", "LOCK", "UNLOCK",
            "SET", "RESET", "USE", "BEGIN", "START", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
            "INTO", "OUTFILE", "DUMPFILE", "NEXTVAL", "SETVAL", "PG_READ_FILE", "PG_READ_BINARY_FILE",
            "PG_LS_DIR", "LO_IMPORT", "LO_EXPORT", "DBLINK", "DBLINK_EXEC", "LOAD_FILE", "SLEEP", "BENCHMARK"
        ])
        if let word = words.first(where: denied.contains) {
            // EXPLAIN is checked separately, but ANALYZE must always remain denied.
            throw MCPReadPolicyError.prohibitedOperation(word)
        }
        if dialect == .postgresql,
           containsSequence(words, ["FOR", "UPDATE"])
            || containsSequence(words, ["FOR", "NO", "KEY", "UPDATE"])
            || containsSequence(words, ["FOR", "SHARE"])
            || containsSequence(words, ["FOR", "KEY", "SHARE"]) {
            throw MCPReadPolicyError.prohibitedOperation("row lock")
        }
        if dialect == .mysql,
           containsSequence(words, ["FOR", "UPDATE"])
            || containsSequence(words, ["FOR", "SHARE"])
            || containsSequence(words, ["LOCK", "IN", "SHARE", "MODE"]) {
            throw MCPReadPolicyError.prohibitedOperation("row lock")
        }
    }

    private func rejectProhibitedTokenPatterns(_ tokens: [SQLToken], dialect: MCPSQLDialect) throws {
        guard dialect == .mysql else { return }
        for index in tokens.indices.dropLast() where tokens[index].text == ":" && tokens[index + 1].text == "=" {
            throw MCPReadPolicyError.prohibitedOperation("MySQL assignment")
        }
    }

    private func containsSequence(_ words: [String], _ sequence: [String]) -> Bool {
        guard words.count >= sequence.count else { return false }
        return (0...(words.count - sequence.count)).contains { Array(words[$0..<($0 + sequence.count)]) == sequence }
    }
}

private struct SQLToken: Sendable {
    let text: String
    let isWord: Bool
    var isQuotedIdentifier: Bool = false
}

private struct SQLTokenizer {
    let characters: [Character]
    let dialect: MCPSQLDialect
    var index = 0
    init(_ sql: String, dialect: MCPSQLDialect) {
        characters = Array(sql)
        self.dialect = dialect
    }

    mutating func tokenize() throws -> [SQLToken] {
        var output: [SQLToken] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "-", peek(1) == "-" {
                if dialect != .mysql || peek(2)?.isWhitespace == true {
                    skipLineComment()
                    continue
                }
            }
            if character == "/", peek(1) == "*" {
                if dialect == .mysql, peek(2) == "!" {
                    throw MCPReadPolicyError.prohibitedOperation("MySQL executable comment")
                }
                try skipBlockComment()
                continue
            }
            if character == "'" {
                output.append(SQLToken(text: try consumeQuoted("'", doubledEscape: true), isWord: false))
                continue
            }
            if character == "\"" {
                output.append(SQLToken(text: try consumeQuoted("\"", doubledEscape: true), isWord: false, isQuotedIdentifier: true))
                continue
            }
            if character == "`" {
                output.append(SQLToken(text: try consumeQuoted("`", doubledEscape: true), isWord: false, isQuotedIdentifier: true))
                continue
            }
            if character == "[" {
                // Only SQLite spells identifiers as [name]. In PostgreSQL `[` starts an
                // array subscript or constructor whose contents must be validated like
                // any other expression, and MySQL has no bracket syntax at all.
                switch dialect {
                case .sqlite:
                    output.append(SQLToken(text: try consumeBracket(), isWord: false, isQuotedIdentifier: true))
                case .postgresql:
                    output.append(SQLToken(text: "[", isWord: false))
                    index += 1
                case .mysql:
                    throw MCPReadPolicyError.malformed("brackets are not MySQL syntax")
                }
                continue
            }
            if character == "]", dialect == .postgresql {
                output.append(SQLToken(text: "]", isWord: false))
                index += 1
                continue
            }
            if character == "$", let quoted = try consumeDollarQuoteIfPresent() {
                output.append(SQLToken(text: quoted, isWord: false))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                index += 1
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == "$" {
                    index += 1
                }
                output.append(SQLToken(text: String(characters[start..<index]), isWord: true))
                continue
            }
            output.append(SQLToken(text: String(character), isWord: false))
            index += 1
        }
        return output
    }

    private func peek(_ offset: Int) -> Character? { index + offset < characters.count ? characters[index + offset] : nil }

    private mutating func skipLineComment() {
        index += 2
        while index < characters.count, characters[index] != "\n" { index += 1 }
    }

    private mutating func skipBlockComment() throws {
        index += 2
        var depth = 1
        while index < characters.count {
            if characters[index] == "/", peek(1) == "*" {
                guard dialect == .postgresql else {
                    throw MCPReadPolicyError.malformed("nested block comments are not accepted for this dialect")
                }
                depth += 1
                index += 2
                continue
            }
            if characters[index] == "*", peek(1) == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return }
                continue
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated block comment")
    }

    private mutating func consumeQuoted(_ quote: Character, doubledEscape: Bool) throws -> String {
        let start = index
        index += 1
        while index < characters.count {
            if characters[index] == quote {
                if doubledEscape, peek(1) == quote {
                    index += 2
                    continue
                }
                index += 1
                return String(characters[start..<index])
            }
            // Backslash-string semantics depend on PostgreSQL/MySQL session
            // settings. Guessing here could hide a statement boundary, so the
            // authorization grammar rejects the ambiguous form.
            if characters[index] == "\\", quote == "'" {
                throw MCPReadPolicyError.malformed("backslash escapes are not accepted in string literals")
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated quoted value")
    }

    /// SQLite-only: `[` and `]` are quoting punctuation here, not tokens of
    /// their own, so the whole bracketed identifier is consumed as one unit.
    private mutating func consumeBracket() throws -> String {
        let start = index
        index += 1
        while index < characters.count {
            if characters[index] == "]" {
                index += 1
                return String(characters[start..<index])
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated bracket identifier")
    }

    private mutating func consumeDollarQuoteIfPresent() throws -> String? {
        let start = index
        var cursor = index + 1
        while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber || characters[cursor] == "_" { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "$" else { return nil }
        let delimiter = Array(characters[start...cursor])
        index = cursor + 1
        while index + delimiter.count <= characters.count {
            if Array(characters[index..<(index + delimiter.count)]) == delimiter {
                index += delimiter.count
                return String(characters[start..<index])
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated dollar quote")
    }
}
