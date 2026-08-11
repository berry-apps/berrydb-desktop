import Foundation

/// Lexical tokens for the Mongo shell query language (`db.<collection>.<method>(args)`,
/// docs/feedback/01.md item 2). Deliberately small: this is a query console
/// grammar, not general JavaScript — no expressions, only literal arguments.
public enum MongoShellToken: Equatable, Sendable {
    case identifier(String)
    case string(String)
    case number(Double)
    case leftParen, rightParen
    case leftBrace, rightBrace
    case leftBracket, rightBracket
    case comma, colon, dot, semicolon
    case keywordTrue, keywordFalse, keywordNull, keywordNew
}

public enum MongoShellLexError: Error, Equatable, Sendable {
    case unterminatedString
    case unexpectedCharacter(Character)
}

public enum MongoShellLexer {
    public static func tokenize(_ text: String) throws -> [MongoShellToken] {
        var tokens: [MongoShellToken] = []
        let chars = Array(text)
        var i = 0
        func peek(_ offset: Int = 0) -> Character? {
            let j = i + offset
            return j < chars.count ? chars[j] : nil
        }

        while let c = peek() {
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "/", peek(1) == "/" {
                while let c = peek(), c != "\n" { i += 1 }
                continue
            }
            if c == "/", peek(1) == "*" {
                i += 2
                while peek() != nil, !(peek() == "*" && peek(1) == "/") { i += 1 }
                i += 2
                continue
            }
            switch c {
            case "(": tokens.append(.leftParen); i += 1
            case ")": tokens.append(.rightParen); i += 1
            case "{": tokens.append(.leftBrace); i += 1
            case "}": tokens.append(.rightBrace); i += 1
            case "[": tokens.append(.leftBracket); i += 1
            case "]": tokens.append(.rightBracket); i += 1
            case ",": tokens.append(.comma); i += 1
            case ":": tokens.append(.colon); i += 1
            case ".": tokens.append(.dot); i += 1
            case ";": tokens.append(.semicolon); i += 1
            case "'", "\"":
                let quote = c
                i += 1
                var value = ""
                while let ch = peek(), ch != quote {
                    if ch == "\\", peek(1) != nil {
                        value.append(peek(1)!)
                        i += 2
                    } else {
                        value.append(ch)
                        i += 1
                    }
                }
                guard peek() == quote else { throw MongoShellLexError.unterminatedString }
                i += 1
                tokens.append(.string(value))
            default:
                if c == "-" || c.isNumber {
                    var text = String(c)
                    i += 1
                    while let ch = peek(), ch.isNumber || ch == "." {
                        text.append(ch)
                        i += 1
                    }
                    guard let n = Double(text) else { throw MongoShellLexError.unexpectedCharacter(c) }
                    tokens.append(.number(n))
                } else if c == "_" || c == "$" || c.isLetter {
                    var text = String(c)
                    i += 1
                    while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" || ch == "$" {
                        text.append(ch)
                        i += 1
                    }
                    switch text {
                    case "true": tokens.append(.keywordTrue)
                    case "false": tokens.append(.keywordFalse)
                    case "null": tokens.append(.keywordNull)
                    case "new": tokens.append(.keywordNew)
                    default: tokens.append(.identifier(text))
                    }
                } else {
                    throw MongoShellLexError.unexpectedCharacter(c)
                }
            }
        }
        return tokens
    }
}

public struct MongoShellCall: Equatable, Sendable {
    public let method: String
    public let arguments: [BerryDocument]
}

/// One `db.<collection>.<method>(args)[.<chain>(args)]*` statement, plus its
/// original source slice (used for the result-tab label and history text).
public struct MongoShellStatement: Equatable, Sendable {
    public let collection: String
    public let calls: [MongoShellCall]
    public let rawText: String
}

public enum MongoShellParseError: Error, Equatable, Sendable {
    case expectedDbPrefix
    case unexpectedToken(String)
    case unexpectedEnd
    case trailingTokens
}

