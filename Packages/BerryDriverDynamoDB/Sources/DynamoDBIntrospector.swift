import BerryDriverKit
import Foundation

/// Introspection via `ListTables`/`DescribeTable`
/// — DynamoDB has no catalog to query with SQL, so every method here
/// is one or two REST calls instead of a query.
public struct DynamoDBIntrospector: Introspector {
    let client: DynamoDBHTTPClient

    /// DynamoDB has no database/schema concept — table names are global per
 /// region (multipleDatabases == false). A single
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
 /// together every `isPrimaryKey` column, and
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

    /// DynamoDB has a single namespace per region, so `scope` selects nothing.
    /// There is no per-table fingerprint to report: `DescribeTable` returns no
    /// definition version or modification time
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_DescribeTable.html).
    public func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        try await client.listTables().map {
            SchemaObjectSummary(ref: TableRef(name: $0), kind: .table, fingerprint: nil)
        }
    }

    /// DynamoDB has no foreign keys. Stated here rather than inherited,
    /// because the inherited default would describe every table to find them.
    public func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] { [] }

    /// False because nothing here can tell which tables changed: without a
    /// fingerprint every pass describes every table again, one `DescribeTable`
    /// call each. That cost is proportional to the table count, which stays
    /// small for the development accounts this is used with.
    public var bulkIntrospection: Bool { false }

    /// `DescribeTable` is a control-plane operation, and DynamoDB may answer
    /// control-plane calls made too rapidly with `ThrottlingException`
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Programming.Errors.html).
    /// A small window overlaps network latency without bursting.
    private static let maxConcurrentDescribes = 4

    /// Retries after the first attempt. The AWS documentation lists both
    /// throttling errors and `RequestLimitExceeded`, the account-level
    /// throughput limit, as retryable ("OK to retry? Yes") and recommends
    /// growing waits between attempts (same page); three retries, 200 ms
    /// then 400 ms then 600 ms, ride out a short burst and fail the batch if
    /// throttling persists.
    private static let maxThrottleRetries = 3
    private static let throttleBackoffStepNanoseconds: UInt64 = 200_000_000

    /// Describes `refs` with at most `maxConcurrentDescribes` calls in flight,
    /// returning details in the order of `refs`. A table that no longer exists
    /// is left out; any other failure fails the whole batch.
    public func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        try await withThrowingTaskGroup(of: (index: Int, detail: TableDetail?).self) { group in
            var pending = refs.enumerated().makeIterator()
            var inFlight = 0
            var details = [TableDetail?](repeating: nil, count: refs.count)
            while true {
                while inFlight < Self.maxConcurrentDescribes, let (index, ref) = pending.next() {
                    try Task.checkCancellation()
                    group.addTask { (index, try await describeRetryingThrottling(ref)) }
                    inFlight += 1
                }
                guard let finished = try await group.next() else { break }
                inFlight -= 1
                details[finished.index] = finished.detail
            }
            return details.compactMap { $0 }
        }
    }

    /// Nil when the table vanished after it was listed: `DescribeTable` then
    /// answers `ResourceNotFoundException`
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_DescribeTable.html).
    private func describeRetryingThrottling(_ ref: TableRef) async throws -> TableDetail? {
        var retries = 0
        while true {
            do {
                return try await tableDetail(ref)
            } catch {
                // A cancelled URLSession task surfaces as a driver error; the
                // caller asked to stop, so report that instead.
                try Task.checkCancellation()
                if Self.isMissingTable(error) { return nil }
                guard Self.isThrottled(error), retries < Self.maxThrottleRetries else { throw error }
                retries += 1
                // `Task.sleep(nanoseconds:)` rather than the `Clock`-generic
                // overload, which crashes release builds that specialize it in
                // more than one module (swiftlang/swift#86204).
                try await Task.sleep(nanoseconds: Self.throttleBackoffStepNanoseconds * UInt64(retries))
            }
        }
    }

    /// `DynamoDBHTTPClient` renders a service error as
    /// `"<ExceptionType>: <Message>"` with the HTTP status as the code, and as
    /// `"HTTP <status>: ..."` when the body names no exception. DynamoDB
    /// answers the errors handled here with status 400, so the exception name
    /// is the only way to tell them apart
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Programming.Errors.html).
    private static func isMissingTable(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .queryFailed(let message, _) = driverError
        else { return false }
        return message.hasPrefix("ResourceNotFoundException:")
    }

    /// DynamoDB itself reports throttling as status 400 with an exception name:
    /// `ProvisionedThroughputExceededException` and `ThrottlingException` for a
    /// table or the control plane, `RequestLimitExceeded` for the account
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Programming.Errors.html).
    /// Status 429, the standard HTTP rate-limit status, is retried as well
    /// because a proxy in front of the endpoint may answer with it instead.
    private static func isThrottled(_ error: Error) -> Bool {
        guard let driverError = error as? DriverError,
              case .queryFailed(let message, let code) = driverError
        else { return false }
        return code == 429
            || message.hasPrefix("ProvisionedThroughputExceededException:")
            || message.hasPrefix("ThrottlingException:")
            || message.hasPrefix("RequestLimitExceeded:")
    }

    /// Best-effort pseudo-DDL synthesized from `KeySchema`/`AttributeDefinitions`
    /// — DynamoDB has no `SHOW CREATE TABLE`/`pg_get_*def()` equivalent to
    /// read back, so unlike the SQL drivers this is NOT authoritative; the
 /// comment header says so explicitly.
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
        -- and are not listed here.
        CREATE TABLE "\(object.name)" (
        \(lines.joined(separator: ",\n"))
        )
        """
    }

 /// `DescribeTable`'s response already carries `ItemCount` (AWS
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
