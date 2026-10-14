import Foundation

/// Danger classification for a statement about to run.
public enum DangerLevel: Equatable, Sendable {
    case safe
    /// Simple confirmation dialog.
    case confirm(DangerReason)
 /// Type-the-object-name confirmation (DROP/TRUNCATE on production).
    case typedConfirm(objectName: String, reason: DangerReason)
}

public enum DangerReason: Equatable, Sendable {
    case updateWithoutWhere
    case deleteWithoutWhere
    case writeOnProduction
    case dropOnProduction
    case truncateOnProduction
 /// Data-destroying statements warn on ANY connection: a targeted
    /// DELETE, a DROP, or a TRUNCATE outside production.
    case deleteData
    case dropObject
    case truncateTable
 /// One summary confirmation for a whole run: N data-destroying
    /// statements ask ONCE, not N times.
    case deleteBatch(count: Int)
}

extension DangerReason {
    /// The soft data-deletion confirms (non-production). These are batched into
    /// one dialog per run and can be switched off by the user; the production
 /// rules are neither.
    public var isSoftDataDeletion: Bool {
        switch self {
        case .deleteData, .dropObject, .truncateTable, .deleteBatch: return true
        default: return false
        }
    }
}

/// Asked before a dangerous statement runs; implemented by the UI layer
/// (NSAlert) and wired into QueryService at startup — one gate for every SQL
/// path in the app (principle N1).
public protocol DangerConfirmer: Sendable {
    func confirm(_ level: DangerLevel, sql: String) async -> Bool
}

