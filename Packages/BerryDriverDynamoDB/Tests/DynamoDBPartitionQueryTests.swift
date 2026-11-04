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
}
