import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

/// Runs against a real dynamodb-local from `BERRYDB_TEST_DYNAMODB` (`host:port`,
/// see Tests/docker/compose.yml); skipped when the env var is unset.
@Suite("DynamoDB partition query conformance", .enabled(if: DynamoDBTestServer.dynamodb != nil))
struct DynamoDBPartitionQueryConformanceTests {
    private var server: DynamoDBTestServer { DynamoDBTestServer.dynamodb! }
    private var fixtures: DynamoDBLiveFixtures { DynamoDBLiveFixtures(server: server) }

    private static let longNumber = "123456789012345678901234567890123456.78"
    private static let blob = Data([0x00, 0xFF, 0x7F])

    private func makeConnection() async throws -> DynamoDBConnection {
        try await DynamoDBConnection(config: ConnectionConfig(
            driver: .dynamodb, name: "test", host: server.host, port: server.port, tlsMode: .disable,
            awsAccessKeyID: "fakeAccessKeyId", awsSecretAccessKey: "fakeSecretAccessKey", awsRegion: "us-east-1"
        ))
    }

    /// A fresh table `pk`/`sk` with a `by_status` index, and four items. `big`
    /// (70,000 bytes) sits on ("a", "2") only.
    private func makeTable() async throws -> String {
        let name = "mcp_query_" + UUID().uuidString.lowercased()
        try await fixtures.createTable(
            name: name, partitionKey: "pk", sortKey: "sk",
            globalSecondaryIndex: .init(name: "by_status", partitionKey: "status", sortKey: "sk")
        )
        for (pk, sk, status) in [("a", "1", "open"), ("a", "2", "closed"), ("a", "3", "closed"), ("b", "1", "open")] {
            var item: [String: Any] = [
                "pk": ["S": pk], "sk": ["S": sk], "status": ["S": status],
                "n": ["N": Self.longNumber], "blob": ["B": Self.blob.base64EncodedString()],
            ]
            if pk == "a", sk == "2" { item["big"] = ["S": String(repeating: "x", count: 70_000)] }
            try await fixtures.putItem(table: name, item: item)
        }
        return name
    }

    private func query(
        _ table: String, index: String? = nil, partition: DynamoDBKeyValue = .string("a"),
        sort: DynamoDBSortKeyCondition? = nil, projection: [String]? = nil, limit: Int = 100,
        start: [String: DynamoDBAttributeValue]? = nil
    ) -> DynamoDBPartitionQuery {
        DynamoDBPartitionQuery(
            table: table, indexName: index, partitionKey: partition, sortKey: sort,
            projection: projection, limit: limit, exclusiveStartKey: start
        )
    }

    private func sortKeys(_ page: DynamoDBQueryPage) -> [String] {
        page.items.compactMap { item in
            if case .string(let value)? = item["sk"] { return value }
            return nil
        }
    }

    @Test func queriesAPartitionInSortKeyOrder() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let page = try await connection.queryPartition(
            query(table, sort: .between(.string("1"), .string("2")))
        )
        #expect(sortKeys(page) == ["1", "2"])
        #expect(page.lastEvaluatedKey == nil)
    }

    @Test func beginsWithAndIndexQueriesWork() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let page = try await connection.queryPartition(
            query(table, index: "by_status", partition: .string("open"), sort: .beginsWith(.string("1")))
        )
        #expect(sortKeys(page) == ["1", "1"])
        let partitions = page.items.compactMap { item -> String? in
            if case .string(let value)? = item["pk"] { return value }
            return nil
        }
        #expect(Set(partitions) == ["a", "b"])
    }

    @Test func numbersKeepThirtyEightDigitsAndBinaryRoundTrips() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let page = try await connection.queryPartition(query(table, sort: .equal(.string("1"))))
        let item = try #require(page.items.first)
        #expect(item["n"] == .number(Self.longNumber))
        #expect(item["blob"] == .binary(Self.blob))
    }

    @Test func limitPagesWithoutLossOrRepeat() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        var collected: [String] = []
        var start: [String: DynamoDBAttributeValue]?
        for _ in 0..<10 {
            let page = try await connection.queryPartition(query(table, limit: 1, start: start))
            collected += sortKeys(page)
            start = page.lastEvaluatedKey
            if start == nil { break }
        }
        #expect(start == nil)
        #expect(collected == ["1", "2", "3"])
    }

    @Test func projectionOmitsOtherAttributesButKeepsKeys() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let page = try await connection.queryPartition(query(table, projection: ["n"]))
        #expect(page.items.count == 3)
        for item in page.items {
            #expect(Set(item.keys) == ["pk", "sk", "n"])
        }
    }

    @Test func consumedCapacityIsReportedWhenTheServiceReturnsIt() async throws {
        let table = try await makeTable()
        defer { Task { await fixtures.deleteTable(name: table) } }
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let page = try await connection.queryPartition(query(table))
        #expect(page.scannedCount == 3)
        // Verified against dynamodb-local 3.3.0: it reports ConsumedCapacity for
        // ReturnConsumedCapacity TOTAL (9.0 units here, dominated by the
        // 70,000-byte item), as the service does:
        // https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html
        let units = try #require(page.consumedCapacityUnits)
        #expect(units > 0)
    }
}
