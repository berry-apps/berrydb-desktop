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

// MARK: - Native fallback when IAM denies dynamodb:PartiQL*

extension DynamoDBConnectionTests {
    typealias Call = (target: String, body: [String: Any])

    static func newHost() -> String { "dynamo-\(UUID().uuidString)".lowercased() }

    /// Answers ListTables (the init ping) itself. Records every other call by
    /// short target name ("ExecuteStatement", "Scan", …) and lets the test
    /// choose each response.
    func makeRecordingConnection(
        respond: @escaping @Sendable (_ target: String, _ body: [String: Any]) -> (Int, [String: Any])
    ) async throws -> (DynamoDBConnection, Box<[Call]>) {
        let calls = Box<[Call]>([])
        let connection = try await makeConnection(host: Self.newHost()) { request, data in
            let target = Self.target(request).replacingOccurrences(of: "DynamoDB_20120810.", with: "")
            if target == "ListTables" {
                return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": []]))
            }
            let body = dynamoStubBody(data)
            calls.mutate { $0.append((target, body)) }
            let (status, json) = respond(target, body)
            return (dynamoStubResponse(request.url!, status: status), dynamoStubJSON(json))
        }
        return (connection, calls)
    }

    static func targets(_ calls: Box<[Call]>) -> [String] {
        calls.wrappedValue.map { $0.target }
    }

    /// The error AWS returns for a denied action. `ACCOUNT` stands in for an account id.
    static func accessDenied(_ action: String, explicitDeny: Bool = false) -> (Int, [String: Any]) {
        let reason = explicitDeny
            ? "with an explicit deny in a service control policy"
            : "because no identity-based policy allows the dynamodb:\(action) action"
        return (400, [
            "__type": "com.amazon.coral.service#AccessDeniedException",
            "Message": "User: arn:aws:iam::ACCOUNT:user/test is not authorized to perform: "
                + "dynamodb:\(action) on resource: arn:aws:dynamodb:us-east-1:ACCOUNT:table/Music \(reason)",
        ])
    }

    /// Exactly what TableTabState.reload sends for an unfiltered, unsorted page.
    static let gridSelect = PartiQLDialect().select(
        from: TableRef(name: "Music"), whereClause: nil, orderBy: nil, limit: 1000
    )

    // MARK: SELECT

    @Test func permittedPartiQLSelectNeverTouchesScan() async throws {
        let (connection, calls) = try await makeRecordingConnection { _, _ in
            (200, ["Items": [["Artist": ["S": "Band1"]]]])
        }
        let result = try await drain(connection.execute(Self.gridSelect))
        #expect(result.rows == [[.text("Band1")]])
        #expect(Self.targets(calls) == ["ExecuteStatement"])
    }

