import BerryDataSourceKit
import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverMongo

@Suite("MongoConnection — query/write routing")
struct MongoConnectionTests {
    private func makeConfig(database: String = "berrydb") -> ConnectionConfig {
        ConnectionConfig(driver: .mongodb, name: "test", host: "stub-host", port: 27017, database: database)
    }

    private func makeConnection(handlers: [MongoStubTransport.Handler]) async throws -> MongoConnection {
        let transport = MongoStubTransport(handlers: [helloHandler] + handlers)
        let connection = try MongoConnection(config: makeConfig(), transport: transport)
        try await connection.open()
        return connection
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

    // MARK: Query rejects Qdrant-shaped requests

    @Test func rejectsQdrantSearch() async throws {
        let connection = try await makeConnection(handlers: [])
        await #expect(throws: DataSourceError.self) {
            _ = try await drain(connection.query(.qdrantSearch(collection: "x", vector: [0.1], filter: nil, topK: 1, scoreThreshold: nil)))
        }
    }

    @Test func rejectsQdrantScroll() async throws {
        let connection = try await makeConnection(handlers: [])
        await #expect(throws: DataSourceError.self) {
            _ = try await drain(connection.query(.qdrantScroll(collection: "x", filter: nil, pageToken: nil)))
        }
    }

    // MARK: mongoFind — single page

    @Test func findYieldsItemsThenComplete() async throws {
        let connection = try await makeConnection(handlers: [
            { _ in
                okReply([("cursor", .object([
                    ("firstBatch", .array([.object([("_id", .int(1))]), .object([("_id", .int(2))])])),
                    ("id", .int(0)),
                ]))])
            },
        ])
        let (items, stats) = try await drain(connection.query(
            .mongoFind(collection: "users", filter: .object([]), projection: nil, limit: nil)
        ))
        #expect(items.count == 2)
        #expect(stats?.itemsReturned == 2)
    }

    // MARK: mongoFind — multi-page via getMore (N3 batching)

    @Test func findDrainsCursorAcrossMultipleGetMorePages() async throws {
        let connection = try await makeConnection(handlers: [
            { _ in // find — first page, cursor still open
                okReply([("cursor", .object([
                    ("firstBatch", .array((0..<3).map { .object([("_id", .int(Int64($0)))]) })),
                    ("id", .int(99)),
                ]))])
            },
            { request in // getMore — second (final) page, cursor exhausted
                #expect(request["getMore"] == .int(99))
                return okReply([("cursor", .object([
                    ("nextBatch", .array((3..<5).map { .object([("_id", .int(Int64($0)))]) })),
                    ("id", .int(0)),
                ]))])
            },
        ])
        let (items, stats) = try await drain(connection.query(
            .mongoFind(collection: "users", filter: .object([]), projection: nil, limit: nil)
        ))
        #expect(items.count == 5)
        #expect(stats?.itemsReturned == 5)
    }

    // MARK: mongoAggregate

    @Test func aggregateYieldsPipelineResults() async throws {
        let connection = try await makeConnection(handlers: [
            { request in
                #expect(request["aggregate"] == .string("orders"))
                return okReply([("cursor", .object([
                    ("firstBatch", .array([.object([("total", .int(42))])])),
                    ("id", .int(0)),
                ]))])
            },
        ])
        let (items, _) = try await drain(connection.query(
            .mongoAggregate(collection: "orders", pipeline: [.object([("$match", .object([]))])])
        ))
        #expect(items == [.object([("total", .int(42))])])
    }

    // MARK: createCollection (docs/architecture/12 §3) — ref.database ignored,
    // always creates on the connection's own working database (makeConfig's
    // "berrydb" default here).

    @Test func createCollectionSendsCreateCommandOnWorkingDatabase() async throws {
        let connection = try await makeConnection(handlers: [
            { request in
                #expect(request["create"] == .string("docs"))
                #expect(request["$db"] == .string("berrydb"))
                return okReply()
            },
        ])
        try await connection.createCollection(CollectionRef(database: "ignored", name: "docs"), options: .object([]))
    }

    // MARK: write — insert

    @Test func insertReturnsAffectedCountAndInsertedID() async throws {
        let connection = try await makeConnection(handlers: [
            { _ in okReply([("n", .int(1))]) },
        ])
        let result = try await connection.write(.insert(collection: "users", document: .object([("name", .string("Alice"))])))
        #expect(result.affectedCount == 1)
        #expect(result.insertedID != nil)
    }

    // MARK: write — update wraps patch in $set, filters by _id

    @Test func updateWrapsPatchInSetAndFiltersByID() async throws {
        let connection = try await makeConnection(handlers: [
            { request in
                guard case .array(let updates)? = request["updates"], updates.count == 1 else {
                    Issue.record("expected one update spec")
                    return okReply([("n", .int(0))])
                }
                #expect(updates[0]["q"] == .object([("_id", .string("p1"))]))
                #expect(updates[0]["u"] == .object([("$set", .object([("city", .string("Saigon"))]))]))
                #expect(updates[0]["multi"] == .bool(false))
                return okReply([("n", .int(1))])
            },
        ])
        let result = try await connection.write(.update(
            collection: "users", id: .string("p1"), patch: .object([("city", .string("Saigon"))])
        ))
        #expect(result.affectedCount == 1)
    }

    // MARK: write — delete (NS-08 routing)

    @Test func deleteWithConcreteIDFiltersByIDAndDeletesOne() async throws {
        let connection = try await makeConnection(handlers: [
            { request in
                guard case .array(let deletes)? = request["deletes"], deletes.count == 1 else {
                    Issue.record("expected one delete spec")
                    return okReply([("n", .int(0))])
                }
                #expect(deletes[0]["q"] == .object([("_id", .string("p1"))]))
                #expect(deletes[0]["limit"] == .int(1))
                return okReply([("n", .int(1))])
            },
        ])
        let result = try await connection.write(.delete(collection: "users", id: .string("p1")))
        #expect(result.affectedCount == 1)
    }

    @Test func deleteWithEmptyIDDeletesEverythingViaDeleteMany() async throws {
        let connection = try await makeConnection(handlers: [
            { request in
                guard case .array(let deletes)? = request["deletes"], deletes.count == 1 else {
                    Issue.record("expected one delete spec")
                    return okReply([("n", .int(0))])
                }
                #expect(deletes[0]["q"] == .object([]))
                #expect(deletes[0]["limit"] == .int(0)) // multi
                return okReply([("n", .int(7))])
            },
        ])
        let result = try await connection.write(.delete(collection: "users", id: .null))
        #expect(result.affectedCount == 7)
    }

    // MARK: Lifecycle

    @Test func operationsAfterCloseThrowNotConnected() async throws {
        let connection = try await makeConnection(handlers: [])
        await connection.close()
        await #expect(throws: DataSourceError.self) {
            _ = try await connection.listCollections()
        }
        await #expect(throws: DataSourceError.self) {
            try await connection.createCollection(CollectionRef(name: "docs"), options: .object([]))
        }
        #expect(await connection.ping() == false)
    }

    @Test func cancelWithNoActiveQueryIsANoOp() async throws {
        let connection = try await makeConnection(handlers: [])
        connection.cancelCurrentQuery()
    }

    @Test func cancelStopsAnInFlightGetMoreLoop() async throws {
        final class GetMoreCount: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        }
        let getMoreCount = GetMoreCount()
        let connection = try await makeConnection(handlers: [
            { _ in // find — first page, cursor still open, more pages available forever
                okReply([("cursor", .object([
                    ("firstBatch", .array([.object([("_id", .int(0))])])),
                    ("id", .int(1)),
                ]))])
            },
            { _ in // getMore — always returns another open page, would loop forever if not cancelled
                _ = getMoreCount.increment()
                return okReply([("cursor", .object([
                    ("nextBatch", .array([.object([("_id", .int(1))])])),
                    ("id", .int(1)),
                ]))])
            },
        ])
        let stream = connection.query(.mongoFind(collection: "users", filter: .object([]), projection: nil, limit: nil))
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next() // consume the first .items batch
        connection.cancelCurrentQuery()
        await #expect(throws: (any Error).self) {
            while try await iterator.next() != nil {}
        }
    }

    // MARK: DataSourceDriver entry point (docs/architecture/12 §2/§8)

    @Test func driverConnectFailsFastWhenHandshakeFails() async throws {
        let driver = MongoDriver()
        let badConfig = ConnectionConfig(driver: .mongodb, name: "test", host: "", port: 1)
        await #expect(throws: (any Error).self) {
            _ = try await driver.connect(badConfig)
        }
    }
}
