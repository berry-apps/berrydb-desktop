import BerryDriverKit
@testable import BerryMCP
import BerryStore
import Foundation
import Synchronization
import Testing

@Suite("MCP partition query service")
struct MCPPartitionQueryServiceTests {
    @Test func aKeyOfTheWrongTypeIsRefusedBeforeTheQuery() async throws {
        let connection = ScriptedPartitionConnection(schema: numberKeyed, pages: [.success(page([]))])
        let harness = Harness(connection: connection)
        let error = await harness.failure(harness.request(table: "events", partitionKey: .string("abc")))
        #expect(error == .invalidRequest("partition_key must be a number for key attribute id (N); pass an integer or a decimal string"))
        #expect(error?.description == "The query was refused before it ran: partition_key must be a number for key attribute id (N); pass an integer or a decimal string")
        #expect(await connection.queries.isEmpty)
    }

    @Test func anEmptyStringKeyIsRefused() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))])
        let harness = Harness(connection: connection)
        #expect(await harness.failure(harness.request(partitionKey: .string(""))) == .invalidRequest("partition_key must not be empty"))
        let emptySort = harness.request(partitionKey: .string("c1"), sortKey: MCPSortKeyInput(op: .eq, value: .string("")))
        #expect(await harness.failure(emptySort) == .invalidRequest("sort_key must not be empty"))
        #expect(await harness.tracker.factoryCalls == 0)
    }

    @Test func aBinaryKeyIsDecodedFromBase64AndRefusedOtherwise() async throws {
        let schema = DynamoDBKeySchema(
            table: "blobs", partitionKey: DynamoDBKeyAttribute(name: "blob", type: .binary), sortKey: nil, indexes: []
        )
        let connection = ScriptedPartitionConnection(schema: schema, pages: Array(repeating: .success(page([])), count: 3))
        let harness = Harness(connection: connection)
        _ = try await harness.query(harness.request(table: "blobs", partitionKey: .string("AQID")))
        #expect(await connection.queries.first?.partitionKey == .binary(Data([1, 2, 3])))
        let error = await harness.failure(harness.request(table: "blobs", partitionKey: .string("not base64!")))
        #expect(error == .invalidRequest("partition_key must be base64 for key attribute blob (B)"))
        let number = await harness.failure(harness.request(table: "blobs", partitionKey: .integer(7)))
        #expect(number == .invalidRequest("partition_key must be base64 for key attribute blob (B)"))
    }

    @Test func anIntegerKeyIsSentAsNumberText() async throws {
        let connection = ScriptedPartitionConnection(schema: numberKeyed, pages: [.success(page([]))])
        let harness = Harness(connection: connection)
        _ = try await harness.query(harness.request(table: "events", partitionKey: .integer(42)))
        let sent = try #require(await connection.queries.first)
        #expect(sent.partitionKey == .number("42"))
        #expect(sent.table == "events")
        #expect(sent.indexName == nil)
        #expect(sent.limit == 100)
        #expect(sent.exclusiveStartKey == nil)
    }

    @Test func aDecimalStringIsAcceptedForANumberKey() async throws {
        let connection = ScriptedPartitionConnection(schema: numberKeyed, pages: [.success(page([])), .success(page([]))])
        let harness = Harness(connection: connection)
        _ = try await harness.query(harness.request(table: "events", partitionKey: .string("1.5e3")))
        #expect(await connection.queries.first?.partitionKey == .number("1.5e3"))
        let error = await harness.failure(harness.request(table: "events", partitionKey: .string("1,5")))
        #expect(error == .invalidRequest("partition_key must be a number for key attribute id (N); pass an integer or a decimal string"))
    }

    @Test func theIndexKeysTypeTheInputsWhenAnIndexIsQueried() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: Array(repeating: .success(page([])), count: 4))
        let harness = Harness(connection: connection)
        _ = try await harness.query(harness.request(
            indexName: "by_status", partitionKey: .string("open"), sortKey: MCPSortKeyInput(op: .gt, value: .integer(3))
        ))
        let sent = try #require(await connection.queries.first)
        #expect(sent.indexName == "by_status")
        #expect(sent.partitionKey == .string("open"))
        #expect(sent.sortKey == .greaterThan(.number("3")))

        // The table's sort key is a string; the index's is a number.
        let textRank = harness.request(
            indexName: "by_status", partitionKey: .string("open"), sortKey: MCPSortKeyInput(op: .gt, value: .string("x"))
        )
        #expect(await harness.failure(textRank) == .invalidRequest(
            "sort_key must be a number for key attribute rank (N); pass an integer or a decimal string"
        ))
        let noIndexSort = harness.request(
            indexName: "by_region", partitionKey: .string("eu"), sortKey: MCPSortKeyInput(op: .eq, value: .string("x"))
        )
        #expect(await harness.failure(noIndexSort) == .invalidRequest("sort_key is not available: index by_region has no sort key"))
        let prefixOfNumber = harness.request(
            indexName: "by_status", partitionKey: .string("open"), sortKey: MCPSortKeyInput(op: .beginsWith, value: .integer(1))
        )
        #expect(await harness.failure(prefixOfNumber) == .invalidRequest("begins_with needs a string or binary sort key"))

        let events = Harness(connection: ScriptedPartitionConnection(schema: numberKeyed, pages: [.success(page([]))]))
        let noTableSort = events.request(table: "events", partitionKey: .integer(1), sortKey: MCPSortKeyInput(op: .eq, value: .integer(1)))
        #expect(await events.failure(noTableSort) == .invalidRequest("sort_key is not available: table events has no sort key"))
    }

    @Test func anUnknownIndexIsRefused() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))])
        let harness = Harness(connection: connection)
        let error = await harness.failure(harness.request(indexName: "nope", partitionKey: .string("open")))
        #expect(error == .unknownIndex)
        #expect(error?.description == "No index by that name exists on this table.")
        #expect(await connection.queries.isEmpty)
    }

    @Test func anUnknownTableIsReported() async throws {
        // DescribeTable is the first request this session sends after
        // connecting, so a missing table is found there.
        let missing = DriverError.queryFailed(message: "ResourceNotFoundException: Requested resource not found", code: nil)
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))], schemaError: missing)
        let harness = Harness(connection: connection)
        let error = await harness.failure(harness.request(partitionKey: .string("c1")))
        #expect(error == .unknownTable)
        #expect(error?.description == "No table by that name can be read with this connection.")
        #expect(await connection.queries.isEmpty)

        // A table deleted between DescribeTable and Query.
        let deleted = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: [.failure(missing)]))
        #expect(await deleted.failure(deleted.request(partitionKey: .string("c1"))) == .unknownTable)
    }

    @Test func itemsComeBackAsTheServiceSentThem() async throws {
        let items: [[String: DynamoDBAttributeValue]] = [
            [
                "customer": .string("c1"), "placed": .string("2026-11-01"),
                "total": .number("12345678901234567890.123456789"), "blob": .binary(Data([0, 255])),
                "flag": .bool(true), "gone": .null, "tags": .stringSet(["a", "b"]),
                "lines": .list([.map(["sku": .string("x"), "qty": .number("2")])]),
            ],
            ["customer": .string("c1"), "placed": .string("2026-11-02"), "sizes": .numberSet(["1", "2"])],
        ]
        let harness = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: [
            .success(DynamoDBQueryPage(items: items, lastEvaluatedKey: nil, consumedCapacityUnits: 0.5, scannedCount: 2)),
        ]))
        let result = try await harness.query(harness.request(partitionKey: .string("c1")))
        #expect(result.items == items)
        #expect(result.itemCount == 2)
        #expect(result.consumedCapacityUnits == 0.5)
        #expect(result.nextCursor == nil)
        #expect(result.truncated == false)
        #expect(result.redactedAttributes.isEmpty)
        #expect(result.keySchema.partitionKey == .init(name: "customer", type: "S"))
        #expect(result.keySchema.sortKey == .init(name: "placed", type: "S"))
        #expect(result.keySchema.index == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == [
            "consumed_capacity_units", "elapsed_ms", "item_count", "key_schema", "omitted_attributes",
            "redacted_attributes", "skipped_items", "truncated",
        ])
        let snake = JSONEncoder()
        snake.keyEncodingStrategy = .convertToSnakeCase
        snake.outputFormatting = [.sortedKeys]
        let plain = JSONEncoder()
        plain.outputFormatting = [.sortedKeys]
        #expect(try snake.encode(result) == plain.encode(result))
    }

    @Test func redactedAttributesAreRemovedFromItems() async throws {
        let harness = Harness(
            connection: ScriptedPartitionConnection(schema: orders, pages: [.success(page([
                ["customer": .string("c1"), "placed": .string("1"), "email": .string("a@example.com")],
                ["customer": .string("c1"), "placed": .string("2")],
            ]))]),
            redactedColumns: ["EMAIL"]
        )
        let result = try await harness.query(harness.request(partitionKey: .string("c1")))
        #expect(result.items == [
            ["customer": .string("c1"), "placed": .string("1")],
            ["customer": .string("c1"), "placed": .string("2")],
        ])
        #expect(result.redactedAttributes == ["email"])
    }

    @Test func anAttributeOverTheCellLimitIsOmittedAndReported() async throws {
        let body = String(repeating: "x", count: 70_000)
        let harness = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: [.success(page([
            ["customer": .string("c1"), "placed": .string("1"), "body": .string(body)],
        ]))]))
        let result = try await harness.query(harness.request(partitionKey: .string("c1")))
        #expect(result.items == [["customer": .string("c1"), "placed": .string("1")]])
        #expect(result.omittedAttributes == [MCPOmittedAttribute(item: 0, name: "body", bytes: try size(["body": .string(body)]))])
        #expect(result.truncated)
    }

    @Test func anItemTooLargeForThePageIsSkippedAndTheCursorMovesPastIt() async throws {
        let items = (1...5).map { order($0) }
        var huge = order(3)
        huge["note"] = .string(String(repeating: "n", count: 2_000))
        let page1 = [items[0], items[1], huge, items[3], items[4]]
        let connection = ScriptedPartitionConnection(schema: orders, pages: [
            .success(page(page1, lastKey: key(items[4]))),
            .success(page([items[3], items[4]])),
        ])
        let harness = try Harness(connection: connection, limits: ceilingFitting(2, of: items[0], index: nil))
        let first = try await harness.query(harness.request(partitionKey: .string("c1")))
        #expect(first.items == [items[0], items[1]])
        #expect(first.skippedItems == [MCPSkippedItem(index: 2, bytes: try size(huge))])
        #expect(first.truncated)
        let cursor = try #require(first.nextCursor)

        _ = try await harness.query(harness.request(partitionKey: .string("c1"), cursor: cursor))
        let queries = await connection.queries
        #expect(queries.count == 2)
        #expect(queries.last?.exclusiveStartKey == key(huge))
    }

    @Test(arguments: [nil, "by_status"])
    func aPageCutByTheByteCeilingContinuesFromTheLastReturnedItem(index: String?) async throws {
        let items = (1...5).map { order($0) }
        let connection = ScriptedPartitionConnection(schema: orders, pages: [
            .success(page(items, lastKey: key(items[4], index: index))),
            .success(page(Array(items[2...3]), lastKey: key(items[3], index: index))),
        ])
        let harness = try Harness(connection: connection, limits: ceilingFitting(2, of: items[0], index: index))
        let request = harness.request(indexName: index, partitionKey: .string(index == nil ? "c1" : "open"))
        let first = try await harness.query(request)
        #expect(first.items == Array(items[0...1]))
        #expect(first.truncated)
        let cursor = try #require(first.nextCursor)

        let second = try await harness.query(harness.request(
            indexName: index, partitionKey: .string(index == nil ? "c1" : "open"), cursor: cursor
        ))
        let queries = await connection.queries
        #expect(queries.count == 2)
        #expect(queries.last?.exclusiveStartKey == key(items[1], index: index))
        #expect(first.items + second.items == Array(items[0...3]))
    }

    @Test func theServiceCursorIsUsedWhenEveryItemFit() async throws {
        let items = (1...2).map { order($0) }
        let lastKey = key(items[1])
        let connection = ScriptedPartitionConnection(schema: orders, pages: [
            .success(page(items, lastKey: lastKey)),
            .success(page([order(3)])),
        ])
        let harness = Harness(connection: connection)
        let first = try await harness.query(harness.request(partitionKey: .string("c1")))
        #expect(first.items == items)
        #expect(first.truncated)
        let cursor = try #require(first.nextCursor)
        let last = try await harness.query(harness.request(partitionKey: .string("c1"), cursor: cursor))
        #expect(await connection.queries.last?.exclusiveStartKey == lastKey)
        #expect(last.nextCursor == nil)
        #expect(last.truncated == false)
    }

    @Test func aCursorFromAnotherQueryIsRefusedByTheService() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: [
            .success(page([order(1)], lastKey: key(order(1)))),
            .success(page([])),
        ])
        let harness = Harness(connection: connection)
        let after1 = MCPSortKeyInput(op: .gt, value: .string("1"))
        let first = try await harness.query(harness.request(partitionKey: .string("c1"), sortKey: after1))
        let cursor = try #require(first.nextCursor)
        let after2 = MCPSortKeyInput(op: .gt, value: .string("2"))
        let error = await harness.failure(harness.request(partitionKey: .string("c1"), sortKey: after2, cursor: cursor))
        #expect(error == .invalidCursor)
        #expect(error?.description == "The cursor does not belong to this query or came from another session; start again without it.")
        #expect(await harness.failure(harness.request(partitionKey: .string("c1"), cursor: "not-a-cursor")) == .invalidCursor)
        #expect(await connection.queries.count == 1)
    }

    @Test func errorsNeverCarryArnsAccountIdsOrAccessKeys() async throws {
        let denied = DriverError.queryFailed(
            message: "AccessDeniedException: User: arn:aws:iam::123456789012:user/bob is not authorized to perform: dynamodb:Query on resource: arn:aws:dynamodb:us-east-1:123456789012:table/orders",
            code: nil
        )
        let harness = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: [.failure(denied)]))
        let error = try #require(await harness.failure(harness.request(partitionKey: .string("c1"))))
        guard case .queryFailed = error else {
            Issue.record("expected queryFailed, got \(error)")
            return
        }
        #expect(error.description.contains("dynamodb:Query"))
        #expect(!error.description.contains("123456789012"))
        #expect(!error.description.contains("arn:aws"))
        #expect(!error.description.contains("bob"))

        let masked = MCPPartitionQueryService.sanitized("key AKIAABCDEFGHIJKLMNOP\n  account 123456789012, order 1234567890123")
        #expect(masked == "key … account …, order 1234567890123")
        let long = MCPPartitionQueryService.sanitized(String(repeating: "a \n", count: 400))
        #expect(long.count == 500)
        #expect(long.hasSuffix("…"))
    }

    @Test func aThrottledQueryIsReportedAsThrottledAndNotRetried() async throws {
        for name in ["ProvisionedThroughputExceededException", "ThrottlingException", "RequestLimitExceeded"] {
            let throttled = DriverError.queryFailed(message: "\(name): Rate of requests exceeds the allowed throughput", code: nil)
            let connection = ScriptedPartitionConnection(schema: orders, pages: [.failure(throttled), .success(page([]))])
            let harness = Harness(connection: connection)
            let error = await harness.failure(harness.request(partitionKey: .string("c1")))
            #expect(error == .throttled, "\(name)")
            #expect(error?.description == "DynamoDB throttled this query; try again later, with a smaller limit or on a read replica.")
            #expect(await connection.queries.count == 1, "\(name)")
        }
    }

    @Test func productionLimitsCapTheItemsAndTheBytes() async throws {
        let wide = String(repeating: "w", count: 10_000)
        let items = (1...50).map { number -> [String: DynamoDBAttributeValue] in
            var item = order(number)
            item["body"] = .string(wide)
            return item
        }
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page(items, lastKey: key(items[49])))])
        let harness = Harness(connection: connection, isProduction: true)
        let result = try await harness.query(harness.request(partitionKey: .string("c1"), limit: 100))
        #expect(await connection.queries.first?.limit == 50)
        #expect(result.itemCount > 0)
        #expect(result.itemCount < 50)
        #expect(result.truncated)
        let reserve = try MCPPartitionQueryService.reserve(for: result.keySchema)
        #expect(try size(items: result.items) + reserve <= 262_144)

        let plain = ScriptedPartitionConnection(schema: orders, pages: [.success(page([])), .success(page([]))])
        let regular = Harness(connection: plain)
        _ = try await regular.query(regular.request(partitionKey: .string("c1")))
        _ = try await regular.query(regular.request(partitionKey: .string("c1"), limit: 7))
        #expect(await plain.queries.map(\.limit) == [100, 7])
    }

    @Test func theWholeResultFitsTheCeilingWithALargeCursorAndOmittedAttributes() async throws {
        // Key attributes at their largest, so the sealed cursor runs to
        // kilobytes: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html#limits-partition-sort-keys
        let wide = DynamoDBKeySchema(
            table: "wide", partitionKey: DynamoDBKeyAttribute(name: "p", type: .string),
            sortKey: DynamoDBKeyAttribute(name: "s", type: .string), indexes: []
        )
        let longName = String(repeating: "b", count: 300)
        let items = (1...5).map { number -> [String: DynamoDBAttributeValue] in
            [
                "p": .string(String(repeating: "p", count: 2_048)),
                "s": .string(String(repeating: "s", count: 1_020) + "000\(number)"),
                longName: .string(String(repeating: "x", count: 4_000)),
            ]
        }
        let kept = items[0].filter { $0.key != longName }
        let itemBytes = try size(kept)
        let reserve = try MCPPartitionQueryService.reserve(for: MCPKeySchemaDescription(schema: wide, index: nil))
        // The first pass fits three items; the cursor and three omitted
        // entries do not fit in what the reserve leaves.
        let ceiling = reserve + 3 * itemBytes + 2
        let connection = ScriptedPartitionConnection(schema: wide, pages: [
            .success(page(items, lastKey: items[4].filter { ["p", "s"].contains($0.key) })),
            .success(page([])),
        ])
        let harness = Harness(connection: connection, limits: { _ in
            MCPResultLimits(maximumRows: 100, maximumCellBytes: 3_000, maximumSerializedBytes: ceiling, maximumElapsed: .seconds(30))
        })
        let request = harness.request(table: "wide", partitionKey: .string(String(repeating: "p", count: 2_048)))
        let result = try await harness.query(request)
        #expect(try emittedSize(result) <= ceiling)
        #expect(try MCPPartitionQueryService.encodedSize(of: result) == emittedSize(result))
        #expect(result.itemCount > 0)
        #expect(result.itemCount < 3)
        #expect(result.items == Array(items[0..<result.itemCount]).map { $0.filter { $0.key != longName } })
        #expect(result.omittedAttributes.map(\.item) == Array(0..<result.itemCount))
        #expect(result.omittedAttributes.allSatisfy { $0.name.count == 255 && $0.name.hasSuffix("…") })
        #expect(result.truncated)
        let cursor = try #require(result.nextCursor)

        _ = try await harness.query(MCPPartitionQueryRequest(
            profileID: request.profileID, table: "wide", partitionKey: request.partitionKey, cursor: cursor
        ))
        let last = items[result.itemCount - 1]
        #expect(await connection.queries.last?.exclusiveStartKey == last.filter { ["p", "s"].contains($0.key) })
    }

    @Test func aFirstItemTheMeasuredResultDropsIsSkippedAndTheCursorMovesPastIt() async throws {
        // Key attributes at their largest, so the cursor alone outgrows the
        // reserve: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/ServiceQuotas.html#limits-partition-sort-keys
        let wide = DynamoDBKeySchema(
            table: "wide", partitionKey: DynamoDBKeyAttribute(name: "p", type: .string),
            sortKey: DynamoDBKeyAttribute(name: "s", type: .string), indexes: []
        )
        let partition = String(repeating: "p", count: 2_048)
        let item: [String: DynamoDBAttributeValue] = [
            "p": .string(partition), "s": .string(String(repeating: "s", count: 1_024)),
            "body": .string(String(repeating: "x", count: 2_000)),
        ]
        let itemKey = item.filter { ["p", "s"].contains($0.key) }
        let itemBytes = try size(item)
        // The first pass keeps the item; with the cursor the result does not
        // fit, and the item is the only one processed.
        let ceiling = try MCPPartitionQueryService.reserve(for: MCPKeySchemaDescription(schema: wide, index: nil)) + itemBytes
        let connection = ScriptedPartitionConnection(schema: wide, pages: [
            .success(page([item], lastKey: itemKey)),
            .success(page([])),
        ])
        let harness = Harness(connection: connection, limits: { _ in
            MCPResultLimits(maximumRows: 100, maximumCellBytes: 65_536, maximumSerializedBytes: ceiling, maximumElapsed: .seconds(30))
        })
        let request = harness.request(table: "wide", partitionKey: .string(partition))
        let result = try await harness.query(request)
        #expect(result.items.isEmpty)
        #expect(result.skippedItems == [MCPSkippedItem(index: 0, bytes: itemBytes)])
        #expect(result.truncated)
        #expect(try emittedSize(result) <= ceiling)
        let cursor = try #require(result.nextCursor)

        _ = try await harness.query(harness.request(table: "wide", partitionKey: .string(partition), cursor: cursor))
        #expect(await connection.queries.last?.exclusiveStartKey == itemKey)
    }

    @Test func aSQLProfileIsRefusedBeforeOpening() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))])
        let harness = Harness(connection: connection, driverID: .postgres)
        let error = await harness.failure(harness.request(partitionKey: .string("c1")))
        #expect(error == .unsupportedDatabase)
        #expect(error?.description == "DynamoDB queries run on DynamoDB connections only; use berrydb_execute_read_query for a SQL connection.")
        #expect(await harness.tracker.factoryCalls == 0)
    }

    @Test func aQueryPastItsTimeLimitIsCancelled() async throws {
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))], delay: .seconds(30))
        // The open budget puts the whole request's bound at 40 + 1 + 2 s;
        // it reports the same text as the query's own bound of 1 + 1 s, so
        // only the time taken shows which fired. A loaded parallel run has
        // delayed a short deadline here by more than 10 s, so the bound sits
        // between the two rather than near the query's.
        let harness = Harness(connection: connection, openBudget: .seconds(40), limits: { _ in
            MCPResultLimits(maximumRows: 100, maximumCellBytes: 65_536, maximumSerializedBytes: 1_048_576, maximumElapsed: .seconds(1))
        })
        let clock = ContinuousClock()
        let started = clock.now
        let error = await harness.failure(harness.request(partitionKey: .string("c1")))
        #expect(clock.now - started < .seconds(25))
        #expect(error == .timedOut(seconds: 1))
        #expect(error?.description == "The query did not finish within 1 seconds.")
        try await eventually { await connection.sawCancellation }
    }

    @Test func aDynamoDBQueryTakesALiveReadSlot() async throws {
        let gate = SQLGate()
        let sql = HeldSQLConnection(gate: gate)
        let connection = ScriptedPartitionConnection(schema: orders, pages: [.success(page([]))])
        let harness = Harness(connection: connection, sqlConnection: sql)
        let liveReads = harness.liveReads
        let sqlRequest = MCPLiveReadRequest(profileID: harness.sqlProfileID, dialect: .sqlite, sql: "SELECT n FROM numbers")
        let held = (0..<4).map { _ in Task { try await liveReads.run(sqlRequest) } }
        try await eventually { sql.statements == 4 }
        let slots = liveReads.slots
        #expect(await slots.inUse == 4)

        let error = await harness.failure(harness.request(partitionKey: .string("c1")))
        #expect(error == .tooManyConcurrentReads(limit: 4))
        #expect(error?.description == "BerryDB is already running 4 live reads for this session; try again when one finishes.")
        #expect(await harness.tracker.factoryCalls == 0)
        #expect(await connection.queries.isEmpty)

        await gate.open()
        for task in held {
            _ = try await withDeadline(.seconds(60)) { try await task.value }
        }
        try await eventually { await slots.inUse == 0 }
    }

    @Test func resolutionRefusalsUseTheirTexts() async throws {
        let profile: @Sendable (UUID) -> MCPConnectionProfile = {
            MCPConnectionProfile(id: $0, driverID: .dynamodb, config: .sqlite(path: ":memory:"))
        }
        let project: @Sendable (UUID, Bool) -> MCPVerifiedProject = { id, liveRead in
            MCPVerifiedProject(
                project: MCPProject(name: "P", isEnabled: true, profiles: [MCPProfileAccess(profileID: id, liveRead: liveRead)]),
                liveReadProfileIDs: liveRead ? [id] : []
            )
        }
        let cases: [(MCPPartitionQueryError, String, @Sendable (UUID) -> MCPProjectResolver)] = [
            (.liveReadNotEnabled, "Live reads are not turned on for this connection. The user can turn them on in BerryDB Settings → AI Agents.", { id in
                MCPProjectResolver(loadProject: { project(id, false) }, profile: { profile($0) })
            }),
            (.unknownConnection, "Unknown connection for this project", { id in
                MCPProjectResolver(loadProject: { project(id, true) }, profile: { _ in nil })
            }),
            (.noProject, "No BerryDB project is selected for this workspace. Call berrydb_status for details.", { _ in
                MCPProjectResolver(loadProject: { nil }, profile: { profile($0) })
            }),
            (.tunnelUnsupported, "Live reads over an SSH tunnel are not available for DynamoDB connections.", { id in
                MCPProjectResolver(
                    loadProject: { project(id, true) },
                    profile: { throw MCPProjectResolutionError.tunnelUnsupported($0) }
                )
            }),
        ]
        for (expected, text, resolver) in cases {
            let harness = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: []), resolver: resolver)
            let error = await harness.failure(harness.request(partitionKey: .string("c1")))
            #expect(error == expected)
            #expect(error?.description == text)
            #expect(await harness.tracker.factoryCalls == 0)
        }
    }

    @Test func malformedRequestsAreRefusedBeforeAnyConnection() async throws {
        let harness = Harness(connection: ScriptedPartitionConnection(schema: orders, pages: []))
        let naming = "table and index names are 3 to 255 characters of A-Z, a-z, 0-9, _, - and ."
        let cases: [(MCPPartitionQueryRequest, String)] = [
            (harness.request(table: "ab", partitionKey: .string("c1")), naming),
            (harness.request(table: "orders;drop", partitionKey: .string("c1")), naming),
            (harness.request(indexName: String(repeating: "i", count: 256), partitionKey: .string("c1")), naming),
            (harness.request(partitionKey: .string("c1"), sortKey: MCPSortKeyInput(op: .between, value: .string("a"))), "between needs value2"),
            (harness.request(partitionKey: .string("c1"), sortKey: MCPSortKeyInput(op: .beginsWith, value: .string("a"), value2: .string("b"))), "begins_with takes no value2"),
            (harness.request(partitionKey: .string("c1"), projection: (0...50).map { "a\($0)" }), "projection holds at most 50 attribute names"),
            (harness.request(partitionKey: .string("c1"), projection: [""]), "projection attribute names are 1 to 255 characters"),
            (harness.request(partitionKey: .string("c1"), limit: 0), "limit must be between 1 and 100"),
            (harness.request(partitionKey: .string("c1"), limit: 101), "limit must be between 1 and 100"),
        ]
        for (request, reason) in cases {
            #expect(await harness.failure(request) == .invalidRequest(reason))
        }
        #expect(await harness.tracker.factoryCalls == 0)
    }
}

