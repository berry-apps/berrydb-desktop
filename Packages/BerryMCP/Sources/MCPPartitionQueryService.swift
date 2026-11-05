import BerryDriverKit
import Foundation

/// A key value as an agent passes it: text, or a whole number. Which DynamoDB
/// type it becomes is decided by the table's key schema.
public enum MCPKeyInput: Sendable, Equatable {
    case string(String)
    case integer(Int64)
}

/// Sort key comparison operators of a `Query` key condition:
/// https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html#DDB-Query-request-KeyConditionExpression
public enum MCPSortKeyOperator: String, Sendable, CaseIterable {
    case eq, lt, le, gt, ge, between
    case beginsWith = "begins_with"
}

public struct MCPSortKeyInput: Sendable, Equatable {
    public let op: MCPSortKeyOperator
    public let value: MCPKeyInput
    /// The upper bound of `between`; every other operator takes none.
    public let value2: MCPKeyInput?

    public init(op: MCPSortKeyOperator, value: MCPKeyInput, value2: MCPKeyInput? = nil) {
        self.op = op
        self.value = value
        self.value2 = value2
    }
}

public struct MCPPartitionQueryRequest: Sendable {
    public let profileID: UUID
    public let table: String
    public let indexName: String?
    public let partitionKey: MCPKeyInput
    public let sortKey: MCPSortKeyInput?
    public let projection: [String]?
    /// Items the caller wants at most; capped by the profile's limit.
    public let limit: Int?
    public let cursor: String?

    public init(
        profileID: UUID, table: String, indexName: String? = nil, partitionKey: MCPKeyInput,
        sortKey: MCPSortKeyInput? = nil, projection: [String]? = nil, limit: Int? = nil, cursor: String? = nil
    ) {
        self.profileID = profileID
        self.table = table
        self.indexName = indexName
        self.partitionKey = partitionKey
        self.sortKey = sortKey
        self.projection = projection
        self.limit = limit
        self.cursor = cursor
    }
}

extension MCPPartitionQueryRequest {
    /// Identifies the query for the audit log without its text. Built from
    /// the request's own fields so it exists before any connection opens and
    /// for requests that fail; the cursor's digest hashes the typed driver
    /// query, which only exists after the table was described. `limit` and
    /// `cursor` stay out so every page of one query shares a digest.
    ///
    /// `keyCondition` has the form described on `auditKeyCondition`.
    public var auditQuery: MCPAuditQuery {
        .partitionQuery(
            table: table, indexName: indexName, keyCondition: auditKeyCondition, projection: projection ?? []
        )
    }

    /// The key condition is `pk=<key>[;sk=<op>:<key>[:<key>]]` where a key is
    /// `s<length>:<text>` or `i:<number>`, and the last part is the upper
    /// bound of `between`. The length prefix stops a key value that contains
    /// the condition's own punctuation from reading as a different condition.
    private var auditKeyCondition: String {
        func key(_ input: MCPKeyInput) -> String {
            switch input {
            case .string(let text): "s" + MCPAuditDigest.field(text)
            case .integer(let number): "i:\(number)"
            }
        }
        var condition = "pk=\(key(partitionKey))"
        if let sortKey {
            condition += ";sk=\(sortKey.op.rawValue):\(key(sortKey.value))"
            if let upper = sortKey.value2 { condition += ":\(key(upper))" }
        }
        return condition
    }
}

/// The key attributes the query used, so an agent can form the next query
/// without describing the table again.
public struct MCPKeySchemaDescription: Encodable, Equatable, Sendable {
    public struct Attribute: Encodable, Equatable, Sendable {
        public let name: String
        /// `S`, `N` or `B`.
        public let type: String
    }

    public struct Index: Encodable, Equatable, Sendable {
        public let name: String
        public let partitionKey: Attribute
        public let sortKey: Attribute?

        enum CodingKeys: String, CodingKey {
            case name
            case partitionKey = "partition_key"
            case sortKey = "sort_key"
        }
    }

    public let partitionKey: Attribute
    public let sortKey: Attribute?
    public let index: Index?

