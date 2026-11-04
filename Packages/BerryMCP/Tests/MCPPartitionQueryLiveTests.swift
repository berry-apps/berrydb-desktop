import BerryDriverKit
import BerryDriverTestKit
import BerryStore
import CryptoKit
import Foundation
import Testing

@testable import BerryCredentials
@testable import BerryDriverDynamoDB
@testable import BerryMCP

/// The partition query service end to end against a real dynamodb-local
/// from `BERRYDB_TEST_DYNAMODB` (`host:port`, see Tests/docker/compose.yml),
/// skipped when the variable is unset. The profile and the project live in
/// an in-memory store and are verified with a test access key on every
/// request, as the helper does, and sessions come from the default
/// connection factories with the real DynamoDB driver.
@Suite("MCP partition queries on dynamodb-local", .enabled(if: DynamoDBTestServer.dynamodb != nil))
struct MCPPartitionQueryLiveTests {
    @Test func aQueryReturnsItemsThroughTheHelperServices() async throws {
        let fixture = try await LiveFixture.make()
        defer { fixture.dropTable() }
        let result = try await fixture.service.run(fixture.request(partitionKey: .string("a")))
        #expect(sortKeys(result) == ["1", "2", "3"])
        #expect(result.itemCount == 3)
        #expect(result.nextCursor == nil)
        #expect(result.keySchema.partitionKey == .init(name: "pk", type: "S"))
        #expect(result.keySchema.sortKey == .init(name: "sk", type: "S"))
        #expect(result.items.first?["n"] == .number(LiveFixture.longNumber))
        #expect(result.items.first?["blob"] == .binary(LiveFixture.blob))
        // Verified against dynamodb-local 3.3.0: it reports ConsumedCapacity
        // for ReturnConsumedCapacity TOTAL, as the service does:
        // https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html
        let units = try #require(result.consumedCapacityUnits)
        #expect(units > 0)
    }

    @Test func pagesUnderATightCeilingCoverThePartitionOnce() async throws {
        let fixture = try await LiveFixture.make()
        defer { fixture.dropTable() }
        // The ceiling holds the service's metadata reserve and one and a half
        // of the largest item, so each page returns one item and the cursor
        // has to continue after an item DynamoDB already sent.
        let whole = try await fixture.service.run(fixture.request(partitionKey: .string("a")))
        let largest = try whole.items.map { try encodedSize(of: $0) }.max() ?? 0
        let ceiling = try MCPPartitionQueryService.reserve(for: whole.keySchema) + largest + largest / 2
        let service = MCPPartitionQueryService(
            coordinator: fixture.liveReads.coordinator, openBudget: fixture.liveReads.openBudget,
            slots: fixture.liveReads.slots,
            limits: { _ in
                MCPResultLimits(
                    maximumRows: 100, maximumCellBytes: 65_536, maximumSerializedBytes: ceiling,
                    maximumElapsed: .seconds(30)
                )
            }
        )

        var collected: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await service.run(fixture.request(partitionKey: .string("a"), cursor: cursor))
            pages += 1
            #expect(try MCPPartitionQueryService.encodedSize(of: page) <= ceiling)
            #expect(page.skippedItems.isEmpty)
            collected += sortKeys(page)
            cursor = page.nextCursor
        } while cursor != nil && pages < 10
        #expect(cursor == nil)
        #expect(collected == ["1", "2", "3"])
        #expect(pages > 1)
    }

    @Test func aLargeAttributeIsOmittedAndTheItemStillReturns() async throws {
        let fixture = try await LiveFixture.make()
        defer { fixture.dropTable() }
        let result = try await fixture.service.run(
            fixture.request(partitionKey: .string("a"), sortKey: MCPSortKeyInput(op: .eq, value: .string("2")))
        )
        let item = try #require(result.items.first)
        #expect(result.itemCount == 1)
        #expect(item["sk"] == .string("2"))
        #expect(item["big"] == nil)
        #expect(item["status"] == .string("closed"))
        let big: [String: DynamoDBAttributeValue] = ["big": .string(String(repeating: "x", count: 70_000))]
        #expect(result.omittedAttributes == [MCPOmittedAttribute(item: 0, name: "big", bytes: try encodedSize(of: big))])
        #expect(result.truncated)
    }

    @Test func anIndexQueryPagesWithItsOwnKeys() async throws {
        let fixture = try await LiveFixture.make()
        defer { fixture.dropTable() }
        // The digest the service binds the cursor to, for this request
        // without its cursor.
        let scope = MCPQueryCursor.Scope(
            profileID: fixture.profileID, table: fixture.table, indexName: "by_status",
            queryDigest: MCPQueryCursor.digest(of: DynamoDBPartitionQuery(
                table: fixture.table, indexName: "by_status", partitionKey: .string("closed"), sortKey: nil,
                projection: nil, limit: 1, exclusiveStartKey: nil
            ))
        )

        var collected: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await fixture.service.run(
                fixture.request(indexName: "by_status", partitionKey: .string("closed"), limit: 1, cursor: cursor)
            )
            pages += 1
            #expect(page.itemCount <= 1)
            #expect(page.keySchema.index?.partitionKey == .init(name: "status", type: "S"))
            collected += sortKeys(page)
            cursor = page.nextCursor
            if let cursor {
                // A start key into a global secondary index needs the
                // index's key and the table's, or DynamoDB refuses it:
                // https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html#DDB-Query-request-ExclusiveStartKey
                let startKey = try MCPQueryCursor.open(cursor, scope: scope)
                #expect(Set(startKey.keys) == ["pk", "sk", "status"])
            }
        } while cursor != nil && pages < 10
        #expect(cursor == nil)
        #expect(collected == ["2", "3"])
    }
}