public enum MongoShellParser {
    /// Splits `;`-separated statements at depth 0 (outside any `(){}[]`/string),
    /// then lexes+parses each independently. Empty/whitespace-only chunks are
    /// dropped so a trailing `;` or blank line doesn't produce a phantom
    /// statement.
    public static func parse(_ script: String) throws -> [MongoShellStatement] {
        let chunks = splitStatements(script)
        var statements: [MongoShellStatement] = []
        for chunk in chunks {
            var tokens = try MongoShellLexer.tokenize(chunk)
            if tokens.first == .identifier("const") || tokens.first == .identifier("let") || tokens.first == .identifier("var") {
                continue
            }
            if tokens.first != .identifier("db") {
                continue
            }
            let (collection, calls) = try parseSingleStatement(&tokens)
            statements.append(MongoShellStatement(
                collection: collection, calls: calls,
                rawText: chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        if statements.isEmpty && !chunks.isEmpty {
            throw MongoShellParseError.expectedDbPrefix
        }
        return statements
    }

    private static func splitStatements(_ script: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var depth = 0
        var inString: Character?
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let quote = inString {
                current.append(c)
                if c == "\\", i + 1 < chars.count {
                    current.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == quote { inString = nil }
                i += 1
                continue
            }
            switch c {
            case "'", "\"":
                inString = c
                current.append(c)
            case "(", "{", "[":
                depth += 1
                current.append(c)
            case ")", "}", "]":
                depth -= 1
                current.append(c)
            case ";" where depth == 0:
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
                current = ""
            default:
                current.append(c)
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks
    }

    private static func parseSingleStatement(
        _ tokens: inout [MongoShellToken]
    ) throws -> (collection: String, calls: [MongoShellCall]) {
        if tokens.first == .identifier("const") || tokens.first == .identifier("let") || tokens.first == .identifier("var") {
            throw MongoShellParseError.unexpectedToken("JavaScript variable declarations ('const', 'let', 'var') are not supported in Mongo Shell. Write statements starting directly with db.<collection>.<method>(...)")
        }
        guard tokens.first == .identifier("db") else { throw MongoShellParseError.expectedDbPrefix }
        tokens.removeFirst()
        try expect(.dot, &tokens)
        let collection = try expectIdentifier(&tokens)
        try expect(.dot, &tokens)
        var calls = [try parseCall(&tokens)]
        while tokens.first == .dot {
            tokens.removeFirst()
            calls.append(try parseCall(&tokens))
        }
        guard tokens.isEmpty else { throw MongoShellParseError.trailingTokens }
        return (collection, calls)
    }

    private static func parseCall(_ tokens: inout [MongoShellToken]) throws -> MongoShellCall {
        let method = try expectIdentifier(&tokens)
        try expect(.leftParen, &tokens)
        var arguments: [BerryDocument] = []
        if tokens.first != .rightParen {
            arguments.append(try parseValue(&tokens))
            while tokens.first == .comma {
                tokens.removeFirst()
                arguments.append(try parseValue(&tokens))
            }
        }
        try expect(.rightParen, &tokens)
        return MongoShellCall(method: method, arguments: arguments)
    }

    private static func parseValue(_ tokens: inout [MongoShellToken]) throws -> BerryDocument {
        guard let first = tokens.first else { throw MongoShellParseError.unexpectedEnd }
        switch first {
        case .leftBrace: return try parseObject(&tokens)
        case .leftBracket: return try parseArray(&tokens)
        case .string(let s): tokens.removeFirst(); return .string(s)
        case .number(let n):
            tokens.removeFirst()
            return n == n.rounded() && abs(n) < 1e18 ? .int(Int64(n)) : .double(n)
        case .keywordTrue: tokens.removeFirst(); return .bool(true)
        case .keywordFalse: tokens.removeFirst(); return .bool(false)
        case .keywordNull: tokens.removeFirst(); return .null
        case .keywordNew:
            tokens.removeFirst()
            let name = try expectIdentifier(&tokens)
            return try parseConstructorCall(name: name, tokens: &tokens)
        case .identifier(let name) where name == "ObjectId" || name == "ISODate":
            tokens.removeFirst()
            return try parseConstructorCall(name: name, tokens: &tokens)
        case .identifier(let name):
            tokens.removeFirst()
            return .string(name)
        default:
            throw MongoShellParseError.unexpectedToken("\(first)")
        }
    }

    /// `ObjectId("...")`, `new Date("...")`, `ISODate("...")` — the shell
    /// literals real mongosh scripts use for ids/dates.
    private static func parseConstructorCall(
        name: String, tokens: inout [MongoShellToken]
    ) throws -> BerryDocument {
        try expect(.leftParen, &tokens)
        var arguments: [BerryDocument] = []
        if tokens.first != .rightParen {
            arguments.append(try parseValue(&tokens))
            while tokens.first == .comma {
                tokens.removeFirst()
                arguments.append(try parseValue(&tokens))
            }
        }
        try expect(.rightParen, &tokens)
        switch name {
        case "ObjectId":
            guard let first = arguments.first else {
                return .objectID(Self.generateObjectIdHex())
            }
            switch first {
            case .string(let hex):
                return .objectID(hex)
            case .int(let n):
                return .objectID(String(format: "%024x", n))
            case .double(let d):
                return .objectID(String(format: "%024x", Int64(d)))
            default:
                return .objectID(Self.generateObjectIdHex())
            }
        case "Date", "ISODate":
            guard let first = arguments.first else {
                return .date(Date())  // bare `new Date()` — matches mongosh's "now" semantics
            }
            guard case .string(let iso) = first, let date = Self.parseMongoDate(iso) else {
                throw MongoShellParseError.unexpectedToken("\(name)(...) expects an ISO8601 date string")
            }
            return .date(date)
        default:
            throw MongoShellParseError.unexpectedToken("unknown constructor \(name)")
        }
    }

    private static func parseMongoDate(_ string: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: string) { return d }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFractional.date(from: string) { return d }
        let isoDateOnly = ISO8601DateFormatter()
        isoDateOnly.formatOptions = [.withFullDate]
        if let d = isoDateOnly.date(from: string) { return d }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let formats = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    private static func parseObject(_ tokens: inout [MongoShellToken]) throws -> BerryDocument {
        try expect(.leftBrace, &tokens)
        var fields: [(String, BerryDocument)] = []
        if tokens.first != .rightBrace {
            fields.append(try parseField(&tokens))
            while tokens.first == .comma {
                tokens.removeFirst()
                if tokens.first == .rightBrace { break } // trailing comma
                fields.append(try parseField(&tokens))
            }
        }
        try expect(.rightBrace, &tokens)
        return .object(fields)
    }

    private static func parseField(_ tokens: inout [MongoShellToken]) throws -> (String, BerryDocument) {
        let key: String
        switch tokens.first {
        case .identifier(let name): tokens.removeFirst(); key = name
        case .string(let s): tokens.removeFirst(); key = s
        default: throw MongoShellParseError.unexpectedToken("expected an object key")
        }
        try expect(.colon, &tokens)
        return (key, try parseValue(&tokens))
    }

    private static func parseArray(_ tokens: inout [MongoShellToken]) throws -> BerryDocument {
        try expect(.leftBracket, &tokens)
        var items: [BerryDocument] = []
        if tokens.first != .rightBracket {
            items.append(try parseValue(&tokens))
            while tokens.first == .comma {
                tokens.removeFirst()
                if tokens.first == .rightBracket { break }
                items.append(try parseValue(&tokens))
            }
        }
        try expect(.rightBracket, &tokens)
        return .array(items)
    }

    private static func expect(_ token: MongoShellToken, _ tokens: inout [MongoShellToken]) throws {
        guard tokens.first == token else {
            throw MongoShellParseError.unexpectedToken(
                "expected \(token), got \(tokens.first.map { "\($0)" } ?? "end")"
            )
        }
        tokens.removeFirst()
    }

    private static func expectIdentifier(_ tokens: inout [MongoShellToken]) throws -> String {
        guard case .identifier(let name) = tokens.first else {
            throw MongoShellParseError.unexpectedToken("expected identifier, got \(tokens.first.map { "\($0)" } ?? "end")")
        }
        tokens.removeFirst()
        return name
    }

    private static func generateObjectIdHex() -> String {
        let timestamp = UInt32(Date().timeIntervalSince1970)
        let random1 = UInt32.random(in: 0...0xFFFFFF)
        let random2 = UInt16.random(in: 0...0xFFFF)
        let counter = UInt32.random(in: 0...0xFFFFFF)
        return String(format: "%08x%06x%04x%06x", timestamp, random1, random2, counter)
    }
}
