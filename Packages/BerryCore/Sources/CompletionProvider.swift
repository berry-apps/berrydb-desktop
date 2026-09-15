import BerryDriverKit
import Foundation

/// Context-aware completion logic on top of SchemaCatalog data.
/// Pure and synchronous over pre-fetched metadata so it is trivially
/// testable; the editor resolves table details ahead of time via the
/// catalog (tree-sitter-based context detection can replace the token
/// heuristics later without touching callers).
public enum CompletionProvider {
    public enum Suggestion: Equatable, Sendable {
        case keyword(String)
        case table(name: String, schema: String?)
        case column(name: String, table: String, schema: String?)
        /// Function / procedure / trigger (objects) — offered in the
        /// general pool but never as a table name after FROM/JOIN.
        case routine(name: String, kind: SchemaObjectKind)
        /// Engine built-in function (NOW, COALESCE, …) — inserted with parens,
        /// never quoted (P1.4).
        case builtin(String)
        /// DDL template snippet (crview, crfunc, crtrig) — inserted as full DDL text.
        case snippet(label: String, template: String, detail: String)

        public static func table(_ name: String) -> Suggestion {
            .table(name: name, schema: nil)
        }

        public static func column(name: String, table: String) -> Suggestion {
            .column(name: name, table: table, schema: nil)
        }

        public var text: String {
            switch self {
            case .keyword(let k): return k
            case .table(let t, _): return t
            case .column(let c, _, _): return c
            case .routine(let n, _): return n
            case .builtin(let f): return f
            case .snippet(let label, _, _): return label
            }
        }

        /// SF Symbol representing the suggestion type (custom popup).
        public var iconName: String {
            switch self {
            case .keyword: return "textformat.abc"
            case .table: return "tablecells"
            case .column: return "cylinder.split.1x2"
            case .routine(_, .procedure): return "gearshape.2"
            case .routine(_, .trigger): return "bolt"
            case .routine: return "function"
            case .builtin: return "function"
            case .snippet: return "square.and.pencil"
            }
        }

        /// Muted secondary text: the category, or a column's owning table.
        public var detail: String {
            switch self {
            case .keyword: return "keyword"
            case .table(_, let schema): return schema ?? "table"
            case .column(_, let table, let schema): return schema.map { "\($0).\(table)" } ?? table
            case .routine(_, let kind): return kind.rawValue
            case .builtin: return "built-in"
            case .snippet(_, _, let detail): return detail
            }
        }
    }