private func sortKeys(_ result: MCPPartitionQueryResult) -> [String] {
    result.items.compactMap { item in
        if case .string(let value)? = item["sk"] { return value }
        return nil
    }
}

/// The bytes the service counts for `item`: its JSON object, encoded the
/// way the result is.
private func encodedSize(of item: [String: DynamoDBAttributeValue]) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(item).count
}

/// A fresh table `pk`/`sk` with a `by_status` index and four items, a
/// DynamoDB profile pointing at it in an in-memory store, a verified project
/// with live reads on for that profile, and the services over them.
private struct LiveFixture: Sendable {
    static let longNumber = "123456789012345678901234567890123456.78"
    static let blob = Data([0x00, 0xFF, 0x7F])
    // The credentials dynamodb-local accepts; it checks the signature's shape only.
    static let accessKeyID = "fakeAccessKeyId"
    static let secretAccessKey = "fakeSecretAccessKey"
    static let region = "us-east-1"

    let server: DynamoDBTestServer
    let table: String
    let profileID: UUID
    let liveReads: MCPLiveReadService
    let service: MCPPartitionQueryService

    func request(
        indexName: String? = nil, partitionKey: MCPKeyInput, sortKey: MCPSortKeyInput? = nil,
        limit: Int? = nil, cursor: String? = nil
    ) -> MCPPartitionQueryRequest {
        MCPPartitionQueryRequest(
            profileID: profileID, table: table, indexName: indexName, partitionKey: partitionKey,
            sortKey: sortKey, limit: limit, cursor: cursor
        )
    }

    /// Runs from a `defer`, which cannot await, so the drop is left to a
    /// detached task the test does not wait for; each table has its own name.
    func dropTable() {
        let server = server
        let table = table
        Task { _ = try? await Self.rawCall(server: server, target: "DeleteTable", body: ["TableName": table]) }
    }

