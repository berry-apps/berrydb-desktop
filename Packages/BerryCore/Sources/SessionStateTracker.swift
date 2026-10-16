import Foundation

/// What a session's own connection holds that a second connection to the
/// same database would not see: a temporary object, a session setting, a
/// prepared statement or cursor, or an open transaction. A statement that
/// runs on another connection while any of them is held can read different
/// rows, or none, from what the user's next statement would read.
///
/// Fed by `QueryService` with every statement that succeeded on a session's
/// own connection. It reads only the statements' leading keywords, so it
/// misses state made in other ways, such as a function that creates a
/// temporary table; the read-only connection then reads without that state,
/// which can make a statement see different rows but never lets it write.
public final class SessionStateTracker: @unchecked Sendable {
    public struct State: Sendable, Equatable {
        /// Lasts until the session closes.
        public var hasSessionLocalState: Bool
        public var hasOpenTransaction: Bool
        /// MySQL's `autocommit` is off: the server opens the next transaction
        /// as soon as one ends, so this holds from `SET autocommit = 0` until
        /// `SET autocommit = 1`, whatever COMMIT or ROLLBACK do in between.
        public var isAutocommitOff: Bool

        public init(
            hasSessionLocalState: Bool = false,
            hasOpenTransaction: Bool = false,
            isAutocommitOff: Bool = false
        ) {
            self.hasSessionLocalState = hasSessionLocalState
            self.hasOpenTransaction = hasOpenTransaction
            self.isAutocommitOff = isAutocommitOff
        }

        /// Whether another connection would read the database differently
        /// from the session's own.
        public var isHiddenFromOtherConnections: Bool { hasSessionLocalState || hasOpenTransaction || isAutocommitOff }
    }

    enum Effect: Equatable {
        case sessionLocal
        case beginsTransaction
        case endsTransaction
        case turnsAutocommitOff
        case turnsAutocommitOn
    }

    public static let shared = SessionStateTracker()

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    public init() {}

    public func state(for sessionID: UUID) -> State {
        lock.lock()
        defer { lock.unlock() }
        return states[sessionID] ?? State()
    }

    /// Records a text that succeeded on the session's own connection, its
    /// statements applied in order.
    public func recordSucceeded(_ sql: String, sessionID: UUID) {
        let effects = Self.effects(of: sql)
        guard !effects.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var state = states[sessionID] ?? State()
        for effect in effects {
            switch effect {
            case .sessionLocal: state.hasSessionLocalState = true
            case .beginsTransaction: state.hasOpenTransaction = true
            case .endsTransaction: state.hasOpenTransaction = false
            case .turnsAutocommitOff:
                state.isAutocommitOff = true
                state.hasOpenTransaction = true
            case .turnsAutocommitOn:
                state.isAutocommitOff = false
                state.hasOpenTransaction = false
            }
        }
        states[sessionID] = state
    }

    public func forget(sessionID: UUID) {
        lock.lock()
        states[sessionID] = nil
        lock.unlock()
    }

    /// Whether anything was recorded for the session since it was last
    /// forgotten, so a test can tell a forgotten session from one recorded
    /// again with nothing held.
    func isTracking(sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[sessionID] != nil
    }

    /// One pass over the text per statement it holds; a text without a
    /// semicolon is one statement and is not split.
    static func effects(of sql: String) -> [Effect] {
        let statements = sql.contains(";") ? StatementSplitter.split(sql).map(\.sql) : [sql]
        return statements.compactMap(effect(of:))
    }

