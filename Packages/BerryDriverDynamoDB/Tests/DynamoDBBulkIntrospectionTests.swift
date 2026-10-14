import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

/// Records how many stubbed requests are in flight at once. A stub handler
/// cannot block to measure this, because every handler in the process shares
/// one thread, so a request counts from its handler call until just before
/// its delayed answer is handed over. Both ends fall inside the time the
/// caller waits for that request, so the count never exceeds what the caller
/// has in flight.
private final class PeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var highest = 0

    func enter() {
        lock.lock(); defer { lock.unlock() }
        current += 1
        highest = max(highest, current)
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        current -= 1
    }

    var inFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var peak: Int {
        lock.lock(); defer { lock.unlock() }
        return highest
    }
}

@Suite("DynamoDBIntrospector — bulk table details")
struct DynamoDBBulkIntrospectionTests {
    private let names = ["Albums", "Artists", "Genres", "Playlists", "Tracks", "Users"]

    private func makeIntrospector(
        host: String, handler: @escaping DynamoDBStubURLProtocol.Handler
    ) throws -> DynamoDBIntrospector {
        let session = DynamoDBStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test", host: host, port: 8000, tlsMode: .disable,
            awsAccessKeyID: "fake", awsSecretAccessKey: "fake", awsRegion: "us-east-1"
        )
        let client = try DynamoDBHTTPClient(config: config, session: session)
        return DynamoDBIntrospector(client: client)
    }

    private func newHost() -> String { "dynamo-\(UUID().uuidString)".lowercased() }

    /// Routes `ListTables` to a fixed listing and each `DescribeTable` to
    /// `describe` with the table name from the request body. The listing is
    /// always every table, including one whose describe later fails, because a
    /// listing read before a table vanishes still names it; a batch that
    /// consulted a fresh listing to excuse a failure would be wrongly excused
    /// here.
    private func scripted(
        describe: @escaping @Sendable (URLRequest, String) throws -> (HTTPURLResponse, Data)
    ) -> DynamoDBStubURLProtocol.Handler {
        let listing = names
        return { request, body in
            if request.value(forHTTPHeaderField: "X-Amz-Target")?.hasSuffix("ListTables") == true {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": listing]))
            }
            return try describe(request, dynamoStubBody(body)["TableName"] as? String ?? "")
        }
    }

    /// One partition key named after the table, so a detail that came back
    /// attached to the wrong ref is visible in its columns.
    private func describeBody(for table: String) -> Data {
        dynamoStubJSON([
            "Table": [
                "TableName": table,
                "KeySchema": [["AttributeName": "\(table)Id", "KeyType": "HASH"]],
                "AttributeDefinitions": [["AttributeName": "\(table)Id", "AttributeType": "S"]],
            ] as [String: Any],
        ])
    }

    private func errorBody(type: String) -> Data {
        dynamoStubJSON([
            "__type": "com.amazonaws.dynamodb.v20120810#\(type)",
            "message": "stubbed \(type)",
        ])
    }

    private func refs(_ tables: [String]) -> [TableRef] { tables.map { TableRef(name: $0) } }

    @Test func describesEveryTableInInputOrderWithAtMostFourInFlight() async throws {
        let flight = PeakCounter()
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            flight.enter()
            throw DynamoDBStubURLProtocol.Delayed(
                delay: 0.05,
                response: dynamoStubResponse(request.url!, status: 200),
                data: describeBody(for: table),
                beforeAnswer: { flight.leave() }
            )
        })

        let details = try await introspector.tableDetails(refs(names))

        #expect(details.map(\.ref.name) == names)
        #expect(details.map { $0.columns.map(\.name) } == names.map { ["\($0)Id"] })
        #expect(flight.peak <= 4)
        #expect(flight.peak >= 2)
    }

    /// A request leaves the count before its caller can see the answer. A
    /// count that dropped only after the answer was handed over could lag a
    /// caller that already went on to start its next request, and so read one
    /// request more in flight than there is. The pause stands for the
    /// answering thread being descheduled at that point.
    @Test func aRequestLeavesTheCountBeforeItsCallerSeesTheAnswer() async throws {
        let flight = PeakCounter()
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            flight.enter()
            throw DynamoDBStubURLProtocol.Delayed(
                delay: 0,
                response: dynamoStubResponse(request.url!, status: 200),
                data: describeBody(for: table),
                beforeAnswer: {
                    Thread.sleep(forTimeInterval: 0.05)
                    flight.leave()
                }
            )
        })

        _ = try await introspector.tableDetail(TableRef(name: "Albums"))

        #expect(flight.inFlight == 0)
    }

    @Test func skipsATableThatVanishedAfterListing() async throws {
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            if table == "Genres" {
                return (dynamoStubResponse(request.url!, status: 400), errorBody(type: "ResourceNotFoundException"))
            }
            return (dynamoStubResponse(request.url!, status: 200), describeBody(for: table))
        })

        let details = try await introspector.tableDetails(refs(names))

        #expect(details.map(\.ref.name) == ["Albums", "Artists", "Playlists", "Tracks", "Users"])
    }

    @Test(arguments: [
        (type: "ProvisionedThroughputExceededException", status: 400),
        (type: "ThrottlingException", status: 400),
        (type: "RequestLimitExceeded", status: 400),
        (type: "", status: 429),
    ])
    func retriesAThrottledDescribe(throttle: (type: String, status: Int)) async throws {
        let attempts = Box<[String: Int]>([:])
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            var attempt = 0
            attempts.mutate { counts in
                counts[table, default: 0] += 1
                attempt = counts[table] ?? 0
            }
            if table == "Tracks", attempt <= 2 {
                let failure = throttle.type.isEmpty ? dynamoStubJSON([:]) : errorBody(type: throttle.type)
                return (dynamoStubResponse(request.url!, status: throttle.status), failure)
            }
            return (dynamoStubResponse(request.url!, status: 200), describeBody(for: table))
        })

        let details = try await introspector.tableDetails(refs(names))

        #expect(details.map(\.ref.name) == names)
        #expect(attempts.wrappedValue["Tracks"] == 3)
        #expect(attempts.wrappedValue["Albums"] == 1)
    }

    @Test func givesUpOnAPersistentlyThrottledTableAfterThreeRetries() async throws {
        let attempts = Box<[String: Int]>([:])
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            attempts.mutate { $0[table, default: 0] += 1 }
            if table == "Tracks" {
                return (dynamoStubResponse(request.url!, status: 400), errorBody(type: "ThrottlingException"))
            }
            return (dynamoStubResponse(request.url!, status: 200), describeBody(for: table))
        })

        do {
            _ = try await introspector.tableDetails(refs(names))
            Issue.record("a table that stays throttled must fail the batch")
        } catch let error as DriverError {
            guard case .queryFailed(let message, _) = error else {
                Issue.record("unexpected driver error \(error)")
                return
            }
            #expect(message.hasPrefix("ThrottlingException:"))
        }
        #expect(attempts.wrappedValue["Tracks"] == 4)
    }

    @Test func doesNotRetryAnErrorThatIsNotThrottling() async throws {
        let attempts = Box<[String: Int]>([:])
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            attempts.mutate { $0[table, default: 0] += 1 }
            if table == "Genres" {
                return (dynamoStubResponse(request.url!, status: 400), errorBody(type: "AccessDeniedException"))
            }
            return (dynamoStubResponse(request.url!, status: 200), describeBody(for: table))
        })

        do {
            _ = try await introspector.tableDetails(refs(names))
            Issue.record("an access error must fail the batch")
        } catch let error as DriverError {
            guard case .queryFailed(let message, _) = error else {
                Issue.record("unexpected driver error \(error)")
                return
            }
            #expect(message.hasPrefix("AccessDeniedException:"))
        }
        #expect(attempts.wrappedValue["Genres"] == 1)
    }

    @Test func cancellingTheCallerStopsTheBatchWithACancellationError() async throws {
        let started = Box(0)
        let introspector = try makeIntrospector(host: newHost(), handler: scripted { [self] request, table in
            started.mutate { $0 += 1 }
            throw DynamoDBStubURLProtocol.Delayed(
                delay: 0.5,
                response: dynamoStubResponse(request.url!, status: 200),
                data: describeBody(for: table),
                beforeAnswer: {}
            )
        })
        let manyTables = (0..<12).map { "Table\($0)" }

        let task = Task { try await introspector.tableDetails(refs(manyTables)) }
        let deadline = Date().addingTimeInterval(5)
        while started.wrappedValue == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()

        switch await task.result {
        case .success:
            Issue.record("a cancelled batch must not return details")
        case .failure(let error):
            #expect(error is CancellationError)
        }
        #expect(started.wrappedValue <= 4)
    }

    @Test func objectSummariesListEveryTableWithoutAFingerprint() async throws {
        let introspector = try makeIntrospector(host: newHost()) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": ["Music", "Users"]]))
        }

        let summaries = try await introspector.objectSummaries(scope: .schemas(["ignored"]))

        #expect(summaries == [
            SchemaObjectSummary(ref: TableRef(name: "Music"), kind: .table, fingerprint: nil),
            SchemaObjectSummary(ref: TableRef(name: "Users"), kind: .table, fingerprint: nil),
        ])
        #expect(try await introspector.schemaVersionToken(scope: .allUserSchemas) == nil)
        #expect(introspector.bulkIntrospection == false)
    }

    @Test func foreignKeysAreEmptyAndCostNoRequests() async throws {
        let host = newHost()
        let introspector = try makeIntrospector(host: host, handler: scripted { [self] request, table in
            (dynamoStubResponse(request.url!, status: 200), describeBody(for: table))
        })

        let relations = try await introspector.foreignKeys(scope: .allUserSchemas)

        #expect(relations.isEmpty)
        #expect(DynamoDBStubURLProtocol.requests(for: host).isEmpty)
    }
}
