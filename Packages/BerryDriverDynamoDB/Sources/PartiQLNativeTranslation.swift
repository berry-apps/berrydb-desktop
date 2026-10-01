import BerryDriverKit
import Foundation

/// The four `AttributeValue` scalars `PartiQLDialect.literal(_:)` can render
/// for a ChangeSet edit. A literal outside this set (`X'…'` binary, `inf`)
/// has no faithful native encoding here, so translation returns nil and the
/// original PartiQL error reaches the user instead of a guess.
enum DynamoDBScalar: Equatable, Sendable {
    case string(String)
    /// Verbatim text — DynamoDB `N` is arbitrary precision, never round-tripped through `Double`.
    case number(String)
    case bool(Bool)
    case null
}

/// The IAM action `ExecuteStatement` checks for each statement kind. Policies
/// grant them independently, so a denial is remembered per action.
enum PartiQLAction: Hashable, Sendable {
    case select, insert, update, delete
}

/// One ChangeSet-generated write, decoded from its SQL text.
enum NativeWrite: Equatable, Sendable {
    case insert(table: String, item: [String: DynamoDBScalar])
    case update(table: String, key: [String: DynamoDBScalar], column: String, value: DynamoDBScalar)
    case delete(table: String, key: [String: DynamoDBScalar])

    var partiQLAction: PartiQLAction {
        switch self {
        case .insert: return .insert
        case .update: return .update
        case .delete: return .delete
        }
    }
}

/// Recognizes the exact statement shapes BerryDB itself generates —
/// `PartiQLDialect.select` for an unfiltered, unsorted grid page and
/// `ChangeSet.statements` for edits — so `DynamoDBConnection` can replay them
/// through the native item API when IAM denies `dynamodb:PartiQL*`.
///
/// Deliberately not a PartiQL parser: anything else (WHERE/ORDER BY on a
/// SELECT, projections, `"Table"."Index"`, hand-written statements) returns
/// nil and keeps the PartiQL error. Translating a WHERE into a
/// `FilterExpression` would need an expression compiler, and would silently
/// turn key lookups into full-table Scans.
enum PartiQLNativeTranslation {
    /// `SELECT * FROM "Table"` → `"Table"`.
    static func scanTable(_ sql: String) -> String? {
        guard var tokens = PartiQLTokens(sql) else { return nil }
        guard tokens.keyword("SELECT"), tokens.word("*"), tokens.keyword("FROM"),
              let table = tokens.identifier(), tokens.isAtEnd
        else { return nil }
        return table
    }

    static func write(_ sql: String) -> NativeWrite? {
        guard var tokens = PartiQLTokens(sql) else { return nil }
        if tokens.keyword("UPDATE") {
            guard let table = tokens.identifier(), tokens.keyword("SET"),
                  let column = tokens.identifier(), tokens.punct("="),
                  let value = tokens.literal(), tokens.keyword("WHERE"),
                  let key = tokens.keyEqualities(), tokens.isAtEnd
            else { return nil }
            return .update(table: table, key: key, column: column, value: value)
        }
        if tokens.keyword("DELETE") {
            guard tokens.keyword("FROM"), let table = tokens.identifier(), tokens.keyword("WHERE"),
                  let key = tokens.keyEqualities(), tokens.isAtEnd
            else { return nil }
            return .delete(table: table, key: key)
        }
        if tokens.keyword("INSERT") {
            guard tokens.keyword("INTO"), let table = tokens.identifier(), tokens.punct("("),
                  let columns = tokens.parenthesizedList({ $0.identifier() }),
                  tokens.keyword("VALUES"), tokens.punct("("),
                  let values = tokens.parenthesizedList({ $0.literal() }),
                  tokens.isAtEnd, !columns.isEmpty, columns.count == values.count,
                  Set(columns).count == columns.count
            else { return nil }
            return .insert(table: table, item: Dictionary(uniqueKeysWithValues: zip(columns, values)))
        }
        return nil
    }
}

