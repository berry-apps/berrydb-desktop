import BerryDataSourceKit
import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverQdrant

@Suite("QdrantHTTPClient — request building, response parsing, error mapping")
struct QdrantHTTPClientTests {
    private func makeClient(
        host: String, apiKey: String? = "test-key", handler: @escaping QdrantStubURLProtocol.Handler
    ) throws -> QdrantHTTPClient {
        let session = QdrantStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(driver: .qdrant, name: "test", host: host, port: 6333, password: apiKey)
        return try QdrantHTTPClient(config: config, session: session)
    }

    // MARK: Collections

    @Test func listCollectionsSendsAPIKeyHeaderAndParsesNames() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/collections")
            #expect(request.value(forHTTPHeaderField: "api-key") == "test-key")
            let body: [String: Any] = ["result": ["collections": [["name": "docs"], ["name": "images"]]], "status": "ok"]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let collections = try await client.listCollections()
        #expect(collections.map(\.name) == ["docs", "images"])
    }

    @Test func collectionInfoParsesSingleVectorConfig() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.url?.path == "/collections/notes")
            let body: [String: Any] = [
                "result": [
                    "points_count": 42,
                    "config": ["params": ["vectors": ["size": 768, "distance": "Cosine"]]],
                ],
                "status": "ok",
            ]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let info = try await client.collectionInfo(name: "notes")
        #expect(info.pointsCount == 42)
        #expect(info.vectorSize == 768)
        #expect(info.distance == "Cosine")
    }

    @Test func collectionInfoBestEffortForNamedVectors() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let body: [String: Any] = [
                "result": [
                    "config": ["params": ["vectors": ["text": ["size": 384, "distance": "Dot"]]]],
                ],
                "status": "ok",
            ]
            return (stubResponse(request.url!, status: 200), stubJSONData(body))
        }
        let info = try await client.collectionInfo(name: "multi")
        #expect(info.vectorSize == 384)
        #expect(info.distance == "Dot")
    }

 // MARK: Collection creation

    @Test func createCollectionSendsPutWithVectorConfig() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/collections/docs")
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            let vectors = body["vectors"] as! [String: Any]
            #expect(vectors["size"] as? Int == 4)
            #expect(vectors["distance"] as? String == "Cosine")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": true, "status": "ok"]))
        }
        try await client.createCollection(name: "docs", vectorSize: 4, distance: "Cosine")
    }

    @Test func createCollectionOnExistingNameMapsToQueryFailed() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let errorBody: [String: Any] = ["status": ["error": "Collection `docs` already exists!"], "time": 0]
            return (stubResponse(request.url!, status: 409), stubJSONData(errorBody))
        }
        do {
            try await client.createCollection(name: "docs", vectorSize: 4, distance: "Cosine")
            Issue.record("expected throw")
        } catch let DataSourceError.queryFailed(message) {
            #expect(message.contains("already exists"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: Query request bodies

    @Test func searchBuildsExpectedBody() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/collections/docs/points/search")
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            #expect(body["limit"] as? Int == 5)
            #expect(body["score_threshold"] as? Double == 0.5)
            #expect((body["vector"] as? [Double])?.count == 3)
            #expect(body["with_vector"] as? Bool == false)
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [["id": "p1", "score": 0.9]]]))
        }
        let points = try await client.search(
            collection: "docs", vector: [0.1, 0.2, 0.3], filter: nil, topK: 5, scoreThreshold: 0.5
        )
        #expect(points.count == 1)
        #expect(points[0]["id"] as? String == "p1")
    }

    @Test func scrollSendsOffsetFromPageTokenAndParsesNextToken() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            #expect(body["offset"] as? Int == 100)
            let resultBody: [String: Any] = [
                "result": ["points": [["id": 101], ["id": 102]], "next_page_offset": 103],
                "status": "ok",
            ]
            return (stubResponse(request.url!, status: 200), stubJSONData(resultBody))
        }
        let page = try await client.scroll(
            collection: "docs", filter: nil, pageToken: "n:100", limit: 500, withVector: false
        )
        #expect(page.points.count == 2)
        #expect(page.nextPageToken == "n:103")
    }

    @Test func scrollWithNoNextPageOffsetReturnsNilToken() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let resultBody: [String: Any] = ["result": ["points": [], "next_page_offset": NSNull()], "status": "ok"]
            return (stubResponse(request.url!, status: 200), stubJSONData(resultBody))
        }
        let page = try await client.scroll(
            collection: "docs", filter: nil, pageToken: nil, limit: 500, withVector: true
        )
        #expect(page.points.isEmpty)
        #expect(page.nextPageToken == nil)
    }

    // MARK: Write request bodies

    @Test func upsertPointBuildsPointsArray() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.url?.path == "/collections/docs/points")
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            let points = body["points"] as! [[String: Any]]
            #expect(points.count == 1)
            #expect(points[0]["id"] as? String == "p1")
            #expect((points[0]["vector"] as? [Double])?.count == 2)
            #expect((points[0]["payload"] as? [String: Any])?["city"] as? String == "Hanoi")
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": ["status": "acknowledged"], "status": "ok"]))
        }
        try await client.upsertPoint(collection: "docs", id: "p1", vector: [0.1, 0.2], payload: ["city": "Hanoi"])
    }

    @Test func setPayloadBuildsExpectedBody() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            #expect(request.url?.path == "/collections/docs/points/payload")
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            #expect((body["payload"] as? [String: Any])?["city"] as? String == "Saigon")
            #expect(body["points"] as? [String] == ["p1"])
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:], "status": "ok"]))
        }
        try await client.setPayload(collection: "docs", id: "p1", payload: ["city": "Saigon"])
    }

    @Test func deleteByIDsBuildsPointsArray() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            #expect(body["points"] as? [String] == ["p1", "p2"])
            #expect(body["filter"] == nil)
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:], "status": "ok"]))
        }
        try await client.deleteByIDs(collection: "docs", ids: ["p1", "p2"])
    }

    @Test func deleteByFilterSendsEmptyFilterBody() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let body = try! JSONSerialization.jsonObject(with: QdrantStubURLProtocol.bodies(for: request.url!.host!).last!) as! [String: Any]
            #expect(body["filter"] as? [String: Any] != nil)
            #expect(body["points"] == nil)
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": [:], "status": "ok"]))
        }
        try await client.deleteByFilter(collection: "docs", filter: [:])
    }

    // MARK: Error mapping

    @Test func nonSuccessStatusMapsToQueryFailedWithMessage() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            let errorBody: [String: Any] = ["status": ["error": "Not found: Collection `ghost` doesn't exist!"], "time": 0]
            return (stubResponse(request.url!, status: 404), stubJSONData(errorBody))
        }
        do {
            _ = try await client.listCollections()
            Issue.record("expected throw")
        } catch let DataSourceError.queryFailed(message) {
            #expect(message.contains("404"))
            #expect(message.contains("doesn't exist"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func malformedJSONResponseMapsToQueryFailed() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request in
            (stubResponse(request.url!, status: 200), "not json".data(using: .utf8)!)
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await client.listCollections()
        }
    }

    @Test func networkFailureMapsToConnectionFailed() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { _ in
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await client.listCollections()
            Issue.record("expected throw")
        } catch DataSourceError.connectionFailed {
            // expected
        } catch {
            Issue.record("expected .connectionFailed, got \(error)")
        }
    }

    @Test func cancelledRequestMapsToCancelled() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { _ in
            throw URLError(.cancelled)
        }
        do {
            _ = try await client.listCollections()
            Issue.record("expected throw")
        } catch DataSourceError.cancelled {
            // expected
        } catch {
            Issue.record("expected .cancelled, got \(error)")
        }
    }

    // MARK: ping

    @Test func pingTrueOnSuccessFalseOnFailure() async throws {
        let hostOK = "qdrant-\(UUID().uuidString)".lowercased()
        let clientOK = try makeClient(host: hostOK) { request in
            (stubResponse(request.url!, status: 200), stubJSONData(["result": ["collections": []], "status": "ok"]))
        }
        #expect(await clientOK.ping() == true)

        let hostBad = "qdrant-\(UUID().uuidString)".lowercased()
        let clientBad = try makeClient(host: hostBad) { request in
            (stubResponse(request.url!, status: 500), stubJSONData(["status": ["error": "boom"]]))
        }
        #expect(await clientBad.ping() == false)
    }

    // MARK: Auth header omission

    @Test func noAPIKeyOmitsHeader() async throws {
        let host = "qdrant-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host, apiKey: nil) { request in
            #expect(request.value(forHTTPHeaderField: "api-key") == nil)
            return (stubResponse(request.url!, status: 200), stubJSONData(["result": ["collections": []], "status": "ok"]))
        }
        _ = try await client.listCollections()
    }
}
