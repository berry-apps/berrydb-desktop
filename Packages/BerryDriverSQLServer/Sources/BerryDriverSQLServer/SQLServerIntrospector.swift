import BerryDriverKit
import Foundation

/// Introspection via `sys.objects`/`sys.columns`/`sys.indexes`
/// (docs/architecture/05 §4). For SQL Server, `SchemaObject`'s `database`
/// field means SCHEMA (namespace, e.g. `dbo`) — same convention
/// `PostgresIntrospector` uses for Postgres schemas.
public struct SQLServerIntrospector: Introspector {
    let connection: SQLServerConnection
    private let dialect = SQLServerDialect()

    public func databases() async throws -> [DatabaseInfo] {
        let rows = try await connection.queryAll(
            "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"
        )
        return rows.compactMap {
            if case .text(let name) = $0[0] { DatabaseInfo(name: name) } else { nil }
        }
    }

    public func objects(in database: String?) async throws -> [SchemaObject] {
        let schema = database ?? "dbo"

        let objRows = try await connection.queryAll(
            """
            SELECT s.name, o.name, o.type
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type IN ('U', 'V') AND s.name = \(dialect.stringLiteral(schema))
            ORDER BY o.type, o.name
            """
        )
        var result: [SchemaObject] = objRows.compactMap { row in
            guard case .text(let schemaName) = row[0],
                  case .text(let name) = row[1],
                  case .text(let kind) = row[2] else { return nil }
            let objectKind: SchemaObjectKind = kind.trimmingCharacters(in: .whitespaces) == "V" ? .view : .table
            return SchemaObject(kind: objectKind, name: name, database: schemaName)
        }

        // Functions & procedures (TR-01). type: 'P' = procedure, 'FN'/'TF'/'IF' = functions.
        let routineRows = try await connection.queryAll(
            """
            SELECT s.name, o.name, o.type
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type IN ('P', 'FN', 'TF', 'IF') AND s.name = \(dialect.stringLiteral(schema))
            ORDER BY o.name
            """
        )
        result += routineRows.compactMap { row in
            guard case .text(let schemaName) = row[0],
                  case .text(let name) = row[1],
                  case .text(let kind) = row[2] else { return nil }
            let trimmedKind = kind.trimmingCharacters(in: .whitespaces)
            return SchemaObject(kind: trimmedKind == "P" ? .procedure : .function, name: name, database: schemaName)
        }

        // Triggers (TR-01).
        let triggerRows = try await connection.queryAll(
            """
            SELECT s.name, tr.name
            FROM sys.triggers tr
            JOIN sys.objects o ON o.object_id = tr.parent_id
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE s.name = \(dialect.stringLiteral(schema))
            ORDER BY tr.name
            """
        )
        result += triggerRows.compactMap { row in
            guard case .text(let schemaName) = row[0], case .text(let name) = row[1] else { return nil }
            return SchemaObject(kind: .trigger, name: name, database: schemaName)
        }

        return result
    }

    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        let schema = ref.database ?? "dbo"
        let qualifiedLiteral = dialect.stringLiteral("\(schema).\(ref.name)")