// MARK: - Fixtures

/// `orders`: customer (S) and placed (S); index `by_status`: status (S) and
/// rank (N); index `by_region`: region (S) only.
private let orders = DynamoDBKeySchema(
    table: "orders",
    partitionKey: DynamoDBKeyAttribute(name: "customer", type: .string),
    sortKey: DynamoDBKeyAttribute(name: "placed", type: .string),
    indexes: [
        DynamoDBIndexKeySchema(
            name: "by_status", partitionKey: DynamoDBKeyAttribute(name: "status", type: .string),
            sortKey: DynamoDBKeyAttribute(name: "rank", type: .number)
        ),
        DynamoDBIndexKeySchema(name: "by_region", partitionKey: DynamoDBKeyAttribute(name: "region", type: .string), sortKey: nil),
    ]
)

private let numberKeyed = DynamoDBKeySchema(
    table: "events", partitionKey: DynamoDBKeyAttribute(name: "id", type: .number), sortKey: nil, indexes: []
)

/// An `orders` item of a fixed encoded size for `number` 1…9.
private func order(_ number: Int) -> [String: DynamoDBAttributeValue] {
    [
        "customer": .string("c1"), "placed": .string("2026-11-0\(number)"),
        "status": .string("open"), "rank": .number("\(number)"), "total": .number("1\(number).50"),
    ]
}