    private static func effect(of statement: String) -> Effect? {
        let lead = words(in: statement, limit: 6)
        guard let first = lead.first else { return nil }
        let rest = lead.dropFirst()
        switch first {
        case "BEGIN":
            return .beginsTransaction
        case "START":
            return rest.first == "TRANSACTION" ? .beginsTransaction : nil
        case "COMMIT", "ROLLBACK", "END", "ABORT":
            // ROLLBACK TO ends a savepoint, not the transaction; AND CHAIN
            // starts the next transaction at once, while AND NO CHAIN (the
            // default) does not.
            if rest.contains("TO") { return nil }
            if let chain = rest.firstIndex(of: "CHAIN"),
               chain == rest.startIndex || rest[rest.index(before: chain)] != "NO" {
                return nil
            }
            return .endsTransaction
        case "CREATE":
            let kind = rest.first { !["OR", "REPLACE", "GLOBAL", "LOCAL"].contains($0) }
            return kind == "TEMP" || kind == "TEMPORARY" ? .sessionLocal : nil
        case "SET":
            let target = rest.first { $0 != "SESSION" && $0 != "LOCAL" }
            if target == "AUTOCOMMIT" {
                return autocommitEffect(rest.drop { $0 != "AUTOCOMMIT" }.dropFirst().first)
            }
            // SET SCHEMA is PostgreSQL's alias for setting search_path
            // (https://www.postgresql.org/docs/current/sql-set.html).
            return ["SEARCH_PATH", "SCHEMA", "ROLE", "AUTHORIZATION"].contains(target ?? "") ? .sessionLocal : nil
        case "USE", "ATTACH", "PREPARE", "DECLARE":
            return .sessionLocal
        case "SELECT", "WITH":
            // PostgreSQL's SELECT ... INTO TEMP creates a temporary table.
            let all = words(in: statement, limit: .max)
            let createsTemporary = zip(all, all.dropFirst()).contains {
                $0.0 == "INTO" && ($0.1 == "TEMP" || $0.1 == "TEMPORARY")
            }
            return createsTemporary ? .sessionLocal : nil
        default:
            return nil
        }
    }

    /// MySQL's `SET autocommit`. Turned off, it keeps a transaction open from
    /// the next statement on (https://dev.mysql.com/doc/refman/8.4/en/commit.html),
    /// and a COMMIT or ROLLBACK does not end that: the server opens the next
    /// transaction at once, holding rows another connection cannot see. So the
    /// session stays hidden until autocommit is turned back on, which commits
    /// the open transaction (https://dev.mysql.com/doc/refman/8.4/en/implicit-commit.html).
    private static func autocommitEffect(_ value: String?) -> Effect? {
        switch value {
        case "0", "OFF", "FALSE": .turnsAutocommitOff
        case "1", "ON", "TRUE": .turnsAutocommitOn
        default: nil
        }
    }

    /// The first `limit` words of `text`, upper-cased, skipping comments and
    /// quoted strings and identifiers, so a keyword inside a literal is never
    /// read as one.
    static func words(in text: String, limit: Int) -> [String] {
        let bytes = Array(text.utf8)
        var words: [String] = []
        var start: Int?
        var index = 0

        func isWordByte(_ byte: UInt8) -> Bool {
            byte >= 0x80 || byte == UInt8(ascii: "_")
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
        }

        // PostgreSQL nests block comments, so `/* a /* b */ USE x */` is one
        // comment there; other engines end it at the first `*/`, which reads
        // the same unless a comment closes early, a case that only ever
        // hides a keyword, never invents one.
        func skipBlockComment(from position: Int) -> Int {
            var cursor = position
            var depth = 1
            while cursor < bytes.count, depth > 0 {
                if bytes[cursor...].starts(with: [UInt8(ascii: "/"), UInt8(ascii: "*")]) {
                    depth += 1
                    cursor += 2
                } else if bytes[cursor...].starts(with: [UInt8(ascii: "*"), UInt8(ascii: "/")]) {
                    depth -= 1
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            return min(cursor, bytes.count)
        }

        func skip(until terminator: [UInt8], from position: Int) -> Int {
            var cursor = position
            while cursor < bytes.count {
                if bytes[cursor...].starts(with: terminator) { return cursor + terminator.count }
                cursor += 1
            }
            return bytes.count
        }

        while index < bytes.count, words.count < limit {
            let byte = bytes[index]
            if isWordByte(byte) {
                if start == nil { start = index }
                index += 1
                continue
            }
            if let wordStart = start {
                words.append(String(decoding: bytes[wordStart..<index], as: UTF8.self).uppercased())
                start = nil
                continue
            }
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            switch byte {
            case UInt8(ascii: "-") where next == UInt8(ascii: "-"):
                index = skip(until: [UInt8(ascii: "\n")], from: index + 2)
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                index = skipBlockComment(from: index + 2)
            case UInt8(ascii: "#") where words.isEmpty:
                // MySQL's line comment; elsewhere `#` is an operator, which
                // never leads a statement.
                index = skip(until: [UInt8(ascii: "\n")], from: index + 1)
            case UInt8(ascii: "'"), UInt8(ascii: "\""), UInt8(ascii: "`"):
                index = skip(until: [byte], from: index + 1)
            default:
                index += 1
            }
        }
        if let wordStart = start, words.count < limit {
            words.append(String(decoding: bytes[wordStart..<index], as: UTF8.self).uppercased())
        }
        return words
    }
}
