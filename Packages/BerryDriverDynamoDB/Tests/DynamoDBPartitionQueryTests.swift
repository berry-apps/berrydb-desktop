import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDB query request")
struct DynamoDBPartitionQueryTests {
    static var describedOrders: [String: Any] { [
        "TableName": "orders",
        "KeySchema": [
            ["AttributeName": "pk", "KeyType": "HASH"],
            ["AttributeName": "sk", "KeyType": "RANGE"],
        ],
        "AttributeDefinitions": [
            ["AttributeName": "pk", "AttributeType": "S"],
            ["AttributeName": "sk", "AttributeType": "S"],
            ["AttributeName": "status", "AttributeType": "S"],
        ],
        "GlobalSecondaryIndexes": [
            [
                "IndexName": "by_status",
                "KeySchema": [
                    ["AttributeName": "status", "KeyType": "HASH"],
                    ["AttributeName": "sk", "KeyType": "RANGE"],
                ],
            ]
        ],
    ] }

    let schema: DynamoDBKeySchema

    init() throws {
        schema = try DynamoDBPartitionQueryRequest.keySchema(describedTable: Self.describedOrders, name: "orders")
    }

    private func query(
        index: String? = nil, partition: DynamoDBKeyValue = .string("a"),
        sort: DynamoDBSortKeyCondition? = nil
    ) -> DynamoDBPartitionQuery {
        DynamoDBPartitionQuery(
            table: "orders", indexName: index, partitionKey: partition, sortKey: sort,
            projection: nil, limit: 10, exclusiveStartKey: nil
        )
    }

    @Test func keySchemaReadsRolesTypesAndIndexes() throws {
        let schema = try DynamoDBPartitionQueryRequest.keySchema(describedTable: Self.describedOrders, name: "orders")
        #expect(schema.partitionKey == .init(name: "pk", type: .string))
        #expect(schema.sortKey == .init(name: "sk", type: .string))
        #expect(schema.indexes == [.init(name: "by_status", partitionKey: .init(name: "status", type: .string), sortKey: .init(name: "sk", type: .string))])
    }

    @Test func bodyBindsEveryNameAndValueThroughPlaceholders() throws {
        let query = DynamoDBPartitionQuery(
            table: "orders", indexName: nil, partitionKey: .string("Status"),
            sortKey: .between(.string("2026-01"), .string("2026-02")), projection: nil, limit: 50, exclusiveStartKey: nil
        )
        let body = try DynamoDBPartitionQueryRequest.body(for: query, schema: schema).body
        #expect(body["KeyConditionExpression"] as? String == "#k0 = :v0 AND #k1 BETWEEN :v1 AND :v2")
        #expect(body["ExpressionAttributeNames"] as? [String: String] == ["#k0": "pk", "#k1": "sk"])
        let values = body["ExpressionAttributeValues"] as? [String: [String: String]]
        #expect(values == [":v0": ["S": "Status"], ":v1": ["S": "2026-01"], ":v2": ["S": "2026-02"]])
        #expect(body["Limit"] as? Int == 50)
        #expect(body["ScanIndexForward"] as? Bool == true)
        #expect(body["ReturnConsumedCapacity"] as? String == "TOTAL")
        #expect(body["ProjectionExpression"] == nil)
        #expect(body["Select"] == nil)
    }