    /// Positions in `candidate` (by character offset) that match `query` as a
    /// case-insensitive subsequence, for highlighting the typed characters in the
 /// completion popup. Empty when the query isn't a subsequence.
    public static func matchOffsets(of query: String, in candidate: String) -> [Int] {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return [] }
        let c = Array(candidate.lowercased())
        var offsets: [Int] = []
        var qi = 0
        for (index, character) in c.enumerated() where qi < q.count {
            if character == q[qi] {
                offsets.append(index)
                qi += 1
            }
        }
        return qi == q.count ? offsets : []
    }

    /// Whether an identifier must be quoted to survive case-folding or special
 /// characters — e.g. a PascalCase table on Postgres. Only a
    /// bare ASCII-lowercase `[a-z_][a-z0-9_]*` is safe unquoted.
    public static func identifierNeedsQuoting(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return true }
        return name.contains { character in
            let allowed = (character.isASCII && character.isLowercase)
                || (character.isASCII && character.isNumber)
                || character == "_"
            return !allowed
        }
    }

    public static let keywords: [String] = [
        // Query / DML clauses
        "SELECT", "FROM", "WHERE", "JOIN", "LEFT JOIN", "INNER JOIN",
        "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "OUTER JOIN", "ON", "USING",
        "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "OFFSET", "INSERT INTO",
        "VALUES", "UPDATE", "SET", "DELETE FROM", "RETURNING", "AND", "OR",
        "NOT", "NULL", "IS NULL", "IS NOT NULL", "IN", "EXISTS", "BETWEEN",
        "LIKE", "ILIKE", "AS", "ASC", "DESC", "DISTINCT", "CASE", "WHEN",
        "THEN", "ELSE", "END", "UNION", "UNION ALL", "INTERSECT", "EXCEPT",
        "WITH", "CAST", "COALESCE",
        // Aggregates
        "COUNT", "SUM", "AVG", "MIN", "MAX",
        // DDL Views, Functions, Procedures & Triggers
        "CREATE TABLE", "ALTER TABLE", "DROP TABLE", "TRUNCATE", "TRUNCATE TABLE",
        "CREATE INDEX", "DROP INDEX", "CREATE VIEW", "CREATE OR REPLACE VIEW", "DROP VIEW",
        "CREATE FUNCTION", "CREATE OR REPLACE FUNCTION", "DROP FUNCTION",
        "CREATE PROCEDURE", "CREATE OR REPLACE PROCEDURE", "DROP PROCEDURE",
        "CREATE TRIGGER", "DROP TRIGGER", "RETURNS", "DETERMINISTIC", "LANGUAGE",
        "PLPGSQL", "BEFORE", "AFTER", "INSTEAD OF", "FOR EACH ROW", "EXECUTE FUNCTION",
        "SECURITY DEFINER", "REPLACE", "FUNCTION", "PROCEDURE", "TRIGGER",
        // Common SQL Data Types
        "INT", "INTEGER", "BIGINT", "SMALLINT", "VARCHAR", "CHAR", "TEXT",
        "TIMESTAMP", "DATE", "TIME", "BOOLEAN", "JSON", "JSONB", "NUMERIC", "DECIMAL", "REAL", "DOUBLE",
        "CREATE DATABASE", "DROP DATABASE", "IF EXISTS", "IF NOT EXISTS",
        "ADD COLUMN", "DROP COLUMN", "RENAME TO", "PRIMARY KEY", "FOREIGN KEY",
        "REFERENCES", "DEFAULT", "UNIQUE", "CHECK", "CONSTRAINT", "CASCADE",
        // Transactions
        "BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT",
        "RELEASE SAVEPOINT",
        // Diagnostics / session / admin (common across dialects)
        "EXPLAIN", "EXPLAIN ANALYZE", "ANALYZE", "SHOW", "DESCRIBE", "GRANT",
        "REVOKE", "CALL",
    ]

    /// Suggestions for the token being typed at `utf16Cursor`.
    /// - `columnsByTable`: pre-fetched columns for tables that appear in the
    ///   statement (the editor warms this from SchemaCatalog).
    public static func suggestions(
        for script: String,
        cursor: Int,
        objects: [SchemaObject],
        tableDetails: [TableRef: TableDetail] = [:],
        columnsByTable: [String: [String]] = [:],
        builtins: [String] = [],
        statements: [String] = []
    ) -> [Suggestion] {
        suggestions(
            script: script,
            utf16Cursor: cursor,
            objects: objects,
            columnsByTable: columnsByTable,
            tableDetails: tableDetails,
            builtins: builtins,
            statements: statements
        )
    }

    public static func suggestions(
        script: String,
        utf16Cursor: Int,
        objects: [SchemaObject],
        columnsByTable: [String: [String]] = [:],
        tableDetails: [TableRef: TableDetail] = [:],
        builtins: [String] = [],
        statements: [String] = []
    ) -> [Suggestion] {
        let statement = StatementSplitter.statement(at: utf16Cursor, in: script)
        let statementText = statement?.sql ?? script
        let prefix = currentTokenPrefix(script: script, utf16Cursor: utf16Cursor)
        let relationalObjects = objects.filter { $0.kind.isRelational }
        let tableNames = relationalObjects.map(\.name)

        // Case 1: "alias." or "table." → columns of the resolved table.
        if let qualifier = prefix.qualifier {
            let aliasRefs = aliasRefMap(statement: statementText, objects: relationalObjects)
            let resolvedRef = aliasRefs[qualifier.lowercased()]
            let parsedQualifier: (schema: String?, table: String) = {
                if let resolvedRef {
                    return (schema: resolvedRef.database, table: resolvedRef.name)
                }
                let qParts = qualifier.split(separator: ".").map(String.init)
                if qParts.count == 2 {
                    return (schema: qParts[0], table: qParts[1])
                }
                return (schema: nil, table: qualifier)
            }()
            let targetTable = parsedQualifier.table
            let targetSchema = parsedQualifier.schema

            var colSuggestions: [Suggestion] = []
            let matchingDetails = tableDetails.filter { detailRef, _ in
                guard detailRef.name.caseInsensitiveCompare(targetTable) == .orderedSame else { return false }
                if let targetSchema {
                    return detailRef.database?.caseInsensitiveCompare(targetSchema) == .orderedSame
                }
                return true
            }
            if !matchingDetails.isEmpty {
                for (ref, detail) in matchingDetails {
                    colSuggestions += detail.columns.map { .column(name: $0.name, table: ref.name, schema: ref.database) }
                }
            } else {
                let columns = columnsByTable.first { $0.key.caseInsensitiveCompare(targetTable) == .orderedSame }?.value ?? []
                let schema = targetSchema ?? relationalObjects.first { $0.name.caseInsensitiveCompare(targetTable) == .orderedSame }?.database
                colSuggestions = columns.map { .column(name: $0, table: targetTable, schema: schema) }
            }
            return rank(colSuggestions, by: prefix.text)
        }

        // Case 2: right after FROM/JOIN/INTO/UPDATE/TABLE → tables first.
        let previous = previousSignificantWord(script: script, utf16Cursor: utf16Cursor, skipping: prefix.text)
        let tableLeaders: Set<String> = ["from", "join", "into", "update", "table", "view"]
        if let previous, tableLeaders.contains(previous.lowercased()) {
            return rank(relationalObjects.map { .table(name: $0.name, schema: $0.database) }, by: prefix.text)
        }

        // Default: keywords + snippets + tables + routines + columns.
        var pool: [Suggestion] = keywords.map { .keyword($0) }
        pool += statements.map { .keyword($0) }
        pool += [
            .snippet(
                label: "crview",
                template: "CREATE OR REPLACE VIEW view_name AS\nSELECT * FROM table_name;",
                detail: "CREATE VIEW template"
            ),
            .snippet(
                label: "crfunc",
                template: "CREATE OR REPLACE FUNCTION func_name()\nRETURNS void AS $$\nBEGIN\n    -- Function logic\nEND;\n$$ LANGUAGE plpgsql;",
                detail: "CREATE FUNCTION template"
            ),
            .snippet(
                label: "crtrig",
                template: "CREATE TRIGGER trigger_name\nBEFORE INSERT ON table_name\nFOR EACH ROW\nEXECUTE FUNCTION trigger_function();",
                detail: "CREATE TRIGGER template"
            )
        ]
        pool += relationalObjects.map { .table(name: $0.name, schema: $0.database) }
        pool += objects
            .filter { !$0.kind.isRelational }
            .map { .routine(name: $0.name, kind: $0.kind) }
        pool += builtins.map { .builtin($0) }
        let aliasRefs = aliasRefMap(statement: statementText, objects: relationalObjects)
        for ref in Set(aliasRefs.values) {
            let matchingDetails = tableDetails.filter { detailRef, _ in
                guard detailRef.name.caseInsensitiveCompare(ref.name) == .orderedSame else { return false }
                if let schema = ref.database {
                    return detailRef.database?.caseInsensitiveCompare(schema) == .orderedSame
                }
                return true
            }
            if !matchingDetails.isEmpty {
                for (detailRef, detail) in matchingDetails {
                    pool += detail.columns.map { .column(name: $0.name, table: detailRef.name, schema: detailRef.database) }
                }
            } else {
                let columns = columnsByTable.first { $0.key.caseInsensitiveCompare(ref.name) == .orderedSame }?.value ?? []
                let schema = ref.database ?? relationalObjects.first { $0.name.caseInsensitiveCompare(ref.name) == .orderedSame }?.database
                pool += columns.map { .column(name: $0, table: ref.name, schema: schema) }
            }
        }
        return rank(pool, by: prefix.text)
    }

    /// Tables referenced by FROM/JOIN in a statement — the editor pre-fetches
    /// their columns before asking for suggestions.
    public static func referencedTables(statement: String, objects: [SchemaObject]) -> [String] {
        let aliasRefs = aliasRefMap(statement: statement, objects: objects)
        return Array(Set(aliasRefs.values.map(\.name)))
    }

    // MARK: - Token context

    struct TokenPrefix {
        let text: String
        /// Non-nil when the token is qualified: "alias." or "table.".
        let qualifier: String?
    }

    static func currentTokenPrefix(script: String, utf16Cursor: Int) -> TokenPrefix {
        let text = script as NSString
        let cursor = min(utf16Cursor, text.length)
        var start = cursor
        func isIdentifierChar(_ c: unichar) -> Bool {
            let scalar = Unicode.Scalar(c)
            return scalar.map {
                CharacterSet.alphanumerics.contains($0) || $0 == "_"
            } ?? false
        }
        while start > 0, isIdentifierChar(text.character(at: start - 1)) {
            start -= 1
        }
        let token = text.substring(with: NSRange(location: start, length: cursor - start))
        // Qualified? Look for "<identifier>." or "<schema>.<identifier>." just before the token.
        if start > 0, text.character(at: start - 1) == unichar(UInt8(ascii: ".")) {
            var qualifierStart = start - 1
            while qualifierStart > 0, isIdentifierChar(text.character(at: qualifierStart - 1)) {
                qualifierStart -= 1
            }
            if qualifierStart > 1, text.character(at: qualifierStart - 1) == unichar(UInt8(ascii: ".")) {
                var schemaStart = qualifierStart - 1
                while schemaStart > 0, isIdentifierChar(text.character(at: schemaStart - 1)) {
                    schemaStart -= 1
                }
                if schemaStart < qualifierStart - 1 {
                    qualifierStart = schemaStart
                }
            }
            let qualifier = text.substring(with: NSRange(location: qualifierStart, length: (start - 1) - qualifierStart))
            if !qualifier.isEmpty {
                return TokenPrefix(text: token, qualifier: qualifier)
            }
        }
        return TokenPrefix(text: token, qualifier: nil)
    }

    static func previousSignificantWord(script: String, utf16Cursor: Int, skipping currentToken: String) -> String? {
        let text = (script as NSString).substring(to: min(utf16Cursor, (script as NSString).length))
        var words = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "(" || $0 == ")" })
        if let last = words.last, last.caseInsensitiveCompare(currentToken) == .orderedSame, !currentToken.isEmpty {
            words.removeLast()
        }
        return words.last.map(String.init)
    }

    /// "FROM s1.items i JOIN s2.orders AS o" →
    /// ["i": TableRef(database: "s1", name: "items"),
    ///  "o": TableRef(database: "s2", name: "orders"), ...]
    static func aliasRefMap(statement: String, objects: [SchemaObject]) -> [String: TableRef] {
        var map: [String: TableRef] = [:]
        let relational = objects.filter { $0.kind.isRelational }
        let knownByBare = Dictionary(relational.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let knownByQualified = Dictionary(relational.compactMap { obj -> (String, SchemaObject)? in
            guard let db = obj.database else { return nil }
            return ("\(db).\(obj.name)".lowercased(), obj)
        }, uniquingKeysWith: { first, _ in first })

        let words = statement
            .replacingOccurrences(of: ",", with: " , ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            if word == "from" || word == "join" || word == "into" || word == "update" {
                var cursor = index + 1
                while cursor < words.count {
                    let rawTable = words[cursor].trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,()"))
                    guard !rawTable.isEmpty, rawTable != "." else { break }

                    let parts = rawTable.split(separator: ".").map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,() "))
                    }.filter { !$0.isEmpty }

                    let resolvedRef: TableRef?
                    if parts.count == 2 {
                        let schema = parts[0]
                        let table = parts[1]
                        let qualifiedKey = "\(schema).\(table)".lowercased()
                        if let matched = knownByQualified[qualifiedKey] {
                            resolvedRef = TableRef(database: matched.database, name: matched.name)
                        } else if let matched = relational.first(where: {
                            $0.name.caseInsensitiveCompare(table) == .orderedSame
                                && $0.database?.caseInsensitiveCompare(schema) == .orderedSame
                        }) {
                            resolvedRef = TableRef(database: matched.database, name: matched.name)
                        } else {
                            resolvedRef = TableRef(database: schema, name: table)
                        }
                    } else if parts.count == 1 {
                        let table = parts[0]
                        let matches = relational.filter { $0.name.caseInsensitiveCompare(table) == .orderedSame }
                        if matches.count == 1 {
                            resolvedRef = TableRef(database: matches[0].database, name: matches[0].name)
                        } else if matches.count > 1 {
                            resolvedRef = TableRef(database: nil, name: matches[0].name)
                        } else if let matched = knownByBare[table.lowercased()] {
                            resolvedRef = TableRef(database: matched.database, name: matched.name)
                        } else {
                            resolvedRef = nil
                        }
                    } else {
                        resolvedRef = nil
                    }

                    guard let ref = resolvedRef else { break }
                    map[ref.name.lowercased()] = ref
                    if let db = ref.database {
                        map["\(db).\(ref.name)".lowercased()] = ref
                    }
                    if rawTable.caseInsensitiveCompare(ref.name) != .orderedSame {
                        map[rawTable.lowercased()] = ref
                    }

                    var next = cursor + 1
                    if next < words.count, words[next].caseInsensitiveCompare("AS") == .orderedSame {
                        next += 1
                    }
                    if next < words.count {
                        let candidate = words[next].trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,()"))
                        let stopWords: Set<String> = [
                            "on", "where", "join", "left", "right", "inner", "outer",
                            "group", "order", "limit", "set", "using", ",",
                        ]
                        if !candidate.isEmpty,
                           !stopWords.contains(candidate.lowercased()),
                           knownByBare[candidate.lowercased()] == nil {
                            map[candidate.lowercased()] = ref
                            next += 1
                        }
                    }
                    if next < words.count, words[next] == "," {
                        cursor = next + 1
                        continue
                    }
                    break
                }
            }
            index += 1
        }
        return map
    }

    /// "FROM users u JOIN orders AS o" → ["u": "users", "o": "orders",
    /// "users": "users", "orders": "orders"].
    static func aliasMap(statement: String, tableNames: [String]) -> [String: String] {
        var map: [String: String] = [:]
        // Not uniqueKeysWithValues: two tables can legally collide once
        // lowercased (e.g. Postgres's quoted "Users" vs. unquoted users are
        // distinct tables) — that traps rather than just picking one.
        let known = Dictionary(tableNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let words = statement
            .replacingOccurrences(of: ",", with: " , ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var index = 0
        while index < words.count {
            let word = words[index].lowercased()
            if word == "from" || word == "join" || word == "into" || word == "update" {
                var cursor = index + 1
                // Chain of "table [AS] [alias]" segments separated by commas.
                while cursor < words.count {
                    let rawTable = words[cursor].trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,()"))
                    guard !rawTable.isEmpty, rawTable != "." else { break }
                    let bareTable = rawTable.split(separator: ".").last.map(String.init) ?? rawTable
                    guard let table = known[rawTable.lowercased()] ?? known[bareTable.lowercased()] else { break }
                    map[table.lowercased()] = table
                    if rawTable.caseInsensitiveCompare(table) != .orderedSame {
                        map[rawTable.lowercased()] = table
                    }
                    var next = cursor + 1
                    if next < words.count, words[next].caseInsensitiveCompare("AS") == .orderedSame {
                        next += 1
                    }
                    if next < words.count {
                        let candidate = words[next].trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,()"))
                        let stopWords: Set<String> = [
                            "on", "where", "join", "left", "right", "inner", "outer",
                            "group", "order", "limit", "set", "using", ",",
                        ]
                        if !candidate.isEmpty,
                           !stopWords.contains(candidate.lowercased()),
                           known[candidate.lowercased()] == nil {
                            map[candidate.lowercased()] = table
                            next += 1
                        }
                    }
                    // Continue after a comma (FROM a, b).
                    if next < words.count, words[next] == "," {
                        cursor = next + 1
                        continue
                    }
                    break
                }
            }
            index += 1
        }
        return map
    }

    // MARK: - Ranking

    static func rank(_ pool: [Suggestion], by prefix: String) -> [Suggestion] {
        guard !prefix.isEmpty else { return dedupe(pool) }
        let lowered = prefix.lowercased()
        let filtered = pool.filter { $0.text.lowercased().hasPrefix(lowered) }
        let fuzzy = pool.filter {
            !$0.text.lowercased().hasPrefix(lowered) && $0.text.lowercased().contains(lowered)
        }
        return dedupe(filtered + fuzzy)
    }

    private static func dedupe(_ suggestions: [Suggestion]) -> [Suggestion] {
        var seen = Set<String>()
        return suggestions.filter { suggestion in
            let key: String
            switch suggestion {
            case .keyword(let k): key = "k:\(k.lowercased())"
            case .table(let t, let schema): key = "t:\(schema ?? "").\(t.lowercased())"
            case .column(let c, let t, let schema): key = "c:\(schema ?? "").\(t.lowercased()).\(c.lowercased())"
            case .routine(let n, let kind): key = "r:\(kind.rawValue).\(n.lowercased())"
            case .builtin(let f): key = "b:\(f.lowercased())"
            case .snippet(let label, _, _): key = "sn:\(label.lowercased())"
            }
            return seen.insert(key).inserted
        }
    }
}
