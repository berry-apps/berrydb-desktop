import BerryDriverKit
import Foundation

/// Introspection via `ListTables`/`DescribeTable` (docs/architecture/05 §5,
/// 12 §4) — DynamoDB has no catalog to query with SQL, so every method here
/// is one or two REST calls instead of a query.
public struct DynamoDBIntrospector: Introspector {
    let client: DynamoDBHTTPClient

    /// DynamoDB has no database/schema concept — table names are global per
    /// region (multipleDatabases == false, docs/architecture/05 §4). A single
    /// synthetic entry follows the exact precedent SQLite already set for the
    /// same capability flag (`SQLiteIntrospector.databases() → [DatabaseInfo(name: "main")]`)
    /// rather than an empty list — `objects(in:)` below ignores whatever
    /// name is passed back in anyway, so this only exists to give the
    /// sidebar one root node to expand.
    public func databases() async throws -> [DatabaseInfo] {
        [DatabaseInfo(name: "default")]
    }

    public func objects(in database: String?) async throws -> [SchemaObject] {
        try await client.listTables().map { SchemaObject(kind: .table, name: $0, database: nil) }
    }

    /// Only key attributes get a `ColumnInfo` — DynamoDB only declares types
    /// for partition/sort key attributes (`AttributeDefinitions`); every
    /// other attribute is per-item schema-flexible, so there is nothing to
    /// declare. BOTH the partition key and the (optional) sort key are
    /// marked `isPrimaryKey: true` — ChangeSet's generated WHERE clause ANDs
    /// together every `isPrimaryKey` column (docs/architecture/06 · L3), and
    /// DynamoDB's own PartiQL UPDATE/DELETE require WHERE to equate the FULL
    /// primary key (verified against dynamodb-local: a partition-key-only
    /// WHERE on a table with a sort key fails with "Where clause does not
    /// contain a mandatory equality on all key attributes") — so this is
    /// what makes ChangeSet-generated UPDATE/DELETE work at all, with no
    /// change to ChangeSet itself.
    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        let table = try await client.describeTable(name: ref.name)
        let keySchema = (table["KeySchema"] as? [[String: Any]]) ?? []
        let typeByName = Self.attributeTypes(table)

        let columns: [ColumnInfo] = keySchema.compactMap { entry in
            guard let name = entry["AttributeName"] as? String else { return nil }
            return ColumnInfo(
                name: name,
                declaredType: Self.friendlyType(typeByName[name] ?? ""),
                isNullable: false,
                defaultValue: nil,
                isPrimaryKey: true
            )
        }

        let indexes =
            ((table["GlobalSecondaryIndexes"] as? [[String: Any]]) ?? []).map(Self.indexInfo)
            + ((table["LocalSecondaryIndexes"] as? [[String: Any]]) ?? []).map(Self.indexInfo)

        return TableDetail(ref: ref, columns: columns, indexes: indexes, foreignKeys: [])
    }

    /// Best-effort pseudo-DDL synthesized from `KeySchema`/`AttributeDefinitions`
    /// — DynamoDB has no `SHOW CREATE TABLE`/`pg_get_*def()` equivalent to
    /// read back, so unlike the SQL drivers this is NOT authoritative; the
    /// comment header says so explicitly (TR-03, docs/architecture/12 §4).
    public func ddl(of object: SchemaObject) async throws -> String {
        let table = try await client.describeTable(name: object.name)
        let keySchema = (table["KeySchema"] as? [[String: Any]]) ?? []
        let typeByName = Self.attributeTypes(table)

        let lines = keySchema.compactMap { entry -> String? in
            guard let name = entry["AttributeName"] as? String,
                  let keyType = entry["KeyType"] as? String else { return nil }
            let role = keyType == "HASH" ? "PARTITION KEY" : "SORT KEY"
            return "    \"\(name)\" \(Self.friendlyType(typeByName[name] ?? "")) \(role)"
        }
        return """
        -- Synthesized from KeySchema/AttributeDefinitions — best-effort, NOT authoritative.
        -- DynamoDB has no DDL to read back; non-key attributes are per-item schema-flexible
        -- and are not listed here (docs/architecture/12 §4).
        CREATE TABLE "\(object.name)" (
        \(lines.joined(separator: ",\n"))
        )
        """
    }

    /// TR-04: `DescribeTable`'s response already carries `ItemCount` (AWS
    /// updates this ~every 6 hours, not realtime — a coarser estimate than
    /// Postgres/MySQL's catalog stats, but it's what the API exposes with no
    /// extra call) and `TableSizeBytes`. No storage-engine concept; DynamoDB
    /// tables have no comment field either.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        let table = try await client.describeTable(name: ref.name)
        return TableStats(
            estimatedRowCount: (table["ItemCount"] as? NSNumber)?.int64Value,
            sizeBytes: (table["TableSizeBytes"] as? NSNumber)?.int64Value,
            engine: nil,
            comment: nil
        )
    }

    private static func attributeTypes(_ table: [String: Any]) -> [String: String] {
        let attributeDefs = (table["AttributeDefinitions"] as? [[String: Any]]) ?? []
        return Dictionary(uniqueKeysWithValues: attributeDefs.compactMap { def -> (String, String)? in
            guard let name = def["AttributeName"] as? String, let type = def["AttributeType"] as? String else {
                return nil
            }
            return (name, type)
        })
    }

    private static func friendlyType(_ dynamoType: String) -> String {
        switch dynamoType {
        case "S": return "String (S)"
        case "N": return "Number (N)"
        case "B": return "Binary (B)"
        default: return dynamoType
        }
    }

    /// GSIs/LSIs surface as `IndexInfo` — best-effort, key-schema only (a
    /// DynamoDB index has no SQL-style "indexed columns beyond its key
    /// schema" concept). `isUnique` is always false: DynamoDB indexes don't
    /// enforce uniqueness the way a SQL unique index does — there is no
    /// equivalent flag to read.
    private static func indexInfo(from entry: [String: Any]) -> IndexInfo {
        let name = (entry["IndexName"] as? String) ?? "?"
        let columns = ((entry["KeySchema"] as? [[String: Any]]) ?? []).compactMap { $0["AttributeName"] as? String }
        return IndexInfo(name: name, isUnique: false, columns: columns)
    }
}
