import BerryDriverKit
import Foundation
import SQLite3

/// SQLite introspection via sqlite_master + PRAGMA.
public struct SQLiteIntrospector: Introspector {
    let connection: SQLiteConnection
    private let dialect = SQLiteDialect()

    public func databases() async throws -> [DatabaseInfo] {
        [DatabaseInfo(name: "main")]
    }

    public func objects(in database: String?) async throws -> [SchemaObject] {
        let rows = try await connection.queryAll(
            """
            SELECT type, name FROM sqlite_master
            WHERE type IN ('table', 'view', 'trigger') AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        )
        return rows.compactMap { row in
            guard case .text(let type) = row[0], case .text(let name) = row[1],
                  let kind = SchemaObjectKind(rawValue: type) else { return nil }
            return SchemaObject(kind: kind, name: name)
        }
    }

    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        let quoted = dialect.quoteIdentifier(ref.name)

        let columnRows = try await connection.queryAll("PRAGMA table_info(\(quoted))")
        // PRAGMA table_info: cid, name, type, notnull, dflt_value, pk
        let columns: [ColumnInfo] = columnRows.compactMap { row in
            guard case .text(let name) = row[1] else { return nil }
            let type: String = if case .text(let t) = row[2] { t } else { "" }
            let notNull: Bool = if case .int(let n) = row[3] { n != 0 } else { false }
            let defaultValue: String? = row[4].displayString
            let pk: Bool = if case .int(let p) = row[5] { p != 0 } else { false }
            return ColumnInfo(
                name: name, declaredType: type, isNullable: !notNull,
                defaultValue: defaultValue, isPrimaryKey: pk
            )
        }

        // PRAGMA index_list: seq, name, unique, origin, partial
        let indexRows = try await connection.queryAll("PRAGMA index_list(\(quoted))")
        var indexes: [IndexInfo] = []
        for row in indexRows {
            guard case .text(let indexName) = row[1] else { continue }
            let isUnique: Bool = if case .int(let u) = row[2] { u != 0 } else { false }
            let infoRows = try await connection.queryAll(
                "PRAGMA index_info(\(dialect.quoteIdentifier(indexName)))"
            )
            let cols = infoRows.compactMap { r -> String? in
                if case .text(let c) = r[2] { return c } else { return nil }
            }
            indexes.append(IndexInfo(name: indexName, isUnique: isUnique, columns: cols))
        }

        // PRAGMA foreign_key_list: id, seq, table, from, to, ...
        let fkRows = try await connection.queryAll("PRAGMA foreign_key_list(\(quoted))")
        let foreignKeys: [ForeignKeyInfo] = fkRows.compactMap { row in
            guard case .text(let refTable) = row[2],
                  case .text(let from) = row[3] else { return nil }
            let to: String = if case .text(let t) = row[4] { t } else { "" }
            return ForeignKeyInfo(column: from, referencedTable: refTable, referencedColumn: to)
        }

        return TableDetail(ref: ref, columns: columns, indexes: indexes, foreignKeys: foreignKeys)
    }

 /// SQLite has no catalog row-count estimate (no `ANALYZE`-free
    /// stats table), so this is an exact `COUNT(*)` rather than an estimate —
    /// strictly better than an estimate, just potentially slower on a huge
    /// table. Size comes from the `dbstat` virtual table, which needs
    /// `SQLITE_ENABLE_DBSTAT_VTAB` at compile time — not guaranteed on every
    /// build of libsqlite3, so that query is best-effort (`try?`, nil on
    /// failure) while the count is a hard failure like any other query.
    /// SQLite has no storage-engine or table-comment concept.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let quoted = dialect.quoteIdentifier(ref.name)
        let countRows = try await connection.queryAll("SELECT COUNT(*) FROM \(quoted)")
        let rowCount: Int64? = if case .int(let n) = countRows.first?.first { n } else { nil }

        let size: Int64?
        if let sizeRows = try? await connection.queryAll(
            "SELECT SUM(pgsize) FROM dbstat WHERE name = ?", binds: [ref.name]
        ), case .int(let n) = sizeRows.first?.first {
            size = n
        } else {
            size = nil
        }

        return TableStats(estimatedRowCount: rowCount, sizeBytes: size, engine: "SQLite", comment: nil)
    }

    public func ddl(of object: SchemaObject) async throws -> String {
        let rows = try await connection.queryAll(
            "SELECT sql FROM sqlite_master WHERE name = ?", binds: [object.name]
        )
        guard let first = rows.first, case .text(let sql) = first[0] else {
            throw DriverError.queryFailed(message: "DDL of \(object.name) not found", code: nil)
        }
        return sql
    }

    // MARK: - Bulk introspection

    // The members below ignore their scope: a SQLite file is one namespace,
    // so `TableRef.database` stays nil and there is nothing to filter by.

    public var bulkIntrospection: Bool { true }

    /// The schema cookie in the database file header, which SQLite increments
    /// on every change to the schema, so two equal values mean no table, view,
    /// column, index or foreign key changed
    /// (https://www.sqlite.org/pragma.html#pragma_schema_version). Row changes
    /// leave it alone. It lives in the file, so a change made through another
    /// connection shows too. Nil when the pragma returns no integer, so the
    /// caller lists the catalog instead.
    public func schemaVersionToken(scope: SchemaScope) async throws -> String? {
        let rows = try await connection.queryAll("PRAGMA schema_version")
        guard case .int(let version) = rows.first?.first else { return nil }
        return String(version)
    }

    /// Every table and view, with a fingerprint of its definition, in two
    /// statements for the whole file. The fingerprint hashes the object's own
    /// `CREATE` text from `sqlite_schema` (https://www.sqlite.org/schematab.html),
    /// followed by the `CREATE INDEX` text of each index on it in name order.
    /// The table text carries its columns, defaults, constraints and foreign
    /// keys, and `ALTER TABLE` updates it
    /// (https://www.sqlite.org/lang_altertable.html). The indexes SQLite
    /// creates for `UNIQUE` and `PRIMARY KEY` constraints have no text of their
    /// own and are covered by the table's. Triggers are not part of a table's
    /// definition, as in `tableDetail`. SQLite has no hash function among its
    /// core functions (https://www.sqlite.org/lang_corefunc.html), so the hash
    /// is computed here.
    ///
    /// A view's fingerprint also holds its column list from `PRAGMA
    /// table_info`. SQLite keeps a view's text as written, so a `SELECT *`
    /// view's text stays the same when its base table gains a column, while
    /// the pragma lists the new column (checked with the sqlite3 3.51.0
    /// shell). A view whose pragma fails, one over a dropped table, gets a
    /// fixed marker instead, so its fingerprint holds from one listing to the
    /// next. The pragma runs in-process, once per view.
    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        let objectRows = try await connection.queryAll(
            """
            SELECT type, name, sql FROM sqlite_schema
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        )
        let indexRows = try await connection.queryAll(
            """
            SELECT tbl_name, sql FROM sqlite_schema
            WHERE type = 'index' AND sql IS NOT NULL
            ORDER BY tbl_name, name
            """
        )
        var indexDefinitions: [String: [String]] = [:]
        for row in indexRows {
            guard case .text(let table) = row[0], case .text(let sql) = row[1] else { continue }
            indexDefinitions[table, default: []].append(sql)
        }
        var summaries: [SchemaObjectSummary] = []
        for row in objectRows {
            guard case .text(let type) = row[0], case .text(let name) = row[1],
                  let kind = SchemaObjectKind(rawValue: type) else { continue }
            let definition: String = if case .text(let sql) = row[2] { sql } else { "" }
            var text = definition + "|" + (indexDefinitions[name] ?? []).joined(separator: ";")
            if kind == .view { text += "|" + (try await resolvedColumns(ofView: name)) }
            summaries.append(SchemaObjectSummary(ref: TableRef(name: name), kind: kind, fingerprint: ContentHash.fnv1a64(text)))
        }
        return summaries
    }

