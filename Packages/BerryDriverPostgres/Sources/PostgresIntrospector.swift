import BerryDriverKit
import Foundation

/// Introspection via pg_catalog — faster and more accurate than
/// information_schema. For Postgres, SchemaObject's
/// `database` field means SCHEMA (namespace).
public struct PostgresIntrospector: Introspector {
    let connection: PostgresDriverConnection
    private let dialect = PostgresDialect()

    public func databases() async throws -> [DatabaseInfo] {
        let rows = try await connection.queryAll(
            "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname"
        )
        return rows.compactMap {
            if case .text(let name) = $0[0] { DatabaseInfo(name: name) } else { nil }
        }
    }

    public func objects(in database: String?) async throws -> [SchemaObject] {
        let filter = database.map { schema in
            "AND n.nspname = '\(schema.replacingOccurrences(of: "'", with: "''"))'"
        } ?? "AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')"

        let relRows = try await connection.queryAll(
            """
            SELECT n.nspname, c.relname, c.relkind::text
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'v', 'm', 'p') \(filter)
            ORDER BY n.nspname, c.relkind, c.relname
            """
        )
        var result: [SchemaObject] = relRows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let kind) = row[2] else { return nil }
            let objectKind: SchemaObjectKind = (kind == "v" || kind == "m") ? .view : .table
            return SchemaObject(kind: objectKind, name: name, database: schema)
        }

 // Functions & procedures. Per-overload signature in object.name
        // so each overloaded function is listed separately on the sidebar and
        // opens its own exact DDL tab.
        let routineRows = try await connection.queryAll(
            """
            SELECT n.nspname, p.proname, p.prokind::text, pg_get_function_identity_arguments(p.oid) AS args
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE p.prokind IN ('f', 'p') \(filter)
            ORDER BY n.nspname, p.proname, p.oid
            """
        )
        result += routineRows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let kind) = row[2] else { return nil }
            let args: String
            if row.count > 3, case .text(let a) = row[3] {
                args = a
            } else {
                args = ""
            }
            let fullName = "\(name)(\(args))"
            return SchemaObject(kind: kind == "p" ? .procedure : .function, name: fullName, database: schema)
        }

 // Triggers — DISTINCT so a name shared across tables shows once.
        let triggerRows = try await connection.queryAll(
            """
            SELECT DISTINCT n.nspname, t.tgname
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE NOT t.tgisinternal \(filter)
            ORDER BY n.nspname, t.tgname
            """
        )
        result += triggerRows.compactMap { row in
            guard case .text(let schema) = row[0], case .text(let name) = row[1] else { return nil }
            return SchemaObject(kind: .trigger, name: name, database: schema)
        }

        return result
    }

    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        // regclass downcases UNQUOTED identifiers, so a PascalCase or
        // reserved-word table (e.g. "User") wouldn't resolve — double-quote both
        // parts inside the literal so the exact name is used. The whole thing is
        // a single-quoted SQL literal, so single quotes are still escaped.
        let qualified = "'" + escaped(
            quotedIdentifier(ref.database ?? "public") + "." + quotedIdentifier(ref.name)
        ) + "'"

        let columnRows = try await connection.queryAll(
            """
            SELECT a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   NOT a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid),
                   COALESCE((
                       SELECT TRUE FROM pg_index i
                       WHERE i.indrelid = a.attrelid AND i.indisprimary
                         AND a.attnum = ANY(i.indkey)
                   ), FALSE)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = \(qualified)::regclass
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """
        )
        let columns: [ColumnInfo] = columnRows.compactMap { row in
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { return nil }
            let nullable: Bool = if case .bool(let b) = row[2] { b } else { true }
            let defaultValue = row[3].displayString
            let pk: Bool = if case .bool(let b) = row[4] { b } else { false }
            return ColumnInfo(
                name: name, declaredType: type, isNullable: nullable,
                defaultValue: defaultValue, isPrimaryKey: pk
            )
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT ic.relname, i.indisunique,
                   array_to_string(ARRAY(
                       SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum, ord)
                       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                       ORDER BY k.ord
                   ), ',')
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = \(qualified)::regclass
            ORDER BY ic.relname
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
            SELECT att.attname, ft.relname, fatt.attname
            FROM pg_constraint c
            JOIN pg_class ft ON ft.oid = c.confrelid
            JOIN unnest(c.conkey) WITH ORDINALITY AS ck(attnum, ord) ON TRUE
            JOIN unnest(c.confkey) WITH ORDINALITY AS fk(attnum, ord) ON fk.ord = ck.ord
            JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = ck.attnum
            JOIN pg_attribute fatt ON fatt.attrelid = c.confrelid AND fatt.attnum = fk.attnum
            WHERE c.contype = 'f' AND c.conrelid = \(qualified)::regclass
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

 /// `pg_stat_user_tables.n_live_tup` (autovacuum's estimate, cheap
    /// no table scan), `pg_total_relation_size` (table + indexes + TOAST),
    /// `obj_description` for any `COMMENT ON TABLE`. Postgres has no storage
    /// engine concept, so `engine` is always nil. `n_live_tup` is 0 (not null)
    /// until autovacuum's first pass on a freshly-populated table — that's a
    /// real "0 rows counted yet" state, distinct from "no stats row exists at
    /// all" (a table with zero rows ever inserted), so it's surfaced as-is.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let qualified = "'" + escaped(
            quotedIdentifier(ref.database ?? "public") + "." + quotedIdentifier(ref.name)
        ) + "'"
        let rows = try await connection.queryAll(
            """
            SELECT
                (SELECT n_live_tup FROM pg_stat_user_tables WHERE relid = \(qualified)::regclass),
                pg_total_relation_size(\(qualified)::regclass),
                obj_description(\(qualified)::regclass, 'pg_class')
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
        let schema = object.database ?? "public"
        switch object.kind {
        case .view:
            let rows = try await connection.queryAll(
                "SELECT pg_get_viewdef('" + escaped(
                    quotedIdentifier(schema) + "." + quotedIdentifier(object.name)
                ) + "'::regclass, true)"
            )
            if case .text(let def)? = rows.first?.first {
                return "CREATE VIEW \(dialect.quoteIdentifier(schema)).\(dialect.quoteIdentifier(object.name)) AS\n\(def)"
            }
            throw DriverError.queryFailed(message: "Cannot fetch view definition", code: nil)
        case .function, .procedure:
            // Match by schema + full signature OR bare proname
            let rows = try await connection.queryAll(
                """
                SELECT pg_get_functiondef(p.oid)
                FROM pg_proc p
                JOIN pg_namespace n ON n.oid = p.pronamespace
                WHERE n.nspname = '\(escaped(schema))'
                  AND (
                    (p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')') = '\(escaped(object.name))'
                    OR p.proname = '\(escaped(object.name))'
                  )
                  AND p.prokind IN ('f', 'p')
                ORDER BY p.oid
                """
            )
            let defs = rows.compactMap { row -> String? in
                if case .text(let def)? = row.first { return def } else { return nil }
            }
            guard !defs.isEmpty else {
                throw DriverError.queryFailed(message: "Cannot fetch routine definition", code: nil)
            }
            return defs.joined(separator: "\n\n")
        case .trigger:
            let rows = try await connection.queryAll(
                """
                SELECT pg_get_triggerdef(t.oid)
                FROM pg_trigger t
                JOIN pg_class c ON c.oid = t.tgrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE NOT t.tgisinternal
                  AND t.tgname = '\(escaped(object.name))'
                  AND n.nspname = '\(escaped(schema))'
                """
            )
            let defs = rows.compactMap { row -> String? in
                if case .text(let def)? = row.first { return def } else { return nil }
            }
            guard !defs.isEmpty else {
                throw DriverError.queryFailed(message: "Cannot fetch trigger definition", code: nil)
            }
            return defs.joined(separator: ";\n\n") + ";"
        default:
            // Postgres has no SHOW CREATE TABLE — rebuild basic DDL from the catalog.
 // Enough for (view/copy); the full version (constraints, storage) is's job.
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

    private func escaped(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "'", with: "''")
    }

    /// Double-quote an identifier (doubling any embedded quote) so PascalCase /
    /// reserved-word names survive regclass resolution.
    private func quotedIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
