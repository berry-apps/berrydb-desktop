import BerryDriverKit
import Foundation

/// Introspection via `sys.objects`/`sys.columns`/`sys.indexes`
/// For SQL Server, `SchemaObject`'s `database`
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

 // Functions & procedures. type: 'P' = procedure, 'FN'/'TF'/'IF' = functions.
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

 // Triggers.
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
            SELECT pc.name, rs.name, rt.name, rc.name
            FROM sys.foreign_key_columns fkc
            JOIN sys.columns pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
            JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            JOIN sys.tables rt ON rt.object_id = fkc.referenced_object_id
            JOIN sys.schemas rs ON rs.schema_id = rt.schema_id
            WHERE fkc.parent_object_id = OBJECT_ID(\(qualifiedLiteral))
            """
        )
        let foreignKeys: [ForeignKeyInfo] = fkRows.compactMap { row in
            guard case .text(let column) = row[0],
                  case .text(let refSchema) = row[1],
                  case .text(let refTable) = row[2],
                  case .text(let refColumn) = row[3] else { return nil }
            return ForeignKeyInfo(
                column: column,
                referencedSchema: refSchema,
                referencedTable: refTable,
                referencedColumn: refColumn
            )
        }

        return TableDetail(ref: ref, columns: columns, indexes: indexes, foreignKeys: foreignKeys)
    }

 /// `sys.dm_db_partition_stats` for an estimated row count (cheap
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
 // "enough for view/copy, full DDL is's job" scope
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

    // MARK: - Bulk introspection

    public var bulkIntrospection: Bool { true }

    /// The catalog's own change dates, read in one query: the largest
    /// `modify_date` and the count of the tables and views in `scope`, and a
    /// checksum over every object's id and date. `modify_date` moves on
    /// `ALTER` and when an index on a table or view is created or altered
    /// (https://learn.microsoft.com/sql/relational-databases/system-catalog-views/sys-objects-transact-sql).
    /// Verified against SQL Server 2022 (mcr.microsoft.com/mssql/server:2022-latest,
    /// 16.0.4295.3): the table's date moved for ADD COLUMN, ALTER COLUMN
    /// (type and nullability), DROP COLUMN, renaming a column or the table,
    /// adding and dropping a default constraint, binding and unbinding a
    /// default with `sp_bindefault` and `sp_unbindefault`, adding a check,
    /// adding a unique constraint, adding and dropping a primary key or a
    /// foreign key (the referenced table's date moves too), creating,
    /// disabling, renaming and dropping an index, including a unique one. A
    /// view's date moved for ALTER VIEW and for `sp_refreshview`, which
    /// changes the view's columns after its base table changed; until then the
    /// view keeps the columns it had and its date stays. A read made right
    /// after the statement already showed the new value, with no lag. Inserts,
    /// `TRUNCATE`, `UPDATE STATISTICS` and `CREATE STATISTICS` left it alone.
    /// `sp_recompile`, `sp_refreshview` on an unchanged view and
    /// `ALTER INDEX ... REBUILD` move it without changing a definition, which
    /// costs one re-read and misses nothing. The date is a `datetime`, so two
    /// changes less than about 3 ms apart share one; a harvest cannot fall
    /// between them.
    ///
    /// The dates are readings of the server's clock. After the clock is set
    /// back, a change can carry a date below the current maximum, so the
    /// maximum alone would report an unchanged catalog; the checksum moves
    /// with any single object's date, up to a hash collision, and the count
    /// covers drops.
    public func schemaVersionToken(scope: SchemaScope) async throws -> String? {
        let rows = try await connection.queryAll(
            """
            SELECT ISNULL(CONVERT(varchar(30), MAX(o.modify_date), 126), ''), COUNT(*),
                   ISNULL(CHECKSUM_AGG(CHECKSUM(o.object_id, o.modify_date)), 0)
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type IN ('U', 'V') AND \(scopeFilter(scope, schemaColumn: "s.name"))
            """
        )
        guard let row = rows.first,
              case .text(let latest) = row[0],
              case .int(let count) = row[1],
              case .int(let checksum) = row[2] else { return nil }
        return "\(latest):\(count):\(checksum)"
    }

    /// The fingerprint is the object's `modify_date` to the millisecond, so it
    /// moves for exactly the changes that `schemaVersionToken` lists as moving
    /// the date, and not for the row changes it lists as leaving it alone. Of
    /// what the details carry, that list covers column changes, defaults of
    /// both kinds, keys and indexes with their names, and the columns of a
    /// view after `ALTER VIEW` or `sp_refreshview`; a change not on that list
    /// has not been measured.
    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        let rows = try await connection.queryAll(
            """
            SELECT s.name, o.name, o.type, CONVERT(varchar(30), o.modify_date, 126)
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type IN ('U', 'V') AND \(scopeFilter(scope, schemaColumn: "s.name"))
            ORDER BY s.name, o.name
            """
        )
        return rows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let type) = row[2] else { return nil }
            let fingerprint: String? = if case .text(let value) = row[3] { value } else { nil }
            return SchemaObjectSummary(
                ref: TableRef(database: schema, name: name),
                kind: type.trimmingCharacters(in: .whitespaces) == "V" ? .view : .table,
                fingerprint: fingerprint
            )
        }
    }

    /// One element per column pair, in the key's own column order, for keys
    /// whose own table is in scope; the referenced table may lie in any schema.
    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        let rows = try await connection.queryAll(
            """
            SELECT ss.name, so.name, sc.name, rs.name, ro.name, rc.name, fk.name
            FROM sys.foreign_key_columns fkc
            JOIN sys.foreign_keys fk ON fk.object_id = fkc.constraint_object_id
            JOIN sys.objects so ON so.object_id = fkc.parent_object_id
            JOIN sys.schemas ss ON ss.schema_id = so.schema_id
            JOIN sys.columns sc ON sc.object_id = fkc.parent_object_id AND sc.column_id = fkc.parent_column_id
            JOIN sys.objects ro ON ro.object_id = fkc.referenced_object_id
            JOIN sys.schemas rs ON rs.schema_id = ro.schema_id
            JOIN sys.columns rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id
            WHERE \(scopeFilter(scope, schemaColumn: "ss.name"))
            ORDER BY ss.name, so.name, fk.name, fkc.constraint_column_id
            """
        )
        return rows.compactMap { row in
            guard case .text(let sourceSchema) = row[0],
                  case .text(let sourceTable) = row[1],
                  case .text(let column) = row[2],
                  case .text(let targetSchema) = row[3],
                  case .text(let targetTable) = row[4],
                  case .text(let referencedColumn) = row[5] else { return nil }
            let constraintName: String? = if case .text(let name) = row[6] { name } else { nil }
            return ForeignKeyRelation(
                source: TableRef(database: sourceSchema, name: sourceTable),
                column: column,
                target: TableRef(database: targetSchema, name: targetTable),
                referencedColumn: referencedColumn,
                constraintName: constraintName
            )
        }
    }

    /// Columns and indexes of `refs` in three queries, whatever their number:
    /// one resolves the schema and table names to object ids, the others read
    /// the columns and the indexes by id. A ref without a schema means `dbo`,
    /// as in `tableDetail`. Each detail carries the ref it was asked for, and
    /// an empty `foreignKeys`, because the keys of a whole scope come from
    /// `foreignKeys(scope:)`. A table that no longer exists is left out, and so
    /// is a ref spelled in another case than the catalog holds, which the
    /// server's names match but the result cannot be paired back to.
    ///
    /// Everything is read the way `tableDetail` reads it, so the two agree: the
    /// type is the bare type name, a default is `OBJECT_DEFINITION` of the
    /// column's default object, and an index lists its columns in
    /// `key_ordinal` order, which puts the columns of an `INCLUDE` clause
    /// (ordinal 0) ahead of the key columns. `OBJECT_DEFINITION` rather than
    /// `sys.default_constraints`, because a default bound with the legacy
    /// `sp_bindefault` has no row there. Verified against SQL Server 2022
    /// (mcr.microsoft.com/mssql/server:2022-latest): such a column reads its
    /// `CREATE DEFAULT` text through `OBJECT_DEFINITION` and NULL through the
    /// view.
    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        guard !refs.isEmpty else { return [] }

        func schemaName(of ref: TableRef) -> String { ref.database ?? "dbo" }
        let predicates = refs.map {
            "(s.name = \(unicodeLiteral(schemaName(of: $0))) AND o.name = \(unicodeLiteral($0.name)))"
        }
        let idRows = try await connection.queryAll(
            """
            SELECT s.name, o.name, o.object_id
            FROM sys.objects o
            JOIN sys.schemas s ON s.schema_id = o.schema_id
            WHERE o.type IN ('U', 'V') AND (\(predicates.joined(separator: " OR ")))
            """
        )
        var idsByRef: [TableRef: Int64] = [:]
        for row in idRows {
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .int(let id) = row[2] else { continue }
            idsByRef[TableRef(database: schema, name: name)] = id
        }
        guard !idsByRef.isEmpty else { return [] }
        // Integers the server returned, so nothing here needs escaping.
        let ids = idsByRef.values.map(String.init).joined(separator: ", ")

        let columnRows = try await connection.queryAll(
            """
            SELECT c.object_id, c.name, t.name, c.is_nullable, OBJECT_DEFINITION(c.default_object_id),
                   CASE WHEN EXISTS (
                       SELECT 1 FROM sys.index_columns ic
                       JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                       WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id
                   ) THEN 1 ELSE 0 END
            FROM sys.columns c
            JOIN sys.types t ON t.user_type_id = c.user_type_id
            WHERE c.object_id IN (\(ids))
            ORDER BY c.object_id, c.column_id
            """
        )
        var columnsById: [Int64: [ColumnInfo]] = [:]
        for row in columnRows {
            guard case .int(let id) = row[0],
                  case .text(let name) = row[1],
                  case .text(let type) = row[2] else { continue }
            let nullable: Bool = if case .bool(let b) = row[3] { b } else { true }
            let primaryKey: Bool = if case .int(let n) = row[5] { n != 0 } else { false }
            columnsById[id, default: []].append(ColumnInfo(
                name: name, declaredType: type, isNullable: nullable,
                defaultValue: row[4].displayString, isPrimaryKey: primaryKey
            ))
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT i.object_id, i.name, i.is_unique, c.name
            FROM sys.indexes i
            JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
            WHERE i.object_id IN (\(ids)) AND i.name IS NOT NULL
            ORDER BY i.object_id, i.name, ic.key_ordinal, ic.index_column_id
            """
        )
        // One row per index column, so consecutive rows of one index are
        // folded into one `IndexInfo`.
        var indexesById: [Int64: [IndexInfo]] = [:]
        var pending: (id: Int64, name: String, isUnique: Bool, columns: [String])?
        func flushPending() {
            guard let index = pending else { return }
            indexesById[index.id, default: []].append(
                IndexInfo(name: index.name, isUnique: index.isUnique, columns: index.columns)
            )
            pending = nil
        }
        for row in indexRows {
            guard case .int(let id) = row[0],
                  case .text(let name) = row[1],
                  case .text(let column) = row[3] else { continue }
            if let index = pending, index.id != id || index.name != name { flushPending() }
            if pending == nil {
                let unique: Bool = if case .bool(let b) = row[2] { b } else { false }
                pending = (id: id, name: name, isUnique: unique, columns: [])
            }
            pending?.columns.append(column)
        }
        flushPending()

        var seen = Set<TableRef>()
        return refs.compactMap { ref in
            let key = TableRef(database: schemaName(of: ref), name: ref.name)
            guard let id = idsByRef[key], seen.insert(key).inserted else { return nil }
            return TableDetail(
                ref: ref, columns: columnsById[id] ?? [], indexes: indexesById[id] ?? [], foreignKeys: []
            )
        }
    }

    /// SQL condition on the schema name `column` for `scope`. `sys` and
    /// `INFORMATION_SCHEMA` are the server's own schemas and never part of
    /// `allUserSchemas`.
    private func scopeFilter(_ scope: SchemaScope, schemaColumn column: String) -> String {
        switch scope {
        case .allUserSchemas:
            return "\(column) NOT IN ('sys', 'INFORMATION_SCHEMA')"
        case .schemas(let names):
            guard !names.isEmpty else { return "1 = 0" }
            return "\(column) IN (" + names.map(unicodeLiteral).joined(separator: ", ") + ")"
        }
    }

    /// A string literal of Unicode type. Without the `N`, the server reads the
    /// literal in the code page of the database's collation, and a name with a
    /// character outside it no longer matches the stored one. Verified against
    /// SQL Server 2022 (mcr.microsoft.com/mssql/server:2022-latest, collation
    /// `SQL_Latin1_General_CP1_CI_AS`): a schema name with Vietnamese letters
    /// written as a plain literal reads back with question marks in place of
    /// some of them and equals no schema name, while the `N` form finds the
    /// schema.
    private func unicodeLiteral(_ value: String) -> String {
        "N" + dialect.stringLiteral(value)
    }
}