/// Minimal lexer over the text `PartiQLDialect` renders: `"identifiers"` and
/// `'strings'` (both with doubled-quote escaping), the punctuation `( ) , =`,
/// and bare words (keywords, numbers, `*`, and anything unexpected).
private struct PartiQLTokens {
    private enum Token: Equatable {
        case identifier(String)
        case string(String)
        case word(String)
        case punct(Character)
    }

    private static let punctuation: Set<Character> = ["(", ")", ",", "="]

    private var tokens: [Token] = []
    private var position = 0

    /// nil on an unterminated quote.
    init?(_ sql: String) {
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
            } else if c == "\"" || c == "'" {
                var text = ""
                var closed = false
                i += 1
                while i < chars.count {
                    if chars[i] == c {
                        if i + 1 < chars.count, chars[i + 1] == c {
                            text.append(c)
                            i += 2
                            continue
                        }
                        closed = true
                        i += 1
                        break
                    }
                    text.append(chars[i])
                    i += 1
                }
                guard closed else { return nil }
                tokens.append(c == "\"" ? .identifier(text) : .string(text))
            } else if Self.punctuation.contains(c) {
                tokens.append(.punct(c))
                i += 1
            } else {
                var word = ""
                while i < chars.count, !chars[i].isWhitespace, !Self.punctuation.contains(chars[i]),
                      chars[i] != "\"", chars[i] != "'" {
                    word.append(chars[i])
                    i += 1
                }
                tokens.append(.word(word))
            }
        }
    }

    var isAtEnd: Bool { position == tokens.count }

    mutating func punct(_ c: Character) -> Bool { take(.punct(c)) }

    mutating func word(_ w: String) -> Bool { take(.word(w)) }

    /// Case-insensitive, as PartiQL keywords are.
    mutating func keyword(_ k: String) -> Bool {
        guard position < tokens.count, case .word(let w) = tokens[position], w.uppercased() == k
        else { return false }
        position += 1
        return true
    }

    mutating func identifier() -> String? {
        guard position < tokens.count, case .identifier(let name) = tokens[position] else { return nil }
        position += 1
        return name
    }

    /// Inverse of `PartiQLDialect.literal(_:)` for its scalar cases.
    mutating func literal() -> DynamoDBScalar? {
        guard position < tokens.count else { return nil }
        let scalar: DynamoDBScalar?
        switch tokens[position] {
        case .string(let s):
            scalar = .string(s)
        case .word(let w):
            switch w.uppercased() {
            case "TRUE": scalar = .bool(true)
            case "FALSE": scalar = .bool(false)
            case "NULL": scalar = .null
            default: scalar = Self.isNumber(w) ? .number(w) : nil
            }
        default:
            scalar = nil
        }
        if scalar != nil { position += 1 }
        return scalar
    }

    /// `"k1" = lit AND "k2" = lit …` — ChangeSet's WHERE over every key column.
    /// NULL never identifies a DynamoDB key (ChangeSet renders it `IS NULL`,
    /// which fails the `=` match here as well).
    mutating func keyEqualities() -> [String: DynamoDBScalar]? {
        var key: [String: DynamoDBScalar] = [:]
        repeat {
            guard let name = identifier(), punct("="), let value = literal(),
                  value != .null, key[name] == nil
            else { return nil }
            key[name] = value
        } while keyword("AND")
        return key
    }

    /// Comma-separated elements up to the closing `)`; the opening `(` is
    /// already consumed.
    mutating func parenthesizedList<T>(_ element: (inout PartiQLTokens) -> T?) -> [T]? {
        var items: [T] = []
        repeat {
            guard let item = element(&self) else { return nil }
            items.append(item)
        } while punct(",")
        return punct(")") ? items : nil
    }

    private mutating func take(_ token: Token) -> Bool {
        guard position < tokens.count, tokens[position] == token else { return false }
        position += 1
        return true
    }

    /// Digits/sign/point/exponent only, and parseable. This rejects `inf`/`nan`
    /// (what `String(Double)` renders for non-finite values) and hex floats.
    private static func isNumber(_ w: String) -> Bool {
        w.allSatisfy { "0123456789+-.eE".contains($0) } && Double(w) != nil
    }
}