    /// Every field `PRAGMA table_info` reports for each column of `view`, or
    /// a fixed marker when the pragma fails to prepare, as it does for a view
    /// over a dropped table. A present field is hashed with a leading marker,
    /// which keeps a missing default apart from a default written as `NULL`.
    private func resolvedColumns(ofView view: String) async throws -> String {
        let rows: [[BerryValue]]
        do {
            rows = try await connection.queryAll("PRAGMA table_info(\(dialect.quoteIdentifier(view)))")
        } catch DriverError.queryFailed(_, let code) where code == SQLITE_ERROR {
            return "unresolved"
        }
        return rows.map { $0.map { $0.displayString.map { "=" + $0 } ?? "" }.joined(separator: ":") }.joined(separator: ",")
    }

    /// One element per column pair of every table's keys, read with
    /// `PRAGMA foreign_key_list` once per table
    /// (https://www.sqlite.org/pragma.html#pragma_foreign_key_list), which
    /// costs no round trip in-process. The pragma does not report constraint
    /// names. A composite key lists its pairs in key order, and the keys come
    /// by id; the pragma's own row order is not documented, so both are sorted.
    ///
    /// A key that names no parent column references the parent's primary key
    /// (https://www.sqlite.org/foreignkeys.html) and the pragma reports the
    /// column as NULL. It is then taken from the parent's primary key columns,
    /// by position in the key. A pair with no such column, because the parent
    /// is missing or has no primary key, is left out: there is no column to
    /// name, and an empty one would make a relation to nothing.
    ///
    /// The pragma reports the parent as the `REFERENCES` clause wrote it, and
    /// SQLite resolves that name ignoring the case of ASCII letters only: with
    /// the sqlite3 3.51.0 shell, `CREATE TABLE orders` fails next to an
    /// existing `Orders`, while `äpfel` and `Äpfel` are two tables. The target
    /// is named as its table is listed, so the relation joins the stored
    /// object, and keeps the written name when no listed table matches.
    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        var relations: [ForeignKeyRelation] = []
        let tables = try await objects(in: nil).filter { $0.kind == .table }
        let listedNames = Dictionary(tables.map { (Self.asciiFolded($0.name), $0.name) }, uniquingKeysWith: { first, _ in first })
        for object in tables {
            try Task.checkCancellation()
            let quoted = dialect.quoteIdentifier(object.name)
            // PRAGMA foreign_key_list: id, seq, table, from, to, ...
            let pairs = try await connection.queryAll("PRAGMA foreign_key_list(\(quoted))")
                .compactMap { row -> (id: Int64, seq: Int64, table: String, from: String, to: String?)? in
                    guard case .int(let id) = row[0], case .int(let seq) = row[1],
                          case .text(let table) = row[2], case .text(let from) = row[3] else { return nil }
                    let to: String? = if case .text(let column) = row[4] { column } else { nil }
                    return (id, seq, table, from, to)
                }
                .sorted { ($0.id, $0.seq) < ($1.id, $1.seq) }
            for pair in pairs {
                var referenced = pair.to
                if referenced == nil {
                    let key = try await primaryKeyColumns(of: pair.table)
                    if key.indices.contains(Int(pair.seq)) { referenced = key[Int(pair.seq)] }
                }
                guard let referenced else { continue }
                let target = listedNames[Self.asciiFolded(pair.table)] ?? pair.table
                relations.append(ForeignKeyRelation(
                    source: TableRef(name: object.name), column: pair.from,
                    target: TableRef(name: target), referencedColumn: referenced
                ))
            }
        }
        return relations
    }

    /// One `tableDetail` per ref: everything is in-process, so a chunked query
    /// would save no round trip. A table dropped since the listing is left
    /// out: `PRAGMA table_info` answers with no rows for a name that does not
    /// exist (checked against the system SQLite by the tests), and a table
    /// always has at least one column
    /// (https://www.sqlite.org/lang_createtable.html).
    ///
    /// A view whose body names a table or column that no longer exists is
    /// left out too: `DROP TABLE` keeps the views that select from it, and
    /// their `PRAGMA table_info` then fails to prepare with "no such table",
    /// SQLite's generic `SQLITE_ERROR` (checked with the sqlite3 3.51.0 shell;
    /// https://www.sqlite.org/rescode.html#error). Failing the whole read
    /// instead would fail every pass at the chunk that holds the view. Any
    /// other failure, such as a lock, a closed connection or a cancel, still
    /// fails the read.
    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        var details: [TableDetail] = []
        details.reserveCapacity(refs.count)
        for ref in refs {
            try Task.checkCancellation()
            let detail: TableDetail
            do {
                detail = try await tableDetail(ref)
            } catch DriverError.queryFailed(_, let code) where code == SQLITE_ERROR {
                continue
            }
            if !detail.columns.isEmpty { details.append(detail) }
        }
        return details
    }

    /// The columns of `table`'s primary key in key order. `PRAGMA table_info`
    /// reports each column's 1-based position in the primary key, and 0 for a
    /// column outside it (https://www.sqlite.org/pragma.html#pragma_table_info).
    private func primaryKeyColumns(of table: String) async throws -> [String] {
        let rows = try await connection.queryAll("PRAGMA table_info(\(dialect.quoteIdentifier(table)))")
        return rows
            .compactMap { row -> (position: Int64, name: String)? in
                guard case .text(let name) = row[1], case .int(let position) = row[5], position > 0 else { return nil }
                return (position, name)
            }
            .sorted { $0.position < $1.position }
            .map(\.name)
    }

    /// `name` with its ASCII capitals lowered and every other byte kept, the
    /// folding SQLite applies when it resolves a table name.
    private static func asciiFolded(_ name: String) -> String {
        String(decoding: name.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }
}
