import BerryDriverKit
import Foundation

/// Declarative table definition for the table designer (CT-01/02/03) —
/// docs/architecture/06 · L3. The form edits this model; the dialect renders
/// DDL; the SQL preview is ALWAYS shown before applying (CT-01), and apply
/// runs through the single QueryService path (N1).
///
/// Scope: this generates CREATE TABLE for a NEW table plus its indexes and
/// foreign keys — the portable subset shared by SQLite/Postgres/MySQL. Editing
/// an existing table via ALTER (dialect-divergent, SQLite especially) is a
/// separate follow-up noted in docs/architecture/06.

public enum ForeignKeyAction: String, Sendable, Equatable, CaseIterable {
    case noAction = "NO ACTION"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case restrict = "RESTRICT"
}

public struct ColumnDesign: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var type: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    /// Raw SQL default fragment (e.g. `0`, `'x'`, `CURRENT_TIMESTAMP`), or nil.
    public var defaultValue: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: String = "TEXT",
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
    }
}

public struct IndexDesign: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var columns: [String]
    public var isUnique: Bool

    public init(id: UUID = UUID(), name: String = "", columns: [String] = [], isUnique: Bool = false) {
        self.id = id
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
    }
}

public struct ForeignKeyDesign: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var column: String
    public var referencedTable: String
    public var referencedColumn: String
    public var onDelete: ForeignKeyAction
    public var onUpdate: ForeignKeyAction

    public init(
        id: UUID = UUID(),
        column: String = "",
        referencedTable: String = "",
        referencedColumn: String = "",
        onDelete: ForeignKeyAction = .noAction,
        onUpdate: ForeignKeyAction = .noAction
    ) {
        self.id = id
        self.column = column
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
        self.onDelete = onDelete
        self.onUpdate = onUpdate
    }
}

public struct TableDesign: Sendable, Equatable {
    public var name: String
    public var database: String?
    public var columns: [ColumnDesign]
    public var indexes: [IndexDesign]
    public var foreignKeys: [ForeignKeyDesign]

    public init(
        name: String = "",
        database: String? = nil,
        columns: [ColumnDesign] = [],
        indexes: [IndexDesign] = [],
        foreignKeys: [ForeignKeyDesign] = []
    ) {
        self.name = name
        self.database = database
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
    }

    /// Reconstructs a design from an introspected table (used for the SQL
    /// export DDL header, XN-03). Column types come from `declaredType`, so the
    /// generated CREATE mirrors the source schema.
    public init(detail: TableDetail) {
        self.init(
            name: detail.ref.name,
            database: detail.ref.database,
            columns: detail.columns.map {
                ColumnDesign(
                    name: $0.name, type: $0.declaredType,
                    isNullable: $0.isNullable, isPrimaryKey: $0.isPrimaryKey,
                    defaultValue: $0.defaultValue
                )
            },
            indexes: detail.indexes.map {
                IndexDesign(name: $0.name, columns: $0.columns, isUnique: $0.isUnique)
            },
            foreignKeys: detail.foreignKeys.map {
                ForeignKeyDesign(
                    column: $0.column,
                    referencedTable: $0.referencedTable,
                    referencedColumn: $0.referencedColumn
                )
            }
        )
    }

    private var ref: TableRef { TableRef(database: database, name: name) }

    /// Reasons the design can't be applied yet — drives the designer's
    /// disabled Apply button and inline warnings. Empty = valid.
    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Table name is required")
        }
        let named = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if named.isEmpty {
            errors.append("At least one column is required")
        }
        let lowered = named.map { $0.name.lowercased() }
        if Set(lowered).count != lowered.count {
            errors.append("Duplicate column names")
        }
        return errors
    }

    public var isValid: Bool { validationErrors.isEmpty }

    // MARK: - DDL generation (SQL preview + apply)

    /// CREATE TABLE followed by CREATE INDEX statements — exactly what the SQL
    /// preview shows and what `apply` executes. Columns/indexes with blank
    /// names are skipped so a half-filled form still previews cleanly.
    public func statements(dialect: any SQLDialect) -> [String] {
        let cols = columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !cols.isEmpty else { return [] }

        var lines: [String] = cols.map { column in
            var line = "  \(dialect.quoteIdentifier(column.name)) \(column.type)"
            if !column.isNullable { line += " NOT NULL" }
            if let def = column.defaultValue, !def.trimmingCharacters(in: .whitespaces).isEmpty {
                line += " DEFAULT \(def)"
            }
            return line
        }

        let pkColumns = cols.filter(\.isPrimaryKey).map { dialect.quoteIdentifier($0.name) }
        if !pkColumns.isEmpty {
            lines.append("  PRIMARY KEY (\(pkColumns.joined(separator: ", ")))")
        }

        for fk in foreignKeys where isValidForeignKey(fk) {
            var line = "  FOREIGN KEY (\(dialect.quoteIdentifier(fk.column)))"
                + " REFERENCES \(dialect.quoteIdentifier(fk.referencedTable))"
                + " (\(dialect.quoteIdentifier(fk.referencedColumn)))"
            if fk.onDelete != .noAction { line += " ON DELETE \(fk.onDelete.rawValue)" }
            if fk.onUpdate != .noAction { line += " ON UPDATE \(fk.onUpdate.rawValue)" }
            lines.append(line)
        }

        var result = ["CREATE TABLE \(dialect.qualifiedName(of: ref)) (\n"
            + lines.joined(separator: ",\n") + "\n)"]

        for index in indexes where isValidIndex(index) {
            let unique = index.isUnique ? "UNIQUE " : ""
            let indexCols = index.columns
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(dialect.quoteIdentifier)
                .joined(separator: ", ")
            result.append(
                "CREATE \(unique)INDEX \(dialect.quoteIdentifier(index.name))"
                + " ON \(dialect.qualifiedName(of: ref)) (\(indexCols))"
            )
        }
        return result
    }

    private func isValidForeignKey(_ fk: ForeignKeyDesign) -> Bool {
        ![fk.column, fk.referencedTable, fk.referencedColumn]
            .contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func isValidIndex(_ index: IndexDesign) -> Bool {
        !index.name.trimmingCharacters(in: .whitespaces).isEmpty
            && index.columns.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Apply (docs/architecture/06 · L3)

    /// Runs the generated DDL through the single SQL path (N1), inside a
    /// transaction when the driver supports it. Returns statements executed.
    @discardableResult
    public func apply(on session: Session) async throws -> Int {
        let sqls = statements(dialect: session.dialect)
        guard !sqls.isEmpty else { return 0 }
        let useTransaction = session.capabilities.transactions

        func run(_ sql: String) async throws {
            for try await _ in QueryService.execute(
                sql, on: session, autoLimit: nil,
                // The SQL preview the user just approved IS the confirmation
                // (06 · L3) — don't stack a second delete dialog, and never
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
