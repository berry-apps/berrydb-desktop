import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryDriverQdrant

@Suite("QdrantWire")
struct QdrantWireTests {
    @Test func pointIDPrefersStringAndObjectID() {
        #expect(QdrantWire.pointID(from: .string("abc")) as? String == "abc")
        #expect(QdrantWire.pointID(from: .objectID("507f1f77bcf86cd799439011")) as? String == "507f1f77bcf86cd799439011")
        #expect(QdrantWire.pointID(from: .int(42)) as? Int64 == 42)
    }

    @Test func berryDocumentFromPointIDRoundTrips() {
        #expect(QdrantWire.berryDocument(fromPointID: "abc") == .string("abc"))
        #expect(QdrantWire.berryDocument(fromPointID: Int64(7)) == .int(7))
        #expect(QdrantWire.berryDocument(fromPointID: NSNumber(value: 9)) == .int(9))
    }

    @Test func vectorArrayFromVectorCase() {
        let floats: [Float] = [0.1, 0.2, 0.3]
        let doc = BerryDocument.vector(floats)
        // Widen the SAME Float values (not Double literals) — Float(0.1) does
        // not equal Double(0.1) bit-for-bit, so the expectation must go
        // through the same Float -> Double conversion the implementation uses.
        #expect(QdrantWire.vectorArray(from: doc) == floats.map(Double.init))
    }

    @Test func vectorArrayFromPlainArrayOfNumbers() {
        let doc = BerryDocument.array([.double(1.5), .int(2)])
        #expect(QdrantWire.vectorArray(from: doc) == [1.5, 2.0])
    }

    @Test func vectorArrayFromNonNumericArrayIsNil() {
        let doc = BerryDocument.array([.string("nope")])
        #expect(QdrantWire.vectorArray(from: doc) == nil)
    }

    @Test func vectorArrayFromNonArrayIsNil() {
        #expect(QdrantWire.vectorArray(from: .string("x")) == nil)
    }

    @Test func documentFromPointJSONBuildsExpectedShape() {
        let json: [String: Any] = [
            "id": "point-1",
            "score": 0.87,
            "payload": ["city": "Hanoi"],
            "vector": [0.1, 0.2],
        ]
        let doc = QdrantWire.document(fromPointJSON: json)
        #expect(doc["id"] == .string("point-1"))
        #expect(doc["score"] == .double(0.87))
        #expect(doc["payload"] == .object([("city", .string("Hanoi"))]))
        if case .vector(let v)? = doc["vector"] {
            #expect(v == [0.1, 0.2])
        } else {
            Issue.record("expected .vector field")
        }
    }

    @Test func documentFromPointJSONOmitsAbsentFields() {
        let doc = QdrantWire.document(fromPointJSON: ["id": 5])
        #expect(doc["id"] == .int(5))
        #expect(doc["score"] == nil)
        #expect(doc["payload"] == nil)
        #expect(doc["vector"] == nil)
    }

    @Test func typeLabelsCoverEveryCase() {
        #expect(QdrantWire.typeLabel(.null) == "null")
        #expect(QdrantWire.typeLabel(.bool(true)) == "bool")
        #expect(QdrantWire.typeLabel(.int(1)) == "int")
        #expect(QdrantWire.typeLabel(.double(1)) == "double")
        #expect(QdrantWire.typeLabel(.string("s")) == "string")
        #expect(QdrantWire.typeLabel(.binary(Data())) == "binary")
        #expect(QdrantWire.typeLabel(.objectID("x")) == "objectID")
        #expect(QdrantWire.typeLabel(.date(Date())) == "date")
        #expect(QdrantWire.typeLabel(.vector([1])) == "vector")
        #expect(QdrantWire.typeLabel(.array([])) == "array")
        #expect(QdrantWire.typeLabel(.object([])) == "object")
    }
}
