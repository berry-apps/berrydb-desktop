import BerryDriverKit
import Foundation

/// Introspection via pg_catalog — faster and more accurate than
/// information_schema. For Postgres, SchemaObject's
/// `database` field means SCHEMA (namespace).
public struct PostgresIntrospector: Introspector, CatalogReadScoping {
    let connection: PostgresDriverConnection
    private let dialect = PostgresDialect()

    /// A pass reads through the connection's scope.
    public func beginCatalogReads() async throws -> CatalogReadScope? {
        try await connection.beginCatalogReads()
    }

    public func endCatalogReads(_ scope: CatalogReadScope, commit: Bool) async {
        await connection.endCatalogReads(scope, commit: commit)
    }

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
            SELECT att.attname, fn.nspname, ft.relname, fatt.attname
            FROM pg_constraint c
            JOIN pg_class ft ON ft.oid = c.confrelid
            JOIN pg_namespace fn ON fn.oid = ft.relnamespace
            JOIN unnest(c.conkey) WITH ORDINALITY AS ck(attnum, ord) ON TRUE
            JOIN unnest(c.confkey) WITH ORDINALITY AS fk(attnum, ord) ON fk.ord = ck.ord
            JOIN pg_attribute att ON att.attrelid = c.conrelid AND att.attnum = ck.attnum
            JOIN pg_attribute fatt ON fatt.attrelid = c.confrelid AND fatt.attnum = fk.attnum
            WHERE c.contype = 'f' AND c.conrelid = \(qualified)::regclass
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

    // MARK: - Bulk introspection

    public var bulkIntrospection: Bool { true }

    /// Always nil, so the caller lists the catalog on every check. The cheap
    /// candidate is the row-change counters of `pg_class`, `pg_attribute`,
    /// `pg_constraint` and `pg_index` in `pg_stat_sys_tables`, summed with the
    /// number of relations in scope, but those counters can trail a DDL
    /// statement of a session that stays connected
    /// (https://www.postgresql.org/docs/16/monitoring-stats.html). Measured
    /// against PostgreSQL 16 (postgres:16-alpine), polling from a second
    /// connection every 100 ms: a CREATE TABLE showed after 2 to 5 ms, only
    /// because the relation count moves at once. An ALTER TABLE ADD COLUMN
    /// showed after 2 to 4 ms when its session disconnected right after it, and
    /// not within 3 s when the session stayed connected. A psql session that
    /// ran the ALTER at once after connecting moved the counters after 10.2 s;
    /// one that waited 2 s first moved them at once. So the lag appears when a
    /// statement follows another within about a second, and a token that
    /// misses an ALTER typed into a connected SQL editor would report the
    /// catalog as unchanged until some later change.
    public func schemaVersionToken(scope: SchemaScope) async throws -> String? { nil }