    enum CodingKeys: String, CodingKey {
        case partitionKey = "partition_key"
        case sortKey = "sort_key"
        case index
    }

    init(schema: DynamoDBKeySchema, index: DynamoDBIndexKeySchema?) {
        partitionKey = Attribute(schema.partitionKey)
        sortKey = schema.sortKey.map(Attribute.init)
        self.index = index.map {
            Index(name: $0.name, partitionKey: Attribute($0.partitionKey), sortKey: $0.sortKey.map(Attribute.init))
        }
    }
}

extension MCPKeySchemaDescription.Attribute {
    init(_ attribute: DynamoDBKeyAttribute) {
        self.init(name: attribute.name, type: attribute.type.rawValue)
    }
}

/// One bounded page of a partition query. `items` is not part of the
/// encoded metadata; the tool renders it next to it.
public struct MCPPartitionQueryResult: Encodable, Equatable, Sendable {
    public let items: [[String: DynamoDBAttributeValue]]
    public let itemCount: Int
    public let keySchema: MCPKeySchemaDescription
    /// Continues the query after the last item this page returned or
    /// skipped; nil once the partition has no more items.
    public let nextCursor: String?
    public let consumedCapacityUnits: Double?
    public let redactedAttributes: [String]
    public let omittedAttributes: [MCPOmittedAttribute]
    public let skippedItems: [MCPSkippedItem]
    /// True when any item or attribute was left out, or more items follow.
    public let truncated: Bool
    public let elapsedMs: Int

    // Spelled out so the result encodes the same under any key strategy.
    enum CodingKeys: String, CodingKey {
        case itemCount = "item_count"
        case keySchema = "key_schema"
        case nextCursor = "next_cursor"
        case consumedCapacityUnits = "consumed_capacity_units"
        case redactedAttributes = "redacted_attributes"
        case omittedAttributes = "omitted_attributes"
        case skippedItems = "skipped_items"
        case truncated
        case elapsedMs = "elapsed_ms"
    }
}

public enum MCPPartitionQueryError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownConnection, liveReadNotEnabled, liveReadExpired, noProject, unsupportedDatabase, tunnelUnsupported
    case invalidRequest(String), unknownTable, unknownIndex, invalidCursor, throttled, queryFailed(String)
    case connectionFailed, openTimedOut(seconds: Int), timedOut(seconds: Int), resultTooLarge
    case tooManyConcurrentReads(limit: Int), openStillPending(retryAfterSeconds: Int)

    public var description: String {
        switch self {
        case .unknownConnection: "Unknown connection for this project"
        case .liveReadExpired: "Live reads on this production connection have expired. The user can renew them in BerryDB Settings → AI Agents."
        case .liveReadNotEnabled: "Live reads are not turned on for this connection. The user can turn them on in BerryDB Settings → AI Agents."
        case .noProject: "No BerryDB project is selected for this workspace. Call berrydb_status for details."
        case .unsupportedDatabase: "DynamoDB queries run on DynamoDB connections only; use berrydb_execute_read_query for a SQL connection."
        case .tunnelUnsupported: "Live reads over an SSH tunnel are not available for DynamoDB connections."
        case .invalidRequest(let reason): "The query was refused before it ran: \(reason)"
        case .unknownTable: "No table by that name can be read with this connection."
        case .unknownIndex: "No index by that name exists on this table."
        case .invalidCursor: "The cursor does not belong to this query or came from another session; start again without it."
        case .throttled: "DynamoDB throttled this query; try again later, with a smaller limit or on a read replica."
        case .queryFailed(let message): "DynamoDB refused the query: \(message)"
        case .connectionFailed: "BerryDB could not connect to this database."
        case .openTimedOut(let seconds): "BerryDB could not open a connection to this database within \(seconds) seconds."
        case .timedOut(let seconds): "The query did not finish within \(seconds) seconds."
        case .resultTooLarge: "Result too large; narrow the request"
        case .tooManyConcurrentReads(let limit):
            "BerryDB is already running \(limit) live reads for this session; try again when one finishes."
        case .openStillPending(let seconds):
            "An earlier connection to this database has not opened yet, so BerryDB did not open another; try again in \(seconds) \(seconds == 1 ? "second" : "seconds")."
        }
    }
}

