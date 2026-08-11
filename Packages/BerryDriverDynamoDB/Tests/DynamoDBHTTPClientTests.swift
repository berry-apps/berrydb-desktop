import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBHTTPClient — request signing, target headers, response parsing, error mapping")
struct DynamoDBHTTPClientTests {
    private func makeClient(
        host: String, port: Int = 8000, handler: @escaping DynamoDBStubURLProtocol.Handler
    ) throws -> DynamoDBHTTPClient {
        let session = DynamoDBStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test", host: host, port: port, tlsMode: .disable,
            awsAccessKeyID: "fakeAccessKeyId", awsSecretAccessKey: "fakeSecretAccessKey", awsRegion: "us-east-1"
        )
        return try DynamoDBHTTPClient(config: config, session: session)
    }

    // MARK: Request shape

    @Test func executeStatementSendsSignedRequestWithCorrectTarget() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request, body in
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "DynamoDB_20120810.ExecuteStatement")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-amz-json-1.0")
            #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
            let json = dynamoStubBody(body)
            #expect(json["Statement"] as? String == #"SELECT * FROM "Music""#)
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        let (items, nextToken) = try await client.executeStatement(
            #"SELECT * FROM "Music""#, nextToken: nil, limit: nil
        )
        #expect(items.isEmpty)
        #expect(nextToken == nil)
    }

    @Test func executeStatementIncludesNextTokenAndLimitWhenGiven() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request, body in
            let json = dynamoStubBody(body)
            #expect(json["NextToken"] as? String == "page-2-token")
            #expect(json["Limit"] as? Int == 500)
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        _ = try await client.executeStatement("SELECT * FROM \"T\"", nextToken: "page-2-token", limit: 500)
    }

    @Test func executeStatementParsesItemsAndNextToken() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request, _ in
            let body: [String: Any] = [
                "Items": [["Artist": ["S": "Acme"]]],
                "NextToken": "abc123",
            ]
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(body))
        }
        let (items, nextToken) = try await client.executeStatement("SELECT * FROM \"T\"", nextToken: nil, limit: nil)
        #expect(items.count == 1)
        #expect(nextToken == "abc123")
    }

    @Test func listTablesFollowsLastEvaluatedTableNamePagination() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let callCount = Box(0)
        let client = try makeClient(host: host) { request, body in
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "DynamoDB_20120810.ListTables")
            callCount.mutate { $0 += 1 }
            let json = dynamoStubBody(body)
            if json["ExclusiveStartTableName"] == nil {
                return (
                    dynamoStubResponse(request.url!, status: 200),
                    dynamoStubJSON(["TableNames": ["A"], "LastEvaluatedTableName": "A"])
                )
            }
            #expect(json["ExclusiveStartTableName"] as? String == "A")
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": ["B"]]))
        }
        let names = try await client.listTables()
        #expect(names == ["A", "B"])
        #expect(callCount.wrappedValue == 2)
    }

    @Test func describeTableReturnsTheTableDictionary() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request, body in
            #expect(request.value(forHTTPHeaderField: "X-Amz-Target") == "DynamoDB_20120810.DescribeTable")
            #expect(dynamoStubBody(body)["TableName"] as? String == "Music")
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": ["TableName": "Music"]]))
        }
        let table = try await client.describeTable(name: "Music")
        #expect(table["TableName"] as? String == "Music")
    }

    // MARK: Error mapping — DynamoDB's JSON-protocol error shape, verified against dynamodb-local:
    // {"__type": "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException", "Message": "..."}

    @Test func mapsDynamoDBExceptionTypeAndMessage() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { request, _ in
            let body: [String: Any] = [
                "__type": "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException",
                "Message": "Cannot do operations on a non-existent table",
            ]
            return (dynamoStubResponse(request.url!, status: 400), dynamoStubJSON(body))
        }
        do {
            _ = try await client.executeStatement("SELECT * FROM \"Ghost\"", nextToken: nil, limit: nil)
            Issue.record("expected throw")
        } catch let DriverError.queryFailed(message, code) {
            #expect(message.contains("ResourceNotFoundException"))
            #expect(message.contains("non-existent table"))
            #expect(code == 400)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func networkFailureMapsToConnectionFailed() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { _, _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await client.listTables()
            Issue.record("expected throw")
        } catch DriverError.connectionFailed {
            // expected
        } catch {
            Issue.record("expected .connectionFailed, got \(error)")
        }
    }

    @Test func cancelledRequestMapsToCancelled() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let client = try makeClient(host: host) { _, _ in throw URLError(.cancelled) }
        do {
            _ = try await client.listTables()
            Issue.record("expected throw")
        } catch DriverError.cancelled {
            // expected
        } catch {
            Issue.record("expected .cancelled, got \(error)")
        }
    }

    // MARK: Endpoint construction

    @Test func explicitHostBuildsLocalEndpoint() throws {
        let client = try makeClient(host: "127.0.0.1", port: 18000) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON([:]))
        }
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:18000")
    }

    @Test func missingHostDerivesRealAWSEndpointFromRegion() throws {
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test",
            awsAccessKeyID: "AKIDEXAMPLE", awsSecretAccessKey: "secret", awsRegion: "eu-west-1"
        )
        let client = try DynamoDBHTTPClient(config: config, session: URLSession(configuration: .ephemeral))
        #expect(client.baseURL.absoluteString == "https://dynamodb.eu-west-1.amazonaws.com")
    }

    @Test func missingCredentialsThrowsConnectionFailed() {
        let config = ConnectionConfig(driver: .dynamodb, name: "test", host: "127.0.0.1", port: 8000)
        #expect(throws: DriverError.self) {
            _ = try DynamoDBHTTPClient(config: config, session: URLSession(configuration: .ephemeral))
        }
    }

    // MARK: ping

    @Test func pingTrueOnSuccessFalseOnFailure() async throws {
        let hostOK = "dynamo-\(UUID().uuidString)".lowercased()
        let clientOK = try makeClient(host: hostOK) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
        }
        #expect(await clientOK.ping() == true)

        let hostBad = "dynamo-\(UUID().uuidString)".lowercased()
        let clientBad = try makeClient(host: hostBad) { request, _ in
            (dynamoStubResponse(request.url!, status: 500), dynamoStubJSON(["__type": "InternalServerError"]))
        }
        #expect(await clientBad.ping() == false)
    }
}
