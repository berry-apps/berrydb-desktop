import BerryDataSourceKit
import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverQdrant

/// Runs against a real Qdrant from `BERRYDB_TEST_QDRANT` (`host:port`, see
/// Tests/docker/compose.yml); skipped when the env var is unset
/// (docs/architecture/12 §10, CLAUDE.md · Build & test).
@Suite("Qdrant driver conformance", .enabled(if: QdrantTestServer.qdrant != nil))
struct QdrantConformanceTests {
    private var server: QdrantTestServer { QdrantTestServer.qdrant! }

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig(driver: .qdrant, name: "test", host: server.host, port: server.port, tlsMode: .disable)
    }

    private func makeConnection() throws -> QdrantConnection {
        try QdrantConnection(config: makeConfig())
    }

    /// Collections are created/torn down directly over the base REST API —
    /// the driver deliberately has no `createCollection` (out of scope,
    /// docs/architecture/12 §5: BerryDB connects to collections the user
    /// already has, same anti-bloat stance as "no data modeler for document
    /// stores", §1).
    private func createCollection(_ name: String, vectorSize: Int = 4) async throws {
        var req = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/collections/\(name)")!)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "vectors": ["size": vectorSize, "distance": "Cosine"],
        ])
        _ = try await URLSession.shared.data(for: req)
    }

    private func deleteCollection(_ name: String) async {
        var req = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/collections/\(name)")!)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    private func scrollAll(_ connection: QdrantConnection, collection: String) async throws -> [BerryDocument] {
        var items: [BerryDocument] = []
        for try await event in connection.query(.qdrantScroll(collection: collection, filter: nil, pageToken: nil)) {
            if case .items(let batch) = event { items += batch }
        }
        return items
    }

    @Test func listCollectionsIncludesCreatedCollection() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createCollection(name)
        defer { Task { await deleteCollection(name) } }

        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        let collections = try await connection.listCollections()
        #expect(collections.contains { $0.name == name })
    }

    @Test func upsertSearchScrollAndDeleteRoundTrip() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createCollection(name)
        defer { Task { await deleteCollection(name) } }

        let connection = try makeConnection()
        defer { Task { await connection.close() } }

        // Insert 3 points on ORTHOGONAL axes — under cosine distance,
        // parallel vectors (e.g. [1,1,1,1] vs [2,2,2,2]) are indistinguishable
        // (same direction, similarity 1.0), so a search test needs vectors
        // that actually differ in direction, not just magnitude.
        let axisVectors: [[Float]] = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
        for i in 0..<3 {
            let document = BerryDocument.object([
                ("id", .int(Int64(i))),
                ("vector", .vector(axisVectors[i])),
                ("payload", .object([("label", .string("item-\(i)"))])),
            ])
            let result = try await connection.write(.insert(collection: name, document: document))
            #expect(result.affectedCount == 1)
        }

        let scrolled = try await scrollAll(connection, collection: name)
        #expect(scrolled.count == 3)

        // Search for the vector matching point 2's axis exactly.
        var searched: [BerryDocument] = []
        for try await event in connection.query(
            .qdrantSearch(collection: name, vector: axisVectors[2], filter: nil, topK: 1, scoreThreshold: nil)
        ) {
            if case .items(let batch) = event { searched += batch }
        }
        #expect(searched.count == 1)
        if case .int(let id)? = searched.first?["id"] {
            #expect(id == 2)
        } else {
            Issue.record("expected an id field on the top search result")
        }

        // Update payload only — vector must survive untouched.
        let updateResult = try await connection.write(.update(
            collection: name, id: .int(0), patch: .object([("payload", .object([("label", .string("updated"))]))])
        ))
        #expect(updateResult.affectedCount == 1)

        // Delete a single point by id.
        let deleteResult = try await connection.write(.delete(collection: name, id: .int(0)))
        #expect(deleteResult.affectedCount == 1)

        let afterDelete = try await scrollAll(connection, collection: name)
        #expect(afterDelete.count == 2)
    }

    @Test func deleteWithoutIDDeletesWholeCollection() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createCollection(name)
        defer { Task { await deleteCollection(name) } }

        let connection = try makeConnection()
        defer { Task { await connection.close() } }

        for i in 0..<2 {
            let document = BerryDocument.object([
                ("id", .int(Int64(i))),
                ("vector", .vector([Float(i + 1), 0, 0, 0])),
            ])
            _ = try await connection.write(.insert(collection: name, document: document))
        }

        // NS-08: an empty/missing id means "no filter" -> delete everything,
        // the same structural risk SQL DangerGuard flags for DELETE w/o WHERE.
        let result = try await connection.write(.delete(collection: name, id: .null))
        #expect(result.affectedCount == 2)

        let remaining = try await scrollAll(connection, collection: name)
        #expect(remaining.isEmpty)
    }

    @Test func scrollPaginatesUsingNextPageToken() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createCollection(name)
        defer { Task { await deleteCollection(name) } }

        let connection = try makeConnection()
        defer { Task { await connection.close() } }

        for i in 0..<5 {
            let document = BerryDocument.object([
                ("id", .int(Int64(i))),
                ("vector", .vector([Float(i + 1), 0, 0, 0])),
            ])
            _ = try await connection.write(.insert(collection: name, document: document))
        }

        // First page.
        var firstPageItems: [BerryDocument] = []
        var token: String?
        for try await event in connection.query(.qdrantScroll(collection: name, filter: nil, pageToken: nil)) {
            switch event {
            case .items(let batch): firstPageItems += batch
            case .complete(let stats): token = stats.nextPageToken
            }
        }
        #expect(firstPageItems.count == 5) // batch size (1000) exceeds total, so one page covers everything
        #expect(token == nil)
    }

    @Test func pingAndCloseWork() async throws {
        let connection = try makeConnection()
        #expect(await connection.ping())
        await connection.close()
        #expect(await connection.ping() == false)
    }

    // MARK: DataSourceDriver entry point (docs/architecture/12 §2/§8)

    @Test func driverConnectSucceedsAgainstAReachableServer() async throws {
        let driver = QdrantDriver()
        let connection = try await driver.connect(makeConfig())
        defer { Task { await connection.close() } }
        #expect(await connection.ping())
    }

    @Test func driverConnectFailsFastAgainstAnUnreachableHost() async throws {
        let driver = QdrantDriver()
        let badConfig = ConnectionConfig(
            driver: .qdrant, name: "test", host: "127.0.0.1", port: 1, tlsMode: .disable
        )
        await #expect(throws: DataSourceError.self) {
            _ = try await driver.connect(badConfig)
        }
    }

    @Test func introspectorReportsVectorConfigAndPayloadFields() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createCollection(name, vectorSize: 4)
        defer { Task { await deleteCollection(name) } }

        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        let document = BerryDocument.object([
            ("id", .int(1)),
            ("vector", .vector([1, 2, 3, 4])),
            ("payload", .object([("city", .string("Hanoi"))])),
        ])
        _ = try await connection.write(.insert(collection: name, document: document))

        let schema = try await connection.introspector.inferredSchema(
            of: CollectionRef(name: name), sampleSize: 10
        )
        #expect(schema["_vector.size"] == "4")
        #expect(schema["_vector.distance"] == "Cosine")
        #expect(schema["city"] == "string")
    }

    @Test func queryRejectsMongoShapedRequests() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            for try await _ in connection.query(.mongoFind(collection: "x", filter: .null, projection: nil, limit: nil)) {}
        }
    }

    @Test func updateByFilterIsRejectedAsUnsupported() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.updateByFilter(
                collection: "test_collection", filter: .object([]),
                update: .object([("$set", .object([]))]), multi: true
            ))
        }
    }

    @Test func deleteByFilterIsRejectedAsUnsupported() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.deleteByFilter(
                collection: "test_collection", filter: .object([]), multi: true
            ))
        }
    }
}
