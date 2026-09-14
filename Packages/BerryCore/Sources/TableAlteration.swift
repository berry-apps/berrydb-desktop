import BerryDriverKit
import Foundation

/// Diff between an introspected table and its edited design, generating ALTER
/// statements. v1 supports add/drop column, add/drop index, and
/// add foreign key (Postgres/MySQL); everything else (type change, rename,
/// dropping an FK) is reported in `warnings` instead of guessed at.
public struct TableAlteration {
    public let original: TableDesign
    public let edited: TableDesign
    public let driver: DriverID

    public init(original: TableDesign, edited: TableDesign, driver: DriverID) {
        self.original = original
        self.edited = edited
        self.driver = driver
    }

    private var ref: TableRef {
        TableRef(database: original.database, name: original.name)
    }

    /// Modifications v1 can't express as ALTER — surfaced in the UI so nothing
    /// is silently ignored.
    public var warnings: [String] {
        var result: [String] = []
        for column in edited.columns {
            guard let match = original.columns.first(where: {
                $0.name.caseInsensitiveCompare(column.name) == .orderedSame
            }) else { continue }
            if match.type != column.type || match.isNullable != column.isNullable
                || match.isPrimaryKey != column.isPrimaryKey
                || (match.defaultValue ?? "") != (column.defaultValue ?? "") {
                result.append("Column \"\(column.name)\": type/constraint changes aren't supported yet — only add/drop")
            }
        }
        let removedFKs = original.foreignKeys.filter { fk in
            !edited.foreignKeys.contains {
                $0.column.caseInsensitiveCompare(fk.column) == .orderedSame
            }
        }
        if !removedFKs.isEmpty {
            result.append("Dropping foreign keys isn't supported yet")
        }
        if driver == .sqlite {
            let addedFKs = edited.foreignKeys.filter { fk in
                !original.foreignKeys.contains {
                    $0.column.caseInsensitiveCompare(fk.column) == .orderedSame
                }
            }
            if !addedFKs.isEmpty {
                result.append("SQLite can't add a foreign key to an existing table")
            }
        }
        return result
    }

    /// The ALTER/CREATE/DROP statements the preview shows and apply runs.
    public func statements(dialect: any SQLDialect) -> [String] {
        var result: [String] = []
        let table = dialect.qualifiedName(of: ref)

        // Added columns (in edited, not in original).
        for column in edited.columns
        where !column.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !original.columns.contains(where: {
                $0.name.caseInsensitiveCompare(column.name) == .orderedSame
            }) {
            // T-SQL rejects "ADD COLUMN" outright ("Incorrect syntax near
            // 'COLUMN'") — ADD takes no COLUMN keyword there, unlike
            // Postgres/MySQL/SQLite.
            let addKeyword = driver == .sqlserver ? "ADD" : "ADD COLUMN"
            var line = "ALTER TABLE \(table) \(addKeyword) \(dialect.quoteIdentifier(column.name)) \(column.type)"
            if !column.isNullable { line += " NOT NULL" }
            if let def = column.defaultValue, !def.trimmingCharacters(in: .whitespaces).isEmpty {
                line += " DEFAULT \(def)"
            }
            result.append(line)
        }

        // Dropped columns (in original, not in edited).
        for column in original.columns
        where !edited.columns.contains(where: {
            $0.name.caseInsensitiveCompare(column.name) == .orderedSame
        }) {
            result.append("ALTER TABLE \(table) DROP COLUMN \(dialect.quoteIdentifier(column.name))")
        }

        // Dropped indexes (by name).
        for index in original.indexes
        where !edited.indexes.contains(where: {
            $0.name.caseInsensitiveCompare(index.name) == .orderedSame
        }) {
            // SQL Server has no `ALTER TABLE ... DROP INDEX` clause at all —
            // only the standalone `DROP INDEX index ON table` form works
            // (matches IndexAdvisor.swift's own dropIndexSQL). That's a
            // different statement shape than MySQL's ALTER-TABLE-prefixed
            // form below, so it needs its own branch, not just joining
            // MySQL's.
            if driver == .mysql {
                result.append("ALTER TABLE \(table) DROP INDEX \(dialect.quoteIdentifier(index.name))")
            } else if driver == .sqlserver {
                result.append("DROP INDEX \(dialect.quoteIdentifier(index.name)) ON \(table)")
            } else {
                result.append("DROP INDEX \(dialect.quoteIdentifier(index.name))")
            }
        }

        // Added indexes.
        for index in edited.indexes
        where !index.name.trimmingCharacters(in: .whitespaces).isEmpty
            && index.columns.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            && !original.indexes.contains(where: {
                $0.name.caseInsensitiveCompare(index.name) == .orderedSame
            }) {
            let unique = index.isUnique ? "UNIQUE " : ""
            let cols = index.columns
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(dialect.quoteIdentifier)
                .joined(separator: ", ")
            result.append(
                "CREATE \(unique)INDEX \(dialect.quoteIdentifier(index.name)) ON \(table) (\(cols))"
            )
        }

        // Added foreign keys — not on SQLite (no ALTER … ADD FOREIGN KEY).
        if driver != .sqlite {
            for fk in edited.foreignKeys
            where ![fk.column, fk.referencedTable, fk.referencedColumn]
                .contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                && !original.foreignKeys.contains(where: {
                    $0.column.caseInsensitiveCompare(fk.column) == .orderedSame
                }) {
                var line = "ALTER TABLE \(table) ADD FOREIGN KEY (\(dialect.quoteIdentifier(fk.column)))"
                    + " REFERENCES \(dialect.quoteIdentifier(fk.referencedTable))"
                    + " (\(dialect.quoteIdentifier(fk.referencedColumn)))"
                if fk.onDelete != .noAction { line += " ON DELETE \(fk.onDelete.rawValue)" }
                if fk.onUpdate != .noAction { line += " ON UPDATE \(fk.onUpdate.rawValue)" }
                result.append(line)
            }
        }

        return result
    }

    /// Runs the alteration through the single SQL path (N1), transactionally
    /// when supported. Returns the number of statements executed.
    @discardableResult
    public func apply(on session: Session) async throws -> Int {
        let sqls = statements(dialect: session.dialect)
        guard !sqls.isEmpty else { return 0 }
        let useTransaction = session.capabilities.transactions

        func run(_ sql: String) async throws {
            for try await _ in QueryService.execute(
                sql, on: session, autoLimit: nil,
                // The SQL preview the user just approved IS the confirmation
 // (06) — don't stack a second delete dialog, and never
                // block a headless run on an alert.
                dangerPreconfirmed: true
            ) {}
        }

        if useTransaction { try await run("BEGIN") }
        do {
            for sql in sqls { try await run(sql) }
            if useTransaction { try await run("COMMIT") }
        } catch {
            if useTransaction { try? await run("ROLLBACK") }
            throw error
        }
        return sqls.count
    }
}
