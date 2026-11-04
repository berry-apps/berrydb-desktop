import BerryDriverKit
import Foundation

/// A `Query` request body. The dictionary is immutable JSON built once; the
/// wrapper lets it cross isolation boundaries, as `NativeWriteRequest` does.
struct DynamoDBQueryRequestBody: @unchecked Sendable {
    let body: [String: Any]
}

/// Builds `Query` request bodies and reads their pages. Pure and network-free.
/// API reference: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html
enum DynamoDBPartitionQueryRequest {
    /// Every attribute name and value goes through a placeholder, so no caller
    /// text reaches an expression: `#k0` partition key, `#k1` sort key, `#p0…`
    /// projection names, `:v0…` values. Only placeholders an expression uses are
    /// sent, because DynamoDB rejects unused ones (verified against
    /// dynamodb-local 3.3.0). Condition grammar:
    /// https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.KeyConditionExpressions.html
    ///
    /// Key mismatches are refused here, before any request, so the caller gets a
    /// plain message instead of a service ValidationException.
    static func body(for query: DynamoDBPartitionQuery, schema: DynamoDBKeySchema) throws -> DynamoDBQueryRequestBody {
        let partitionKey: DynamoDBKeyAttribute
        let sortKey: DynamoDBKeyAttribute?
        if let indexName = query.indexName {
            guard let index = schema.index(named: indexName) else {
                throw DriverError.unsupported("Index \(indexName) does not exist on table \(query.table)")
            }
            partitionKey = index.partitionKey
            sortKey = index.sortKey
        } else {
            partitionKey = schema.partitionKey
            sortKey = schema.sortKey
        }

        try check(query.partitionKey, against: partitionKey)
        var names = ["#k0": partitionKey.name]
        var values = [":v0": query.partitionKey.attributeValue.json]
        var condition = "#k0 = :v0"

        if let sort = query.sortKey {
            guard let sortKey else {
                throw DriverError.unsupported("Table \(query.table) has no sort key")
            }
            names["#k1"] = sortKey.name
            let operands: [DynamoDBKeyValue]
            switch sort {
            case .equal(let value): operands = [value]; condition += " AND #k1 = :v1"
            case .lessThan(let value): operands = [value]; condition += " AND #k1 < :v1"
            case .lessThanOrEqual(let value): operands = [value]; condition += " AND #k1 <= :v1"
            case .greaterThan(let value): operands = [value]; condition += " AND #k1 > :v1"
            case .greaterThanOrEqual(let value): operands = [value]; condition += " AND #k1 >= :v1"
            case .between(let low, let high): operands = [low, high]; condition += " AND #k1 BETWEEN :v1 AND :v2"
            case .beginsWith(let prefix): operands = [prefix]; condition += " AND begins_with(#k1, :v1)"
            }
            for (offset, operand) in operands.enumerated() {
                try check(operand, against: sortKey)
                values[":v\(offset + 1)"] = operand.attributeValue.json
            }
        }

        var body: [String: Any] = [
            "TableName": query.table,
            "KeyConditionExpression": condition,
            "ExpressionAttributeValues": values,
            "Limit": query.limit,
            "ScanIndexForward": true,
            "ReturnConsumedCapacity": "TOTAL",
        ]
        if let indexName = query.indexName { body["IndexName"] = indexName }

        if let projection = query.projection {
            // Key attributes come first so a caller can always build the next
            // page's ExclusiveStartKey from the returned items.
            var projected: [String] = []
            for name in schema.keyAttributeNames(index: query.indexName) + projection where !projected.contains(name) {
                projected.append(name)
            }
            for (offset, name) in projected.enumerated() { names["#p\(offset)"] = name }
            body["ProjectionExpression"] = projected.indices.map { "#p\($0)" }.joined(separator: ", ")
        }
        body["ExpressionAttributeNames"] = names

        if let start = query.exclusiveStartKey {
            body["ExclusiveStartKey"] = start.mapValues(\.json)
        }
        return DynamoDBQueryRequestBody(body: body)
    }

    private static func check(_ value: DynamoDBKeyValue, against attribute: DynamoDBKeyAttribute) throws {
        guard value.type == attribute.type else {
            throw DriverError.unsupported(
                "Key attribute \(attribute.name) is \(attribute.type.rawValue), the value given is \(value.type.rawValue)"
            )
        }
    }

    /// Reads the key schema from a `DescribeTable` `Table` object, keeping the
    /// `HASH`/`RANGE` roles and `S`/`N`/`B` types that the introspector's column
    /// list drops:
    /// https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_DescribeTable.html
    static func keySchema(describedTable table: [String: Any], name: String) throws -> DynamoDBKeySchema {
        let definitions = (table["AttributeDefinitions"] as? [[String: Any]] ?? []).reduce(into: [String: DynamoDBKeyType]()) {
            if let attribute = $1["AttributeName"] as? String, let raw = $1["AttributeType"] as? String,
               let type = DynamoDBKeyType(rawValue: raw) {
                $0[attribute] = type
            }
        }
        func keys(_ entries: Any?) -> (partition: DynamoDBKeyAttribute?, sort: DynamoDBKeyAttribute?) {
            var partition: DynamoDBKeyAttribute?
            var sort: DynamoDBKeyAttribute?
            for entry in entries as? [[String: Any]] ?? [] {
                guard let attribute = entry["AttributeName"] as? String, let type = definitions[attribute] else { continue }
                switch entry["KeyType"] as? String {
                case "HASH": partition = DynamoDBKeyAttribute(name: attribute, type: type)
                case "RANGE": sort = DynamoDBKeyAttribute(name: attribute, type: type)
                default: break
                }
            }
            return (partition, sort)
        }

        guard let partitionKey = keys(table["KeySchema"]).partition else {
            throw DriverError.queryFailed(message: "DescribeTable returned no HASH key for \(name)", code: nil)
        }
        var indexes: [DynamoDBIndexKeySchema] = []
        for list in ["GlobalSecondaryIndexes", "LocalSecondaryIndexes"] {
            for index in table[list] as? [[String: Any]] ?? [] {
                guard let indexName = index["IndexName"] as? String, let partition = keys(index["KeySchema"]).partition else {
                    continue
                }
                indexes.append(DynamoDBIndexKeySchema(
                    name: indexName, partitionKey: partition, sortKey: keys(index["KeySchema"]).sort
                ))
            }
        }
        return DynamoDBKeySchema(
            table: name, partitionKey: partitionKey, sortKey: keys(table["KeySchema"]).sort, indexes: indexes
        )
    }

    /// Reads one `Query` response. `ScannedCount` and `CapacityUnits` are
    /// optional in the response, so a missing count reads as 0 and missing
    /// capacity as nil rather than failing the page.
    static func page(json: [String: Any]) throws -> DynamoDBQueryPage {
        func attributes(_ raw: Any) throws -> [String: DynamoDBAttributeValue] {
            guard let map = raw as? [String: Any] else {
                throw DriverError.queryFailed(message: "Query returned a malformed item", code: nil)
            }
            return try map.mapValues { try DynamoDBAttributeValue(json: $0) }
        }
        let items = try (json["Items"] as? [Any] ?? []).map(attributes)
        let last = try json["LastEvaluatedKey"].map(attributes)
        let capacity = (json["ConsumedCapacity"] as? [String: Any])?["CapacityUnits"] as? Double
        return DynamoDBQueryPage(
            items: items, lastEvaluatedKey: last, consumedCapacityUnits: capacity,
            scannedCount: json["ScannedCount"] as? Int ?? 0
        )
    }
}
