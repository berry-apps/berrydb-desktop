import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBConnection — partition queries")
struct DynamoDBPartitionQueryConnectionTests {
    /// `init` pings with ListTables, so every handler below answers that target too.
    private func makeConnection(
        host: String, handler: @escaping DynamoDBStubURLProtocol.Handler
    ) async throws -> DynamoDBConnection {
        let session = DynamoDBStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test", host: host, port: 8000, tlsMode: .disable,
            awsAccessKeyID: "fakeAccessKeyId", awsSecretAccessKey: "fakeSecretAccessKey", awsRegion: "us-east-1"
        )
        return try await DynamoDBConnection(config: config, session: session)
    }

    private static func target(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
    }

    private static func newHost() -> String { "dynamo-\(UUID().uuidString)".lowercased() }

    private static func ok(_ request: URLRequest, _ json: Any) -> (HTTPURLResponse, Data) {
        (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(json))
    }

    private static func described(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        ok(request, ["Table": DynamoDBPartitionQueryTests.describedOrders])
    }

    private static var lastKey: [String: Any] { ["pk": ["S": "a"], "sk": ["S": "1"]] }

    private static let query = DynamoDBPartitionQuery(
        table: "orders", indexName: nil, partitionKey: .string("a"), sortKey: nil,
        projection: nil, limit: 10, exclusiveStartKey: nil
    )

    @Test func afterConnectingOnlyDescribeTableAndQueryAreSent() async throws {
        let host = Self.newHost()
        let queryBodies = Box<[[String: Any]]>([])
        let connection = try await makeConnection(host: host) { request, body in
            switch Self.target(request) {
            case "DynamoDB_20120810.DescribeTable":
                return Self.described(request)
            case "DynamoDB_20120810.Query":
                queryBodies.mutate { $0.append(dynamoStubBody(body)) }
                return Self.ok(request, [
                    "Items": [["pk": ["S": "a"], "sk": ["S": "1"]]], "Count": 1, "ScannedCount": 1,
                ])
            default:
                return Self.ok(request, ["TableNames": []])
            }
        }
        let schema = try await connection.keySchema(of: "orders")
        let page = try await connection.queryPartition(Self.query)

        let requests = DynamoDBStubURLProtocol.requests(for: host)
        #expect(requests.first.map(Self.target) == "DynamoDB_20120810.ListTables")
        let targets = requests.map(Self.target).dropFirst()
        #expect(Set(targets) == ["DynamoDB_20120810.DescribeTable", "DynamoDB_20120810.Query"])
        #expect(schema.partitionKey.name == "pk")
        #expect(page.items.count == 1)

        let body = try #require(queryBodies.wrappedValue.first)
        #expect(body["ReturnConsumedCapacity"] as? String == "TOTAL")
        #expect(body["ScanIndexForward"] as? Bool == true)
    }

    @Test func theKeySchemaIsDescribedOncePerTable() async throws {
        let host = Self.newHost()
        let connection = try await makeConnection(host: host) { request, _ in
            switch Self.target(request) {
            case "DynamoDB_20120810.DescribeTable": return Self.described(request)
            case "DynamoDB_20120810.Query": return Self.ok(request, ["Items": [], "ScannedCount": 0])
            default: return Self.ok(request, ["TableNames": []])
            }
        }
        _ = try await connection.keySchema(of: "orders")
        _ = try await connection.queryPartition(Self.query)
        _ = try await connection.queryPartition(Self.query)
        #expect(DynamoDBStubURLProtocol.requests(for: host).map(Self.target) == [
            "DynamoDB_20120810.ListTables", "DynamoDB_20120810.DescribeTable",
            "DynamoDB_20120810.Query", "DynamoDB_20120810.Query",
        ])
    }

    @Test func queryPartitionPassesTheExclusiveStartKeyThrough() async throws {
        let host = Self.newHost()
        let queryBodies = Box<[[String: Any]]>([])
        let connection = try await makeConnection(host: host) { request, body in
            switch Self.target(request) {
            case "DynamoDB_20120810.DescribeTable":
                return Self.described(request)
            case "DynamoDB_20120810.Query":
                queryBodies.mutate { $0.append(dynamoStubBody(body)) }
                if queryBodies.wrappedValue.count == 1 {
                    return Self.ok(request, [
                        "Items": [["pk": ["S": "a"], "sk": ["S": "1"]]], "LastEvaluatedKey": Self.lastKey, "ScannedCount": 1,
                    ])
                }
                return Self.ok(request, ["Items": [], "ScannedCount": 0])
            default:
                return Self.ok(request, ["TableNames": []])
            }
        }
        let first = try await connection.queryPartition(Self.query)
        let start = try #require(first.lastEvaluatedKey)
        _ = try await connection.queryPartition(DynamoDBPartitionQuery(
            table: "orders", indexName: nil, partitionKey: .string("a"), sortKey: nil,
            projection: nil, limit: 10, exclusiveStartKey: start
        ))

        let queries = queryBodies.wrappedValue
        #expect(queries.count == 2)
        #expect(queries[0]["ExclusiveStartKey"] == nil)
        let sent = try #require(queries[1]["ExclusiveStartKey"] as? [String: Any])
        #expect(NSDictionary(dictionary: sent).isEqual(to: Self.lastKey))
    }

    @Test func aThrottledQueryKeepsItsExceptionName() async throws {
        let host = Self.newHost()
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.DescribeTable" { return Self.described(request) }
            if Self.target(request) == "DynamoDB_20120810.Query" {
                let json = [
                    "__type": "com.amazonaws.dynamodb.v20120810#ProvisionedThroughputExceededException",
                    "Message": "Slow down",
                ]
                return (dynamoStubResponse(request.url!, status: 400), dynamoStubJSON(json))
            }
            return Self.ok(request, ["TableNames": []])
        }
        do {
            _ = try await connection.queryPartition(Self.query)
            Issue.record("a throttled query must throw")
        } catch let DriverError.queryFailed(message, code) {
            #expect(message == "ProvisionedThroughputExceededException: Slow down")
            #expect(code == 400)
        } catch {
            Issue.record("expected DriverError.queryFailed, got \(error)")
        }
    }

    /// Same shape as `DynamoDBConnectionTests.cancelCurrentQueryAbortsAnInFlightSelect`:
    /// the request is held open until the cancel arrives, and the time limit only
    /// turns a cancel that does nothing into a failure instead of a hang.
    @Test(.timeLimit(.minutes(1)))
    func cancellingAbortsAnInFlightQuery() async throws {
        let (started, signalStarted) = AsyncStream.makeStream(of: Void.self)
        let (stopped, signalStopped) = AsyncStream.makeStream(of: Void.self)
        let host = Self.newHost()
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.DescribeTable" { return Self.described(request) }
            if Self.target(request) == "DynamoDB_20120810.Query" {
                signalStarted.yield()
                throw DynamoDBStubURLProtocol.Suspend { signalStopped.yield() }
            }
            return Self.ok(request, ["TableNames": []])
        }
        Task {
            for await _ in started { break }
            connection.cancelCurrentQuery()
        }
        do {
            _ = try await connection.queryPartition(Self.query)
            Issue.record("the query finished although its request was never answered")
        } catch DriverError.cancelled {
        } catch {
            Issue.record("cancelling an in-flight query must surface as DriverError.cancelled, got \(error)")
        }
        for await _ in stopped { break }
    }

    @Test func aClosedConnectionRefusesAQuery() async throws {
        let host = Self.newHost()
        let connection = try await makeConnection(host: host) { request, _ in
            Self.target(request) == "DynamoDB_20120810.DescribeTable" ? Self.described(request) : Self.ok(request, ["TableNames": []])
        }
        _ = try await connection.keySchema(of: "orders")
        await connection.close()
        do {
            _ = try await connection.queryPartition(Self.query)
            Issue.record("a closed connection must refuse a query")
        } catch DriverError.notConnected {
        } catch {
            Issue.record("expected DriverError.notConnected, got \(error)")
        }
        do {
            _ = try await connection.keySchema(of: "orders")
            Issue.record("a closed connection must refuse a key schema read")
        } catch DriverError.notConnected {
        } catch {
            Issue.record("expected DriverError.notConnected, got \(error)")
        }
        #expect(DynamoDBStubURLProtocol.requests(for: host).map(Self.target)
            == ["DynamoDB_20120810.ListTables", "DynamoDB_20120810.DescribeTable"])
    }

    /// The partition query is the only new wire call, so its code must not name any target of its own;
    /// the client's `query(_:)` is the single sender of `Query`.
    @Test func partitionQueryCodeSendsOnlyTheQueryTarget() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let queryCode = try String(contentsOf: sources.appendingPathComponent("DynamoDBPartitionQuery.swift"), encoding: .utf8)
        let client = try String(contentsOf: sources.appendingPathComponent("DynamoDBHTTPClient.swift"), encoding: .utf8)
        #expect(queryCode.components(separatedBy: "DynamoDB_20120810.").count == 1)
        #expect(client.components(separatedBy: "DynamoDB_20120810.Query").count == 2)
    }
}