    /// Partition children are left out and a partitioned table is listed as a
    /// table. The fingerprint hashes, per relation, each live column's name,
    /// formatted type, NOT NULL flag and default expression, in column order,
    /// and each index's oid, name, uniqueness, primary-key flag and key
    /// columns, so a changed default or a renamed index changes it. It does
    /// not see a replaced view body that keeps the same columns. System
    /// columns are skipped, and `attisdropped` hides dropped ones, which stay
    /// in `pg_attribute` (https://www.postgresql.org/docs/16/catalog-pg-attribute.html).
    ///
    /// The type is hashed as `format_type` writes it, with its modifier,
    /// rather than as its oid: renaming a user-defined type keeps the oid and
    /// changes the name every column of that type reads as. The primary-key
    /// flag is hashed because `ADD PRIMARY KEY USING INDEX` on columns already
    /// `NOT NULL` changes nothing else the fingerprint sees
    /// (https://www.postgresql.org/docs/16/sql-altertable.html). Both were
    /// checked against PostgreSQL 16 (postgres:16-alpine) by the tests.
    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        let rows = try await connection.queryAll(
            """
            SELECT n.nspname, c.relname, c.relkind::text,
                   md5(COALESCE((SELECT string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod)
                                                   || ':' || a.attnotnull::text || ':' || a.atthasdef::text
                                                   || ':' || COALESCE(pg_get_expr(d.adbin, d.adrelid), ''),
                                                   ',' ORDER BY a.attnum)
                                   FROM pg_attribute a
                                   LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
                                  WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped), '')
                       || '|' ||
                       COALESCE((SELECT string_agg(i.indexrelid::text || ':' || i.indisunique::text
                                                   || ':' || i.indisprimary::text || ':' || i.indkey::text
                                                   || ':' || ic.relname,
                                                   ',' ORDER BY i.indexrelid)
                                   FROM pg_index i
                                   JOIN pg_class ic ON ic.oid = i.indexrelid
                                  WHERE i.indrelid = c.oid), '')) AS fingerprint
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm') AND NOT c.relispartition AND \(scopeFilter(scope))
            ORDER BY n.nspname, c.relname
            """
        )
        return rows.compactMap { row in
            guard case .text(let schema) = row[0],
                  case .text(let name) = row[1],
                  case .text(let kind) = row[2] else { return nil }
            let fingerprint: String? = if case .text(let value) = row[3] { value } else { nil }
            return SchemaObjectSummary(
                ref: TableRef(database: schema, name: name),
                kind: (kind == "v" || kind == "m") ? .view : .table,
                fingerprint: fingerprint
            )
        }
    }

    /// One element per column pair, in key order, for keys whose own table is
    /// in scope; the referenced table may lie in any schema. PostgreSQL copies
    /// a key onto every partition of a partitioned table, on the referencing
    /// side and on the referenced side, and links each copy to the original
    /// through `conparentid`; keeping only the originals lists each key once
    /// and never names a partition child (verified against PostgreSQL 16,
    /// postgres:16-alpine; https://www.postgresql.org/docs/16/catalog-pg-constraint.html).
    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        let rows = try await connection.queryAll(
            """
            SELECT sn.nspname, sc.relname, att.attname, tn.nspname, tc.relname, fatt.attname, con.conname
            FROM pg_constraint con
            JOIN pg_class sc ON sc.oid = con.conrelid
            JOIN pg_namespace sn ON sn.oid = sc.relnamespace
            JOIN pg_class tc ON tc.oid = con.confrelid
            JOIN pg_namespace tn ON tn.oid = tc.relnamespace
            JOIN unnest(con.conkey) WITH ORDINALITY AS ck(attnum, ord) ON TRUE
            JOIN unnest(con.confkey) WITH ORDINALITY AS fk(attnum, ord) ON fk.ord = ck.ord
            JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = ck.attnum
            JOIN pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = fk.attnum
            WHERE con.contype = 'f' AND con.conparentid = 0 AND \(scopeFilter(scope, namespace: "sn.nspname"))
            ORDER BY sn.nspname, sc.relname, con.conname, ck.ord
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
    /// one resolves the oids, one reads the columns and one the indexes. Each
    /// detail carries the ref it was asked for, and an empty `foreignKeys`,
    /// because the keys of a whole scope come from `foreignKeys(scope:)`. A
    /// table that no longer exists is left out.
    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        guard !refs.isEmpty else { return [] }
        func resolved(_ ref: TableRef) -> TableRef { TableRef(database: ref.database ?? "public", name: ref.name) }

        let pairs = Set(refs.map(resolved)).map { "('\(escaped($0.database ?? ""))', '\(escaped($0.name))')" }
        let oidRows = try await connection.queryAll(
            """
            SELECT n.nspname, c.relname, c.oid::bigint
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE (n.nspname, c.relname) IN (\(pairs.joined(separator: ", ")))
            """
        )
        var oidByRef: [TableRef: Int64] = [:]
        for row in oidRows {
            guard case .text(let schema) = row[0], case .text(let name) = row[1], case .int(let oid) = row[2] else {
                continue
            }
            oidByRef[TableRef(database: schema, name: name)] = oid
        }
        guard !oidByRef.isEmpty else { return [] }
        let oidList = "ARRAY[" + oidByRef.values.map(String.init).joined(separator: ", ") + "]::oid[]"

        let columnRows = try await connection.queryAll(
            """
            SELECT a.attrelid::bigint, a.attname,
                   format_type(a.atttypid, a.atttypmod),
                   NOT a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid),
                   EXISTS (
                       SELECT 1 FROM pg_index i
                       WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY(i.indkey)
                   )
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = ANY(\(oidList)) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attrelid, a.attnum
            """
        )
        var columnsByOID: [Int64: [ColumnInfo]] = [:]
        for row in columnRows {
            guard case .int(let oid) = row[0], case .text(let name) = row[1], case .text(let type) = row[2] else {
                continue
            }
            let nullable: Bool = if case .bool(let b) = row[3] { b } else { true }
            let pk: Bool = if case .bool(let b) = row[5] { b } else { false }
            columnsByOID[oid, default: []].append(ColumnInfo(
                name: name, declaredType: type, isNullable: nullable,
                defaultValue: row[4].displayString, isPrimaryKey: pk
            ))
        }

        let indexRows = try await connection.queryAll(
            """
            SELECT i.indrelid::bigint, ic.relname, i.indisunique,
                   array_to_string(ARRAY(
                       SELECT a.attname FROM unnest(i.indkey) WITH ORDINALITY k(attnum, ord)
                       JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                       ORDER BY k.ord
                   ), ',')
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = ANY(\(oidList))
            ORDER BY i.indrelid, ic.relname
            """
        )
        var indexesByOID: [Int64: [IndexInfo]] = [:]
        for row in indexRows {
            guard case .int(let oid) = row[0], case .text(let name) = row[1] else { continue }
            let unique: Bool = if case .bool(let b) = row[2] { b } else { false }
            let columns: [String] = if case .text(let joined) = row[3] {
                joined.split(separator: ",").map(String.init)
            } else { [] }
            indexesByOID[oid, default: []].append(IndexInfo(name: name, isUnique: unique, columns: columns))
        }

        var seen = Set<TableRef>()
        return refs.compactMap { ref in
            let key = resolved(ref)
            guard let oid = oidByRef[key], seen.insert(key).inserted else { return nil }
            return TableDetail(
                ref: ref, columns: columnsByOID[oid] ?? [], indexes: indexesByOID[oid] ?? [], foreignKeys: []
            )
        }
    }

    /// SQL condition on the schema name `column` for `scope`. The system
    /// schemas, and the per-session temporary ones, are never part of
    /// `allUserSchemas`; the underscores of the temporary prefixes are
    /// escaped so a schema such as `pgxtemp1` is not mistaken for one.
    private func scopeFilter(_ scope: SchemaScope, namespace column: String = "n.nspname") -> String {
        switch scope {
        case .allUserSchemas:
            return """
                \(column) NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
                AND \(column) NOT LIKE 'pg!_temp!_%' ESCAPE '!' \
                AND \(column) NOT LIKE 'pg!_toast!_temp!_%' ESCAPE '!'
                """
        case .schemas(let names):
            guard !names.isEmpty else { return "FALSE" }
            return "\(column) IN (" + names.map { "'\(escaped($0))'" }.joined(separator: ", ") + ")"
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
