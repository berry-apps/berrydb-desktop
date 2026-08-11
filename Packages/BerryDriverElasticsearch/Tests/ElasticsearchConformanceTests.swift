import BerryDataSourceKit
import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverElasticsearch

/// Runs against a real Elasticsearch from `BERRYDB_TEST_ELASTICSEARCH`
/// (`host:port`, see Tests/docker/compose.yml); skipped when the env var is
/// unset (docs/architecture/17 §6, CLAUDE.md · Build & test).
@Suite("Elasticsearch driver conformance", .enabled(if: ElasticsearchTestServer.elasticsearch != nil))
struct ElasticsearchConformanceTests {
    private var server: ElasticsearchTestServer { ElasticsearchTestServer.elasticsearch! }

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig(driver: .elasticsearch, name: "test", host: server.host, port: server.port, tlsMode: .disable)
    }

    private func makeConnection() throws -> ElasticsearchConnection {
        try ElasticsearchConnection(config: makeConfig())
    }

    private func deleteIndex(_ name: String) async {
        var req = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/\(name)")!)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Indexes `count` trivial documents in one `_bulk` call — fast setup for
    /// the multi-page scroll test, which needs more documents than one page
    /// (`ElasticsearchConnection.batchSize`) holds.
    private func bulkIndex(_ name: String, count: Int) async throws {
        var lines = ""
        for i in 0..<count {
            lines += "{\"index\":{\"_index\":\"\(name)\"}}\n"
            lines += "{\"n\":\(i)}\n"
        }
        var req = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/_bulk?refresh=true")!)
        req.httpMethod = "POST"
        req.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(lines.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200, "bulk index failed: \(String(data: data, encoding: .utf8) ?? "")")
    }

    private func scrollAll(_ connection: ElasticsearchConnection, index: String) async throws -> [BerryDocument] {
        var items: [BerryDocument] = []
        var token: String?
        repeat {
            var page: [BerryDocument] = []
            for try await event in connection.query(.esScroll(index: index, query: .null, pageToken: token)) {
                switch event {
                case .items(let batch): page += batch
                case .complete(let stats): token = stats.nextPageToken
                }
            }
            items += page
        } while token != nil
        return items
    }

    @Test func listCollectionsIncludesCreatedIndex() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        let connection = try makeConnection()
        defer { Task { await connection.close(); await deleteIndex(name) } }
        try await connection.createCollection(CollectionRef(name: name), options: .object([]))

        let collections = try await connection.listCollections()
        #expect(collections.contains { $0.name == name })
    }

    @Test func insertSearchUpdateDeleteRoundTrip() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        let connection = try makeConnection()
        defer { Task { await connection.close(); await deleteIndex(name) } }
        try await connection.createCollection(CollectionRef(name: name), options: .object([]))

        var ids: [String] = []
        for i in 0..<3 {
            let document = BerryDocument.object([("label", .string("item-\(i)")), ("n", .int(Int64(i)))])
            let result = try await connection.write(.insert(collection: name, document: document))
            #expect(result.affectedCount == 1)
            guard case .string(let id)? = result.insertedID else {
                Issue.record("expected an insertedID string")
                continue
            }
            ids.append(id)
        }

        // Query DSL search matching one document by an exact numeric field
        // (a `term` query on `n`, not `match` on `label`: dynamic mapping
        // maps `label` as analyzed `text`, whose standard analyzer tokenizes
        // "item-1" into "item"/"1" — a `match` on it would match all 3 docs).
        var searched: [BerryDocument] = []
        for try await event in connection.query(
            .esSearch(index: name, query: .object([("term", .object([("n", .int(1))]))]), from: 0, size: 10)
        ) {
            if case .items(let batch) = event { searched += batch }
        }
        #expect(searched.count == 1)
        if case .object(let fields)? = searched.first, case .string(let label)? = BerryDocument.object(fields)["_source"]?["label"] {
            #expect(label == "item-1")
        } else {
            Issue.record("expected a _source.label field on the search hit")
        }

        // Partial update — only the patched field changes.
        let updateResult = try await connection.write(.update(
            collection: name, id: .string(ids[0]), patch: .object([("label", .string("updated"))])
        ))
        #expect(updateResult.affectedCount == 1)

        // Delete a single document by id.
        let deleteResult = try await connection.write(.delete(collection: name, id: .string(ids[0])))
        #expect(deleteResult.affectedCount == 1)

        let remaining = try await scrollAll(connection, index: name)
        #expect(remaining.count == 2)
    }

    @Test func deleteWithoutIDDeletesWholeIndex() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        let connection = try makeConnection()
        defer { Task { await connection.close(); await deleteIndex(name) } }
        try await connection.createCollection(CollectionRef(name: name), options: .object([]))

        for i in 0..<2 {
            _ = try await connection.write(.insert(collection: name, document: .object([("n", .int(Int64(i)))])))
        }

        // An empty/missing id means "no filter" -> delete everything, same
        // structural risk SQL DangerGuard flags for DELETE without WHERE.
        let result = try await connection.write(.delete(collection: name, id: .null))
        #expect(result.affectedCount == 2)

        let remaining = try await scrollAll(connection, index: name)
        #expect(remaining.isEmpty)
    }

    @Test func deleteByFilterDeletesOnlyMatchingDocuments() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        let connection = try makeConnection()
        defer { Task { await connection.close(); await deleteIndex(name) } }
        try await connection.createCollection(CollectionRef(name: name), options: .object([]))

        for i in 0..<4 {
            _ = try await connection.write(.insert(
                collection: name, document: .object([("group", .string(i < 2 ? "a" : "b"))])
            ))
        }

        let result = try await connection.write(.deleteByFilter(
            collection: name, filter: .object([("match", .object([("group", .string("a"))]))]), multi: true
        ))
        #expect(result.affectedCount == 2)

        let remaining = try await scrollAll(connection, index: name)
        #expect(remaining.count == 2)
    }

    @Test func scrollPaginatesAcrossMultiplePages() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        defer { Task { await deleteIndex(name) } }
        // ElasticsearchConnection.batchSize is 500 (N3 floor) — insert more
        // than one page's worth to force real PIT + search_after continuation,
        // not just the single-page-covers-everything path.
        try await bulkIndex(name, count: 520)

        let connection = try makeConnection()
        defer { Task { await connection.close() } }

        var pageCount = 0
        var total = 0
        var token: String?
        repeat {
            var itemsThisPage = 0
            for try await event in connection.query(.esScroll(index: name, query: .null, pageToken: token)) {
                switch event {
                case .items(let batch): itemsThisPage += batch.count
                case .complete(let stats): token = stats.nextPageToken
                }
            }
            total += itemsThisPage
            pageCount += 1
        } while token != nil
        #expect(total == 520)
        #expect(pageCount == 2)
    }

    @Test func pingAndCloseWork() async throws {
        let connection = try makeConnection()
        #expect(await connection.ping())
        await connection.close()
        #expect(await connection.ping() == false)
    }

    // MARK: DataSourceDriver entry point (docs/architecture/17 §2)

    @Test func driverConnectSucceedsAgainstAReachableServer() async throws {
        let driver = ElasticsearchDriver()
        let connection = try await driver.connect(makeConfig())
        defer { Task { await connection.close() } }
        #expect(await connection.ping())
    }

    @Test func driverConnectFailsFastAgainstAnUnreachableHost() async throws {
        let driver = ElasticsearchDriver()
        let badConfig = ConnectionConfig(
            driver: .elasticsearch, name: "test", host: "127.0.0.1", port: 1, tlsMode: .disable
        )
        await #expect(throws: DataSourceError.self) {
            _ = try await driver.connect(badConfig)
        }
    }

    @Test func introspectorReportsDeclaredMappingFields() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8).lowercased())"
        let connection = try makeConnection()
        defer { Task { await connection.close(); await deleteIndex(name) } }
        try await connection.createCollection(CollectionRef(name: name), options: .object([]))
        _ = try await connection.write(.insert(
            collection: name,
            document: .object([("city", .string("Hanoi")), ("visits", .int(3))])
        ))

        let schema = try await connection.introspector.inferredSchema(of: CollectionRef(name: name), sampleSize: 10)
        #expect(schema["city"] == "text" || schema["city"] == "keyword")
        #expect(schema["visits"] == "long")
    }

    @Test func queryRejectsMongoAndQdrantShapedRequests() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            for try await _ in connection.query(.mongoFind(collection: "x", filter: .null, projection: nil, limit: nil)) {}
        }
        await #expect(throws: DataSourceError.self) {
            for try await _ in connection.query(.qdrantSearch(collection: "x", vector: [1], filter: nil, topK: 1, scoreThreshold: nil)) {}
        }
    }

    @Test func updateByFilterIsRejectedAsUnsupported() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.updateByFilter(
                collection: "test_index", filter: .object([]), update: .object([("x", .int(1))]), multi: true
            ))
        }
    }

    @Test func createIndexAndDropIndexAreRejectedAsUnsupported() async throws {
        let connection = try makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.createIndex(collection: "test_index", keys: .object([]), options: nil))
        }
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.write(.dropIndex(collection: "test_index", indexName: "x"))
        }
    }
}
