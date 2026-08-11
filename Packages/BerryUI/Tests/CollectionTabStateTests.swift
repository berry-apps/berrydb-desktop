import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryUI

/// Records the last `DataSourceQuery` passed to `query(_:)` so `run()`'s
/// branching (search vs. scroll, threshold, payload filter) can be asserted
/// without Docker. Lock-based recording (not actor-hop) for the same reason
/// `QdrantCancelBox`/`MongoCancelBox` are — `query` is `nonisolated`
/// and must record synchronously, before the caller can `await` anything.
private final class QueryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DataSourceQuery?
    var current: DataSourceQuery? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private struct StubIntrospector: DataSourceIntrospector {
    func collections() async throws -> [CollectionRef] { [] }
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] { [:] }
}

private actor RecordingConnection: DataSourceConnection {
    nonisolated let id = UUID()
    private nonisolated let box = QueryBox()
    var lastQuery: DataSourceQuery? { box.current }

    func listCollections() async throws -> [CollectionRef] { [] }
    func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {}

    nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error> {
        box.current = request
        return AsyncThrowingStream { continuation in
            continuation.yield(.complete(DataSourceStats(itemsReturned: 0, duration: .zero)))
            continuation.finish()
        }
    }

    func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        DataSourceWriteResult(affectedCount: 0)
    }

    nonisolated func cancelCurrentQuery() {}
    nonisolated var introspector: any DataSourceIntrospector { StubIntrospector() }
    func ping() async -> Bool { true }
    func close() async {}
}

/// Pure text→query-param parsing, `run()`'s query-construction branching, and
/// edit-in-place id/patch stripping (docs/architecture/12 §7) — no Docker,
/// always runs.
@MainActor
@Suite("CollectionTabState parsing")
struct CollectionTabStateTests {
    @Test func parseVectorParsesNumericArray() {
        #expect(CollectionTabState.parseVector("[0.1, 0.2, 3]") == [0.1, 0.2, 3])
    }

    @Test func parseVectorReturnsNilForEmptyOrInvalidText() {
        #expect(CollectionTabState.parseVector("") == nil)
        #expect(CollectionTabState.parseVector("not a vector") == nil)
    }

    @Test func idOfExtractsMongoUnderscoreID() {
        let doc = BerryDocument.object([("_id", .string("abc")), ("name", .string("x"))])
        #expect(CollectionTabState.id(of: doc, kind: .document) == .string("abc"))
    }

    @Test func idOfExtractsQdrantTopLevelID() {
        let doc = BerryDocument.object([("id", .int(7)), ("payload", .object([]))])
        #expect(CollectionTabState.id(of: doc, kind: .vector) == .int(7))
    }

    @Test func patchStripsMongoImmutableID() {
        let edited = BerryDocument.object([("_id", .string("abc")), ("name", .string("y"))])
        let patch = CollectionTabState.patch(from: edited, kind: .document)
        #expect(patch == .object([("name", .string("y"))]))
    }

    @Test func patchStripsQdrantIDAndScoreKeepingVectorAndPayload() {
        let edited = BerryDocument.object([
            ("id", .int(1)),
            ("score", .double(0.9)),
            ("vector", .vector([1, 0])),
            ("payload", .object([("label", .string("x"))])),
        ])
        let patch = CollectionTabState.patch(from: edited, kind: .vector)
        #expect(patch == .object([
            ("vector", .vector([1, 0])),
            ("payload", .object([("label", .string("x"))])),
        ]))
    }

    // MARK: - parseOptionalFilter (Qdrant payload filter)

    @Test func parseOptionalFilterReturnsNilForBlankText() {
        #expect(CollectionTabState.parseOptionalFilter("") == nil)
        #expect(CollectionTabState.parseOptionalFilter("   ") == nil)
    }

    @Test func parseOptionalFilterParsesValidJSONObject() {
        #expect(CollectionTabState.parseOptionalFilter("{\"category\": \"docs\"}")
            == .object([("category", .string("docs"))]))
    }

    @Test func parseOptionalFilterReturnsNilForInvalidJSON() {
        #expect(CollectionTabState.parseOptionalFilter("not json") == nil)
    }

    // MARK: - parseScoreThreshold (Qdrant score threshold)

    @Test func parseScoreThresholdParsesValidNumber() {
        #expect(CollectionTabState.parseScoreThreshold("0.75") == 0.75)
    }

    @Test func parseScoreThresholdReturnsNilForBlankOrInvalidText() {
        #expect(CollectionTabState.parseScoreThreshold("") == nil)
        #expect(CollectionTabState.parseScoreThreshold("   ") == nil)
        #expect(CollectionTabState.parseScoreThreshold("not a number") == nil)
    }

    // MARK: - run() query construction

    @Test func runBuildsQdrantSearchWithThresholdAndPayloadFilter() async {
        let connection = RecordingConnection()
        let state = CollectionTabState(ref: CollectionRef(name: "coll"), kind: .vector, connection: connection)
        state.vectorText = "[0.1, 0.2]"
        state.topK = 5
        state.scoreThresholdText = "0.8"
        state.payloadFilterText = "{\"category\": \"docs\"}"
        state.run()
        await state.buffer.waitUntilFinished()

        guard case .qdrantSearch(let collection, let vector, let filter, let topK, let scoreThreshold)
            = await connection.lastQuery else {
            Issue.record("expected .qdrantSearch")
            return
        }
        #expect(collection == "coll")
        #expect(vector == [0.1, 0.2])
        #expect(filter == .object([("category", .string("docs"))]))
        #expect(topK == 5)
        #expect(scoreThreshold == 0.8)
    }

    @Test func runBuildsQdrantScrollWhenVectorTextIsEmpty() async {
        let connection = RecordingConnection()
        let state = CollectionTabState(ref: CollectionRef(name: "coll"), kind: .vector, connection: connection)
        state.payloadFilterText = "{\"category\": \"docs\"}"
        state.run()
        await state.buffer.waitUntilFinished()

        guard case .qdrantScroll(let collection, let filter, let pageToken) = await connection.lastQuery else {
            Issue.record("expected .qdrantScroll")
            return
        }
        #expect(collection == "coll")
        #expect(filter == .object([("category", .string("docs"))]))
        #expect(pageToken == nil)
    }
}