    static func make() async throws -> LiveFixture {
        let server = try #require(DynamoDBTestServer.dynamodb)
        let table = "mcp_live_" + UUID().uuidString.lowercased()
        try await createTable(server: server, name: table)
        do {
            for (pk, sk, status) in [("a", "1", "open"), ("a", "2", "closed"), ("a", "3", "closed"), ("b", "1", "open")] {
                var item: [String: Any] = [
                    "pk": ["S": pk], "sk": ["S": sk], "status": ["S": status],
                    "n": ["N": longNumber], "blob": ["B": blob.base64EncodedString()],
                ]
                if pk == "a", sk == "2" { item["big"] = ["S": String(repeating: "x", count: 70_000)] }
                try await rawCall(server: server, target: "PutItem", body: ["TableName": table, "Item": item])
            }
            return try makeServices(server: server, table: table)
        } catch {
            _ = try? await rawCall(server: server, target: "DeleteTable", body: ["TableName": table])
            throw error
        }
    }

    private static func makeServices(server: DynamoDBTestServer, table: String) throws -> LiveFixture {
        let store = try BerryStore(path: ":memory:")
        // A DynamoDB profile keeps the access key ID in `username` and the
        // region in `database`; the secret comes from the credential resolver.
        let profile = ConnectionProfile(
            driverID: DriverID.dynamodb.rawValue, name: "dynamodb-local", host: server.host, port: server.port,
            username: accessKeyID, database: region, tlsMode: TLSMode.disable.rawValue
        )
        try store.save(profile)
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        let project = MCPProject(
            name: "Live", isEnabled: true, profiles: [MCPProfileAccess(profileID: profile.id, liveRead: true)]
        )
        try store.saveMCPProject(project, sealingKey: key, previousKey: nil)
        let resolver = MCPProjectResolver(
            store: store, projectID: project.id,
            keyStore: MCPAccessKeyStore(read: { keyData }, write: { _ in false }),
            credentialResolver: MCPCredentialResolver { _ in ConnectionSecrets(dbPassword: secretAccessKey) }
        )
        // The helper registers every driver with `DriverRegistry` at launch;
        // naming DynamoDB here keeps the process-wide registry untouched.
        let registries = MCPDriverRegistries(sql: { $0 == .dynamodb ? DynamoDBDriver.self : nil })
        let coordinator = MCPConnectionCoordinator(resolver: resolver, factories: MCPConnectionFactories(registries: registries))
        let liveReads = MCPLiveReadService(coordinator: coordinator)
        return LiveFixture(
            server: server, table: table, profileID: profile.id, liveReads: liveReads,
            service: MCPPartitionQueryService(sharing: liveReads)
        )
    }

    /// Table creation is not something the driver does, so fixtures go
    /// through the raw DynamoDB API.
    private static func createTable(server: DynamoDBTestServer, name: String) async throws {
        let attributes = ["pk", "sk", "status"].map { ["AttributeName": $0, "AttributeType": "S"] }
        try await rawCall(server: server, target: "CreateTable", body: [
            "TableName": name, "BillingMode": "PAY_PER_REQUEST", "AttributeDefinitions": attributes,
            "KeySchema": [["AttributeName": "pk", "KeyType": "HASH"], ["AttributeName": "sk", "KeyType": "RANGE"]],
            "GlobalSecondaryIndexes": [[
                "IndexName": "by_status",
                "KeySchema": [
                    ["AttributeName": "status", "KeyType": "HASH"], ["AttributeName": "sk", "KeyType": "RANGE"],
                ],
                "Projection": ["ProjectionType": "ALL"],
            ] as [String: Any]],
        ])
    }

    @discardableResult
    private static func rawCall(server: DynamoDBTestServer, target: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.\(target)", forHTTPHeaderField: "X-Amz-Target")
        let data = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = data
        SigV4Signer.sign(
            &request, body: data,
            credentials: .init(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey),
            region: region, service: "dynamodb"
        )
        let (response, status) = try await URLSession.shared.data(for: request)
        guard let http = status as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ConformanceFailure("\(target) failed: \(String(data: response, encoding: .utf8) ?? "")")
        }
        return response
    }
}
