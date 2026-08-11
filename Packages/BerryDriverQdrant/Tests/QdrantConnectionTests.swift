import BerryDataSourceKit
import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverQdrant

@Suite("QdrantConnection — query/write routing")
struct QdrantConnectionTests {
    private func makeConnection(
        host: String, handler: @escaping QdrantStubURLProtocol.Handler
    ) throws -> QdrantConnection {
        let session = QdrantStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(driver: .qdrant, name: "test", host: host, port: 6333, password: "key")
        return try QdrantConnection(config: config, session: session)
    }

    private func drain(_ stream: AsyncThrowingStream<DataSourceEvent, Error>) async throws -> ([BerryDocument], DataSourceStats?) {
        var items: [BerryDocument] = []
        var stats: DataSourceStats?
        for try await event in stream {
            switch event {
            case .items(let batch): items.append(contentsOf: batch)
            case .complete(let s): stats = s
            }
        }
        return (items, stats)
    }

    // MARK: createCollection (docs/architecture/12 §5)

    @Test func createCollectionSendsExpectedRequest() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/collections/docs")
            let body = try! JSONSerialization.jsonObject(
                with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!
            ) as! [String: Any]
            let vectors = body["vectors"] as! [String: Any]
            #expect(vectors["size"] as? Int == 8)
            #expect(vectors["distance"] as? String == "Euclid")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": true]))
        }
        let options = BerryDocument.object([("vectorSize", .int(8)), ("distance", .string("Euclid"))])
        try await connection.createCollection(CollectionRef(name: "docs"), options: options)
    }

    @Test func createCollectionDefaultsToCosineDistanceWhenOmitted() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            let body = try! JSONSerialization.jsonObject(
                with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!
            ) as! [String: Any]
            let vectors = body["vectors"] as! [String: Any]
            #expect(vectors["distance"] as? String == "Cosine")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": true]))
        }
        let options = BerryDocument.object([("vectorSize", .int(4))])
        try await connection.createCollection(CollectionRef(name: "docs"), options: options)
    }

    @Test func createCollectionWithoutVectorSizeThrows() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            try await connection.createCollection(CollectionRef(name: "docs"), options: .object([]))
        }
    }

    @Test func createCollectionWithNonPositiveVectorSizeThrows() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        let options = BerryDocument.object([("vectorSize", .int(0))])
        await #expect(throws: DataSourceError.self) {
            try await connection.createCollection(CollectionRef(name: "docs"), options: options)
        }
    }

    // MARK: Query rejects Mongo-shaped requests

    @Test func rejectsMongoFind() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await drain(connection.query(.mongoFind(collection: "x", filter: .null, projection: nil, limit: nil)))
        }
    }

    @Test func rejectsMongoAggregate() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await drain(connection.query(.mongoAggregate(collection: "x", pipeline: [])))
        }
    }

    @Test func rejectsMongoListIndexes() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await drain(connection.query(.mongoListIndexes(collection: "x")))
        }
    }

    // MARK: qdrantSearch

    @Test func searchYieldsItemsThenComplete() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            let body: [String: Any] = ["result": [["id": "a", "score": 0.5], ["id": "b", "score": 0.4]]]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let (items, stats) = try await drain(connection.query(
            .qdrantSearch(collection: "docs", vector: [0.1, 0.2], filter: nil, topK: 2, scoreThreshold: nil)
        ))
        #expect(items.count == 2)
        #expect(stats?.itemsReturned == 2)
        #expect(stats?.nextPageToken == nil)
    }

    @Test func searchChunksLargeResultSets() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let total = 2500
        let connection = try makeConnection(host: host) { request in
            let points = (0..<total).map { ["id": $0] }
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": points]))
        }
        var batchSizes: [Int] = []
        var totalItems = 0
        for try await event in connection.query(
            .qdrantSearch(collection: "docs", vector: [0.1], filter: nil, topK: total, scoreThreshold: nil)
        ) {
            if case .items(let batch) = event {
                batchSizes.append(batch.count)
                totalItems += batch.count
            }
        }
        #expect(totalItems == total)
        #expect(batchSizes == [1000, 1000, 500])
    }

    // MARK: qdrantScroll

    @Test func scrollYieldsItemsAndNextPageToken() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.url?.path == "/collections/docs/points/scroll")
            let body: [String: Any] = ["result": ["points": [["id": 1], ["id": 2]], "next_page_offset": 3]]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let (items, stats) = try await drain(connection.query(
            .qdrantScroll(collection: "docs", filter: nil, pageToken: nil)
        ))
        #expect(items.count == 2)
        #expect(stats?.nextPageToken == "n:3")
    }

    @Test func scrollWithNoMorePagesReturnsNilToken() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            let body: [String: Any] = ["result": ["points": [], "next_page_offset": NSNull()]]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let (items, stats) = try await drain(connection.query(
            .qdrantScroll(collection: "docs", filter: nil, pageToken: "n:3")
        ))
        #expect(items.isEmpty)
        #expect(stats?.nextPageToken == nil)
    }

    // MARK: write — insert

    @Test func insertWithoutVectorThrows() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.insert(collection: "docs", document: .object([])))
        }
    }

    @Test func insertWithExplicitIDUpsertsAndReturnsIt() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.httpMethod == "PUT")
            let body = try! JSONSerialization.jsonObject(
                with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!
            ) as! [String: Any]
            let points = body["points"] as! [[String: Any]]
            #expect(points[0]["id"] as? String == "p1")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": ["status": "acknowledged"]]))
        }
        let document = BerryDocument.object([
            ("id", .string("p1")),
            ("vector", .vector([0.1, 0.2])),
            ("payload", .object([("city", .string("Hanoi"))])),
        ])
        let result = try await connection.write(.insert(collection: "docs", document: document))
        #expect(result.affectedCount == 1)
        #expect(result.insertedID == .string("p1"))
    }

    @Test func insertWithoutIDGeneratesAUUID() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), stubJSONData(["result": ["status": "acknowledged"]]))
        }
        let document = BerryDocument.object([("vector", .vector([0.1]))])
        let result = try await connection.write(.insert(collection: "docs", document: document))
        guard case .string(let generatedID)? = result.insertedID else {
            Issue.record("expected a generated string id")
            return
        }
        #expect(UUID(uuidString: generatedID) != nil)
    }

    // MARK: write — update

    @Test func updateWithVectorPatchUpserts() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/collections/docs/points")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": ["status": "acknowledged"]]))
        }
        let patch = BerryDocument.object([("vector", .vector([0.5]))])
        let result = try await connection.write(.update(collection: "docs", id: .string("p1"), patch: patch))
        #expect(result.affectedCount == 1)
    }

    @Test func updateWithPayloadOnlyPatchSetsPayload() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/collections/docs/points/payload")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:]]))
        }
        let patch = BerryDocument.object([("payload", .object([("city", .string("Saigon"))]))])
        let result = try await connection.write(.update(collection: "docs", id: .string("p1"), patch: patch))
        #expect(result.affectedCount == 1)
    }

    @Test func updateWithNeitherVectorNorPayloadThrows() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.update(collection: "docs", id: .string("p1"), patch: .object([])))
        }
    }

    // MARK: write — delete (NS-08 routing)

    @Test func deleteWithConcreteIDDeletesByID() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            #expect(request.url?.path == "/collections/docs/points/delete")
            let body = try! JSONSerialization.jsonObject(
                with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!
            ) as! [String: Any]
            #expect(body["points"] as? [String] == ["p1"])
            #expect(body["filter"] == nil)
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:]]))
        }
        let result = try await connection.write(.delete(collection: "docs", id: .string("p1")))
        #expect(result.affectedCount == 1)
    }

    @Test func deleteWithEmptyIDDeletesWholeCollectionViaFilter() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            switch request.url?.path {
            case "/collections/docs":
                return (stubResponse(request.url!, status: 200), stubJSONData(["result": ["points_count": 7]]))
            case "/collections/docs/points/delete":
                let body = try! JSONSerialization.jsonObject(
                    with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!
                ) as! [String: Any]
                #expect(body["filter"] as? [String: Any] != nil)
                #expect(body["points"] == nil)
                return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:]]))
            default:
                Issue.record("unexpected path \(request.url?.path ?? "")")
                return (stubResponse(request.url!, status: 500), Data())
            }
        }
        let result = try await connection.write(.delete(collection: "docs", id: .null))
        #expect(result.affectedCount == 7)
    }

    // MARK: Lifecycle

    @Test func operationsAfterCloseThrowNotConnected() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), stubJSONData(["result": ["collections": []]]))
        }
        await connection.close()
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.listCollections()
        }
        await #expect(throws: DataSourceError.self) {
            try await connection.createCollection(CollectionRef(name: "docs"), options: .object([("vectorSize", .int(4))]))
        }
        #expect(await connection.ping() == false)
    }

    @Test func cancelWithNoActiveQueryIsANoOp() throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        connection.cancelCurrentQuery()
    }

    // MARK: write — rejection of unsupported operations

    @Test func dropCollectionIsRejectedAsUnsupported() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.dropCollection(collection: "docs"))
        }
    }

    @Test func createIndexIsRejectedAsUnsupported() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.createIndex(collection: "docs", keys: .object([]), options: nil))
        }
    }

    @Test func dropIndexIsRejectedAsUnsupported() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.dropIndex(collection: "docs", indexName: "x"))
        }
    }

    @Test func renameCollectionIsRejectedAsUnsupported() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let connection = try makeConnection(host: host) { request in
            (stubResponse(request.url!, status: 200), Data())
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.renameCollection(collection: "docs", newName: "y"))
        }
    }
}