    @Test func deniedPlainSelectFallsBackToPaginatedScanAndRemembers() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, body in
            switch target {
            case "ExecuteStatement":
                return Self.accessDenied("PartiQLSelect")
            case "Scan" where body["ExclusiveStartKey"] == nil:
                return (200, [
                    "Items": [["Artist": ["S": "Band1"]]],
                    "LastEvaluatedKey": ["Artist": ["S": "Band1"]],
                ])
            case "Scan":
                // "Year" never appeared on the first page, so it is dropped —
                // the same first-page column rule the PartiQL path has.
                return (200, ["Items": [["Artist": ["S": "Band2"], "Year": ["N": "1999"]]]])
            default:
                return (500, [:])
            }
        }
        let first = try await drain(connection.execute(Self.gridSelect))
        #expect(first.columns.map(\.name) == ["Artist"])
        #expect(first.rows == [[.text("Band1")], [.text("Band2")]])
        #expect(first.stats != nil)
        #expect(Self.targets(calls) == ["ExecuteStatement", "Scan", "Scan"])
        #expect(NSDictionary(dictionary: calls.wrappedValue[1].body).isEqual(to: ["TableName": "Music", "Limit": 1000]))

        // Second browse: the denial is remembered, so no PartiQL round trip.
        _ = try await drain(connection.execute(Self.gridSelect))
        #expect(Self.targets(calls) == ["ExecuteStatement", "Scan", "Scan", "Scan", "Scan"])
    }

    @Test(arguments: [
        PartiQLDialect().select(
            from: TableRef(name: "Music"), whereClause: #""Artist" = 'Acme'"#, orderBy: nil, limit: 1000
        ),
        PartiQLDialect().select(
            from: TableRef(name: "Music"), whereClause: nil, orderBy: ("Artist", false), limit: 1000
        ),
        #"SELECT "Artist" FROM "Music""#,
    ])
    func deniedSelectThatScanCannotReproduceKeepsThePartiQLError(sql: String) async throws {
        let (connection, calls) = try await makeRecordingConnection { _, _ in Self.accessDenied("PartiQLSelect") }
        do {
            _ = try await drain(connection.execute(sql))
            Issue.record("expected the PartiQL AccessDeniedException")
        } catch DriverError.queryFailed(let message, _) {
            #expect(message.contains("dynamodb:PartiQLSelect"))
        }
        #expect(Self.targets(calls) == ["ExecuteStatement"])
    }

    @Test func explicitDenyWordingAlsoFallsBack() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, _ in
            target == "Scan"
                ? (200, ["Items": [["Artist": ["S": "Band1"]]]])
                : Self.accessDenied("PartiQLSelect", explicitDeny: true)
        }
        let result = try await drain(connection.execute(Self.gridSelect))
        #expect(result.rows == [[.text("Band1")]])
        #expect(Self.targets(calls) == ["ExecuteStatement", "Scan"])
    }

    @Test func nonAccessDeniedErrorsNeverFallBack() async throws {
        let (connection, calls) = try await makeRecordingConnection { _, _ in
            (400, [
                "__type": "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException",
                "Message": "Requested resource not found",
            ])
        }
        do {
            _ = try await drain(connection.execute(Self.gridSelect))
            Issue.record("expected ResourceNotFoundException")
        } catch DriverError.queryFailed(let message, _) {
            #expect(message.hasPrefix("ResourceNotFoundException:"))
        }
        #expect(Self.targets(calls) == ["ExecuteStatement"])
    }

    @Test func scanDeniedTooSurfacesTheScanError() async throws {
        let (connection, _) = try await makeRecordingConnection { target, _ in
            Self.accessDenied(target == "Scan" ? "Scan" : "PartiQLSelect")
        }
        do {
            _ = try await drain(connection.execute(Self.gridSelect))
            Issue.record("expected the Scan AccessDeniedException")
        } catch DriverError.queryFailed(let message, _) {
            #expect(message.contains("dynamodb:Scan"))
        }
    }

    // MARK: Writes — exactly the shapes ChangeSet.statements generates

    static let update = #"UPDATE "Music" SET "Status" = 'live' WHERE "Artist" = 'Acme' AND "SongTitle" = 'Hit'"#
    static let insert = #"INSERT INTO "Music" ("Artist", "SongTitle") VALUES ('Acme', 'Hit')"#
    static let insert2 = #"INSERT INTO "Music" ("Artist", "SongTitle") VALUES ('Acme', 'Hit 2')"#
    static let delete = #"DELETE FROM "Music" WHERE "Artist" = 'Acme' AND "SongTitle" = 'Hit'"#

    static func describedMusic() -> [String: Any] {
        ["Table": ["TableName": "Music", "KeySchema": [
            ["AttributeName": "Artist", "KeyType": "HASH"],
            ["AttributeName": "SongTitle", "KeyType": "RANGE"],
        ]]]
    }

    @Test func permittedPartiQLWritesNeverTouchTheItemAPI() async throws {
        let (connection, calls) = try await makeRecordingConnection { _, _ in (200, ["Items": []]) }
        for sql in [Self.insert, Self.update, Self.delete] {
            _ = try await drain(connection.execute(sql))
        }
        #expect(Self.targets(calls) == ["ExecuteStatement", "ExecuteStatement", "ExecuteStatement"])
    }

    @Test func deniedUpdateFallsBackToConditionalUpdateItemAndRemembers() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, _ in
            target == "ExecuteStatement" ? Self.accessDenied("PartiQLUpdate") : (200, [:])
        }
        let result = try await drain(connection.execute(Self.update))
        _ = try await drain(connection.execute(Self.update))

        #expect(Self.targets(calls) == ["ExecuteStatement", "UpdateItem", "UpdateItem"])
        let expected = try NativeWriteRequest.make(
            for: try #require(PartiQLNativeTranslation.write(Self.update)), partitionKey: nil
        )
        #expect(NSDictionary(dictionary: calls.wrappedValue[1].body).isEqual(to: expected.body))
        #expect(result.stats != nil)
        #expect(result.stats?.rowsAffected == nil)
    }

    @Test func deniedInsertDescribesTheTableOnceAndPutsConditionally() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, _ in
            switch target {
            case "ExecuteStatement": return Self.accessDenied("PartiQLInsert")
            case "DescribeTable": return (200, Self.describedMusic())
            default: return (200, [:])
            }
        }
        _ = try await drain(connection.execute(Self.insert))
        _ = try await drain(connection.execute(Self.insert2))

        #expect(Self.targets(calls) == ["ExecuteStatement", "DescribeTable", "PutItem", "PutItem"])
        let put = calls.wrappedValue[2].body
        #expect(put["ConditionExpression"] as? String == "attribute_not_exists(#pk)")
        #expect(put["ExpressionAttributeNames"] as? [String: String] == ["#pk": "Artist"])
        let item = put["Item"] as? [String: Any]
        #expect((item?["SongTitle"] as? [String: Any])?["S"] as? String == "Hit")
    }

    @Test func deniedDeleteFallsBackToDeleteItem() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, _ in
            target == "ExecuteStatement" ? Self.accessDenied("PartiQLDelete") : (200, [:])
        }
        _ = try await drain(connection.execute(Self.delete))
        #expect(Self.targets(calls) == ["ExecuteStatement", "DeleteItem"])
        #expect(NSDictionary(dictionary: calls.wrappedValue[1].body).isEqual(to: [
            "TableName": "Music",
            "Key": ["Artist": ["S": "Acme"], "SongTitle": ["S": "Hit"]],
        ]))
    }

    @Test func deniedWriteBerryDBCannotTranslateKeepsThePartiQLError() async throws {
        let (connection, calls) = try await makeRecordingConnection { _, _ in Self.accessDenied("PartiQLUpdate") }
        let binaryEdit = #"UPDATE "Music" SET "Blob" = X'dead' WHERE "Artist" = 'Acme' AND "SongTitle" = 'Hit'"#
        do {
            _ = try await drain(connection.execute(binaryEdit))
            Issue.record("expected the PartiQL AccessDeniedException")
        } catch DriverError.queryFailed(let message, _) {
            #expect(message.contains("dynamodb:PartiQLUpdate"))
        }
        #expect(Self.targets(calls) == ["ExecuteStatement"])
    }

    @Test func denialIsRememberedPerAction() async throws {
        let (connection, calls) = try await makeRecordingConnection { target, body in
            let statement = body["Statement"] as? String ?? ""
            if target == "ExecuteStatement", statement.hasPrefix("UPDATE") {
                return Self.accessDenied("PartiQLUpdate")
            }
            return (200, ["Items": []])
        }
        _ = try await drain(connection.execute(Self.update))
        _ = try await drain(connection.execute(Self.insert))
        _ = try await drain(connection.execute(Self.gridSelect))
        #expect(Self.targets(calls) == ["ExecuteStatement", "UpdateItem", "ExecuteStatement", "ExecuteStatement"])
    }
}
