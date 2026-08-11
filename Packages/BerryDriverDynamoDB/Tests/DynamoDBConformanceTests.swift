import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

/// Runs against a real dynamodb-local from `BERRYDB_TEST_DYNAMODB`
/// (`host:port`, see Tests/docker/compose.yml); skipped when the env var is
/// unset (docs/architecture/12 §10, CLAUDE.md · Build & test). dynamodb-local
/// accepts any non-empty SigV4 credentials — no real AWS account needed.
@Suite("DynamoDB driver conformance", .enabled(if: DynamoDBTestServer.dynamodb != nil))
struct DynamoDBConformanceTests {
    private var server: DynamoDBTestServer { DynamoDBTestServer.dynamodb! }

    private func makeConfig() -> ConnectionConfig {
        ConnectionConfig(
            driver: .dynamodb, name: "test", host: server.host, port: server.port, tlsMode: .disable,
            awsAccessKeyID: "fakeAccessKeyId", awsSecretAccessKey: "fakeSecretAccessKey", awsRegion: "us-east-1"
        )
    }

    private func makeConnection() async throws -> DynamoDBConnection {
        try await DynamoDBConnection(config: makeConfig())
    }

    /// Table creation is out of scope for the driver itself — same posture
    /// as Qdrant's "BerryDB only connects to a collection the user already
    /// has" (docs/architecture/12 §5) — so conformance tests create/drop
    /// tables directly via the raw DynamoDB API, not through the driver.
    private func createTable(
        name: String, partitionKey: String, sortKey: String? = nil
    ) async throws {
        var keySchema: [[String: Any]] = [["AttributeName": partitionKey, "KeyType": "HASH"]]
        var attributeDefs: [[String: Any]] = [["AttributeName": partitionKey, "AttributeType": "S"]]
        if let sortKey {
            keySchema.append(["AttributeName": sortKey, "KeyType": "RANGE"])
            attributeDefs.append(["AttributeName": sortKey, "AttributeType": "S"])
        }
        let body: [String: Any] = [
            "TableName": name, "KeySchema": keySchema, "AttributeDefinitions": attributeDefs,
            "BillingMode": "PAY_PER_REQUEST",
        ]
        _ = try await rawCall(target: "CreateTable", body: body)
        // dynamodb-local creates synchronously, but poll briefly for ACTIVE to be safe.
        for _ in 0..<20 {
            let describe = try await rawCall(target: "DescribeTable", body: ["TableName": name])
            let status = ((describe["Table"] as? [String: Any])?["TableStatus"] as? String) ?? ""
            if status == "ACTIVE" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func deleteTable(name: String) async {
        _ = try? await rawCall(target: "DeleteTable", body: ["TableName": name])
    }

    /// Minimal hand-signed request — deliberately reuses `SigV4Signer` (the
    /// unit under test elsewhere) rather than a second signing path, since
    /// this helper exists only to set up/tear down fixtures, not to
    /// re-verify signing.
    @discardableResult
    private func rawCall(target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.\(target)", forHTTPHeaderField: "X-Amz-Target")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        SigV4Signer.sign(
            &request, body: bodyData,
            credentials: .init(accessKeyID: "fakeAccessKeyId", secretAccessKey: "fakeSecretAccessKey"),
            region: "us-east-1", service: "dynamodb"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ConformanceFailure("\(target) failed: \(text)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
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

    // MARK: DatabaseDriver entry point (KN-06 "Test connection" expectation)

    @Test func driverConnectSucceedsAgainstAReachableServer() async throws {
        let driver = DynamoDBDriver()
        let connection = try await driver.connect(makeConfig())
        defer { Task { await connection.close() } }
        #expect(await connection.ping())
    }

    @Test func driverConnectFailsFastAgainstAnUnreachableHost() async throws {
        let driver = DynamoDBDriver()
        let badConfig = ConnectionConfig(
            driver: .dynamodb, name: "test", host: "127.0.0.1", port: 1, tlsMode: .disable,
            awsAccessKeyID: "x", awsSecretAccessKey: "x", awsRegion: "us-east-1"
        )
        await #expect(throws: DriverError.self) {
            _ = try await driver.connect(badConfig)
        }
    }

    // MARK: Write path — INSERT (rewritten)/UPDATE/DELETE round trip through ChangeSet's exact shape

    @Test func changeSetShapedInsertUpdateDeleteRoundTrip() async throws {
        let table = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createTable(name: table, partitionKey: "Artist", sortKey: "SongTitle")
        defer { Task { await deleteTable(name: table) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let quotedTable = "\"\(table)\""

        // Exactly the shape ChangeSet.statements() generates (BerryCore, untouched) —
        // proves PartiQLInsertRewriter makes it work end-to-end against a real server.
        let insert = "INSERT INTO \(quotedTable) (\"Artist\", \"SongTitle\", \"Awards\") "
            + "VALUES ('Acme Band', 'PartiQL Rocks', 10)"
        _ = try await drain(connection.execute(insert))

        let select = "SELECT * FROM \(quotedTable) WHERE \"Artist\" = 'Acme Band' AND \"SongTitle\" = 'PartiQL Rocks'"
        let afterInsert = try await drain(connection.execute(select))
        #expect(afterInsert.rows.count == 1)
        #expect(afterInsert.columns.map(\.name).sorted() == ["Artist", "Awards", "SongTitle"])

        let update = "UPDATE \(quotedTable) SET \"Awards\" = 99 "
            + "WHERE \"Artist\" = 'Acme Band' AND \"SongTitle\" = 'PartiQL Rocks'"
        _ = try await drain(connection.execute(update))
        let afterUpdate = try await drain(connection.execute(select))
        let awardsIndex = afterUpdate.columns.firstIndex { $0.name == "Awards" }!
        #expect(afterUpdate.rows.first?[awardsIndex] == .int(99))

        let delete = "DELETE FROM \(quotedTable) WHERE \"Artist\" = 'Acme Band' AND \"SongTitle\" = 'PartiQL Rocks'"
        _ = try await drain(connection.execute(delete))
        let afterDelete = try await drain(connection.execute(select))
        #expect(afterDelete.rows.isEmpty)
    }

    /// Verified restriction (docs/architecture/12 §4): UPDATE/DELETE need
    /// the FULL primary key in WHERE — a partition-key-only condition on a
    /// table with a sort key is rejected. This is exactly why
    /// `DynamoDBIntrospector.tableDetail` marks BOTH key columns
    /// `isPrimaryKey: true`.
    @Test func updateWithoutFullPrimaryKeyIsRejected() async throws {
        let table = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createTable(name: table, partitionKey: "Artist", sortKey: "SongTitle")
        defer { Task { await deleteTable(name: table) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        let quotedTable = "\"\(table)\""

        await #expect(throws: DriverError.self) {
            _ = try await drain(connection.execute(
                "UPDATE \(quotedTable) SET \"Awards\" = 1 WHERE \"Artist\" = 'Acme Band'"
            ))
        }
    }

    // MARK: SELECT pagination — real NextToken round-trip against dynamodb-local

    /// The HTTP client's `limit` maps to ExecuteStatement's real page-size
    /// cap; forcing it small against a real server proves `NextToken`
    /// actually round-trips through dynamodb-local (the connection itself
    /// always uses batchSize=1000, too large to exercise multi-page
    /// pagination cheaply against a real server — that side of the loop is
    /// covered deterministically by `DynamoDBConnectionTests` with a stub).
    @Test func nextTokenPaginationRoundTripsAgainstARealServer() async throws {
        let table = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createTable(name: table, partitionKey: "ID")
        defer { Task { await deleteTable(name: table) } }

        let config = makeConfig()
        let client = try DynamoDBHTTPClient(config: config, session: URLSession(configuration: .ephemeral))
        for i in 0..<5 {
            _ = try await client.executeStatement(
                "INSERT INTO \"\(table)\" VALUE {'ID': '\(i)'}", nextToken: nil, limit: nil
            )
        }

        var allItems: [[String: Any]] = []
        var nextToken: String?
        var pages = 0
        repeat {
            let page = try await client.executeStatement(
                "SELECT * FROM \"\(table)\"", nextToken: nextToken, limit: 2
            )
            allItems += page.items
            nextToken = page.nextToken
            pages += 1
        } while nextToken != nil
        #expect(allItems.count == 5)
        #expect(pages >= 3) // 5 items at 2/page -> at least 3 pages
    }

    // MARK: Introspection against a real DescribeTable/ListTables

    @Test func introspectorReportsRealKeySchemaAndIndexes() async throws {
        let table = "berry_conf_\(UUID().uuidString.prefix(8))"
        try await createTable(name: table, partitionKey: "Artist", sortKey: "SongTitle")
        defer { Task { await deleteTable(name: table) } }

        let connection = try await makeConnection()
        defer { Task { await connection.close() } }

        let objects = try await connection.introspector.objects(in: nil)
        #expect(objects.contains { $0.name == table && $0.kind == .table })

        let detail = try await connection.introspector.tableDetail(TableRef(name: table))
        #expect(detail.columns.map(\.name) == ["Artist", "SongTitle"])
        #expect(detail.columns.allSatisfy { $0.isPrimaryKey })

        let ddl = try await connection.introspector.ddl(of: SchemaObject(kind: .table, name: table))
        #expect(ddl.contains("PARTITION KEY"))
        #expect(ddl.contains("SORT KEY"))
    }

    // MARK: Transaction-control no-op (docs/architecture/12 §4)

    @Test func beginCommitRollbackAreAcceptedAsNoOpsByARealConnection() async throws {
        let connection = try await makeConnection()
        defer { Task { await connection.close() } }
        for sql in ["BEGIN", "COMMIT", "ROLLBACK"] {
            let result = try await drain(connection.execute(sql))
            #expect(result.stats != nil)
        }
    }

    // MARK: ping/close

    @Test func pingAndCloseWork() async throws {
        let connection = try await makeConnection()
        #expect(await connection.ping())
        await connection.close()
        #expect(await connection.ping() == false)
    }
}