        let columnRows = try await connection.queryAll(
            """
            SELECT c.name, TYPE_NAME(c.user_type_id), c.is_nullable,
                   OBJECT_DEFINITION(c.default_object_id),
                   CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END
            FROM sys.columns c
            LEFT JOIN (
                SELECT ic.column_id, ic.object_id
                FROM sys.index_columns ic
                JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                WHERE i.is_primary_key = 1
            ) pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
            WHERE c.object_id = OBJECT_ID(\(qualifiedLiteral))
            ORDER BY c.column_id
            """
        )
        let columns: [ColumnInfo] = columnRows.compactMap { row in
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            let nullable: Bool = if case .bool(let b) = row[2] { b } else { true }
            let defaultValue = row[3].displayString
            let pk: Bool = if case .int(let n) = row[4] { n != 0 } else { false }
            return ColumnInfo(
                name: name, declaredType: type, isNullable: nullable,
                defaultValue: defaultValue, isPrimaryKey: pk
            )
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT i.name, i.is_unique,
                   STUFF((
                       SELECT ',' + c.name
                       FROM sys.index_columns ic
                       JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                       WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id
                       ORDER BY ic.key_ordinal
                       FOR XML PATH('')
                   ), 1, 1, '')
            FROM sys.indexes i
            WHERE i.object_id = OBJECT_ID(\(qualifiedLiteral)) AND i.name IS NOT NULL
            ORDER BY i.name
            """
        )
        let indexes: [IndexInfo] = indexRows.compactMap { row in
            guard case .text(let name) = row[0] else { return nil }
            let unique: Bool = if case .bool(let b) = row[1] { b } else { false }
            let cols: [String] = if case .text(let joined) = row[2] {
                joined.split(separator: ",").map(String.init)
            } else { [] }
            return IndexInfo(name: name, isUnique: unique, columns: cols)
        }

        let fkRows = try await connection.queryAll(
            """
            SELECT pc.name, rt.name, rc.name
            FROM sys.foreign_key_columns fkc
            JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
            JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            JOIN sys.objects rt ON rt.object_id = fkc.referenced_object_id
            WHERE fkc.parent_object_id = OBJECT_ID(\(qualifiedLiteral))
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

    /// TR-04: `sys.dm_db_partition_stats` for an estimated row count (cheap —
    /// no table scan, matches Postgres's own `n_live_tup` estimate
    /// reasoning), `sys.partitions` reserved-page count × 8KB for size (index
    /// pages + data, same "table + indexes" scope Postgres's
    /// `pg_total_relation_size` covers), extended properties for a
    /// `MS_Description` comment if one was ever set via `sp_addextendedproperty`.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let schema = ref.database ?? "dbo"
        let qualifiedLiteral = dialect.stringLiteral("\(schema).\(ref.name)")
        let rows = try await connection.queryAll(
            """
            SELECT
                (SELECT SUM(row_count) FROM sys.dm_db_partition_stats
                 WHERE object_id = OBJECT_ID(\(qualifiedLiteral)) AND index_id IN (0, 1)),
                (SELECT SUM(reserved_page_count) * 8192 FROM sys.dm_db_partition_stats
                 WHERE object_id = OBJECT_ID(\(qualifiedLiteral))),
                (SELECT CAST(value AS NVARCHAR(MAX)) FROM sys.extended_properties
                 WHERE major_id = OBJECT_ID(\(qualifiedLiteral)) AND minor_id = 0 AND name = 'MS_Description')
            """
        )
        guard let row = rows.first else {
            return TableStats(estimatedRowCount: nil, sizeBytes: nil, engine: nil, comment: nil)
        }
        let rowCount: Int64? = if case .int(let n) = row[0] { n } else { nil }
        let size: Int64? = if case .int(let n) = row[1] { n } else { nil }
        let comment: String? = if case .text(let c) = row[2] { c } else { nil }
        return TableStats(estimatedRowCount: rowCount, sizeBytes: size, engine: nil, comment: comment)
    }

    public func ddl(of object: SchemaObject) async throws -> String {
        let schema = object.database ?? "dbo"
        switch object.kind {
        case .view, .function, .procedure, .trigger:
            // sp_helptext returns the CREATE statement's text, one row per
            // line of the original source — SQL Server has no single-string
            // "SHOW CREATE" the way Postgres/MySQL do for these object kinds.
            let rows = try await connection.queryAll(
                "EXEC sp_helptext \(dialect.stringLiteral("\(schema).\(object.name)"))"
            )
            let lines = rows.compactMap { row -> String? in
                if case .text(let line)? = row.first { return line } else { return nil }
            }
            guard !lines.isEmpty else {
                throw DriverError.queryFailed(message: "Cannot fetch definition for \(object.name)", code: nil)
            }
            return lines.joined()
        default:
            // No SHOW CREATE TABLE — rebuild basic DDL from the catalog, same
            // "enough for TR-03 view/copy, full DDL is CT-01's job" scope
            // `PostgresIntrospector.ddl` documents for its own table case.
            let detail = try await tableDetail(TableRef(database: schema, name: object.name))
            var lines: [String] = []
            for column in detail.columns {
                var line = "    \(dialect.quoteIdentifier(column.name)) \(column.declaredType)"
                if !column.isNullable { line += " NOT NULL" }
                if let def = column.defaultValue { line += " DEFAULT \(def)" }
                lines.append(line)
            }
            let pkCols = detail.columns.filter(\.isPrimaryKey).map { dialect.quoteIdentifier($0.name) }
            if !pkCols.isEmpty {
                lines.append("    PRIMARY KEY (\(pkCols.joined(separator: ", ")))")
            }
            let qualified = "\(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(object.name))"
            return "CREATE TABLE \(qualified) (\n\(lines.joined(separator: ",\n"))\n)"
        }
    }
}
