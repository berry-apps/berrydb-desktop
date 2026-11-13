import BerryDriverKit
import Foundation

struct LibSQLIntrospector: Introspector {
    private let connection: LibSQLConnection
    private let dialect = SQLiteDialect()

    var bulkIntrospection: Bool { true }

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
        let tableRows = try await connection.queryAll(
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
        let tableNames = tableRows.compactMap { $0.first?.textValue }
        guard !tableNames.isEmpty else { return [] }

        let listedNames = Dictionary(
            tableNames.map { (Self.asciiFolded($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let fkQueries: [(sql: String, binds: [SQLParameter])] = tableNames.map { tableName in
            (sql: "PRAGMA foreign_key_list(\(dialect.quoteIdentifier(tableName)))", binds: [])
        }
        let fkResults = try await connection.queryBatch(fkQueries)

        var parsedPairs: [(source: String, id: Int64, seq: Int64, table: String, from: String, to: String?)] = []
        var parentsNeedingPK: [String: String] = [:]

        for (index, tableName) in tableNames.enumerated() {
            guard index < fkResults.count else { continue }
            let tablePairs = Self.parseForeignKeyRows(fkResults[index])
            for pair in tablePairs {
                parsedPairs.append((
                    source: tableName,
                    id: pair.id,
                    seq: pair.seq,
                    table: pair.table,
                    from: pair.from,
                    to: pair.to
                ))
                if pair.to == nil {
                    let folded = Self.asciiFolded(pair.table)
                    if parentsNeedingPK[folded] == nil {
                        parentsNeedingPK[folded] = listedNames[folded] ?? pair.table
                    }
                }
            }
        }

        let parentPKs = try await fetchPrimaryKeyColumns(for: parentsNeedingPK)

        var relations: [ForeignKeyRelation] = []
        relations.reserveCapacity(parsedPairs.count)
        for pair in parsedPairs {
            let referenced: String?
            if let explicit = pair.to {
                referenced = explicit
            } else if let pkCols = parentPKs[Self.asciiFolded(pair.table)],
                      pkCols.indices.contains(Int(pair.seq)) {
                referenced = pkCols[Int(pair.seq)]
            } else {
                referenced = nil
            }
            guard let referenced else { continue }
            let targetName = listedNames[Self.asciiFolded(pair.table)] ?? pair.table
            relations.append(ForeignKeyRelation(
                source: TableRef(database: nil, name: pair.source),
                column: pair.from,
                target: TableRef(database: nil, name: targetName),
                referencedColumn: referenced,
                constraintName: nil
            ))
        }
        return relations
    }

    func tableDetail(_ table: TableRef) async throws -> TableDetail {
        let quoted = dialect.quoteIdentifier(table.name)

        let baseResults = try await connection.queryBatch([
            (sql: "PRAGMA table_info(\(quoted))", binds: []),
            (sql: "PRAGMA index_list(\(quoted))", binds: []),
            (sql: "PRAGMA foreign_key_list(\(quoted))", binds: []),
        ])
        let colRows = baseResults.indices.contains(0) ? baseResults[0] : []
        let indexListRows = baseResults.indices.contains(1) ? baseResults[1] : []
        let fkRows = baseResults.indices.contains(2) ? baseResults[2] : []

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

        let parsedIndexes: [(name: String, isUnique: Bool)] = indexListRows.compactMap { row in
            // PRAGMA index_list: seq(0), name(1), unique(2), origin(3), partial(4)
            guard row.count >= 3, let indexName = row[1].textValue else { return nil }
            let isUnique = (row[2].numericValue ?? 0) != 0
            return (name: indexName, isUnique: isUnique)
        }

        let parsedFKs = Self.parseForeignKeyRows(fkRows)
        var parentsNeedingPK: [String: String] = [:]
        for pair in parsedFKs where pair.to == nil {
            let folded = Self.asciiFolded(pair.table)
            if parentsNeedingPK[folded] == nil {
                parentsNeedingPK[folded] = pair.table
            }
        }
        let sortedParentKeys = parentsNeedingPK.sorted { $0.key < $1.key }

        var followUpQueries: [(sql: String, binds: [SQLParameter])] = parsedIndexes.map { item in
            (sql: "PRAGMA index_info(\(dialect.quoteIdentifier(item.name)))", binds: [])
        }
        for (_, parentTable) in sortedParentKeys {
            followUpQueries.append((
                sql: "PRAGMA table_info(\(dialect.quoteIdentifier(parentTable)))",
                binds: []
            ))
        }
        let hasImplicitFKs = !sortedParentKeys.isEmpty
        if hasImplicitFKs {
            followUpQueries.append((
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
                binds: []
            ))
        }

        let followUpResults = followUpQueries.isEmpty ? [] : try await connection.queryBatch(followUpQueries)

        var indexes: [IndexInfo] = []
        indexes.reserveCapacity(parsedIndexes.count)
        for (idx, item) in parsedIndexes.enumerated() {
            let infoRows = followUpResults.indices.contains(idx) ? followUpResults[idx] : []
            let indexCols = infoRows.compactMap { $0.count >= 3 ? $0[2].textValue : nil }
            indexes.append(IndexInfo(name: item.name, isUnique: item.isUnique, columns: indexCols))
        }

        var parentPKs: [String: [String]] = [:]
        for (offset, entry) in sortedParentKeys.enumerated() {
            let resultIdx = parsedIndexes.count + offset
            let rows = followUpResults.indices.contains(resultIdx) ? followUpResults[resultIdx] : []
            parentPKs[entry.key] = Self.extractPrimaryKeyColumns(from: rows)
        }

        var listedNames: [String: String] = [:]
        if hasImplicitFKs {
            let namesIdx = parsedIndexes.count + sortedParentKeys.count
            let nameRows = followUpResults.indices.contains(namesIdx) ? followUpResults[namesIdx] : []
            listedNames = Dictionary(
                nameRows.compactMap { $0.first?.textValue }.map { (Self.asciiFolded($0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        let foreignKeys: [ForeignKeyInfo] = parsedFKs.compactMap { pair in
            let referenced: String?
            if let explicit = pair.to {
                referenced = explicit
            } else if let pkCols = parentPKs[Self.asciiFolded(pair.table)],
                      pkCols.indices.contains(Int(pair.seq)) {
                referenced = pkCols[Int(pair.seq)]
            } else {
                referenced = nil
            }
            guard let referenced else { return nil }
            let targetName = listedNames[Self.asciiFolded(pair.table)] ?? pair.table
            return ForeignKeyInfo(
                column: pair.from,
                referencedSchema: nil,
                referencedTable: targetName,
                referencedColumn: referenced
            )
        }

        return TableDetail(
            ref: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    private func fetchPrimaryKeyColumns(for parentsByFoldedName: [String: String]) async throws -> [String: [String]] {
        guard !parentsByFoldedName.isEmpty else { return [:] }
        let ordered = parentsByFoldedName.sorted { $0.key < $1.key }
        let queries: [(sql: String, binds: [SQLParameter])] = ordered.map { _, tableName in
            (sql: "PRAGMA table_info(\(dialect.quoteIdentifier(tableName)))", binds: [])
        }
        let results = try await connection.queryBatch(queries)
        var output: [String: [String]] = [:]
        for (idx, entry) in ordered.enumerated() {
            let rows = results.indices.contains(idx) ? results[idx] : []
            output[entry.key] = Self.extractPrimaryKeyColumns(from: rows)
        }
        return output
    }

    private static func parseForeignKeyRows(
        _ rows: [[BerryValue]]
    ) -> [(id: Int64, seq: Int64, table: String, from: String, to: String?)] {
        rows.compactMap { row -> (id: Int64, seq: Int64, table: String, from: String, to: String?)? in
            // PRAGMA foreign_key_list: id(0), seq(1), table(2), from(3), to(4), on_update(5), on_delete(6), match(7)
            guard row.count >= 5,
                  let id = int64Value(row[0]),
                  let seq = int64Value(row[1]),
                  let targetTable = row[2].textValue,
                  let fromCol = row[3].textValue
            else { return nil }
            let toCol = row[4].textValue
            return (id: id, seq: seq, table: targetTable, from: fromCol, to: toCol)
        }
        .sorted { ($0.id, $0.seq) < ($1.id, $1.seq) }
    }

    private static func extractPrimaryKeyColumns(from rows: [[BerryValue]]) -> [String] {
        rows.compactMap { row -> (position: Int64, name: String)? in
            guard row.count >= 6,
                  let name = row[1].textValue,
                  let position = int64Value(row[5]),
                  position > 0
            else { return nil }
            return (position: position, name: name)
        }
        .sorted { $0.position < $1.position }
        .map(\.name)
    }

    private static func int64Value(_ value: BerryValue) -> Int64? {
        switch value {
        case .int(let n): n
        case .double(let d): Int64(d)
        case .text(let s): Int64(s)
        default: nil
        }
    }

    private static func asciiFolded(_ name: String) -> String {
        String(decoding: name.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
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