/// Lexical SQL danger classifier. Token scan only (strings/comments are
/// skipped), no parser — deliberately conservative: unknown statements are
/// treated as safe unless they carry a write keyword.
public enum DangerGuard {
    private static let writeKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE", "MERGE",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "GRANT", "REVOKE",
    ]

    public static func classify(_ sql: String, isProduction: Bool) -> DangerLevel {
        let statementTokens = topLevelTokens(sql)
        guard let leading = statementTokens.first?.uppercased() else { return .safe }

        // Transaction control is always safe.
        if ["BEGIN", "COMMIT", "ROLLBACK", "START", "SAVEPOINT", "RELEASE"].contains(leading) {
            return .safe
        }

        // A WITH clause or EXPLAIN ANALYZE carries out the write it wraps, so
        // that write decides, from its own keyword on. A WHERE after it that
        // belongs to an outer SELECT turns a no-WHERE warning into the
        // targeted-write one, which still asks.
        let tokens = Array(statementTokens[(embeddedWriteIndex(in: statementTokens) ?? 0)...])
        let first = tokens[0].uppercased()
        let upper = tokens.map { $0.uppercased() }
        let hasWhere = upper.contains("WHERE")

        if isProduction {
            switch first {
            case "DROP":
                return .typedConfirm(objectName: objectName(from: tokens), reason: .dropOnProduction)
            case "TRUNCATE":
                return .typedConfirm(objectName: objectName(from: tokens), reason: .truncateOnProduction)
            default:
                if writeKeywords.contains(first) {
                    // No-WHERE is the sharper warning even on production.
                    if first == "UPDATE", !hasWhere { return .confirm(.updateWithoutWhere) }
                    if first == "DELETE", !hasWhere { return .confirm(.deleteWithoutWhere) }
                    return .confirm(.writeOnProduction)
                }
                return .safe
            }
        }

        switch first {
        case "UPDATE" where !hasWhere:
            return .confirm(.updateWithoutWhere)
        case "DELETE" where !hasWhere:
            return .confirm(.deleteWithoutWhere)
        // Data-destroying statements always confirm, even off production
 // a targeted DELETE removes rows; DROP/TRUNCATE remove
        // objects/all rows.
        case "DELETE":
            return .confirm(.deleteData)
        case "DROP":
            return .confirm(.dropObject)
        case "TRUNCATE":
            return .confirm(.truncateTable)
        default:
            return .safe
        }
    }

    /// What a WITH clause may wrap or lead into that changes data
    /// (https://www.postgresql.org/docs/current/queries-with.html#QUERIES-WITH-MODIFYING).
    private static let dataModifyingKeywords: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]

    /// Keywords that begin the statement an EXPLAIN describes.
    private static let explainTargets: Set<String> = writeKeywords.union([
        "SELECT", "WITH", "VALUES", "TABLE", "EXECUTE", "DECLARE",
    ])

    /// Index of the write that a leading WITH clause, or an EXPLAIN that runs
    /// its statement, carries out; nil when the leading keyword decides.
    /// EXPLAIN without ANALYZE only plans the statement
    /// (https://www.postgresql.org/docs/current/sql-explain.html,
    /// https://dev.mysql.com/doc/refman/8.4/en/explain.html#explain-analyze).
    private static func embeddedWriteIndex(in tokens: [String]) -> Int? {
        let upper = tokens.map { $0.uppercased() }
        switch upper.first {
        case "WITH":
            return firstDataModifyingIndex(in: upper, from: 1)
        case "EXPLAIN":
            guard let target = upper.indices.dropFirst().first(where: { explainTargets.contains(upper[$0]) }),
                  upper[1..<target].contains(where: { analyzeSpellings.contains($0) })
            else { return nil }
            if upper[target] == "WITH" { return firstDataModifyingIndex(in: upper, from: target + 1) }
            return writeKeywords.contains(upper[target]) ? target : nil
        default:
            return nil
        }
    }

    /// `FOR UPDATE` and `FOR NO KEY UPDATE` lock the rows a read returns;
    /// they change no data.
    private static func firstDataModifyingIndex(in upper: [String], from start: Int) -> Int? {
        guard start < upper.count else { return nil }
        for index in start..<upper.count where dataModifyingKeywords.contains(upper[index]) {
            let locksRows = upper[index] == "UPDATE" && lockingUpdatePrefixes.contains(upper[index - 1])
            if !locksRows { return index }
        }
        return nil
    }

    private static let lockingUpdatePrefixes: Set<String> = ["FOR", "KEY"]
    private static let analyzeSpellings: Set<String> = ["ANALYZE", "ANALYSE"]

    /// Object name for typed confirmation: the last identifier of the
    /// statement head, unqualified ("schema"."name" → name), original casing.
    static func objectName(from tokens: [String]) -> String {
        let skip: Set<String> = [
            "DROP", "TRUNCATE", "TABLE", "VIEW", "INDEX", "SCHEMA", "DATABASE",
            "FUNCTION", "PROCEDURE", "TRIGGER", "SEQUENCE", "IF", "EXISTS",
            "CASCADE", "RESTRICT", "ONLY", "MATERIALIZED",
        ]
        let candidates = tokens.dropFirst().filter { !skip.contains($0.uppercased()) }
        guard let raw = candidates.first else { return "" }
        // Unqualify and unquote.
        let lastPart = raw.split(separator: ".").last.map(String.init) ?? raw
        return lastPart.trimmingCharacters(in: CharacterSet(charactersIn: "\"`'"))
    }

    /// Identifier/keyword tokens outside strings, comments, and dollar quotes.
    /// Quoted identifiers are kept as single tokens (with their quotes).
    static func topLevelTokens(_ sql: String) -> [String] {
        scanTokens(sql).tokens
    }

    /// Scalars read while scanning `sql` for tokens. Every statement is
    /// classified synchronously by its caller, often the main actor, before
    /// any query timeout applies, so tests hold this linear in the length of
    /// the text.
    static func tokenScanReads(_ sql: String) -> Int {
        scanTokens(sql).reads
    }

    /// The scanned text, readable only through subscripts that count every
    /// scalar they return, so a rescan added anywhere in the scan shows up in
    /// `tokenScanReads` instead of only in wall-clock time.
    private struct CountedScalars {
        private let storage: [Unicode.Scalar]
        private(set) var reads = 0

        init(_ text: String) { storage = Array(text.unicodeScalars) }

        var count: Int { storage.count }

        subscript(position: Int) -> Unicode.Scalar {
            mutating get {
                reads += 1
                return storage[position]
            }
        }

        subscript<R: RangeExpression>(bounds: R) -> ArraySlice<Unicode.Scalar> where R.Bound == Int {
            mutating get {
                let range = bounds.relative(to: storage)
                reads += range.count
                return storage[range]
            }
        }
    }

    private static func scanTokens(_ sql: String) -> (tokens: [String], reads: Int) {
        var tokens: [String] = []
        var scalars = CountedScalars(sql)
        var i = 0

        func isWordScalar(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(s) || s == "_" || s == "."
        }

        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "'":
                i += 1
                while i < scalars.count {
                    if scalars[i] == "'" {
                        i += 1
                        if i < scalars.count, scalars[i] == "'" { i += 1; continue }
                        break
                    }
                    i += 1
                }
            case "\"", "`":
                // Quoted identifier — capture as one token including quotes.
                let quote = c
                var token = String(c)
                i += 1
                while i < scalars.count {
                    token.unicodeScalars.append(scalars[i])
                    if scalars[i] == quote { i += 1; break }
                    i += 1
                }
                tokens.append(token)
            case "-" where i + 1 < scalars.count && scalars[i + 1] == "-":
                while i < scalars.count, scalars[i] != "\n" { i += 1 }
            case "/" where i + 1 < scalars.count && scalars[i + 1] == "*":
                i += 2
                while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                i = min(i + 2, scalars.count)
            case "$":
                var j = i + 1
                while j < scalars.count,
                      scalars[j] == "_" || CharacterSet.alphanumerics.contains(scalars[j]) {
                    j += 1
                }
                if j < scalars.count, scalars[j] == "$" {
                    let tag = Array(scalars[i...j])
                    i = j + 1
                    // The closing tag is compared in place. Only its first
                    // and last scalars are `$`, so the scalars a failed
                    // candidate matched after its opening `$` cannot start
                    // the closing tag, and the search resumes at the scalar
                    // that differed. Copying the candidate at every `$`
                    // instead cost the tag's length per `$`, quadratic for a
                    // long tag over a body full of `$`.
                    while i < scalars.count {
                        guard scalars[i] == "$" else {
                            i += 1
                            continue
                        }
                        var matched = 1
                        while matched < tag.count, i + matched < scalars.count,
                              scalars[i + matched] == tag[matched] {
                            matched += 1
                        }
                        i += matched
                        if matched == tag.count { break }
                    }
                } else {
                    i += 1
                }
            default:
                if isWordScalar(c), !CharacterSet.decimalDigits.contains(c) || !(tokens.isEmpty) {
                    var token = ""
                    while i < scalars.count, isWordScalar(scalars[i]) {
                        token.unicodeScalars.append(scalars[i])
                        i += 1
                    }
                    tokens.append(token)
                } else {
                    i += 1
                }
            }
        }
        return (tokens, scalars.reads)
    }
}