private func key(_ item: [String: DynamoDBAttributeValue], index: String? = nil) -> [String: DynamoDBAttributeValue] {
    item.filter { orders.keyAttributeNames(index: index).contains($0.key) }
}

private func page(
    _ items: [[String: DynamoDBAttributeValue]], lastKey: [String: DynamoDBAttributeValue]? = nil
) -> DynamoDBQueryPage {
    DynamoDBQueryPage(items: items, lastEvaluatedKey: lastKey, consumedCapacityUnits: 0.5, scannedCount: items.count)
}

/// The bytes of `result` as one JSON object holding its metadata and its
/// items under `items`, counted independently of the service.
private func emittedSize(_ result: MCPPartitionQueryResult) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let metadata = try encoder.encode(result).count
    return metadata + #""items":"#.utf8.count + (try encoder.encode(result.items).count) + 1
}

private func size(_ item: [String: DynamoDBAttributeValue]) throws -> Int {
    try size(items: [item]) - 2
}

private func size(items: [[String: DynamoDBAttributeValue]]) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(items).count
}

/// Limits whose byte ceiling, after the service's reserve, holds `count`
/// items the size of `item` and their separators, and not one more.
private func ceilingFitting(
    _ count: Int, of item: [String: DynamoDBAttributeValue], index: String?
) throws -> @Sendable (Bool) -> MCPResultLimits {
    let description = MCPKeySchemaDescription(schema: orders, index: index.flatMap { orders.index(named: $0) })
    let bytes = try size(item)
    let ceiling = try MCPPartitionQueryService.reserve(for: description) + count * bytes + (count - 1) + bytes / 2
    return { _ in
        MCPResultLimits(maximumRows: 100, maximumCellBytes: 65_536, maximumSerializedBytes: ceiling, maximumElapsed: .seconds(30))
    }
}

