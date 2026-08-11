import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBConnection — statement routing, pagination, transaction no-ops")
struct DynamoDBConnectionTests {
    /// `init` calls `client.ping()` (fail-fast, KN-06) which hits ListTables —
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

    // MARK: Transaction control — client-side no-op (docs/architecture/12 §4)

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

    /// Deterministic proof of the client-side cancel mechanism
    /// (capabilities.cancelQuery == false — "❌ chỉ hủy phía client",
    /// docs/architecture/05 §4): a stub handler sleeps briefly before
    /// answering, so if `cancelCurrentQuery()` did NOT abort the in-flight
    /// request the stream would complete successfully after the full sleep
    /// instead of throwing quickly. Deterministic (not timing-sensitive
    /// against a real server) — that's why this lives here rather than as a
    /// conformance test racing dynamodb-local, which has no PartiQL
    /// equivalent of `pg_sleep` to build a genuinely slow real query.
    ///
    /// Sleep/deadline widened from 300ms/250ms (2026-08-07): that margin was
    /// too tight for CI — observed failing in real GitHub Actions runs at
    /// 480ms and 304ms elapsed, both times against the same PASSING local
    /// runs, meaning CI's shared/lower-core runners plus Swift Testing's
    /// default cross-suite parallelism occasionally eat into the margin
    /// between "cancelled quickly" and "waited out the stub" enough to trip
    /// a deadline that close to the sleep duration itself. 1s/700ms keeps
    /// `Thread.sleep`'s stall of other concurrently-running stub-based tests
    /// short (the original concern this file's history already flagged)
    /// while giving the deadline real headroom over realistic scheduling
    /// jitter — a genuinely broken cancel would still fail clearly (~1s+,
    /// not the passing runs' typical tens of ms).
    @Test func cancelCurrentQueryAbortsAnInFlightSelect() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let connection = try await makeConnection(host: host) { request, _ in
            if Self.target(request) == "DynamoDB_20120810.ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            Thread.sleep(forTimeInterval: 1.0)
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Items": []]))
        }
        let stream = connection.execute(#"SELECT * FROM "Music""#)
        let started = ContinuousClock.now
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
        let elapsed = ContinuousClock.now - started
        #expect(threw)
        #expect(elapsed < .milliseconds(700))
    }
}
