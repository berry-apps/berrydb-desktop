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

        let viewNames = objects.filter { $0.kind == .view }.map(\.name)
        var resolvedViewColumns: [String: String] = [:]
        if !viewNames.isEmpty {
            let viewQueries: [(sql: String, binds: [SQLParameter])] = viewNames.map { viewName in
                (sql: "PRAGMA table_info(\(dialect.quoteIdentifier(viewName)))", binds: [])
            }
            let viewResults = try await connection.queryBatchAllowingStepErrors(viewQueries)
            for (idx, viewName) in viewNames.enumerated() {
                guard idx < viewResults.count else { continue }
                switch viewResults[idx] {
                case .success(let colRows):
                    resolvedViewColumns[viewName] = Self.formatResolvedViewColumns(colRows)
                case .failure(let error):
                    if case .queryFailed = error {
                        resolvedViewColumns[viewName] = "unresolved"
                    } else {
                        throw error
                    }
                }
            }
        }

        return objects.map { obj in
            var parts = ddlPartsByTable[obj.name] ?? []
            if obj.kind == .view, let resolved = resolvedViewColumns[obj.name] {
                parts.append(resolved)
            }
            let combined = parts.joined(separator: "\n")
            let hash = combined.isEmpty ? nil : ContentHash.fnv1a64(combined)
            return SchemaObjectSummary(
                ref: TableRef(database: nil, name: obj.name),
                kind: obj.kind,
                fingerprint: hash
            )
        }
    }

    private static func formatResolvedViewColumns(_ rows: [[BerryValue]]) -> String {
        rows.map { $0.map { $0.displayString.map { "=" + $0 } ?? "" }.joined(separator: ":") }.joined(separator: ",")
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

        let columns = Self.parseColumnRows(colRows)
        let parsedIndexes = Self.parseIndexListRows(indexListRows)
        let parsedFKs = Self.parseForeignKeyRows(fkRows)

        let (indexColsByName, parentPKs, listedNames) = try await fetchFollowUpMetadata(
            indexNames: parsedIndexes.map(\.name),
            parsedFKs: parsedFKs
        )

        let indexes = parsedIndexes.map { item in
            IndexInfo(name: item.name, isUnique: item.isUnique, columns: indexColsByName[item.name] ?? [])
        }
        let foreignKeys = Self.assembleForeignKeys(
            parsedFKs: parsedFKs,
            parentPKs: parentPKs,
            listedNames: listedNames
        )

        return TableDetail(
            ref: table,
            columns: columns,
            indexes: indexes,
            foreignKeys: foreignKeys
        )
    }

    func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        guard !refs.isEmpty else { return [] }
        try Task.checkCancellation()

        var baseQueries: [(sql: String, binds: [SQLParameter])] = []
        baseQueries.reserveCapacity(refs.count * 3)
        for ref in refs {
            let quoted = dialect.quoteIdentifier(ref.name)
            baseQueries.append((sql: "PRAGMA table_info(\(quoted))", binds: []))
            baseQueries.append((sql: "PRAGMA index_list(\(quoted))", binds: []))
            baseQueries.append((sql: "PRAGMA foreign_key_list(\(quoted))", binds: []))
        }

        let baseResults = try await connection.queryBatchAllowingStepErrors(baseQueries)

        struct ParsedTableEntry {
            let ref: TableRef
            let columns: [ColumnInfo]
            let parsedIndexes: [(name: String, isUnique: Bool)]
            let parsedFKs: [(id: Int64, seq: Int64, table: String, from: String, to: String?)]
        }

        var surviving: [ParsedTableEntry] = []
        surviving.reserveCapacity(refs.count)
        var allIndexNames: [String] = []
        var seenIndexNames: Set<String> = []
        var allParsedFKs: [(id: Int64, seq: Int64, table: String, from: String, to: String?)] = []

        for (index, ref) in refs.enumerated() {
            try Task.checkCancellation()
            let baseOffset = index * 3
            guard baseOffset < baseResults.count else { continue }
            let colRows: [[BerryValue]]
            switch baseResults[baseOffset] {
            case .success(let rows):
                colRows = rows
            case .failure(let error):
                if case .queryFailed = error {
                    continue
                }
                throw error
            }
            let columns = Self.parseColumnRows(colRows)
            guard !columns.isEmpty else { continue }

            let indexListRows: [[BerryValue]]
            if baseOffset + 1 < baseResults.count {
                switch baseResults[baseOffset + 1] {
                case .success(let rows): indexListRows = rows
                case .failure(let error):
                    if case .queryFailed = error { indexListRows = [] } else { throw error }
                }
            } else {
                indexListRows = []
            }

            let fkRows: [[BerryValue]]
            if baseOffset + 2 < baseResults.count {
                switch baseResults[baseOffset + 2] {
                case .success(let rows): fkRows = rows
                case .failure(let error):
                    if case .queryFailed = error { fkRows = [] } else { throw error }
                }
            } else {
                fkRows = []
            }

            let parsedIndexes = Self.parseIndexListRows(indexListRows)
            for idxItem in parsedIndexes where seenIndexNames.insert(idxItem.name).inserted {
                allIndexNames.append(idxItem.name)
            }
            let parsedFKs = Self.parseForeignKeyRows(fkRows)
            allParsedFKs.append(contentsOf: parsedFKs)
            surviving.append(ParsedTableEntry(
                ref: ref,
                columns: columns,
                parsedIndexes: parsedIndexes,
                parsedFKs: parsedFKs
            ))
        }

        guard !surviving.isEmpty else { return [] }

        let (indexColsByName, parentPKs, listedNames) = try await fetchFollowUpMetadata(
            indexNames: allIndexNames,
            parsedFKs: allParsedFKs
        )

        return surviving.map { entry in
            let indexes = entry.parsedIndexes.map { item in
                IndexInfo(name: item.name, isUnique: item.isUnique, columns: indexColsByName[item.name] ?? [])
            }
            let foreignKeys = Self.assembleForeignKeys(
                parsedFKs: entry.parsedFKs,
                parentPKs: parentPKs,
                listedNames: listedNames
            )
            return TableDetail(
                ref: entry.ref,
                columns: entry.columns,
                indexes: indexes,
                foreignKeys: foreignKeys
            )
        }
    }

    private func fetchFollowUpMetadata(
        indexNames: [String],
        parsedFKs: [(id: Int64, seq: Int64, table: String, from: String, to: String?)]
    ) async throws -> (
        indexColsByName: [String: [String]],
        parentPKs: [String: [String]],
        listedNames: [String: String]
    ) {
        var parentsNeedingPK: [String: String] = [:]
        for pair in parsedFKs where pair.to == nil {
            let folded = Self.asciiFolded(pair.table)
            if parentsNeedingPK[folded] == nil {
                parentsNeedingPK[folded] = pair.table
            }
        }
        let sortedParentKeys = parentsNeedingPK.sorted { $0.key < $1.key }

        var followUpQueries: [(sql: String, binds: [SQLParameter])] = indexNames.map { indexName in
            (sql: "PRAGMA index_info(\(dialect.quoteIdentifier(indexName)))", binds: [])
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

        let followUpResults = followUpQueries.isEmpty
            ? []
            : try await connection.queryBatchAllowingStepErrors(followUpQueries)

        var indexColsByName: [String: [String]] = [:]
        indexColsByName.reserveCapacity(indexNames.count)
        for (idx, indexName) in indexNames.enumerated() {
            let infoRows = (followUpResults.indices.contains(idx) ? (try? followUpResults[idx].get()) : nil) ?? []
            indexColsByName[indexName] = infoRows.compactMap { $0.count >= 3 ? $0[2].textValue : nil }
        }

        var parentPKs: [String: [String]] = [:]
        for (offset, entry) in sortedParentKeys.enumerated() {
            let resultIdx = indexNames.count + offset
            let rows = (followUpResults.indices.contains(resultIdx) ? (try? followUpResults[resultIdx].get()) : nil) ?? []
            parentPKs[entry.key] = Self.extractPrimaryKeyColumns(from: rows)
        }

        var listedNames: [String: String] = [:]
        if hasImplicitFKs {
            let namesIdx = indexNames.count + sortedParentKeys.count
            let nameRows = (followUpResults.indices.contains(namesIdx) ? (try? followUpResults[namesIdx].get()) : nil) ?? []
            listedNames = Dictionary(
                nameRows.compactMap { $0.first?.textValue }.map { (Self.asciiFolded($0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        return (indexColsByName, parentPKs, listedNames)
    }

    private static func parseColumnRows(_ rows: [[BerryValue]]) -> [ColumnInfo] {
        rows.compactMap { row in
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
    }

    private static func parseIndexListRows(_ rows: [[BerryValue]]) -> [(name: String, isUnique: Bool)] {
        rows.compactMap { row in
            // PRAGMA index_list: seq(0), name(1), unique(2), origin(3), partial(4)
            guard row.count >= 3, let indexName = row[1].textValue else { return nil }
            let isUnique = (row[2].numericValue ?? 0) != 0
            return (name: indexName, isUnique: isUnique)
        }
    }

    private static func assembleForeignKeys(
        parsedFKs: [(id: Int64, seq: Int64, table: String, from: String, to: String?)],
        parentPKs: [String: [String]],
        listedNames: [String: String]
    ) -> [ForeignKeyInfo] {
        parsedFKs.compactMap { pair in
            let referenced: String?
            if let explicit = pair.to {
                referenced = explicit
            } else if let pkCols = parentPKs[asciiFolded(pair.table)],
                      pkCols.indices.contains(Int(pair.seq)) {
                referenced = pkCols[Int(pair.seq)]
            } else {
                referenced = nil
            }
            guard let referenced else { return nil }
            let targetName = listedNames[asciiFolded(pair.table)] ?? pair.table
            return ForeignKeyInfo(
                column: pair.from,
                referencedSchema: nil,
                referencedTable: targetName,
                referencedColumn: referenced
            )
        }
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
