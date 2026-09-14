import BerryDataSourceKit
import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMongo

/// Runs against a real `mongo:7` from `BERRYDB_TEST_MONGO` (`host:port:user:
/// pass:database`, see Tests/docker/compose.yml); skipped when the env var is
/// unset (see Tests/docker/compose.yml). This is the
/// "ground truth" suite for the hand-rolled OP_MSG/BSON/SCRAM-SHA-256 stack —
/// the pure unit tests (BSONTests, MongoOpMsgTests, SCRAMTests,
/// MongoWireClientTests, MongoConnectionTests) exercise the same code against
/// stubs/RFC vectors, but only a real `mongod` can confirm the wire bytes
/// this driver produces are actually accepted end to end.
@Suite("Mongo driver conformance", .enabled(if: TestServer.mongo != nil))
struct MongoConformanceTests {
    private var server: TestServer { TestServer.mongo! }

    private func makeConfig(database: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            driver: .mongodb, name: "test", host: server.host, port: server.port,
            username: server.username, password: server.password,
            database: database ?? server.database, tlsMode: .disable
        )
    }

    private func makeConnection() async throws -> MongoConnection {
        let connection = try MongoConnection(config: makeConfig())
        try await connection.open()
        return connection
    }

    /// `drop` isn't exposed on the driver surface (out of scope, same
    /// "connect to collections the user already has" stance as Qdrant's
    /// missing `createCollection`) — cleanup goes straight through
    /// `MongoWireClient.runCommand`, same as Qdrant conformance tests reach
    /// past the driver for setup/teardown.
    private func dropCollection(_ name: String) async {
        let client = try? MongoWireClient(config: makeConfig())
        try? await client?.connect()
        _ = try? await client?.runCommand(.object([("drop", .string(name))]), database: server.database ?? "admin")
        await client?.close()
    }

    private func findAll(_ connection: MongoConnection, collection: String) async throws -> [BerryDocument] {
        var items: [BerryDocument] = []
        for try await event in connection.query(.mongoFind(collection: collection, filter: .object([]), projection: nil, limit: nil)) {
            if case .items(let batch) = event { items += batch }
        }
        return items
    }

    @Test func listCollectionsIncludesACollectionCreatedByInsert() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("seed", .bool(true))])))

        let collections = try await connection.listCollections()
        #expect(collections.contains { $0.name == name })
    }

    @Test func insertFindUpdateDeleteRoundTrip() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        for i in 0..<3 {
            let document = BerryDocument.object([
                ("idx", .int(Int64(i))),
                ("label", .string("item-\(i)")),
            ])
            let result = try await connection.write(.insert(collection: name, document: document))
            #expect(result.affectedCount == 1)
            guard case .objectID(let hex)? = result.insertedID else {
                Issue.record("expected a client-generated ObjectId")
                continue
            }
            #expect(hex.count == 24)
        }

        let found = try await findAll(connection, collection: name)
        #expect(found.count == 3)

        // Update the doc labeled "item-0" by its real `_id` — round trip the
        // `_id` value real mongod assigned/echoed back, not a client guess.
        guard let target = found.first(where: { $0["label"] == .string("item-0") }), let targetID = target["_id"] else {
            Issue.record("expected to find item-0 with an _id")
            return
        }
        let updateResult = try await connection.write(.update(
            collection: name, id: targetID, patch: .object([("label", .string("updated"))])
        ))
        #expect(updateResult.affectedCount == 1)

        let afterUpdate = try await findAll(connection, collection: name)
        #expect(afterUpdate.contains { $0["label"] == .string("updated") })
        // $set patch must not disturb sibling fields.
        #expect(afterUpdate.first { $0["label"] == .string("updated") }?["idx"] == .int(0))

        let deleteResult = try await connection.write(.delete(collection: name, id: targetID))
        #expect(deleteResult.affectedCount == 1)

        let afterDelete = try await findAll(connection, collection: name)
        #expect(afterDelete.count == 2)
    }

    /// Sibling of `aggregatePipelineRuns` below, adding `$sort` (order, not
    /// just membership) — both build stages via direct `BerryDocument`
    /// construction, so neither exercises the JSON-text parsing path a real
    /// pipeline-mode query goes through (`CollectionTabState.parsePipeline`
    /// → `BerryDocument.init(jsonObject:)`). That JSON path is where
    /// `WorkspaceMongoDataSourceTests.aggregationPipelineFiltersAndSorts`
 /// (query UI) caught a real, pre-existing bug:
    /// `JSONSerialization` bridges JSON `0`/`1` AND `true`/`false` to
    /// `NSNumber` ambiguously (both satisfy `as? Bool`), so a `$sort`
    /// direction like `{"price": 1}` was silently mistyped as `.bool(true)`
    /// — mongod then rejected the pipeline outright ("Illegal key in $sort
    /// specification"). Fixed in `BerryDocument.init(jsonObject:)` via
    /// `NSNumber.objCType` (real booleans decode as ObjC `BOOL`/"c", real
    /// numbers never do) — see `BerryDocumentTests
    /// .integerZeroAndOneSurviveThroughRealJSONDecoding` for the precise
    /// regression test, at the layer the bug actually lived in.
    @Test func aggregatePipelineMatchesAndSorts() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        for (active, price) in [(true, 10), (true, 20), (false, 30)] {
            let r = try await connection.write(.insert(collection: name, document: .object([
                ("active", .bool(active)), ("price", .int(Int64(price))),
            ])))
            #expect(r.affectedCount == 1)
        }

        var items: [BerryDocument] = []
        for try await event in connection.query(.mongoAggregate(
            collection: name,
            pipeline: [
                .object([("$match", .object([("active", .bool(true))]))]),
                .object([("$sort", .object([("price", .int(1))]))]),
            ]
        )) {
            if case .items(let batch) = event { items += batch }
        }
        #expect(items.map { $0["price"] ?? .null } == [.int(10), .int(20)])
    }

    @Test func deleteWithoutIDDeletesWholeCollection() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        for i in 0..<4 {
            _ = try await connection.write(.insert(collection: name, document: .object([("i", .int(Int64(i)))])))
        }

 // an empty/null id means "no filter" -> deleteMany({}), the
        // same structural risk SQL DangerGuard flags for DELETE w/o WHERE.
        let result = try await connection.write(.delete(collection: name, id: .null))
        #expect(result.affectedCount == 4)

        let remaining = try await findAll(connection, collection: name)
        #expect(remaining.isEmpty)
    }

    @Test func aggregatePipelineRuns() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        for i in 0..<3 {
            _ = try await connection.write(.insert(collection: name, document: .object([("n", .int(Int64(i)))])))
        }

        var items: [BerryDocument] = []
        let pipeline: [BerryDocument] = [.object([("$match", .object([("n", .object([("$gte", .int(1))]))]))])]
        for try await event in connection.query(.mongoAggregate(collection: name, pipeline: pipeline)) {
            if case .items(let batch) = event { items += batch }
        }
        #expect(items.count == 2) // n=1, n=2
    }

    @Test func introspectorReportsUnionOfSampledFieldTypes() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("city", .string("Hanoi")), ("pop", .int(8))])))
        _ = try await connection.write(.insert(collection: name, document: .object([("city", .string("Saigon")), ("pop", .double(9.5))])))

        let schema = try await connection.introspector.inferredSchema(of: CollectionRef(name: name), sampleSize: 10)
        #expect(schema["city"] == "string")
        #expect(schema["pop"] == "double|int")
        #expect(schema["_id"] == "objectID")
    }

    @Test func pingAndCloseWork() async throws {
        let connection = try await makeConnection()
        #expect(await connection.ping())
        await connection.close()
        #expect(await connection.ping() == false)
    }

    @Test func updateManyAppliesToEveryMatchingDocument() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        for role in ["admin", "admin", "guest"] {
            _ = try await connection.write(.insert(collection: name, document: .object([("role", .string(role))])))
        }

        let result = try await connection.write(.updateByFilter(
            collection: name,
            filter: .object([("role", .string("admin"))]),
            update: .object([("$set", .object([("promoted", .bool(true))]))]),
            multi: true
        ))
        #expect(result.affectedCount == 2)

        // Verify actual field values were updated correctly, and that the
        // update document wasn't double-wrapped in $set (which would set a
        // literal field named "$set" instead of applying the operators).
        let afterUpdate = try await findAll(connection, collection: name)
        let adminDocs = afterUpdate.filter { $0["role"] == .string("admin") }
        let guestDocs = afterUpdate.filter { $0["role"] == .string("guest") }

        #expect(adminDocs.count == 2)
        #expect(guestDocs.count == 1)

        // Both matching documents must have promoted=true at top level.
        for adminDoc in adminDocs {
            #expect(adminDoc["promoted"] == .bool(true))
        }

        // Non-matching document must not have a promoted field.
        #expect(guestDocs.first?["promoted"] == nil)
    }

    @Test func deleteByFilterRemovesOnlyMatchingDocuments() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        for role in ["admin", "admin", "guest"] {
            _ = try await connection.write(.insert(collection: name, document: .object([("role", .string(role))])))
        }

        let result = try await connection.write(.deleteByFilter(
            collection: name,
            filter: .object([("role", .string("guest"))]),
            multi: true
        ))
        #expect(result.affectedCount == 1)

        // Verify that only the matching document was deleted, and the others
        // remain untouched.
        let afterDelete = try await findAll(connection, collection: name)
        #expect(afterDelete.count == 2)
        #expect(afterDelete.allSatisfy { $0["role"] == .string("admin") })
    }

    @Test func listIndexesReturnsTheDefaultIdIndex() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("x", .int(1))])))

        var docs: [BerryDocument] = []
        for try await event in connection.query(.mongoListIndexes(collection: name)) {
            if case .items(let batch) = event { docs.append(contentsOf: batch) }
        }
        #expect(docs.contains { doc in
            if case .string("_id_")? = doc["name"] { return true }
            return false
        })
    }

    @Test func createIndexThenGetIndexesShowsTheNewIndex() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("email", .string("a@x.com"))])))
        _ = try await connection.write(.createIndex(collection: name, keys: .object([("email", .int(1))]), options: nil))

        var docs: [BerryDocument] = []
        for try await event in connection.query(.mongoListIndexes(collection: name)) {
            if case .items(let batch) = event { docs.append(contentsOf: batch) }
        }
        #expect(docs.contains { doc in
            if case .string("email_1")? = doc["name"] { return true }
            return false
        })
    }

    @Test func dropIndexRemovesIt() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("email", .string("a@x.com"))])))
        _ = try await connection.write(.createIndex(collection: name, keys: .object([("email", .int(1))]), options: nil))
        _ = try await connection.write(.dropIndex(collection: name, indexName: "email_1"))

        var docs: [BerryDocument] = []
        for try await event in connection.query(.mongoListIndexes(collection: name)) {
            if case .items(let batch) = event { docs.append(contentsOf: batch) }
        }
        #expect(!docs.contains { doc in
            if case .string("email_1")? = doc["name"] { return true }
            return false
        })
    }

    @Test func renameCollectionMakesItVisibleUnderTheNewName() async throws {
        let oldName = "berry_conf_\(UUID().uuidString.prefix(8))"
        let newName = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(oldName) } }
        defer { Task { await dropCollection(newName) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: oldName, document: .object([("x", .int(1))])))
        _ = try await connection.write(.renameCollection(collection: oldName, newName: newName))

        let names = try await connection.listCollections().map(\.name)
        #expect(names.contains(newName))
        #expect(!names.contains(oldName))
    }

    @Test func dropRemovesTheCollectionEntirely() async throws {
        let name = "berry_conf_\(UUID().uuidString.prefix(8))"
        defer { Task { await dropCollection(name) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        _ = try await connection.write(.insert(collection: name, document: .object([("x", .int(1))])))
        _ = try await connection.write(.dropCollection(collection: name))

        let names = try await connection.listCollections().map(\.name)
        #expect(!names.contains(name))
    }

 // MARK: DataSourceDriver entry point

    @Test func driverConnectSucceedsAgainstAReachableServer() async throws {
        let driver = MongoDriver()
        let connection = try await driver.connect(makeConfig())
        defer { Task { await connection.close() } }
        #expect(await connection.ping())
    }

    @Test func driverConnectFailsFastAgainstAnUnreachableHost() async throws {
        let driver = MongoDriver()
        let badConfig = ConnectionConfig(driver: .mongodb, name: "test", host: "127.0.0.1", port: 1, tlsMode: .disable)
        await #expect(throws: (any Error).self) {
            _ = try await driver.connect(badConfig)
        }
    }

    /// Real SCRAM-SHA-256 rejection from genuine `mongod` — not just our own
    /// stub verifying itself — confirms the hand-rolled handshake fails
    /// closed on bad credentials instead of silently "succeeding".
    @Test func driverConnectFailsWithWrongPassword() async throws {
        let driver = MongoDriver()
        let badConfig = ConnectionConfig(
            driver: .mongodb, name: "test", host: server.host, port: server.port,
            username: server.username, password: "definitely-wrong", database: server.database, tlsMode: .disable
        )
        await #expect(throws: (any Error).self) {
            _ = try await driver.connect(badConfig)
        }
    }

    @Test func queryRejectsQdrantShapedRequests() async throws {
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            for try await _ in connection.query(.qdrantSearch(collection: "x", vector: [0.1], filter: nil, topK: 1, scoreThreshold: nil)) {}
        }
    }

 // MARK: - User management (Phase C)

    /// Real `createUser`/`usersInfo`/`dropUser` admin commands against a real
    /// `mongod` — not just our own BSON encoding verifying itself. Only
    /// asserts the test user shows up/disappears (not an exact user count):
    /// `usersInfo: 1` lists every user on the connection's working database,
    /// which here is `admin` (the container's root auth database, see
    /// `Tests/docker/compose.yml`'s `mongo` service comment) — so the
    /// existing root user is always present alongside whatever this test adds.
    @Test func userManagementCreatesListsAndDropsARealUser() async throws {
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let username = "berry_conf_user_\(UUID().uuidString.prefix(8))"

        try await connection.createUser(username: username, password: "correct-horse-battery", roles: ["readWrite"])

        let usersAfterCreate = try await connection.listUsers()
        let created = try #require(usersAfterCreate.first { $0.username == username })
        #expect(created.roles == ["readWrite"])

        try await connection.dropUser(username: username)

        let usersAfterDrop = try await connection.listUsers()
        #expect(!usersAfterDrop.contains { $0.username == username })
    }

    /// A user created with no roles must round-trip as an empty array, not
    /// crash the BSON decode or silently default to some role.
    @Test func userManagementCreatesAUserWithNoRoles() async throws {
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let username = "berry_conf_noroles_\(UUID().uuidString.prefix(8))"
        defer { Task { try? await connection.dropUser(username: username) } }

        try await connection.createUser(username: username, password: "correct-horse-battery", roles: [])

        let users = try await connection.listUsers()
        let created = try #require(users.first { $0.username == username })
        #expect(created.roles.isEmpty)
    }

    /// Dropping a user that doesn't exist is a real server-side error
    /// (`USER_NOT_FOUND`), not a silent no-op — same "surface the DB's own
    /// error" contract `SQLDialect.dropUserSQL` documents.
    @Test func userManagementDroppingAnUnknownUserFails() async throws {
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        await #expect(throws: DataSourceError.self) {
            try await connection.dropUser(username: "berry_conf_does_not_exist_\(UUID().uuidString.prefix(8))")
        }
    }
}