extension MCPPartitionQueryError {
    /// A stable code for the audit log; see `MCPLiveReadError.auditCode`.
    public var auditCode: String {
        switch self {
        case .unknownConnection: "unknown_connection"
        case .liveReadNotEnabled: "live_read_not_enabled"
        case .liveReadExpired: "live_read_expired"
        case .noProject: "no_project"
        case .unsupportedDatabase: "unsupported_database"
        case .tunnelUnsupported: "tunnel_unsupported"
        case .invalidRequest: "invalid_request"
        case .unknownTable: "unknown_table"
        case .unknownIndex: "unknown_index"
        case .invalidCursor: "invalid_cursor"
        case .throttled: "throttled"
        case .queryFailed: "query_failed"
        case .connectionFailed: "connection_failed"
        case .openTimedOut: "open_timed_out"
        case .timedOut: "timed_out"
        case .resultTooLarge: "result_too_large"
        case .tooManyConcurrentReads: "too_many_concurrent_reads"
        case .openStillPending: "open_still_pending"
        }
    }
}

/// Runs one DynamoDB `Query` on one partition for a coding agent and returns
/// at most the profile's limits of its page.
public struct MCPPartitionQueryService: Sendable {
    private let coordinator: MCPConnectionCoordinator
    private let openBudget: Duration
    private let slots: MCPLiveReadSlots
    private let limits: @Sendable (Bool) -> MCPResultLimits

    /// Shares the live-read service's coordinator, open budget and slots, so
    /// SQL reads and DynamoDB queries together stay within one cap.
    public init(sharing liveReads: MCPLiveReadService) {
        self.init(coordinator: liveReads.coordinator, openBudget: liveReads.openBudget, slots: liveReads.slots)
    }

    /// `limits` gives the limits for a profile, by whether it is labeled
    /// production.
    init(
        coordinator: MCPConnectionCoordinator, openBudget: Duration, slots: MCPLiveReadSlots,
        limits: @escaping @Sendable (Bool) -> MCPResultLimits = { $0 ? .productionLiveRead : .liveRead }
    ) {
        self.coordinator = coordinator
        self.openBudget = openBudget
        self.slots = slots
        self.limits = limits
    }

    /// Checks the request's shape, then resolves the profile, reads the
    /// table's key schema, types the key values against it and runs exactly
    /// one `Query`, returning at most the profile's limits of its page. A
    /// malformed request never opens a connection, and a key the schema
    /// refuses never reaches DynamoDB. Throws `MCPPartitionQueryError`, or
    /// `CancellationError` when the calling task was cancelled; no error
    /// carries a host, an account ID, an ARN, an access key ID or a file path.
    public func run(_ request: MCPPartitionQueryRequest) async throws -> MCPPartitionQueryResult {
        try Self.checkShape(request)
        let coordinator = self.coordinator
        let limits = self.limits
        do {
            return try await MCPLiveReadAdmission.run(
                profileID: request.profileID, slots: slots, openBudget: openBudget,
                statementBudget: max(limits(false).maximumElapsed, limits(true).maximumElapsed),
                check: { profile in
                    guard profile.driverID == .dynamodb else { throw MCPPartitionQueryError.unsupportedDatabase }
                },
                open: { requestID, beforeOpening, operation in
                    try await coordinator.withPartitionSession(
                        requestID: requestID, profileID: request.profileID,
                        beforeOpening: beforeOpening, operation: operation
                    )
                },
                operation: { session, opening in
                    try await Self.query(request, session: session, opening: opening, limits: limits)
                }
            )
        } catch {
            throw Self.mapped(error)
        }
    }

    private static let unexpected = "unexpected error"

    private enum SessionFault: Error {
        case missingProfile
    }

