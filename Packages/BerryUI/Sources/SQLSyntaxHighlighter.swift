import AppKit
import BerryCore
import Foundation

/// High-performance lexical syntax highlighter for SQL Editor.
/// Applies rich token colors (keywords, built-in functions, data types,
/// quoted identifiers, literals, and comments) with dynamic Light/Dark mode palette.
public enum SQLSyntaxHighlighter {
    // MARK: - Dynamic Theme Colors

    public static let keywordColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x5C/255.0, green: 0x9C/255.0, blue: 1.0, alpha: 1.0)
            : NSColor(srgbRed: 0x00/255.0, green: 0x33/255.0, blue: 0xB3/255.0, alpha: 1.0)
    }

    public static let functionColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x4E/255.0, green: 0xC9/255.0, blue: 0xB0/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x00/255.0, green: 0x7A/255.0, blue: 0x87/255.0, alpha: 1.0)
    }

    public static let typeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xE5/255.0, green: 0xB5/255.0, blue: 0x67/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x9C/255.0, green: 0x5B/255.0, blue: 0x00/255.0, alpha: 1.0)
    }

    public static let quotedIdentifierColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x9C/255.0, green: 0xDC/255.0, blue: 0xFE/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x2E/255.0, green: 0x5B/255.0, blue: 0x88/255.0, alpha: 1.0)
    }

    public static let stringColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xCE/255.0, green: 0x91/255.0, blue: 0x78/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0xA3/255.0, green: 0x15/255.0, blue: 0x15/255.0, alpha: 1.0)
    }

    public static let numberColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xB5/255.0, green: 0xCE/255.0, blue: 0xA8/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x78/255.0, green: 0x2E/255.0, blue: 0x9E/255.0, alpha: 1.0)
    }

    public static let commentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x6A/255.0, green: 0x99/255.0, blue: 0x55/255.0, alpha: 1.0)
            : NSColor(srgbRed: 0x5C/255.0, green: 0x63/255.0, blue: 0x70/255.0, alpha: 1.0)
    }

    // MARK: - Token Definitions

    public static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL", "ON", "USING",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "RETURNING",
        "AND", "OR", "NOT", "NULL", "IS", "IN", "EXISTS", "BETWEEN", "LIKE", "ILIKE", "AS", "ASC", "DESC", "DISTINCT",
        "CASE", "WHEN", "THEN", "ELSE", "END", "UNION", "ALL", "INTERSECT", "EXCEPT", "WITH", "RECURSIVE",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "TABLE", "INDEX", "VIEW", "FUNCTION", "PROCEDURE", "TRIGGER",
        "DATABASE", "SCHEMA", "IF", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "DEFAULT", "UNIQUE", "CHECK", "CONSTRAINT",
        "CASCADE", "RESTRICT", "BEGIN", "START", "TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE",
        "EXPLAIN", "ANALYZE", "SHOW", "DESCRIBE", "PRAGMA", "VACUUM", "GRANT", "REVOKE", "CALL", "REPLACE", "RETURNS",
        "LANGUAGE", "PLPGSQL", "BEFORE", "AFTER", "INSTEAD", "OF", "FOR", "EACH", "ROW", "EXECUTE",
        "OVER", "PARTITION", "WINDOW", "FILTER", "DO", "NOTHING", "CONFLICT", "TRUE", "FALSE", "ANY", "SOME"
    ]

    public static let types: Set<String> = [
        "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "MEDIUMINT",
        "SERIAL", "BIGSERIAL", "SMALLSERIAL",
        "VARCHAR", "CHAR", "CHARACTER", "VARYING", "TEXT", "CITEXT",
        "BOOLEAN", "BOOL",
        "DECIMAL", "NUMERIC", "REAL", "FLOAT", "DOUBLE", "PRECISION",
        "DATE", "TIME", "TIMESTAMP", "TIMESTAMPTZ", "DATETIME", "INTERVAL", "YEAR",
        "JSON", "JSONB", "XML",
        "UUID", "BYTEA", "BLOB", "BINARY", "VARBINARY", "BIT",
        "MONEY", "INET", "CIDR", "MACADDR", "VECTOR", "ARRAY", "ENUM", "SET"
    ]

    public static let functions: Set<String> = {
        var fns: Set<String> = [
            "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "ABS", "ROUND",
            "LENGTH", "LOWER", "UPPER", "TRIM", "LTRIM", "RTRIM", "REPLACE", "SUBSTR", "SUBSTRING",
            "DATE", "TIME", "DATETIME", "STRFTIME", "JULIANDAY", "UNIXEPOCH", "IFNULL", "INSTR", "HEX", "QUOTE",
            "RANDOM", "TYPEOF", "TOTAL", "GROUP_CONCAT", "JSON", "JSON_EXTRACT", "JSON_OBJECT", "JSON_ARRAY",
            "JSON_EACH", "LAST_INSERT_ROWID", "CHANGES", "PRINTF", "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP",
            "CURRENT_TIME", "AGE", "DATE_TRUNC", "DATE_PART", "EXTRACT", "TO_CHAR", "TO_DATE", "TO_TIMESTAMP",
            "TO_NUMBER", "CONCAT", "CONCAT_WS", "SPLIT_PART", "POSITION", "STRING_AGG", "ARRAY_AGG", "ARRAY_LENGTH",
            "UNNEST", "GENERATE_SERIES", "JSONB_BUILD_OBJECT", "JSONB_AGG", "JSON_BUILD_OBJECT", "JSONB_SET",
            "JSONB_EXTRACT_PATH", "ROW_NUMBER", "RANK", "DENSE_RANK", "LAG", "LEAD", "FIRST_VALUE", "LAST_VALUE",
            "GREATEST", "LEAST", "GEN_RANDOM_UUID", "MD5", "LEFT", "RIGHT", "LPAD", "RPAD", "INITCAP",
            "REGEXP_REPLACE", "REGEXP_MATCHES", "TIME_BUCKET", "CURDATE", "CURTIME", "DATE_FORMAT", "STR_TO_DATE",
            "DATEDIFF", "DATE_ADD", "DATE_SUB", "TIMESTAMPDIFF", "UNIX_TIMESTAMP", "FROM_UNIXTIME", "SUBSTRING_INDEX",
            "LOCATE", "JSON_UNQUOTE", "JSON_CONTAINS", "IF", "RAND", "UUID", "SHA2", "LAST_INSERT_ID", "FORMAT"
        ]
        return fns
    }()

    // MARK: - Compiled Regular Expressions

    private static let commentRegex = try! NSRegularExpression(
        pattern: "--[^\\n]*|#[^\\n]*|/\\*(?:.|\\n)*?\\*/"
    )

    private static let stringRegex = try! NSRegularExpression(
        pattern: "'(?:[^'\\\\]|\\\\.|'')*'|\\$([A-Za-z0-9_]*)\\$(?:.|\\n)*?\\$\\1\\$"
    )

    private static let quotedIdentifierRegex = try! NSRegularExpression(
        pattern: #""(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`|\[[^\]\n]+\]"#
    )

    private static let keywordRegex: NSRegularExpression = {
        let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let typeRegex: NSRegularExpression = {
        let pattern = "\\b(" + types.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let builtinFunctionRegex: NSRegularExpression = {
        let pattern = "\\b(" + functions.joined(separator: "|") + ")\\b"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let genericFunctionRegex = try! NSRegularExpression(
        pattern: "\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()"
    )

    private static let numberRegex = try! NSRegularExpression(
        pattern: "\\b0x[0-9a-fA-F]+\\b|\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b"
    )

    // MARK: - Highlighting Execution

    /// Highlights the provided `storage` in place.
    /// Safe on large texts: skips full-document regex passes when length exceeds 256KB.
    public static func highlight(_ storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString

        storage.beginEditing()
        storage.removeAttribute(.foregroundColor, range: fullRange)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

        // For large texts (>256 KB), skip regex passes to keep the UI responsive.
        guard storage.length <= 256 * 1024 else {
            storage.endEditing()
            return
        }

        func apply(_ regex: NSRegularExpression, _ color: NSColor) {
            regex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
                if let range = match?.range {
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
        }

        // 1. Numbers
        apply(numberRegex, numberColor)

        // 2. SQL Keywords
        apply(keywordRegex, keywordColor)

        // 3. Built-in Functions
        apply(builtinFunctionRegex, functionColor)

        // 4. Generic Function Calls (custom_func(...))
        genericFunctionRegex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
            guard let range = match?.range(at: 1) else { return }
            let name = text.substring(with: range).uppercased()
            // Do not override keywords or types such as VARCHAR(255), DECIMAL(10,2), IF, VALUES, IN, EXISTS if they precede '('
            if !keywords.contains(name) && !types.contains(name) {
                storage.addAttribute(.foregroundColor, value: functionColor, range: range)
            }
        }

        // 5. SQL Data Types (including parameterized types like VARCHAR(255), NUMERIC(10,2))
        apply(typeRegex, typeColor)

        // 6. Quoted Identifiers ("col", `col`, [col])
        apply(quotedIdentifierRegex, quotedIdentifierColor)

        // 7. Strings ('...', $$...$$) - overrides keywords/types/numbers inside string literals
        apply(stringRegex, stringColor)

        // 8. Comments (-- ..., # ..., /* ... */) - highest precedence
        apply(commentRegex, commentColor)

        storage.endEditing()
    }
}