    @Test func projectionAlwaysCarriesTheTableAndIndexKeys() throws {
        let query = DynamoDBPartitionQuery(
            table: "orders", indexName: "by_status", partitionKey: .string("paid"),
            sortKey: .beginsWith(.string("2026")), projection: ["total", "sk"], limit: 10, exclusiveStartKey: nil
        )
        let body = try DynamoDBPartitionQueryRequest.body(for: query, schema: schema).body
        #expect(body["IndexName"] as? String == "by_status")
        #expect(body["KeyConditionExpression"] as? String == "#k0 = :v0 AND begins_with(#k1, :v1)")
        #expect(body["ProjectionExpression"] as? String == "#p0, #p1, #p2, #p3")
        #expect(body["ExpressionAttributeNames"] as? [String: String]
            == ["#k0": "status", "#k1": "sk", "#p0": "pk", "#p1": "sk", "#p2": "status", "#p3": "total"])
    }

    @Test func anExclusiveStartKeyIsSentAsGiven() throws {
        let query = DynamoDBPartitionQuery(
            table: "orders", indexName: nil, partitionKey: .string("a"), sortKey: nil, projection: nil,
            limit: 10, exclusiveStartKey: ["pk": .string("a"), "sk": .string("b")]
        )
        let body = try DynamoDBPartitionQueryRequest.body(for: query, schema: schema).body
        #expect(body["ExclusiveStartKey"] as? [String: [String: String]] == ["pk": ["S": "a"], "sk": ["S": "b"]])
        #expect(body["KeyConditionExpression"] as? String == "#k0 = :v0")
        #expect(body["ExpressionAttributeNames"] as? [String: String] == ["#k0": "pk"])
    }

    @Test func mismatchedKeysAreRefusedBeforeAnyRequest() throws {
        func message(_ run: () throws -> Any) -> String? {
            do { _ = try run() } catch DriverError.unsupported(let text) { return text } catch { return "other: \(error)" }
            return nil
        }
        let numeric = DynamoDBKeySchema(
            table: "orders", partitionKey: .init(name: "id", type: .number), sortKey: nil, indexes: []
        )
        #expect(message { try DynamoDBPartitionQueryRequest.body(for: query(), schema: numeric) }
            == "Key attribute id is N, the value given is S")
        #expect(message { try DynamoDBPartitionQueryRequest.body(for: query(partition: .number("1"), sort: .equal(.string("x"))), schema: numeric) }
            == "Table orders has no sort key")
        #expect(message { try DynamoDBPartitionQueryRequest.body(for: query(index: "missing"), schema: schema) }
            == "Index missing does not exist on table orders")
    }

    @Test func pageKeepsNumbersAsTextAndReadsConsumedCapacity() throws {
        let json: [String: Any] = [
            "Items": [["pk": ["S": "a"], "n": ["N": "123456789012345678901234567890123456.78"]]],
            "LastEvaluatedKey": ["pk": ["S": "a"]], "ScannedCount": 1,
            "ConsumedCapacity": ["TableName": "orders", "CapacityUnits": 0.5],
        ]
        let page = try DynamoDBPartitionQueryRequest.page(json: json)
        #expect(page.items == [["pk": .string("a"), "n": .number("123456789012345678901234567890123456.78")]])
        #expect(page.lastEvaluatedKey == ["pk": .string("a")])
        #expect(page.consumedCapacityUnits == 0.5)
        #expect(page.scannedCount == 1)
    }

    @Test func localSecondaryIndexesAreParsedWithTheirOwnSortKey() throws {
        var described = Self.describedOrders
        var definitions = described["AttributeDefinitions"] as? [[String: String]] ?? []
        definitions.append(["AttributeName": "total", "AttributeType": "N"])
        described["AttributeDefinitions"] = definitions
        described["LocalSecondaryIndexes"] = [
            [
                "IndexName": "by_total",
                "KeySchema": [
                    ["AttributeName": "pk", "KeyType": "HASH"],
                    ["AttributeName": "total", "KeyType": "RANGE"],
                ],
            ]
        ]
        let schema = try DynamoDBPartitionQueryRequest.keySchema(describedTable: described, name: "orders")
        #expect(schema.index(named: "by_total")
            == .init(name: "by_total", partitionKey: .init(name: "pk", type: .string), sortKey: .init(name: "total", type: .number)))
        #expect(schema.indexes.count == 2)
    }

    private func described(
        keySchema: [[String: String]]? = nil, definitions: [[String: String]]? = nil,
        indexKeySchema: [[String: String]]? = nil
    ) -> [String: Any] {
        var table = Self.describedOrders
        if let keySchema { table["KeySchema"] = keySchema }
        if let definitions { table["AttributeDefinitions"] = definitions }
        if let indexKeySchema {
            table["GlobalSecondaryIndexes"] = [["IndexName": "by_status", "KeySchema": indexKeySchema]]
        }
        return table
    }

    private func queryFailedMessage(_ table: [String: Any]) -> String? {
        do { _ = try DynamoDBPartitionQueryRequest.keySchema(describedTable: table, name: "orders") } catch DriverError.queryFailed(let message, _) {
            return message
        } catch { return "other: \(error)" }
        return nil
    }

    @Test func aMalformedDescribeTableIsAnErrorNotAMissingKeyOrIndex() {
        let sk = ["AttributeName": "sk", "KeyType": "RANGE"]
        let defs = [["AttributeName": "pk", "AttributeType": "S"], ["AttributeName": "sk", "AttributeType": "S"],
                    ["AttributeName": "status", "AttributeType": "S"]]
        #expect(queryFailedMessage(described(keySchema: [sk])) == "DescribeTable returned no HASH key for orders")
        #expect(queryFailedMessage(described(definitions: [defs[1], defs[2]])) == "DescribeTable returned no HASH key for orders")
        #expect(queryFailedMessage(described(definitions: [defs[0], defs[2]]))
            == "DescribeTable returned no type for key attribute sk of orders")
        #expect(queryFailedMessage(described(indexKeySchema: [sk]))
            == "DescribeTable returned no HASH key for index by_status of orders")
        #expect(queryFailedMessage(described(definitions: [defs[0], defs[1]]))
            == "DescribeTable returned no HASH key for index by_status of orders")
    }

    @Test func aSortKeyOfTheWrongTypeIsRefused() {
        let q = query(sort: .greaterThan(.number("5")))
        do {
            _ = try DynamoDBPartitionQueryRequest.body(for: q, schema: schema)
            Issue.record("expected a refusal")
        } catch DriverError.unsupported(let text) {
            #expect(text == "Key attribute sk is S, the value given is N")
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test(arguments: [
        ("=", "#k1 = :v1"), ("<", "#k1 < :v1"), ("<=", "#k1 <= :v1"), (">", "#k1 > :v1"), (">=", "#k1 >= :v1"),
        ("between", "#k1 BETWEEN :v1 AND :v2"), ("begins_with", "begins_with(#k1, :v1)"),
    ])
    func everySortOperatorBindsItsOperandsThroughPlaceholders(operatorName: String, clause: String) throws {
        let a = DynamoDBKeyValue.string("a"), b = DynamoDBKeyValue.string("b")
        let condition: DynamoDBSortKeyCondition
        switch operatorName {
        case "=": condition = .equal(a)
        case "<": condition = .lessThan(a)
        case "<=": condition = .lessThanOrEqual(a)
        case ">": condition = .greaterThan(a)
        case ">=": condition = .greaterThanOrEqual(a)
        case "between": condition = .between(a, b)
        default: condition = .beginsWith(a)
        }
        let body = try DynamoDBPartitionQueryRequest.body(for: query(sort: condition), schema: schema).body
        #expect(body["KeyConditionExpression"] as? String == "#k0 = :v0 AND \(clause)")
        let values = body["ExpressionAttributeValues"] as? [String: [String: String]]
        let expected: [String: [String: String]] = operatorName == "between"
            ? [":v0": ["S": "a"], ":v1": ["S": "a"], ":v2": ["S": "b"]]
            : [":v0": ["S": "a"], ":v1": ["S": "a"]]
        #expect(values == expected)
    }

    @Test func numberAndBinaryStartKeyValuesAreSentAsAttributeValues() throws {
        let query = DynamoDBPartitionQuery(
            table: "orders", indexName: nil, partitionKey: .string("a"), sortKey: nil, projection: nil, limit: 10,
            exclusiveStartKey: ["n": .number("12.50"), "b": .binary(Data([1, 2, 3]))]
        )
        let body = try DynamoDBPartitionQueryRequest.body(for: query, schema: schema).body
        #expect(body["ExclusiveStartKey"] as? [String: [String: String]]
            == ["n": ["N": "12.50"], "b": ["B": Data([1, 2, 3]).base64EncodedString()]])
    }
}
