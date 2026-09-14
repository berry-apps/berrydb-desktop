import BerryDriverKit
import Foundation

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
}
