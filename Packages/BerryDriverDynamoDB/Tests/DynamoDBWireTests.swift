import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBWire — AttributeValue <-> BerryValue")
struct DynamoDBWireTests {
    @Test func stringMapsToText() {
        #expect(DynamoDBWire.berryValue(from: ["S": "hello"]) == .text("hello"))
    }

    @Test func plainIntegerNumberMapsToIntWithNoLoss() {
        // Above 2^53 — must survive without Double round-trip loss (same
        // principle as the Postgres bigint conformance test).
        #expect(DynamoDBWire.berryValue(from: ["N": "9007199254740993"]) == .int(9_007_199_254_740_993))
    }

    @Test func decimalOrOversizedNumberStaysVerbatim() {
        #expect(DynamoDBWire.berryValue(from: ["N": "12345.6789"]) == .decimal("12345.6789"))
        // 38-digit precision — DynamoDB Numbers support this; Int64/Double can't.
        #expect(DynamoDBWire.berryValue(from: ["N": "99999999999999999999999999999999999999"])
            == .decimal("99999999999999999999999999999999999999"))
    }

    @Test func boolMapsToBool() {
        #expect(DynamoDBWire.berryValue(from: ["BOOL": true]) == .bool(true))
    }

    @Test func nullMapsToNull() {
        #expect(DynamoDBWire.berryValue(from: ["NULL": true]) == .null)
    }

    @Test func binaryMapsToBytesViaBase64() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(DynamoDBWire.berryValue(from: ["B": data.base64EncodedString()]) == .bytes(data))
    }

    @Test func invalidBase64BinaryFallsBackToUnknownInsteadOfCrashing() {
        guard case .unknown = DynamoDBWire.berryValue(from: ["B": "not-valid-base64!!!"]) else {
            Issue.record("expected .unknown for invalid base64")
            return
        }
    }

    @Test func mapRendersAsJSONText() {
        let value = DynamoDBWire.berryValue(from: ["M": ["age": ["N": "30"], "name": ["S": "Nam"]]])
        guard case .json(let text) = value else {
            Issue.record("expected .json, got \(value)")
            return
        }
        let parsed = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(parsed["age"] as? Int64 == 30 || parsed["age"] as? Int == 30)
        #expect(parsed["name"] as? String == "Nam")
    }

    @Test func listRendersAsJSONText() {
        let value = DynamoDBWire.berryValue(from: ["L": [["S": "a"], ["N": "1"]]])
        guard case .json(let text) = value else {
            Issue.record("expected .json, got \(value)")
            return
        }
        let parsed = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [Any]
        #expect(parsed.count == 2)
    }

    @Test func stringSetRendersAsJSONArrayText() {
        let value = DynamoDBWire.berryValue(from: ["SS": ["a", "b"]])
        guard case .json(let text) = value else {
            Issue.record("expected .json, got \(value)")
            return
        }
        #expect(text == "[\"a\",\"b\"]")
    }

    @Test func unrecognizedAttributeShapeFallsBackToUnknown() {
        guard case .unknown = DynamoDBWire.berryValue(from: [:]) else {
            Issue.record("expected .unknown for an empty attribute")
            return
        }
    }

    // MARK: - row(from:columnOrder:) — column alignment (05 §1 ResultEvent contract)

    @Test func rowFillsMissingAttributesWithNull() {
        let item: [String: Any] = ["Artist": ["S": "Acme"]]
        let row = DynamoDBWire.row(from: item, columnOrder: ["Artist", "SongTitle"])
        #expect(row == [.text("Acme"), .null])
    }

    @Test func rowDropsAttributesNotInColumnOrder() {
        // Known limitation (docs/architecture/12 §4): a later page can
        // introduce an attribute the first page never announced — it's
        // dropped rather than corrupting the fixed column alignment.
        let item: [String: Any] = ["Artist": ["S": "Acme"], "Unexpected": ["S": "surprise"]]
        let row = DynamoDBWire.row(from: item, columnOrder: ["Artist"])
        #expect(row == [.text("Acme")])
    }

    @Test func declaredTypeReportsTheAttributeValueTag() {
        let batch: [[String: Any]] = [["Awards": ["N": "10"]]]
        #expect(DynamoDBWire.declaredType(of: "Awards", firstBatch: batch) == "N")
        #expect(DynamoDBWire.declaredType(of: "Missing", firstBatch: batch) == "")
    }
}
