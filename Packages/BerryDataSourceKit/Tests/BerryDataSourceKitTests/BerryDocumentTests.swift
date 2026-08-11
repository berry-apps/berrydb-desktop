import BerryDriverKit
import Foundation
import Testing

@testable import BerryDataSourceKit

@Suite("BerryDocument")
struct BerryDocumentTests {
    @Test("JSON round-trip preserves object field order and primitive values")
    func jsonRoundTrip() {
        let json: [String: Any] = [
            "name": "Alice",
            "age": 30,
            "active": true,
            "tags": ["a", "b"],
        ]
        let doc = BerryDocument(jsonObject: json)
        guard case .object(let fields) = doc else {
            Issue.record("expected .object")
            return
        }
        #expect(fields.count == 4)
        #expect(doc["name"] == .string("Alice"))
        #expect(doc["age"] == .int(30))
        #expect(doc["active"] == .bool(true))
        #expect(doc["tags"] == .array([.string("a"), .string("b")]))
        #expect(doc["missing"] == nil)
    }

    @Test("Equality and hashing treat object field order as significant")
    func equalityAndHashing() {
        let a = BerryDocument.object([("x", .int(1)), ("y", .int(2))])
        let b = BerryDocument.object([("x", .int(1)), ("y", .int(2))])
        let c = BerryDocument.object([("y", .int(2)), ("x", .int(1))])
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Vector case round-trips through jsonObject")
    func vectorRoundTrip() {
        let doc = BerryDocument.vector([0.1, 0.2, 0.3])
        let json = doc.jsonObject as? [Double]
        #expect(json?.count == 3)
    }

    /// Reported crash-risk audit: `.object` is deliberately an ORDERED ARRAY
    /// of pairs (not a Dictionary) so it can represent non-unique/ordered
    /// BSON fields — the BSON spec permits duplicate keys, and
    /// `BSON.decodeDocumentFields` doesn't dedup when decoding a real
    /// server response. `.jsonObject` collapsed it back via
    /// `Dictionary(uniqueKeysWithValues:)`, which traps the instant two
    /// fields share a key — reachable from the Mongo Shell tab too
    /// (`db.coll.insertOne({a: 1, a: 2})` parses to exactly this shape
    /// before any network call).
    @Test("jsonObject does not crash on a document with a duplicate key")
    func jsonObjectDoesNotCrashOnADuplicateKey() {
        let doc = BerryDocument.object([("a", .int(1)), ("a", .int(2))])
        let json = doc.jsonObject as? [String: Any]
        #expect(json?["a"] != nil)
    }

    /// Regression for a real bug: `jsonRoundTrip` above builds its `[String:
    /// Any]` from a Swift dictionary LITERAL, where `30`/`true` are already
    /// native `Int`/`Bool` — no ambiguity. Every actual caller
    /// (`CollectionTabState.parseFilter`/`parsePipeline`,
    /// `DocumentCellViewerSheet.parse`) instead goes through
    /// `JSONSerialization.jsonObject(with:)` first, which bridges JSON
    /// numbers AND booleans to `NSNumber` — a literal `0`/`1` satisfies
    /// Swift's `as? Bool` too, so checking `Bool` before `Int`/`Int64`
    /// silently mistyped e.g. a Mongo `$sort` direction (`{"price": 1}`) as
    /// `.bool(true)`. Caught via `WorkspaceMongoDataSourceTests
    /// .aggregationPipelineFiltersAndSorts` (a real `$sort` rejected by
    /// mongod), fixed via `NSNumber.objCType` in `init(jsonObject:)`.
    @Test("Integers 0/1 decode as .int, not .bool, through the real JSONSerialization path")
    func integerZeroAndOneSurviveThroughRealJSONDecoding() throws {
        let data = try #require("""
        {"zero": 0, "one": 1, "active": true, "inactive": false, "big": 2, "neg": -1}
        """.data(using: .utf8))
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        let doc = BerryDocument(jsonObject: jsonObject)

        #expect(doc["zero"] == .int(0))
        #expect(doc["one"] == .int(1))
        #expect(doc["active"] == .bool(true))
        #expect(doc["inactive"] == .bool(false))
        #expect(doc["big"] == .int(2))
        #expect(doc["neg"] == .int(-1))
    }
}

@Suite("DataSourceRegistry")
struct DataSourceRegistryTests {
    private struct FakeDriver: DataSourceDriver {
        static let id: DriverID = .qdrant
        static let displayName = "Fake"
        static let kind: DataSourceKind = .vector
        static let capabilities = DataSourceCapabilities()
        init() {}
        func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection {
            throw DataSourceError.unsupported("fake driver — test double")
        }
    }

    @Test("register then look up by DriverID")
    func registerAndLookUp() {
        DataSourceRegistry.register(FakeDriver.self)
        #expect(DataSourceRegistry.driverType(for: .qdrant) is FakeDriver.Type)
        #expect(DataSourceRegistry.registered.contains(.qdrant))
    }
}
