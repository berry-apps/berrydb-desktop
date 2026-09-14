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
        let tokens = topLevelTokens(sql)
        guard let first = tokens.first?.uppercased() else { return .safe }
        let upper = tokens.map { $0.uppercased() }

        // Transaction control is always safe.
        if ["BEGIN", "COMMIT", "ROLLBACK", "START", "SAVEPOINT", "RELEASE"].contains(first) {
            return .safe
        }

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
        var tokens: [String] = []
        let scalars = Array(sql.unicodeScalars)
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
                    while i < scalars.count {
                        if scalars[i] == "$", i + tag.count <= scalars.count,
                           Array(scalars[i..<(i + tag.count)]) == tag {
                            i += tag.count
                            break
                        }
                        i += 1
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
        return tokens
    }
}