// MARK: - Harness

/// One coordinator over a DynamoDB profile whose sessions run on a scripted
/// partition connection, and a SQLite profile for SQL reads that share the
/// same slots.
private struct Harness {
    let profileID: UUID
    let sqlProfileID: UUID
    let tracker: PartitionTracker
    let liveReads: MCPLiveReadService
    let service: MCPPartitionQueryService

    init(
        connection: ScriptedPartitionConnection,
        driverID: DriverID = .dynamodb,
        isProduction: Bool = false,
        redactedColumns: [String] = [],
        resolver: (@Sendable (UUID) -> MCPProjectResolver)? = nil,
        openBudget: Duration = .seconds(3),
        limits: (@Sendable (Bool) -> MCPResultLimits)? = nil,
        sqlConnection: HeldSQLConnection? = nil
    ) {
        let id = UUID()
        let sqlID = UUID()
        let tracker = PartitionTracker()
        let project = MCPProject(name: "P", isEnabled: true, profiles: [
            MCPProfileAccess(profileID: id, liveRead: true, redactedColumns: redactedColumns),
            MCPProfileAccess(profileID: sqlID, liveRead: true),
        ])
        let resolver = resolver?(id) ?? MCPProjectResolver(
            loadProject: { MCPVerifiedProject(project: project, liveReadProfileIDs: [id, sqlID]) },
            profile: { requested in
                switch requested {
                case id:
                    MCPConnectionProfile(id: id, driverID: driverID, config: .sqlite(path: ":memory:"), isProduction: isProduction)
                case sqlID:
                    MCPConnectionProfile(id: sqlID, driverID: .sqlite, config: .sqlite(path: ":memory:"))
                default:
                    nil
                }
            }
        )
        let held = sqlConnection
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            sqlFactory: { profile in
                guard let held else { throw DriverError.connectionFailed("no SQL connection scripted") }
                let lifecycle = MCPConnectionLifecycle(cancel: {}, closeConnection: {})
                return MCPSQLSession(connection: held, lifecycle: lifecycle, profile: profile)
            },
            partitionFactory: { profile in
                await tracker.factoryCalled()
                let lifecycle = MCPConnectionLifecycle(
                    cancel: { connection.cancelCurrentQuery() },
                    closeConnection: { await connection.close() }
                )
                return MCPPartitionSession(reader: MCPPartitionReader(connection), lifecycle: lifecycle, profile: profile)
            }
        )
        profileID = id
        sqlProfileID = sqlID
        self.tracker = tracker
        liveReads = MCPLiveReadService(coordinator: coordinator, openBudget: openBudget, slots: MCPLiveReadSlots(capacity: 4))
        if let limits {
            service = MCPPartitionQueryService(coordinator: coordinator, openBudget: openBudget, slots: liveReads.slots, limits: limits)
        } else {
            service = MCPPartitionQueryService(sharing: liveReads)
        }
    }

    func request(
        table: String = "orders", indexName: String? = nil, partitionKey: MCPKeyInput,
        sortKey: MCPSortKeyInput? = nil, projection: [String]? = nil, limit: Int? = nil, cursor: String? = nil
    ) -> MCPPartitionQueryRequest {
        MCPPartitionQueryRequest(
            profileID: profileID, table: table, indexName: indexName, partitionKey: partitionKey,
            sortKey: sortKey, projection: projection, limit: limit, cursor: cursor
        )
    }

    func query(_ request: MCPPartitionQueryRequest) async throws -> MCPPartitionQueryResult {
        let service = self.service
        return try await withDeadline(.seconds(60)) { try await service.run(request) }
    }

    /// The service's refusal; records an issue when it returned or threw anything else.
    func failure(_ request: MCPPartitionQueryRequest) async -> MCPPartitionQueryError? {
        do {
            let result = try await query(request)
            Issue.record("expected a refusal, got \(result)")
        } catch let error as MCPPartitionQueryError {
            return error
        } catch {
            Issue.record("expected MCPPartitionQueryError, got \(error)")
        }
        return nil
    }
}

private actor PartitionTracker {
    private(set) var factoryCalls = 0
    func factoryCalled() { factoryCalls += 1 }
}

private actor SQLGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A read-only SQL connection whose every statement returns one column and
/// finishes only once `gate` opens, so a read holds its slot until then.
private actor HeldSQLConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private nonisolated let gate: SQLGate
    private nonisolated let started = Mutex(0)

    init(gate: SQLGate) {
        self.gate = gate
    }

    nonisolated var statements: Int { started.withLock { $0 } }

    func prepareReadOnly() async throws {}

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        started.withLock { $0 += 1 }
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            continuation.yield(.columns([ColumnMeta(name: "n", declaredType: "")]))
            Task {
                await gate.wait()
                continuation.finish()
            }
        }
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}
