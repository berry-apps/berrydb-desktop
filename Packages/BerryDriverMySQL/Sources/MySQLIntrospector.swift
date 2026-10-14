import BerryDriverKit
import Foundation

/// Introspection via information_schema + SHOW CREATE TABLE
/// In MySQL, database and schema are the same thing.
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
        let schemaFilter = database.map { "= '\(Self.escaped($0))'" } ?? "= DATABASE()"
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

 // Functions & procedures. MySQL forbids overloading, so the
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

 // Triggers.
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
        let schemaExpr = ref.database.map { "'\(Self.escaped($0))'" } ?? "DATABASE()"
        let table = Self.escaped(ref.name)

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
            SELECT COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = \(schemaExpr) AND TABLE_NAME = '\(table)'
              AND REFERENCED_TABLE_NAME IS NOT NULL
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

 /// `information_schema.TABLES` carries all four fields at once
    /// `TABLE_ROWS` is InnoDB's estimate (not exact; MySQL's own docs say so),
    /// `DATA_LENGTH + INDEX_LENGTH` is on-disk size, `ENGINE` and
    /// `TABLE_COMMENT` are exact.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let schemaExpr = ref.database.map { "'\(Self.escaped($0))'" } ?? "DATABASE()"
        let table = Self.escaped(ref.name)
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

    // MARK: - Bulk introspection

    public var bulkIntrospection: Bool { true }

    /// Always nil, so the caller lists the catalog on every check. The
    /// candidate is `information_schema.TABLES.CREATE_TIME`, which moves when
    /// ALTER TABLE rewrites a table's definition, `INSTANT` and `INPLACE`
    /// alters included, but it is a TIMESTAMP with one-second resolution and a
    /// replaced view keeps its own
    /// (https://dev.mysql.com/doc/refman/8.4/en/information-schema-tables-table.html).
    /// Measured against MySQL 8.4 (mysql:8.4, 8.4.11): in six of six runs a
    /// CREATE TABLE, an `INSTANT` ADD COLUMN and an `INPLACE` ADD INDEX issued
    /// one after another left the value equal, and CREATE OR REPLACE VIEW with
    /// a new column list left the view's value as it was. `UPDATE_TIME` follows
    /// row changes, not definitions, and read NULL after an INSERT in the same
    /// measurement. A token that missed an ALTER typed into a connected SQL
    /// editor would report the catalog as unchanged until some later change.
    public func schemaVersionToken(scope: SchemaScope) async throws -> String? { nil }

    /// The fingerprint hashes, per table or view, each column's position,
    /// name, type, nullability, default and key flag, in column order, and each
    /// index's name, uniqueness and key columns, so a changed default or a
    /// renamed index changes it. A default is hashed with a leading marker,
    /// which keeps a column without one apart from a column whose default is
    /// the empty string, as the details do. A functional key part has no column name and
    /// counts with an empty one, since `GROUP_CONCAT` would otherwise drop the
    /// whole element and an expression-only index would leave no trace. Row
    /// counts, cardinality and auto-increment values are left out: they change
    /// with data and with `ANALYZE TABLE`, and a fingerprint that followed them
    /// would send every table to a full re-read after any write. It does not
    /// see a replaced view body that keeps the same columns.
    ///
    /// `GROUP_CONCAT` cuts its result at `group_concat_max_len`, 1024
    /// characters by default on MySQL, which a table with a few dozen columns
    /// exceeds; the fingerprint would then ignore every later column
    /// (https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_group_concat_max_len).
    /// The limit is raised for this query alone where the server can, so the
    /// user's session keeps its own limit and a server session a pooler hands
    /// to another client carries nothing; an older server raises it for the
    /// session.
    ///
    /// MariaDB reports a system-versioned table as `SYSTEM VERSIONED`
    /// (https://mariadb.com/kb/en/information-schema-tables-table/); it has
    /// columns, indexes and keys like any table and is listed as one, verified
    /// against MariaDB 11.8.9. A sequence, `SEQUENCE` there, is left out: it is
    /// a generator with no columns or keys of its own to harvest.
    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        let rows = try await connection.queryAll(
            """
            SELECT t.TABLE_SCHEMA, t.TABLE_NAME, t.TABLE_TYPE,
                   MD5(CONCAT(
                     COALESCE((SELECT GROUP_CONCAT(CONCAT(c.ORDINAL_POSITION, ':', c.COLUMN_NAME, ':', c.COLUMN_TYPE, ':',
                                                          c.IS_NULLABLE, ':', COALESCE(CONCAT('=', c.COLUMN_DEFAULT), ''), ':', c.COLUMN_KEY)
                                                   ORDER BY c.ORDINAL_POSITION SEPARATOR ',')
                                 FROM information_schema.COLUMNS c
                                WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME), ''),
                     '|',
                     COALESCE((SELECT GROUP_CONCAT(CONCAT(s.INDEX_NAME, ':', s.NON_UNIQUE, ':', s.SEQ_IN_INDEX, ':', COALESCE(s.COLUMN_NAME, ''))
                                                   ORDER BY s.INDEX_NAME, s.SEQ_IN_INDEX SEPARATOR ',')
                                 FROM information_schema.STATISTICS s
                                WHERE s.TABLE_SCHEMA = t.TABLE_SCHEMA AND s.TABLE_NAME = t.TABLE_NAME), '')
                   )) AS fingerprint
            FROM information_schema.TABLES t
            WHERE \(try await scopeFilter(scope, schemaColumn: "t.TABLE_SCHEMA")) AND t.TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED', 'VIEW')
            ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME
            """,
            groupConcatMaxLength: 1_048_576
        )
        return rows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let type) = row[2] else { return nil }
            let fingerprint: String? = if case .text(let value) = row[3] { value } else { nil }
            return SchemaObjectSummary(
                ref: TableRef(database: schema, name: name),
                kind: type == "VIEW" ? .view : .table,
                fingerprint: fingerprint
            )
        }
    }

    /// One element per column pair, in key order, for keys whose own table is
    /// in scope; the referenced table may lie in any schema.
    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        let rows = try await connection.queryAll(
            """
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME,
                   REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, CONSTRAINT_NAME
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE REFERENCED_TABLE_NAME IS NOT NULL AND \(try await scopeFilter(scope, schemaColumn: "TABLE_SCHEMA"))
            ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
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

    /// Columns and indexes of `refs` in two queries, whatever their number,
    /// plus one to learn the connection's current schema when a ref names none.
    /// Each detail carries the ref it was asked for, and an empty
    /// `foreignKeys`, because the keys of a whole scope come from
    /// `foreignKeys(scope:)`. A table that no longer exists is left out.
    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        guard !refs.isEmpty else { return [] }

        var currentSchema: String?
        if refs.contains(where: { $0.database == nil }),
           case .text(let name)? = try await connection.queryAll("SELECT DATABASE()").first?.first {
            currentSchema = name
        }
        func resolved(_ ref: TableRef) -> TableRef? {
            guard let schema = ref.database ?? currentSchema else { return nil }
            return TableRef(database: schema, name: ref.name)
        }

        let keys = Set(refs.compactMap(resolved))
        guard !keys.isEmpty else { return [] }
        let pairs = keys.map { "('\(Self.escaped($0.database ?? ""))', '\(Self.escaped($0.name))')" }.joined(separator: ", ")

        let columnRows = try await connection.queryAll(
            """
            SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY
            FROM information_schema.COLUMNS
            WHERE (TABLE_SCHEMA, TABLE_NAME) IN (\(pairs))
            ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION
            """
        )
        var columnsByRef: [TableRef: [ColumnInfo]] = [:]
        for row in columnRows {
            guard case .text(let schema) = row[0],
                  case .text(let table) = row[1],
                  case .text(let name) = row[2] else { continue }
            columnsByRef[TableRef(database: schema, name: table), default: []].append(ColumnInfo(
                name: name,
                declaredType: row[3].displayString ?? "",
                isNullable: row[4].displayString == "YES",
                defaultValue: row[5].isNull ? nil : row[5].displayString,
                isPrimaryKey: row[6].displayString == "PRI"
            ))
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, NON_UNIQUE, COLUMN_NAME
            FROM information_schema.STATISTICS
            WHERE (TABLE_SCHEMA, TABLE_NAME) IN (\(pairs))
            ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            """
        )
        // One row per key column. The per-table query groups them in SQL, where
        // GROUP_CONCAT skips a NULL name; a functional key part has none, so it
        // is skipped here the same way and the index is still listed.
        var indexesByRef: [TableRef: [IndexInfo]] = [:]
        var pending: (ref: TableRef, name: String, isUnique: Bool, columns: [String])?
        func flushPending() {
            guard let index = pending else { return }
            indexesByRef[index.ref, default: []].append(
                IndexInfo(name: index.name, isUnique: index.isUnique, columns: index.columns)
            )
            pending = nil
        }
        for row in indexRows {
            guard case .text(let schema) = row[0],
                  case .text(let table) = row[1],
                  case .text(let name) = row[2] else { continue }
            let ref = TableRef(database: schema, name: table)
            if let index = pending, index.ref != ref || index.name != name { flushPending() }
            if pending == nil {
                let nonUnique: Bool = if case .int(let n) = row[3] { n != 0 } else { true }
                pending = (ref: ref, name: name, isUnique: !nonUnique, columns: [])
            }
            if case .text(let column) = row[4] { pending?.columns.append(column) }
        }
        flushPending()

        var seen = Set<TableRef>()
        return refs.compactMap { ref in
            // A table has at least one column, so a key without any is gone.
            guard let key = resolved(ref), let columns = columnsByRef[key], seen.insert(key).inserted else {
                return nil
            }
            return TableDetail(ref: ref, columns: columns, indexes: indexesByRef[key] ?? [], foreignKeys: [])
        }
    }

    /// SQL condition on the schema name `column` for `scope`. A MySQL schema is
    /// a database, and a profile usually names the one it works in, as the
    /// sidebar's listing does: the default scope is then that database alone,
    /// so the names of every other database on a shared server reach neither
    /// the stored schema nor what is built from it. Only a connection with no
    /// database selected (`DATABASE()` is NULL,
    /// https://dev.mysql.com/doc/refman/8.4/en/information-functions.html#function_database)
    /// takes every database but the server's own four. An explicit selection
    /// may still name any database.
    private func scopeFilter(_ scope: SchemaScope, schemaColumn column: String) async throws -> String {
        switch scope {
        case .allUserSchemas:
            return try Self.defaultScopeFilter(answer: try await connection.queryAll("SELECT DATABASE()"), schemaColumn: column)
        case .schemas(let names):
            guard !names.isEmpty else { return "FALSE" }
            return "\(column) IN (" + names.map { "'\(Self.escaped($0))'" }.joined(separator: ", ") + ")"
        }
    }

    /// The default scope's filter from the answer to `SELECT DATABASE()`:
    /// the connection's database, or every user database when the answer is NULL.
    static func defaultScopeFilter(answer: [[BerryValue]], schemaColumn column: String) throws -> String {
        switch answer.first?.first {
        case .text(let current)?:
            return "\(column) = '\(Self.escaped(current))'"
        case .null?:
            break
        default:
            // Neither a name nor NULL: nothing is known about the connection's
            // database, and reading every database would be the wrong guess.
            throw DriverError.queryFailed(message: "Could not read the connection's current database", code: nil)
        }
        return "\(column) NOT IN (" + Self.systemSchemas.map { "'\($0)'" }.joined(separator: ", ") + ")"
    }

    /// Escapes `value` for a single-quoted string literal. A quote is doubled,
    /// and so is a backslash, which MySQL reads as the escape character inside
    /// a string literal unless the `NO_BACKSLASH_ESCAPES` SQL mode is set
    /// (https://dev.mysql.com/doc/refman/8.4/en/string-literals.html). Without
    /// the second step a name that ends with a backslash swallows the closing
    /// quote and splices the next literal of the statement into itself. Under
    /// `NO_BACKSLASH_ESCAPES` a doubled backslash is taken literally, so a name
    /// that contains one would then not match; that is the one mode this
    /// mis-escapes, accepted because the default mode is the common one.
    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
    }
}
