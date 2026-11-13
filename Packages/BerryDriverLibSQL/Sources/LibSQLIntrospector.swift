import BerryDriverKit
import Foundation

struct LibSQLIntrospector: Introspector {
    private let connection: LibSQLConnection
    private let dialect = LibSQLDialect()

    init(connection: LibSQLConnection) {
        self.connection = connection
    }

    func databases() async throws -> [DatabaseInfo] {
        // libSQL uses a single database namespace per URL/endpoint, matching SQLite.
        []
    }

    func objects(in database: String?) async throws -> [SchemaObject] {
        let rows = try await connection.queryAll(
            """
            SELECT type, name FROM sqlite_master
            WHERE type IN ('table', 'view', 'trigger', 'index')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        )
        return rows.compactMap { row in
            guard row.count >= 2,
                  let typeStr = row[0].textValue,
                  let name = row[1].textValue,
                  let kind = SchemaObjectKind(rawValue: typeStr)
            else { return nil }
            return SchemaObject(kind: kind, name: name, database: nil)
        }
    }

    func schemaVersionToken(scope: SchemaScope) async throws -> String? {
        let rows = try await connection.queryAll("PRAGMA schema_version")
        guard let first = rows.first?.first else { return nil }
        return first.displayString
    }

    func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        let rows = try await connection.queryAll(
            """
            SELECT type, name, tbl_name, sql FROM sqlite_master
            WHERE type IN ('table', 'view', 'index', 'trigger')
              AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """
        )

        var objects: [(kind: SchemaObjectKind, name: String)] = []
        var ddlPartsByTable: [String: [String]] = [:]

        for row in rows {
            guard row.count >= 4,
                  let type = row[0].textValue,
                  let name = row[1].textValue
            else { continue }
            let tableName = row[2].textValue ?? name
            let sql = row[3].textValue ?? ""
            if type == "table" || type == "view",
               let kind = SchemaObjectKind(rawValue: type) {
                objects.append((kind, name))
            }
            if !sql.isEmpty {
                ddlPartsByTable[tableName, default: []].append(sql)
            }
        }

        return objects.map { obj in
            let combined = (ddlPartsByTable[obj.name] ?? []).joined(separator: "\n")
            let hash = combined.isEmpty ? nil : ContentHash.fnv1a64(combined)
            return SchemaObjectSummary(
                ref: TableRef(database: nil, name: obj.name),
                kind: obj.kind,
                fingerprint: hash
            )
        }
    }

    func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] {
        let tables = try await connection.queryAll(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )

        var relations: [ForeignKeyRelation] = []
        for row in tables {
            guard let tableName = row.first?.textValue else { continue }
            let fkRows = try await connection.queryAll("PRAGMA foreign_key_list(\(dialect.quoteIdentifier(tableName)))")
            for fk in fkRows {
                // PRAGMA foreign_key_list columns: id(0), seq(1), table(2), from(3), to(4), on_update(5), on_delete(6), match(7)
                guard fk.count >= 5,
                      let targetTable = fk[2].textValue,
                      let column = fk[3].textValue,
                      let referencedColumn = fk[4].textValue
                else { continue }
                relations.append(ForeignKeyRelation(
                    source: TableRef(database: nil, name: tableName),
                    column: column,
                    target: TableRef(database: nil, name: targetTable),
                    referencedColumn: referencedColumn,
                    constraintName: nil
                ))
            }
        }
        return relations
    }

    func tableDetail(_ table: TableRef) async throws -> TableDetail {
        let quoted = dialect.quoteIdentifier(table.name)

        let colRows = try await connection.queryAll("PRAGMA table_info(\(quoted))")
        let columns: [ColumnInfo] = colRows.compactMap { row in
            // PRAGMA table_info: cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5)
            guard row.count >= 6, let name = row[1].textValue else { return nil }
            let declaredType = row[2].textValue ?? ""
            let notNull = (row[3].numericValue ?? 0) != 0
            let defaultValue: String? = row[4] == .null ? nil : row[4].displayString
            let isPK = (row[5].numericValue ?? 0) != 0
            return ColumnInfo(
                name: name,
                declaredType: declaredType,
                isNullable: !notNull,
                defaultValue: defaultValue,
                isPrimaryKey: isPK
            )
        }

        let indexListRows = try await connection.queryAll("PRAGMA index_list(\(quoted))")
        var indexes: [IndexInfo] = []
        for row in indexListRows {
            // PRAGMA index_list: seq(0), name(1), unique(2), origin(3), partial(4)
            guard row.count >= 3, let indexName = row[1].textValue else { continue }
            let isUnique = (row[2].numericValue ?? 0) != 0
            let infoRows = try await connection.queryAll("PRAGMA index_info(\(dialect.quoteIdentifier(indexName)))")
            let indexCols = infoRows.compactMap { $0.count >= 3 ? $0[2].textValue : nil }
            indexes.append(IndexInfo(name: indexName, isUnique: isUnique, columns: indexCols))
        }

        let fkRows = try await connection.queryAll("PRAGMA foreign_key_list(\(quoted))")
        let foreignKeys: [ForeignKeyInfo] = fkRows.compactMap { row in
            guard row.count >= 5,
                  let targetTable = row[2].textValue,
                  let fromCol = row[3].textValue,
                  let toCol = row[4].textValue
            else { return nil }
            return ForeignKeyInfo(
                column: fromCol,
                referencedSchema: nil,
                referencedTable: targetTable,
                referencedColumn: toCol
            )
        }

        return TableDetail(
            ref: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    func tableStats(_ table: TableRef) async throws -> TableStats {
        let quoted = dialect.quoteIdentifier(table.name)
        var rowCount: Int64?
        if let rows = try? await connection.queryAll("SELECT COUNT(*) FROM \(quoted)"),
           let first = rows.first?.first {
            if case .int(let n) = first {
                rowCount = n
            } else if let dbl = first.numericValue {
                rowCount = Int64(dbl)
            }
        }
        return TableStats(
            estimatedRowCount: rowCount,
            sizeBytes: nil,
            engine: "libSQL",
            comment: nil
        )
    }

    func ddl(of object: SchemaObject) async throws -> String {
        let rows: [[BerryValue]]
        if object.kind == .table {
            rows = try await connection.queryAll(
                """
                SELECT sql FROM sqlite_master
                WHERE tbl_name = ? AND sql IS NOT NULL
                ORDER BY CASE type
                    WHEN 'table' THEN 0
                    WHEN 'index' THEN 1
                    WHEN 'trigger' THEN 2
                    ELSE 3
                END, name
                """,
                binds: [.text(object.name)]
            )
        } else {
            rows = try await connection.queryAll(
                """
                SELECT sql FROM sqlite_master
                WHERE type = ? AND name = ? AND sql IS NOT NULL
                LIMIT 1
                """,
                binds: [.text(object.kind.rawValue), .text(object.name)]
            )
        }
        let statements = rows.compactMap { $0.first?.textValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return statements.map { $0.hasSuffix(";") ? $0 : "\($0);" }.joined(separator: "\n")
    }
}

private extension BerryValue {
    var textValue: String? {
        switch self {
        case .text(let s): s
        case .null: nil
        default: displayString
        }
    }
}
