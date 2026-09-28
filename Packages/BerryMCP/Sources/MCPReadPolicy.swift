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
    /// session, not a substitute for one. See `validateFunctionCalls` for
    /// exactly what the function-call check does and does not see.
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

        var withMainIndex: Int?
        var cteExemptions = Set<Int>()
        if first == "WITH" {
            guard let main = topLevelMainStatementIndex(statementTokens, from: 1, to: statementTokens.count),
                  statementTokens[main].text.uppercased() == "SELECT"
            else {
                throw MCPReadPolicyError.unsupportedStatement("WITH without a final SELECT")
            }
            withMainIndex = main
            cteExemptions = cteDeclarationExemptions(statementTokens, withIndex: 0, mainIndex: main)
        }
        if first != "PRAGMA" { try validateFunctionCalls(statementTokens, dialect: dialect, cteExemptions: cteExemptions) }

        switch first {
        case "SELECT": try validateProjection(after: 0, in: statementTokens)
        case "VALUES": try validateValues(after: 0, in: statementTokens)
        case "WITH":
            try validateProjection(after: withMainIndex!, in: statementTokens)
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

    /// Finds the first `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`MERGE` keyword
    /// at paren depth 0 *relative to `start`*, searching `[start, end)`.
    /// Depth resets at `start` regardless of absolute nesting elsewhere in
    /// `tokens`, so this doubles as the bounded search used to locate a
    /// nested `WITH`-clause's own main statement inside its parent CTE's
    /// body.
    private func topLevelMainStatementIndex(_ tokens: [SQLToken], from start: Int, to end: Int) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < end {
            let token = tokens[cursor]
            if token.text == "(" {
                depth += 1
            } else if token.text == ")" {
                depth -= 1
            } else if depth == 0, token.isWord, ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"].contains(token.text.uppercased()) {
                return cursor
            }
            cursor += 1
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

    /// Rejects any `name(` call-syntax token pair whose name is not on the
    /// per-dialect allowlist below, a CTE name declared in this statement's
    /// own `WITH`-clause column list (`cteExemptions`), or one of the small
    /// set of keywords that share call syntax without being a function
    /// (`IN (...)`, `EXISTS (...)`, and similar).
    ///
    /// This check is purely lexical and purely about `name(` call syntax.
    /// It does **not** see, and cannot reject on its own:
    /// - attribute/operator notation that invokes a function without `(`
    ///   immediately following a name (for example PostgreSQL's `@>`, `->`
    ///   operators, or a cast written as `value::type` rather than
    ///   `CAST(value AS type)`);
    /// - a function reachable only indirectly — inside a view definition, a
    ///   column default, a domain check constraint, or a trigger — that the
    ///   validated statement merely references by name;
    /// - a name resolved differently than expected because of
    ///   `search_path`/schema shadowing (an allowlisted name like `lower`
    ///   resolving to a same-named function in a schema earlier in the
    ///   session's `search_path`, rather than the built-in).
    ///
    /// Closing these gaps is not this function's job: the database
    /// connection must also be read-only at the session/transaction level,
    /// and the role it authenticates as must not hold `CREATE` on any
    /// schema in its `search_path` (so it cannot install a same-named
    /// shadowing function in the first place). This lexical check is
    /// defense in depth on top of both, not a replacement for either.
    private func validateFunctionCalls(_ tokens: [SQLToken], dialect: MCPSQLDialect, cteExemptions: Set<Int>) throws {
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
            if syntax.contains(name) || safe.contains(name) || cteExemptions.contains(index) { continue }
            throw MCPReadPolicyError.prohibitedOperation("unapproved function \(name)")
        }
    }

    /// Structurally collects the token index of every CTE name in the
    /// `WITH`-clause starting at `withIndex` that declares an explicit
    /// column list (`name(col, ...) AS (...)`) — the only shape that reads
    /// as a `name(` call to `validateFunctionCalls`. Only names declared
    /// here, before `mainIndex` (the already-located main-statement
    /// keyword for this same `WITH`), are exempt; a token elsewhere that
    /// merely resembles this shape (for example a real function call
    /// following a `), ` sequence deeper in the query) is never exempted,
    /// because its index cannot appear in this set — the set is built by
    /// forward-parsing the WITH-clause grammar itself, not by
    /// pattern-matching around any one occurrence.
    ///
    /// A CTE body that is itself `WITH ... SELECT ...` opens its own,
    /// independently scoped CTE list, so its own declarations are
    /// collected by recursing into it.
    private func cteDeclarationExemptions(_ tokens: [SQLToken], withIndex: Int, mainIndex: Int) -> Set<Int> {
        var exemptions = Set<Int>()
        var cursor = withIndex + 1
        if tokens.indices.contains(cursor), tokens[cursor].isWord, tokens[cursor].text.uppercased() == "RECURSIVE" {
            cursor += 1
        }
        while cursor < mainIndex {
            guard tokens.indices.contains(cursor), tokens[cursor].isWord else { return exemptions }
            let nameIndex = cursor
            var next = cursor + 1
            if tokens.indices.contains(next), tokens[next].text == "(" {
                exemptions.insert(nameIndex)
                // `matchingCloseParen(after:)` takes the index of the token
                // immediately before the paren it matches, not the paren's
                // own index.
                guard let close = matchingCloseParen(after: nameIndex, tokens: tokens) else { return exemptions }
                next = close + 1
            }
            guard tokens.indices.contains(next), tokens[next].isWord, tokens[next].text.uppercased() == "AS" else { return exemptions }
            let asIndex = next
            next += 1
            guard tokens.indices.contains(next), tokens[next].text == "(" else { return exemptions }
            let bodyOpen = next
            guard let bodyClose = matchingCloseParen(after: asIndex, tokens: tokens) else { return exemptions }
            if tokens.indices.contains(bodyOpen + 1), tokens[bodyOpen + 1].isWord, tokens[bodyOpen + 1].text.uppercased() == "WITH",
               let nestedMain = topLevelMainStatementIndex(tokens, from: bodyOpen + 2, to: bodyClose) {
                exemptions.formUnion(cteDeclarationExemptions(tokens, withIndex: bodyOpen + 1, mainIndex: nestedMain))
            }
            cursor = bodyClose + 1
            guard cursor < mainIndex, tokens[cursor].text == "," else { return exemptions }
            cursor += 1
        }
        return exemptions
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
        // ANALYSE is PostgreSQL's accepted British spelling of ANALYZE —
        // an alternate spelling of the same keyword, not a different one.
        if words.contains("ANALYZE") || words.contains("ANALYSE") {
            throw MCPReadPolicyError.prohibitedOperation("EXPLAIN ANALYZE")
        }
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

/// Tokenizes over Unicode scalars (code points), never `Character`
/// (extended grapheme cluster). A grapheme cluster merges a trailing
/// combining mark onto whatever precedes it — including a quote,
/// semicolon, or paren — so comparing whole `Character`s can fail to
/// recognize a delimiter immediately followed by a combining mark. The
/// database lexes by code point, not by grapheme cluster, so it sees the
/// plain delimiter underneath regardless; scalar-level comparison here
/// keeps this tokenizer seeing the same boundaries the database does.
private struct SQLTokenizer {
    let scalars: [Unicode.Scalar]
    let dialect: MCPSQLDialect
    var index = 0
    init(_ sql: String, dialect: MCPSQLDialect) {
        scalars = Array(sql.unicodeScalars)
        self.dialect = dialect
    }

    mutating func tokenize() throws -> [SQLToken] {
        var output: [SQLToken] = []
        while index < scalars.count {
            let scalar = scalars[index]
            if isWhitespace(scalar) {
                index += 1
                continue
            }
            if scalar == "-", peek(1) == "-" {
                if dialect != .mysql || isWhitespace(peek(2)) {
                    skipLineComment(markerLength: 2)
                    continue
                }
            }
            if scalar == "#", dialect == .mysql {
                skipLineComment(markerLength: 1)
                continue
            }
            if scalar == "/", peek(1) == "*" {
                if dialect == .mysql, isMySQLExecutableCommentMarker() {
                    throw MCPReadPolicyError.prohibitedOperation("MySQL executable comment")
                }
                try skipBlockComment()
                continue
            }
            if scalar == "'" {
                output.append(SQLToken(text: try consumeQuoted("'", doubledEscape: true, rejectBackslash: true), isWord: false))
                continue
            }
            if scalar == "\"" {
                // PostgreSQL and SQLite always quote an identifier with
                // `"..."`. MySQL (outside ANSI_QUOTES mode, which this
                // policy does not attempt to detect) treats it as a string
                // literal instead, with exactly the same session-dependent
                // backslash-escape ambiguity as `'...'`.
                if dialect == .mysql {
                    output.append(SQLToken(text: try consumeQuoted("\"", doubledEscape: true, rejectBackslash: true), isWord: false))
                } else {
                    output.append(SQLToken(text: try consumeQuoted("\"", doubledEscape: true, rejectBackslash: false), isWord: false, isQuotedIdentifier: true))
                }
                continue
            }
            if scalar == "`" {
                output.append(SQLToken(text: try consumeQuoted("`", doubledEscape: true, rejectBackslash: false), isWord: false, isQuotedIdentifier: true))
                continue
            }
            if scalar == "[" {
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
            if scalar == "]", dialect == .postgresql {
                output.append(SQLToken(text: "]", isWord: false))
                index += 1
                continue
            }
            if scalar == "$", dialect == .postgresql, let quoted = try consumeDollarQuoteIfPresent() {
                output.append(SQLToken(text: quoted, isWord: false))
                continue
            }
            if isIdentifierStart(scalar) {
                let start = index
                index += 1
                while index < scalars.count, isIdentifierContinuation(scalars[index]) { index += 1 }
                output.append(SQLToken(text: string(scalars[start..<index]), isWord: true))
                continue
            }
            output.append(SQLToken(text: String(scalar), isWord: false))
            index += 1
        }
        return output
    }

    private func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }

    private func isWhitespace(_ scalar: Unicode.Scalar?) -> Bool { scalar.map { $0.properties.isWhitespace } ?? false }

    private func isIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar == "_"
    }

    private func isIdentifierContinuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || isASCIIDigit(scalar) || scalar == "_" || scalar == "$"
    }

    private func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }

    private func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }

    /// `/*M!...*/` (any case of `M`) is MariaDB's executable comment, the
    /// same escape hatch as MySQL's `/*!...*/`: content inside it is inert
    /// to a validator that only skips block comments, but MariaDB executes
    /// it as real SQL.
    private func isMySQLExecutableCommentMarker() -> Bool {
        if peek(2) == "!" { return true }
        guard let afterSlashStar = peek(2), afterSlashStar == "M" || afterSlashStar == "m" else { return false }
        return peek(3) == "!"
    }

    private mutating func skipLineComment(markerLength: Int) {
        index += markerLength
        while index < scalars.count, scalars[index] != "\n" { index += 1 }
    }

    private mutating func skipBlockComment() throws {
        index += 2
        var depth = 1
        while index < scalars.count {
            if scalars[index] == "/", peek(1) == "*" {
                guard dialect == .postgresql else {
                    throw MCPReadPolicyError.malformed("nested block comments are not accepted for this dialect")
                }
                depth += 1
                index += 2
                continue
            }
            if scalars[index] == "*", peek(1) == "/" {
                depth -= 1
                index += 2
                if depth == 0 { return }
                continue
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated block comment")
    }

    /// Backslash-escape semantics inside a string literal depend on
    /// PostgreSQL/MySQL session settings. Guessing here could hide a
    /// statement boundary, so the authorization grammar rejects the
    /// ambiguous form outright whenever `rejectBackslash` applies — for
    /// every string-literal quote style, not just `'...'`.
    private mutating func consumeQuoted(_ quote: Unicode.Scalar, doubledEscape: Bool, rejectBackslash: Bool) throws -> String {
        let start = index
        index += 1
        while index < scalars.count {
            if scalars[index] == quote {
                if doubledEscape, peek(1) == quote {
                    index += 2
                    continue
                }
                index += 1
                return string(scalars[start..<index])
            }
            if scalars[index] == "\\", rejectBackslash {
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
        while index < scalars.count {
            if scalars[index] == "]" {
                index += 1
                return string(scalars[start..<index])
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated bracket identifier")
    }

    /// PostgreSQL-only syntax. The opening tag must not start with a digit
    /// — `$1` is a positional parameter, not the start of a dollar-quote —
    /// so a digit-leading `$...$` is left for ordinary tokenization rather
    /// than treated as quoting. Treating it as quoting anyway would let a
    /// tag like `$1$` (`$1` plus a stray `$`) swallow everything up to a
    /// later matching `$1$` as inert content, hiding a real statement
    /// boundary that PostgreSQL itself would not treat as quoted.
    private mutating func consumeDollarQuoteIfPresent() throws -> String? {
        let start = index
        var cursor = index + 1
        if cursor < scalars.count, scalars[cursor] != "$" {
            // A non-empty tag (`$$` alone is the valid empty tag) must not
            // start with a digit.
            guard !isASCIIDigit(scalars[cursor]) else { return nil }
            while cursor < scalars.count, isIdentifierContinuation(scalars[cursor]) { cursor += 1 }
        }
        guard cursor < scalars.count, scalars[cursor] == "$" else { return nil }
        return try consumeDollarQuoteBody(start: start, tagEnd: cursor)
    }

    private mutating func consumeDollarQuoteBody(start: Int, tagEnd: Int) throws -> String {
        let delimiter = Array(scalars[start...tagEnd])
        index = tagEnd + 1
        while index + delimiter.count <= scalars.count {
            if Array(scalars[index..<(index + delimiter.count)]) == delimiter {
                index += delimiter.count
                return string(scalars[start..<index])
            }
            index += 1
        }
        throw MCPReadPolicyError.malformed("unterminated dollar quote")
    }
}
