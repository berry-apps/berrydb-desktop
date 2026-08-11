import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryDriverMongo

/// Hex fixtures below are transcribed verbatim from MongoDB's own
/// `bson-corpus` conformance test suite
/// (https://github.com/mongodb/specifications/tree/master/source/bson-corpus)
/// — not hand-derived — same "verify against a real vector" discipline
/// `SigV4SignerTests` used for AWS SigV4 (docs/architecture/12 §4).
@Suite("BSON encode/decode")
struct BSONTests {
    private func hexData(_ hex: String) -> Data {
        var bytes = [UInt8]()
        var chars = Substring(hex)
        while chars.count >= 2 {
            bytes.append(UInt8(chars.prefix(2), radix: 16)!)
            chars = chars.dropFirst(2)
        }
        return Data(bytes)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: - bson-corpus: string (test_key "a")

    @Test func decodesEmptyString() throws {
        let doc = try BSON.decode(hexData("0D000000026100010000000000"))
        #expect(doc["a"] == .string(""))
    }

    @Test func stringRoundTrips() throws {
        let bytes = hexData("0E00000002610002000000620000")
        let doc = try BSON.decode(bytes)
        #expect(doc["a"] == .string("b"))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: int32 (test_key "i")

    @Test func int32RoundTripsAtBoundaries() throws {
        let cases: [(String, Int64)] = [
            ("0C0000001069000000008000", -2_147_483_648),
            ("0C000000106900FFFFFF7F00", 2_147_483_647),
            ("0C000000106900FFFFFFFF00", -1),
            ("0C0000001069000000000000", 0),
        ]
        for (hex, expected) in cases {
            let bytes = hexData(hex)
            let doc = try BSON.decode(bytes)
            #expect(doc["i"] == .int(expected))
            #expect(hexString(BSON.encode(doc)) == hexString(bytes))
        }
    }

    // MARK: - bson-corpus: int64 (test_key "a") — values that do NOT fit int32

    @Test func int64RoundTripsAtBoundaries() throws {
        let cases: [(String, Int64)] = [
            ("10000000126100000000000000008000", Int64.min),
            ("10000000126100FFFFFFFFFFFFFF7F00", Int64.max),
        ]
        for (hex, expected) in cases {
            let bytes = hexData(hex)
            let doc = try BSON.decode(bytes)
            #expect(doc["a"] == .int(expected))
            #expect(hexString(BSON.encode(doc)) == hexString(bytes))
        }
    }

    // MARK: - bson-corpus: double (test_key "d")

    @Test func doubleRoundTrips() throws {
        let bytes = hexData("10000000016400000000000000F03F00")
        let doc = try BSON.decode(bytes)
        #expect(doc["d"] == .double(1.0))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: boolean (test_key "b")

    @Test func boolRoundTrips() throws {
        let trueBytes = hexData("090000000862000100")
        let falseBytes = hexData("090000000862000000")
        #expect(try BSON.decode(trueBytes)["b"] == .bool(true))
        #expect(try BSON.decode(falseBytes)["b"] == .bool(false))
        #expect(hexString(BSON.encode(try BSON.decode(trueBytes))) == hexString(trueBytes))
        #expect(hexString(BSON.encode(try BSON.decode(falseBytes))) == hexString(falseBytes))
    }

    // MARK: - bson-corpus: null (test_key "a")

    @Test func nullRoundTrips() throws {
        let bytes = hexData("080000000A610000")
        let doc = try BSON.decode(bytes)
        #expect(doc["a"] == .null)
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: ObjectId (test_key "a")

    @Test func objectIDRoundTrips() throws {
        let bytes = hexData("1400000007610056E1FC72E0C917E9C471416100")
        let doc = try BSON.decode(bytes)
        #expect(doc["a"] == .objectID("56e1fc72e0c917e9c4714161"))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: datetime (test_key "a")

    @Test func datetimeEpochRoundTrips() throws {
        let bytes = hexData("10000000096100000000000000000000")
        let doc = try BSON.decode(bytes)
        #expect(doc["a"] == .date(Date(timeIntervalSince1970: 0)))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: array (test_key "a") — [10]

    @Test func arrayRoundTrips() throws {
        let bytes = hexData("140000000461000C0000001030000A0000000000")
        let doc = try BSON.decode(bytes)
        #expect(doc["a"] == .array([.int(10)]))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: binary subtype 0x00 (test_key "x") — [0xFF, 0xFF]

    @Test func binarySubtype0RoundTrips() throws {
        let bytes = hexData("0F0000000578000200000000FFFF00")
        let doc = try BSON.decode(bytes)
        #expect(doc["x"] == .binary(Data([0xFF, 0xFF])))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - bson-corpus: document (test_key "x") — nested {"a": "b"}

    @Test func emptySubdocumentRoundTrips() throws {
        let bytes = hexData("0D000000037800050000000000")
        let doc = try BSON.decode(bytes)
        #expect(doc["x"] == .object([]))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    @Test func nestedSubdocumentRoundTrips() throws {
        let bytes = hexData("160000000378000E0000000261000200000062000000")
        let doc = try BSON.decode(bytes)
        #expect(doc["x"] == .object([("a", .string("b"))]))
        #expect(hexString(BSON.encode(doc)) == hexString(bytes))
    }

    // MARK: - Round trip across every BerryDocument case in one document (not from corpus)

    @Test func compositeDocumentRoundTrips() throws {
        let original = BerryDocument.object([
            ("n", .null),
            ("b", .bool(true)),
            ("i32", .int(42)),
            ("i64", .int(9_000_000_000)),
            ("d", .double(3.5)),
            ("s", .string("hello")),
            ("bin", .binary(Data([1, 2, 3]))),
            ("oid", .objectID("56e1fc72e0c917e9c4714161")),
            ("dt", .date(Date(timeIntervalSince1970: 1_000))),
            ("arr", .array([.int(1), .string("two"), .bool(false)])),
            ("obj", .object([("nested", .string("value"))])),
        ])
        let decoded = try BSON.decode(BSON.encode(original))
        #expect(decoded == original)
    }

    /// `.vector` has no native BSON type for general documents (docs/architecture/12
    /// §3) — it's written as a plain array of doubles, and decode never
    /// re-produces `.vector` for a plain numeric array. Documented, not a bug.
    @Test func vectorEncodesAsDoubleArrayAndDoesNotRoundTrip() throws {
        let original = BerryDocument.object([("v", .vector([1.0, 2.0]))])
        let decoded = try BSON.decode(BSON.encode(original))
        #expect(decoded["v"] == .array([.double(1.0), .double(2.0)]))
    }

    // MARK: - Malformed input

    @Test func decodeThrowsOnTruncatedInput() {
        #expect(throws: (any Error).self) {
            _ = try BSON.decode(Data([0x10, 0x00, 0x00, 0x00]))
        }
    }
}
