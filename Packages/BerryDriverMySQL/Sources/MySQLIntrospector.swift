import BerryDriverKit
import Foundation

/// Introspection via information_schema + SHOW CREATE TABLE
/// (docs/architecture/05 §5). In MySQL, database and schema are the same thing.
public struct MySQLIntrospector: Introspector {
    let connection: MySQLDriverConnection
    private let dialect = MySQLDialect()

    private static let systemSchemas = ["mysql", "information_schema", "performance_schema", "sys"]

    public func databases() async throws -> [DatabaseInfo] {
        let rows = try await connection.queryAll("SHOW DATABASES")
        return rows.compactMap { row in
            guard case .text(let name) = row[0],
                  !Self.systemSchemas.contains(name) else { return nil }
            return DatabaseInfo(name: name)
        }
    }

    public func objects(in database: String?) async throws -> [SchemaObject] {
        let schemaFilter = database.map { "= '\(escaped($0))'" } ?? "= DATABASE()"
        let tableRows = try await connection.queryAll(
            """
            SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA \(schemaFilter)
            ORDER BY TABLE_TYPE, TABLE_NAME
            """
        )
        var result: [SchemaObject] = tableRows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let type) = row[2] else { return nil }
            let kind: SchemaObjectKind = type.contains("VIEW") ? .view : .table
            return SchemaObject(kind: kind, name: name, database: schema)
        }

        // Functions & procedures (TR-01). MySQL forbids overloading, so the
        // name is a unique key within its schema.
        let routineRows = try await connection.queryAll(
            """
            SELECT ROUTINE_SCHEMA, ROUTINE_NAME, ROUTINE_TYPE
            FROM information_schema.ROUTINES
            WHERE ROUTINE_SCHEMA \(schemaFilter)
            ORDER BY ROUTINE_TYPE, ROUTINE_NAME
            """
        )
        result += routineRows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let type) = row[2] else { return nil }
            return SchemaObject(kind: type == "PROCEDURE" ? .procedure : .function, name: name, database: schema)
        }

        // Triggers (TR-01).
        let triggerRows = try await connection.queryAll(
            """
            SELECT TRIGGER_SCHEMA, TRIGGER_NAME
            FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA \(schemaFilter)
            ORDER BY TRIGGER_NAME
            """
        )
        result += triggerRows.compactMap { row in
            guard case .text(let schema) = row[0], case .text(let name) = row[1] else { return nil }
            return SchemaObject(kind: .trigger, name: name, database: schema)
        }

        return result
    }

    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        let schemaExpr = ref.database.map { "'\(escaped($0))'" } ?? "DATABASE()"
        let table = escaped(ref.name)

        let columnRows = try await connection.queryAll(
            """
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(schemaExpr) AND TABLE_NAME = '\(table)'
            ORDER BY ORDINAL_POSITION
            """
        )
        let columns: [ColumnInfo] = columnRows.compactMap { row in
            guard case .text(let name) = row[0] else { return nil }
            let type = row[1].displayString ?? ""
            let nullable = row[2].displayString == "YES"
            let defaultValue = row[3].isNull ? nil : row[3].displayString
            let pk = row[4].displayString == "PRI"
            return ColumnInfo(
                name: name, declaredType: type, isNullable: nullable,
                defaultValue: defaultValue, isPrimaryKey: pk
            )
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(schemaExpr) AND TABLE_NAME = '\(table)'
            GROUP BY INDEX_NAME, NON_UNIQUE
            ORDER BY INDEX_NAME
            """
        )
        let indexes: [IndexInfo] = indexRows.compactMap { row in
            guard case .text(let name) = row[0] else { return nil }
            let nonUnique: Bool = if case .int(let n) = row[1] { n != 0 } else { true }
            let cols = (row[2].displayString ?? "").split(separator: ",").map(String.init)
            return IndexInfo(name: name, isUnique: !nonUnique, columns: cols)
        }

        let fkRows = try await connection.queryAll(
            """
            SELECT COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = \(schemaExpr) AND TABLE_NAME = '\(table)'
              AND REFERENCED_TABLE_NAME IS NOT NULL
            """
        )
        let foreignKeys: [ForeignKeyInfo] = fkRows.compactMap { row in
            guard case .text(let column) = row[0],
                  case .text(let refTable) = row[1],
                  case .text(let refColumn) = row[2] else { return nil }
            return ForeignKeyInfo(column: column, referencedTable: refTable, referencedColumn: refColumn)
        }

        return TableDetail(ref: ref, columns: columns, indexes: indexes, foreignKeys: foreignKeys)
    }

    /// TR-04: `information_schema.TABLES` carries all four fields at once —
    /// `TABLE_ROWS` is InnoDB's estimate (not exact; MySQL's own docs say so),
    /// `DATA_LENGTH + INDEX_LENGTH` is on-disk size, `ENGINE` and
    /// `TABLE_COMMENT` are exact.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let schemaExpr = ref.database.map { "'\(escaped($0))'" } ?? "DATABASE()"
        let table = escaped(ref.name)
        let rows = try await connection.queryAll(
            """
            SELECT TABLE_ROWS, DATA_LENGTH + INDEX_LENGTH, ENGINE, NULLIF(TABLE_COMMENT, '')
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(schemaExpr) AND TABLE_NAME = '\(table)'
            """
        )
        guard let row = rows.first else {
            return TableStats(estimatedRowCount: nil, sizeBytes: nil, engine: nil, comment: nil)
        }
        let rowCount: Int64? = if case .int(let n) = row[0] { n } else { nil }
        let size: Int64? = if case .int(let n) = row[1] { n } else { nil }
        let engine: String? = if case .text(let e) = row[2] { e } else { nil }
        let comment: String? = if case .text(let c) = row[3] { c } else { nil }
        return TableStats(estimatedRowCount: rowCount, sizeBytes: size, engine: engine, comment: comment)
    }

    public func ddl(of object: SchemaObject) async throws -> String {
        let qualified = object.database.map {
            "\(dialect.quoteIdentifier($0)).\(dialect.quoteIdentifier(object.name))"
        } ?? dialect.quoteIdentifier(object.name)

        // The DDL column differs per statement: TABLE/VIEW put it at index 1,
        // while FUNCTION/PROCEDURE/TRIGGER add a sql_mode column first (index 2).
        let statement: String
        let ddlColumn: Int
        switch object.kind {
        case .view: (statement, ddlColumn) = ("SHOW CREATE VIEW", 1)
        case .function: (statement, ddlColumn) = ("SHOW CREATE FUNCTION", 2)
        case .procedure: (statement, ddlColumn) = ("SHOW CREATE PROCEDURE", 2)
        case .trigger: (statement, ddlColumn) = ("SHOW CREATE TRIGGER", 2)
        default: (statement, ddlColumn) = ("SHOW CREATE TABLE", 1)
        }
        let rows = try await connection.queryAll("\(statement) \(qualified)")
        guard let row = rows.first, row.count > ddlColumn, case .text(let ddl) = row[ddlColumn] else {
            throw DriverError.queryFailed(message: "Cannot fetch DDL of \(object.name)", code: nil)
        }
        return ddl
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
