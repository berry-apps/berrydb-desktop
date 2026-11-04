import Foundation
import Testing

@testable import BerryDriverKit

@Suite("Partition query contract")
struct PartitionQueryTests {
    @Test func attributeValuesRoundTripTheirJSON() throws {
        let entries: [[String: Any]] = [
            ["S": "x"], ["N": "123456789012345678901234567890123456.78"], ["B": "AQID"], ["BOOL": true],
            ["NULL": true], ["L": [["S": "a"], ["N": "1"]]], ["M": ["k": ["S": "v"]]],
            ["SS": ["a", "b"]], ["NS": ["1", "2"]], ["BS": ["AQ==", "Ag=="]],
        ]
        for entry in entries {
            let value = try DynamoDBAttributeValue(json: entry)
            #expect(NSDictionary(dictionary: value.json) == NSDictionary(dictionary: entry))
        }
        #expect(try DynamoDBAttributeValue(json: ["N": "123456789012345678901234567890123456.78"]) == .number("123456789012345678901234567890123456.78"))
        #expect(try DynamoDBAttributeValue(json: ["B": "AQID"]) == .binary(Data([1, 2, 3])))
    }

    @Test func anUnknownTagOrBadBase64IsRefused() {
        #expect(throws: DriverError.self) { try DynamoDBAttributeValue(json: ["X": "1"]) }
        #expect(throws: DriverError.self) { try DynamoDBAttributeValue(json: ["B": "not base64!"]) }
    }

    @Test func encodingWritesTheAttributeValueShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(["n": DynamoDBAttributeValue.number("1.50"), "m": .map(["b": .binary(Data([255]))])])
        #expect(String(decoding: data, as: UTF8.self) == #"{"m":{"M":{"b":{"B":"/w=="}}},"n":{"N":"1.50"}}"#)
    }

    @Test func keyAttributeNamesListTheTableKeysThenTheIndexKeys() {
        let schema = DynamoDBKeySchema(
            table: "orders",
            partitionKey: .init(name: "pk", type: .string), sortKey: .init(name: "sk", type: .string),
            indexes: [.init(name: "by_status", partitionKey: .init(name: "status", type: .string), sortKey: .init(name: "sk", type: .string))]
        )
        #expect(schema.keyAttributeNames(index: nil) == ["pk", "sk"])
        #expect(schema.keyAttributeNames(index: "by_status") == ["pk", "sk", "status"])
        #expect(schema.index(named: "missing") == nil)
    }
}
