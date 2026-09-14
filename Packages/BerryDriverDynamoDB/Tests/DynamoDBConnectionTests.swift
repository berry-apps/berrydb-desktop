import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBConnection — statement routing, pagination, transaction no-ops")
struct DynamoDBConnectionTests {
 /// `init` calls `client.ping()` (fail-fast) which hits ListTables
    /// every stub handler below must answer that target too.
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

    private func drain(
        _ stream: AsyncThrowingStream<ResultEvent, Error>
    ) async throws -> (columns: [ColumnMeta], rows: [[BerryValue]], stats: QueryStats?) {
        var columns: [ColumnMeta] = []
        var rows: [[BerryValue]] = []
        var stats: QueryStats?
        for try await event in stream {
            switch event {
            case .columns(let c): columns = c
            case .rows(let batch): rows += batch
            case .complete(let s): stats = s
            }
        }
        return (columns, rows, stats)
    }

    private static func target(_ request: URLRequest) -> String {
        request.value(forHTTPHeaderField: "X-Amz-Target") ?? ""
    }

 // MARK: Transaction control — client-side no-op

    @Test func beginCommitRollbackCompleteWithoutAnyNetworkCall() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let executeStatementCalls = Box(0)
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.ExecuteStatement" {
                executeStatementCalls.mutate { $0 += 1 }
            }
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
        }
        for sql in ["BEGIN", "COMMIT", "ROLLBACK"] {
            let result = try await drain(connection.execute(sql))
            #expect(result.rows.isEmpty)
            #expect(result.stats != nil)
        }
        #expect(executeStatementCalls.wrappedValue == 0)
    }

    // MARK: SELECT — pagination + column establishment from first non-empty page

    @Test func selectFollowsNextTokenAcrossPagesAndStreamsAllRows() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let page = Box(0)
        let connection = try await makeConnection(host: host) { request, body in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            page.mutate { $0 += 1 }
            switch page.wrappedValue {
            case 1:
                let response: [String: Any] = [
                    "Items": [["Artist": ["S": "Band1"]], ["Artist": ["S": "Band2"]]],
                    "NextToken": "tok-2",
                ]
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(response))
            case 2:
                #expect(dynamoStubBody(body)["NextToken"] as? String == "tok-2")
                let response: [String: Any] = ["Items": [["Artist": ["S": "Band3"]]]]
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(response))
            default:
                Issue.record("unexpected extra page fetch")
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
            }
        }
        let result = try await drain(connection.execute(#"SELECT * FROM "Music""#))
        #expect(result.columns.map(\.name) == ["Artist"])
        #expect(result.rows == [[.text("Band1")], [.text("Band2")], [.text("Band3")]])
        #expect(page.wrappedValue == 2)
    }

    @Test func selectSkipsEmptyPagesWhenEstablishingColumns() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let page = Box(0)
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            page.mutate { $0 += 1 }
            if page.wrappedValue == 1 {
                // Evaluated up to the page limit but everything got filtered out — still a NextToken.
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": [], "NextToken": "tok"]))
            }
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": [["X": ["N": "1"]]]]))
        }
        let result = try await drain(connection.execute(#"SELECT * FROM "T" WHERE "Y" = 1"#))
        #expect(result.columns.map(\.name) == ["X"])
        #expect(result.rows == [[.int(1)]])
    }

    // MARK: Write path — single call, INSERT rewritten first

    @Test func insertIsRewrittenToTupleFormBeforeSending() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let sentStatement = Box<String?>(nil)
        let connection = try await makeConnection(host: host) { request, body in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            sentStatement.mutate { $0 = dynamoStubBody(body)["Statement"] as? String }
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        let sql = #"INSERT INTO "Music" ("Artist", "SongTitle") VALUES ('Acme Band', 'PartiQL Rocks')"#
        let result = try await drain(connection.execute(sql))
        #expect(sentStatement.wrappedValue == #"INSERT INTO "Music" VALUE {'Artist': 'Acme Band', 'SongTitle': 'PartiQL Rocks'}"#)
        #expect(result.stats?.rowsAffected == nil)
    }

    @Test func updateAndDeletePassThroughUnchanged() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let sentStatements = Box<[String]>([])
        let connection = try await makeConnection(host: host) { request, body in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            if let statement = dynamoStubBody(body)["Statement"] as? String {
                sentStatements.mutate { $0.append(statement) }
            }
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        let update = #"UPDATE "Music" SET "Awards" = 1 WHERE "Artist" = 'Acme Band' AND "SongTitle" = 'PartiQL Rocks'"#
        let delete = #"DELETE FROM "Music" WHERE "Artist" = 'Acme Band' AND "SongTitle" = 'PartiQL Rocks'"#
        _ = try await drain(connection.execute(update))
        _ = try await drain(connection.execute(delete))
        #expect(sentStatements.wrappedValue == [update, delete])
    }

    // MARK: Control surface

    @Test func setDatabaseIsUnsupported() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let connection = try await makeConnection(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
        }
        await #expect(throws: DriverError.self) {
            try await connection.setDatabase("anything")
        }
    }

    @Test func pingFalseAfterClose() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let connection = try await makeConnection(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
        }
        #expect(await connection.ping())
        await connection.close()
        #expect(await connection.ping() == false)
    }

    @Test func connectThrowsWhenPingFails() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let session = DynamoDBStubURLProtocol.session(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 400), dynamoStubJSON(["__type": "UnrecognizedClientException"]))
        }
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test", host: host, port: 8000, tlsMode: .disable,
            awsAccessKeyID: "bad", awsSecretAccessKey: "bad", awsRegion: "us-east-1"
        )
        await #expect(throws: DriverError.self) {
            _ = try await DynamoDBConnection(config: config, session: session)
        }
    }
    /// Cancellation must abort the in-flight request rather than wait it out.
    ///
    /// This used to assert a wall-clock deadline, and that deadline kept
    /// failing on CI: a shared runner measured 843 ms against a 700 ms bound
    /// while the stub slept 1 s, so cancellation had worked and only its
    /// propagation was slow. The bound could not simply be raised, because it
    /// has to stay under the stub's sleep to mean anything, and the sleep
    /// cannot be lengthened either — `Thread.sleep` blocks a stub thread and
    /// stalls every other test running in parallel, which is the compromise
    /// the previous 1 s/700 ms pairing was already navigating.
    ///
    /// So the timing assertion is gone. The stub records when it finishes
    /// sleeping, and the test asserts the stream threw *before* that happened.
    /// That is the property the deadline was standing in for, stated directly
    /// and without a clock: a cancel that silently waited out the request
    /// fails, however loaded the machine is.
    @Test func cancelCurrentQueryAbortsAnInFlightSelect() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = false
            func raise() { lock.lock(); raised = true; lock.unlock() }
            var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
        }
        let stubFinished = Flag()

        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            Thread.sleep(forTimeInterval: 1.0)
            stubFinished.raise()
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        let stream = connection.execute(#"SELECT * FROM "Music""#)
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            connection.cancelCurrentQuery()
        }
        var threw = false
        do {
            for try await _ in stream {}
        } catch {
            threw = true
        }
        #expect(threw, "cancelling an in-flight query must surface as an error")
        #expect(!stubFinished.isRaised, "cancel waited out the request instead of aborting it")
    }
}