    private static func query(
        _ request: MCPPartitionQueryRequest, session: MCPPartitionSession,
        opening: MCPRequestDeadline.Opening, limits limitsFor: @Sendable (Bool) -> MCPResultLimits
    ) async throws -> MCPPartitionQueryResult {
        // The profile carries the production label and the redactions;
        // without it neither is known, so nothing runs.
        guard let profile = session.profile else { throw SessionFault.missingProfile }
        let limits = limitsFor(profile.isProduction)
        // `DescribeTable` is the first request this session sends after
        // connecting, so it counts as part of opening.
        let schema = try await session.reader.keySchema(request.table)
        opening.opened(statementLimit: limits.maximumElapsed)

        var index: DynamoDBIndexKeySchema?
        if let name = request.indexName {
            guard let found = schema.index(named: name) else { throw MCPPartitionQueryError.unknownIndex }
            index = found
        }
        let unstarted = try typedQuery(
            request, schema: schema, index: index,
            limit: min(request.limit ?? limits.maximumRows, limits.maximumRows)
        )
        let scope = MCPQueryCursor.Scope(
            profileID: request.profileID, table: request.table, indexName: request.indexName,
            queryDigest: MCPQueryCursor.digest(of: unstarted)
        )
        var startKey: [String: DynamoDBAttributeValue]?
        if let cursor = request.cursor {
            do {
                startKey = try MCPQueryCursor.open(cursor, scope: scope)
            } catch {
                throw MCPPartitionQueryError.invalidCursor
            }
        }
        let query = DynamoDBPartitionQuery(
            table: unstarted.table, indexName: unstarted.indexName, partitionKey: unstarted.partitionKey,
            sortKey: unstarted.sortKey, projection: unstarted.projection, limit: unstarted.limit,
            exclusiveStartKey: startKey
        )

        let reader = session.reader
        let clock = ContinuousClock()
        let started = clock.now
        let page: DynamoDBQueryPage
        do {
            // The extra second lets the connection's own request timeout,
            // when it has one, end the call first.
            page = try await MCPRequestDeadline.run(limits.maximumElapsed + .seconds(1)) {
                try await reader.queryPartition(query)
            }
        } catch MCPLiveReadError.timedOut {
            throw MCPPartitionQueryError.timedOut(seconds: MCPRequestDeadline.wholeSeconds(limits.maximumElapsed))
        }
        let elapsed = clock.now - started

        let description = MCPKeySchemaDescription(schema: schema, index: index)
        let bounder = MCPPartitionResultBounder(
            limits: limits, reserve: try reserve(for: description),
            redactedAttributes: Set(profile.redactedColumns)
        )
        var bounded = try bounder.bound(page.items)
        let keyNames = schema.keyAttributeNames(index: request.indexName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The first pass budgets the metadata with a fixed reserve; the
        // cursor and the lists of what was left out can outgrow it, so the
        // finished result is measured and gives back items until it fits.
        while true {
            let nextKey: [String: DynamoDBAttributeValue]?
            // A cut page always follows a returned or skipped item: the first
            // item either fits an empty page or is skipped, and the first item
            // the measurement gives back is skipped too.
            if bounded.cutByCeiling, let last = bounded.lastProcessedIndex {
                // The next page starts after the last item returned or
                // skipped, so nothing returned repeats and a skipped item is
                // not fetched again. Its key is read from the item DynamoDB
                // sent, since a redacted or omitted attribute may be part of it.
                nextKey = page.items[last].filter { keyNames.contains($0.key) }
            } else {
                nextKey = page.lastEvaluatedKey
            }
            let nextCursor = try nextKey.map { try MCPQueryCursor.seal(lastKey: $0, scope: scope) }
            let result = MCPPartitionQueryResult(
                items: bounded.kept,
                itemCount: bounded.kept.count,
                keySchema: description,
                nextCursor: nextCursor,
                consumedCapacityUnits: page.consumedCapacityUnits,
                redactedAttributes: bounded.redactedAttributes,
                omittedAttributes: bounded.omittedAttributes,
                skippedItems: bounded.skippedItems,
                truncated: bounded.cutByCeiling || !bounded.omittedAttributes.isEmpty
                    || !bounded.skippedItems.isEmpty || nextCursor != nil,
                elapsedMs: milliseconds(elapsed)
            )
            let size = encodedSize(metadataBytes: try encoder.encode(result).count, itemBytes: bounded.keptBytes)
            if size <= limits.maximumSerializedBytes { return result }
            // Nothing left to give back: even the result without items does
            // not fit.
            guard bounded.dropLastKept() else { throw MCPPartitionQueryError.resultTooLarge }
        }
    }

    /// Bytes of the ceiling the first pass holds back for everything in the
    /// result except its items: the result's own encoding with no items,
    /// plus 1,024 bytes. That covers a short cursor and a few omitted or
    /// skipped entries, not a cursor over large keys; the finished result is
    /// measured with `encodedSize` and shrunk when it does not fit.
    static func reserve(for keySchema: MCPKeySchemaDescription) throws -> Int {
        let empty = MCPPartitionQueryResult(
            items: [], itemCount: 0, keySchema: keySchema, nextCursor: nil, consumedCapacityUnits: nil,
            redactedAttributes: [], omittedAttributes: [], skippedItems: [], truncated: false, elapsedMs: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(empty).count + 1_024
    }

    /// The bytes of `result` emitted as one JSON object: its encoded
    /// metadata with its items added under `items`, everything encoded with
    /// `[.sortedKeys, .withoutEscapingSlashes]`. The byte ceiling bounds this.
    static func encodedSize(of result: MCPPartitionQueryResult) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encodedSize(
            metadataBytes: try encoder.encode(result).count,
            itemBytes: try result.items.map { try encoder.encode($0).count }
        )
    }

    /// As `encodedSize(of:)`, from the metadata's and each item's encoded
    /// bytes: the metadata object gains a comma, `"items":`, the brackets
    /// and a comma between items.
    static func encodedSize(metadataBytes: Int, itemBytes: [Int]) -> Int {
        metadataBytes + 1 + #""items":"#.utf8.count + 2 + itemBytes.reduce(0, +) + max(0, itemBytes.count - 1)
    }

    // MARK: - Request checks

    // https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.NamingRulesDataTypes.html#HowItWorks.NamingRules
    private static let namingRule = "table and index names are 3 to 255 characters of A-Z, a-z, 0-9, _, - and ."
    private static let maximumProjection = 50

    /// Refusals that need no schema, so a malformed request opens nothing.
    private static func checkShape(_ request: MCPPartitionQueryRequest) throws {
        for name in [request.table] + (request.indexName.map { [$0] } ?? []) where !isValidName(name) {
            throw MCPPartitionQueryError.invalidRequest(namingRule)
        }
        if let projection = request.projection {
            guard projection.count <= maximumProjection else {
                throw MCPPartitionQueryError.invalidRequest("projection holds at most 50 attribute names")
            }
            guard projection.allSatisfy({ (1...255).contains($0.count) }) else {
                throw MCPPartitionQueryError.invalidRequest("projection attribute names are 1 to 255 characters")
            }
        }
        if let limit = request.limit, !(1...100).contains(limit) {
            throw MCPPartitionQueryError.invalidRequest("limit must be between 1 and 100")
        }
        if request.partitionKey == .string("") {
            throw MCPPartitionQueryError.invalidRequest("partition_key must not be empty")
        }
        if let sortKey = request.sortKey {
            if sortKey.value == .string("") || sortKey.value2 == .string("") {
                throw MCPPartitionQueryError.invalidRequest("sort_key must not be empty")
            }
            if sortKey.op == .between, sortKey.value2 == nil {
                throw MCPPartitionQueryError.invalidRequest("between needs value2")
            }
            if sortKey.op != .between, sortKey.value2 != nil {
                throw MCPPartitionQueryError.invalidRequest("\(sortKey.op.rawValue) takes no value2")
            }
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        (3...255).contains(name.count) && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        }
    }

    /// The query with its key values typed against the schema of the table,
    /// or of the index when one is named, and no start key.
    private static func typedQuery(
        _ request: MCPPartitionQueryRequest, schema: DynamoDBKeySchema, index: DynamoDBIndexKeySchema?, limit: Int
    ) throws -> DynamoDBPartitionQuery {
        let partitionAttribute = index?.partitionKey ?? schema.partitionKey
        let partitionKey = try typed(request.partitionKey, as: partitionAttribute, field: "partition_key")
        var sortCondition: DynamoDBSortKeyCondition?
        if let input = request.sortKey {
            let sortAttribute = index.map(\.sortKey) ?? schema.sortKey
            guard let sortAttribute else {
                let owner = index.map { "index \($0.name)" } ?? "table \(request.table)"
                throw MCPPartitionQueryError.invalidRequest("sort_key is not available: \(owner) has no sort key")
            }
            // https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html#DDB-Query-request-KeyConditionExpression
            if input.op == .beginsWith, sortAttribute.type == .number {
                throw MCPPartitionQueryError.invalidRequest("begins_with needs a string or binary sort key")
            }
            let value = try typed(input.value, as: sortAttribute, field: "sort_key")
            switch input.op {
            case .eq: sortCondition = .equal(value)
            case .lt: sortCondition = .lessThan(value)
            case .le: sortCondition = .lessThanOrEqual(value)
            case .gt: sortCondition = .greaterThan(value)
            case .ge: sortCondition = .greaterThanOrEqual(value)
            case .beginsWith: sortCondition = .beginsWith(value)
            case .between:
                // `checkShape` already required the upper bound.
                guard let upper = input.value2 else { throw MCPPartitionQueryError.invalidRequest("between needs value2") }
                sortCondition = .between(value, try typed(upper, as: sortAttribute, field: "sort_key"))
            }
        }
        return DynamoDBPartitionQuery(
            table: request.table, indexName: request.indexName, partitionKey: partitionKey,
            sortKey: sortCondition, projection: request.projection, limit: limit, exclusiveStartKey: nil
        )
    }

    private static func typed(_ input: MCPKeyInput, as attribute: DynamoDBKeyAttribute, field: String) throws -> DynamoDBKeyValue {
        switch (attribute.type, input) {
        case (.string, .string(let text)):
            return .string(text)
        case (.number, .integer(let number)):
            return .number(String(number))
        // A DynamoDB number: an optional sign, digits, an optional fraction
        // and an optional exponent
        // (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.NamingRulesDataTypes.html#HowItWorks.DataTypes.Number).
        case (.number, .string(let text)) where text.wholeMatch(of: #/-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/#) != nil:
            return .number(text)
        case (.binary, .string(let text)):
            if let bytes = Data(base64Encoded: text) { return .binary(bytes) }
        default:
            break
        }
        let reason = switch attribute.type {
        case .string: "\(field) must be a string for key attribute \(attribute.name) (S)"
        case .number: "\(field) must be a number for key attribute \(attribute.name) (N); pass an integer or a decimal string"
        case .binary: "\(field) must be base64 for key attribute \(attribute.name) (B)"
        }
        throw MCPPartitionQueryError.invalidRequest(reason)
    }

    // MARK: - Errors

    /// The agent-facing error for `error`. An unrecognized error raised while
    /// resolving or opening becomes `connectionFailed`, because a connect
    /// error can name the host or a file path; an error DynamoDB returned
    /// for the request is forwarded as one masked line.
    private static func mapped(_ error: Error) -> Error {
        // A cancelled caller gets cancellation whatever its request ended
        // with; it is never turned into a tool error.
        if Task.isCancelled { return CancellationError() }
        let readFailure = error as? MCPLiveReadAdmission.ReadFailure
        let underlying = readFailure?.underlying ?? error
        let wasRead = readFailure != nil
        var isCancel = underlying is CancellationError
        if case .cancelled? = underlying as? DriverError { isCancel = true }
        if isCancel {
            // The calling task is not cancelled, so the cancel came from the
            // coordinator shutting down.
            return MCPPartitionQueryError.queryFailed(unexpected)
        }
        switch underlying {
        case let error as MCPPartitionQueryError:
            return error
        case let error as MCPLiveReadError:
            // Raised by the shared slots and deadlines.
            switch error {
            case .openTimedOut(let seconds): return MCPPartitionQueryError.openTimedOut(seconds: seconds)
            case .timedOut(let seconds): return MCPPartitionQueryError.timedOut(seconds: seconds)
            case .tooManyConcurrentReads(let limit): return MCPPartitionQueryError.tooManyConcurrentReads(limit: limit)
            case .openStillPending(let seconds): return MCPPartitionQueryError.openStillPending(retryAfterSeconds: seconds)
            default: return MCPPartitionQueryError.queryFailed(unexpected)
            }
        case let error as MCPProjectResolutionError:
            switch error {
            case .unauthorizedProfile, .missingProfile: return MCPPartitionQueryError.unknownConnection
            case .liveReadNotEnabled: return MCPPartitionQueryError.liveReadNotEnabled
            case .liveReadExpired: return MCPPartitionQueryError.liveReadExpired
            case .projectNotFound, .projectDisabled: return MCPPartitionQueryError.noProject
            case .unsupportedDriver: return MCPPartitionQueryError.unsupportedDatabase
            case .tunnelUnsupported: return MCPPartitionQueryError.tunnelUnsupported
            }
        case let error as MCPConnectionCoordinatorError:
            switch error {
            case .wrongDriverFamily, .sqlReadOnlyEnforcementUnavailable, .partitionQueryUnavailable:
                return MCPPartitionQueryError.unsupportedDatabase
            case .duplicateRequestID, .shuttingDown:
                return MCPPartitionQueryError.queryFailed(unexpected)
            }
        case let error as MCPResultLimiterError where error == .metadataExceedsByteLimit:
            return MCPPartitionQueryError.resultTooLarge
        case let error as DriverError:
            switch error {
            case .connectionFailed, .connectionLost, .notConnected, .sshHostKeyChanged:
                return MCPPartitionQueryError.connectionFailed
            case .queryFailed(let message, _) where wasRead:
                return classified(message)
            case .unsupported(let message) where wasRead:
                // The driver's own refusal of a key or condition this
                // service's checks let through.
                return MCPPartitionQueryError.invalidRequest(sanitized(message))
            default:
                break
            }
        default:
            break
        }
        return wasRead ? MCPPartitionQueryError.queryFailed(unexpected) : MCPPartitionQueryError.connectionFailed
    }

    /// Error names DynamoDB returns, which the driver puts first in its
    /// message: https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Programming.Errors.html
    private static let throttlePrefixes = [
        "ProvisionedThroughputExceededException:", "ThrottlingException:", "RequestLimitExceeded:",
    ]

    private static func classified(_ message: String) -> MCPPartitionQueryError {
        if message.hasPrefix("ResourceNotFoundException:") { return .unknownTable }
        // A throttled query is reported, never retried: a retry would add
        // load to a table that is already over its capacity.
        if throttlePrefixes.contains(where: message.hasPrefix) { return .throttled }
        return .queryFailed(sanitized(message))
    }

    /// One line of at most 500 characters with every ARN, access key ID and
    /// account ID masked before the cut, so none reaches the agent even in
    /// part; AccessDeniedException, for one, quotes the caller's ARN and the
    /// table's. An ARN names the account and the resource
    /// (https://docs.aws.amazon.com/IAM/latest/UserGuide/reference-arns.html),
    /// an access key ID is AKIA or ASIA and 16 more characters
    /// (https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_identifiers.html#identifiers-unique-ids),
    /// and an account ID is 12 digits
    /// (https://docs.aws.amazon.com/accounts/latest/reference/manage-acct-identifiers.html).
    /// Any run of exactly 12 digits is masked, an account ID or not: an
    /// unrelated number lost from a message costs less than an account ID
    /// let through.
    static func sanitized(_ message: String) -> String {
        let masked = message
            .replacing(#/arn:[^\s"']+/#, with: "arn:…")
            .replacing(#/(?:AKIA|ASIA)[0-9A-Z]{16}/#, with: "…")
            // A whole run of digits, so a longer number is left as it is.
            .replacing(#/[0-9]+/#) { $0.output.count == 12 ? "…" : $0.output }
        let line = masked.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > 500 else { return line }
        return String(line.prefix(499)) + "…"
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
