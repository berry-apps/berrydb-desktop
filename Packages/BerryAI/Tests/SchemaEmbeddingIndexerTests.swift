import BerryStore
import Foundation
import SQLite3
import Testing
@testable import BerryAI

/// Answers every name with one fixed vector, an empty one for a name containing
/// "fail" and a short one for a name containing "short", and records how many
/// requests were running at the same time and how many had started when each
/// one finished.
///
/// `waitsUntil` holds a request until it returns true for that request's name,
/// the number of requests started so far and the most that have been in flight
/// at once, so a test decides the order in which requests finish without
/// relying on sleeps, which a loaded machine stretches unpredictably. Both
/// numbers only grow, so a condition that has become true stays true for every
/// request still waiting. The wait gives up after 20 seconds,
/// so a drain that can never satisfy it fails instead of hanging. `onAnswer`
/// runs just before a request is answered, to change the store while the
/// request is still outstanding.
private final class EmbeddingStub: AITransport, @unchecked Sendable {
    static let vector: [Float] = {
        var values = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        values[0] = 1
        return values
    }()

    private let lock = NSLock()
    private let waitsUntil: (@Sendable (_ name: String, _ started: Int, _ peak: Int) -> Bool)?
    private let cancelsItsOwnRequest: Bool
    private let onAnswer: (@Sendable (String) -> Void)?
    private var inFlight = 0
    private var _maxInFlight = 0
    private var _requests: [String] = []
    private var _startedWhenFinished: [String: Int] = [:]

    init(
        waitsUntil: (@Sendable (_ name: String, _ started: Int, _ peak: Int) -> Bool)? = nil,
        cancelsItsOwnRequest: Bool = false,
        onAnswer: (@Sendable (String) -> Void)? = nil
    ) {
        self.waitsUntil = waitsUntil
        self.cancelsItsOwnRequest = cancelsItsOwnRequest
        self.onAnswer = onAnswer
    }

    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var requests: [String] { lock.withLock { _requests } }
    var startedWhenFinished: [String: Int] { lock.withLock { _startedWhenFinished } }

    func createThread(dialect: String, schemaDigest: String) async throws -> String { "unused" }
    func postMessage(threadID: String, text: String, tools: [AIToolSpec]) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func postToolResult(
        threadID: String, callID: String, dispatchNonce: String,
        capabilitySetDigest: String, status: String, resultJSON: String?
    ) async throws {}
    func rankSkills(skills: [SkillRankInput], query: String) async -> [String] { [] }

    func embed(text: String) async -> [Float] {
        lock.withLock {
            _requests.append(text)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        if let waitsUntil {
            let deadline = ContinuousClock.now + .seconds(20)
            while !lock.withLock({ waitsUntil(text, _requests.count, _maxInFlight) }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        lock.withLock {
            inFlight -= 1
            _startedWhenFinished[text] = _requests.count
        }
        onAnswer?(text)
        if cancelsItsOwnRequest {
            withUnsafeCurrentTask { $0?.cancel() }
            return []
        }
        if text.contains("fail") { return [] }
        if text.contains("short") { return [1, 2, 3] }
        return Self.vector
    }
}

@Suite("Schema name embedding drain")
struct SchemaEmbeddingIndexerTests {
    let profile = UUID()
    let now = Date(timeIntervalSince1970: 1_000)

    private func store(listing names: [String]) throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: names.map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: "f") },
            relations: nil, now: now
        )
        return store
    }

    private func list(_ store: BerryStore, _ names: [String]) throws {
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: names.map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: "f") },
            relations: nil, now: now
        )
    }

    private func queued(_ store: BerryStore) throws -> [String] {
        try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 1_000).map(\.name)
    }

    /// Failed attempts so far for a name still in the queue.
    private func attempts(_ store: BerryStore, _ name: String) throws -> Int? {
        guard try queued(store).contains(name) else { return nil }
        return try store.currentSchemaObjects(profileID: profile).first { $0.name == name }?.embeddingAttempts
    }

    @Test func embedsEveryQueuedNameAndClearsTheQueue() async throws {
        let store = try store(listing: ["users", "orders", "invoices"])
        let transport = EmbeddingStub()

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport).drain(profileID: profile)

        #expect(result.embedded == 3)
        #expect(result.failed == 0)
        #expect(try queued(store).isEmpty)
        #expect(transport.requests.sorted() == ["invoices", "orders", "users"])
        let nearest = try store.nearestSchemaObjects(profileID: profile, to: EmbeddingStub.vector, limit: 8)
        #expect(nearest.map(\.name).sorted() == ["invoices", "orders", "users"])
    }

    @Test func aFailedNameKeepsItsPlaceInTheQueueAndCountsAnAttempt() async throws {
        let store = try store(listing: ["users", "fail_orders", "short_invoices"])
        let transport = EmbeddingStub()

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport).drain(profileID: profile)

        #expect(result == DrainResult(embedded: 1, failed: 2, unavailable: false))
        #expect(try queued(store).sorted() == ["fail_orders", "short_invoices"])
        #expect(try attempts(store, "fail_orders") == 1)
        #expect(try attempts(store, "short_invoices") == 1)
        #expect(try attempts(store, "users") == nil)
        let nearest = try store.nearestSchemaObjects(profileID: profile, to: EmbeddingStub.vector, limit: 8)
        #expect(nearest.map(\.name) == ["users"])
    }

    /// A failure counts only in a batch where another request succeeded, so each
    /// round brings a new name that does.
    @Test func aNameIsGivenUpOnAfterFiveFailures() async throws {
        let store = try store(listing: ["fail_orders"])
        let transport = EmbeddingStub()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: transport)
        var names = ["fail_orders"]

        for round in 0..<5 {
            names.append("ok_\(round)")
            try list(store, names)
            let result = await indexer.drain(profileID: profile)
            #expect(result == DrainResult(embedded: 1, failed: 1, unavailable: false))
        }
        names.append("ok_5")
        try list(store, names)
        let sixth = await indexer.drain(profileID: profile)

        #expect(sixth == DrainResult(embedded: 1, failed: 0, unavailable: false))
        #expect(transport.requests.filter { $0 == "fail_orders" }.count == 5)
        #expect(try queued(store).isEmpty)
    }

    /// The transport answers every failure with an empty vector, so a batch in
    /// which every request failed is the only sign of an outage, and it says
    /// nothing about any one name.
    @Test func aBatchWhereEveryRequestFailedIsAnOutageAndCountsNoAttempts() async throws {
        let store = try store(listing: ["fail_orders", "fail_invoices"])
        let transport = EmbeddingStub()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: transport)

        let result = await indexer.drain(profileID: profile)

        #expect(result == DrainResult(embedded: 0, failed: 2, unavailable: true))
        #expect(try attempts(store, "fail_orders") == 0)
        #expect(try attempts(store, "fail_invoices") == 0)
    }

    /// A store file with the given names queued, removed afterwards.
    private func storeFile(listing names: [String]) throws -> (path: String, store: BerryStore) {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
        let store = try BerryStore(path: path)
        try list(store, names)
        return (path, store)
    }

    private func removeStoreFile(_ path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// A store that cannot save says nothing about the names: the drain stops
    /// as for an outage, so the caller backs off instead of sending the same
    /// names again at once, and no name is charged an attempt.
    @Test func aStoreThatRefusesWritesStopsTheDrainAsAnOutage() async throws {
        let (path, writable) = try storeFile(listing: (0..<10).map { "t\($0)" })
        defer { removeStoreFile(path) }
        let refusing = try BerryStore.openReadOnly(path: path)
        let transport = EmbeddingStub()

        let result = await SchemaEmbeddingIndexer(store: refusing, transport: transport).drain(profileID: profile)

        #expect(result.unavailable)
        #expect(result.embedded == 0)
        #expect(transport.requests.count < 10, "requests went on after the store refused a write")
        for name in try queued(writable) { #expect(try attempts(writable, name) == 0) }
        #expect(try queued(writable).count == 10)
    }

    /// Recording a rejected name's attempt is a store write too. When it
    /// fails the attempt is never counted, so draining again would send the
    /// same names for ever; the drain ends as an outage instead.
    @Test func aFailedAttemptThatCannotBeRecordedStopsTheDrainAsAnOutage() async throws {
        let (path, writable) = try storeFile(listing: ["users", "fail_orders"])
        defer { removeStoreFile(path) }
        var connection: OpaquePointer?
        #expect(sqlite3_open(path, &connection) == SQLITE_OK)
        #expect(sqlite3_exec(connection, """
            CREATE TRIGGER refuse_attempts BEFORE UPDATE OF embeddingAttempts ON schema_object
            BEGIN SELECT RAISE(ABORT, 'refused'); END
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(connection)

        let result = await SchemaEmbeddingIndexer(store: writable, transport: EmbeddingStub()).drain(profileID: profile)

        #expect(result.unavailable)
        #expect(result.embedded == 1)
        #expect(try queued(writable) == ["fail_orders"])
    }

    /// The cost of that rule, kept on purpose: a name that fails on its own is
    /// retried for as long as every batch it is in fails, however many drains
    /// that takes.
    @Test func aLoneFailingNameIsRetriedUntilABatchAlsoHasASuccess() async throws {
        let store = try store(listing: ["fail_orders"])
        let transport = EmbeddingStub()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: transport)

        for _ in 0..<8 {
            let result = await indexer.drain(profileID: profile)
            #expect(result.unavailable)
        }

        #expect(transport.requests.count == 8)
        #expect(try attempts(store, "fail_orders") == 0)
    }

    @Test func anEmptyQueueIsNotAnOutage() async throws {
        let store = try store(listing: [])

        let result = await SchemaEmbeddingIndexer(store: store, transport: EmbeddingStub()).drain(profileID: profile)

        #expect(result == DrainResult(embedded: 0, failed: 0, unavailable: false))
    }

    /// The object can be removed while its request is outstanding. Storing its
    /// vector then would leave one that nothing deletes.
    @Test func anObjectRemovedWhileItsRequestWasOutstandingGetsNoVector() async throws {
        let store = try store(listing: ["users", "orders"])
        let transport = EmbeddingStub(onAnswer: { [profile, now] name in
            guard name == "users" else { return }
            _ = try? store.applySchemaListing(
                profileID: profile,
                objects: [SchemaListedObject(database: nil, name: "orders", kind: "table", fingerprint: "f")],
                relations: nil, now: now.addingTimeInterval(60)
            )
        })

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport, maxConcurrentRequests: 1)
            .drain(profileID: profile)

        #expect(result == DrainResult(embedded: 1, failed: 0, unavailable: false))
        let nearest = try store.nearestSchemaObjects(profileID: profile, to: EmbeddingStub.vector, limit: 8)
        #expect(nearest.map(\.name) == ["orders"])
    }

    @Test func neverRunsMoreThanTheConfiguredNumberOfRequestsAtOnce() async throws {
        let store = try store(listing: (0..<16).map { "table_\($0)" })
        // The first four hold until all four are running, so the cap is reached
        // and a missing cap would show as more than four at once.
        let firstFour: Set<String> = ["table_0", "table_1", "table_2", "table_3"]
        let transport = EmbeddingStub(waitsUntil: { name, _, peak in !firstFour.contains(name) || peak >= 4 })

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport).drain(profileID: profile)

        #expect(result.embedded == 16)
        #expect(transport.maxInFlight == 4)
    }

    @Test func aSlowRequestDoesNotHoldBackTheNextOnesInTheBatch() async throws {
        // Fixed groups of two would wait for the slow name before starting the
        // third; a sliding window keeps the other slot busy meanwhile. The slow
        // name is held until every other name has been requested.
        let names = ["slow_one"] + (1..<6).map { "table_\($0)" }
        let store = try store(listing: names)
        let transport = EmbeddingStub(waitsUntil: { name, started, _ in name != "slow_one" || started == 6 })

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport, maxConcurrentRequests: 2)
            .drain(profileID: profile)

        #expect(result.embedded == 6)
        #expect(transport.startedWhenFinished["slow_one"] == 6)
    }

    @Test func takesAtMostOneBatchOldestFirst() async throws {
        let store = try store(listing: ["a", "b", "c", "d", "e"])
        let transport = EmbeddingStub()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: transport)

        let result = await indexer.drain(profileID: profile, batch: 2)

        #expect(result.embedded == 2)
        #expect(Set(transport.requests) == ["a", "b"])
        #expect(try queued(store) == ["c", "d", "e"])
    }

    @Test func onlyDrainsTheRequestedConnection() async throws {
        let store = try store(listing: ["users"])
        let other = UUID()
        _ = try store.applySchemaListing(
            profileID: other, objects: [SchemaListedObject(database: nil, name: "elsewhere", kind: "table", fingerprint: "f")],
            relations: nil, now: now
        )
        let transport = EmbeddingStub()

        _ = await SchemaEmbeddingIndexer(store: store, transport: transport).drain(profileID: profile)

        #expect(transport.requests == ["users"])
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: other, limit: 10).map(\.name) == ["elsewhere"])
    }

    @Test func aCancelledDrainStartsNoRequestsAndKeepsTheQueue() async throws {
        let store = try store(listing: ["users", "orders"])
        let transport = EmbeddingStub()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: transport)

        let result = await Task { [profile] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await indexer.drain(profileID: profile)
        }.value

        #expect(result.embedded == 0)
        #expect(result.failed == 0)
        #expect(transport.requests.isEmpty)
        #expect(try queued(store).sorted() == ["orders", "users"])
    }

    /// A request that ends because the work was cancelled says nothing about
    /// the name, and counting it would use up the name's five attempts every
    /// time the app quits mid-drain.
    @Test func aRequestCancelledMidFlightDoesNotCountAsAFailure() async throws {
        let store = try store(listing: ["users"])
        let transport = EmbeddingStub(cancelsItsOwnRequest: true)

        let result = await SchemaEmbeddingIndexer(store: store, transport: transport).drain(profileID: profile)

        #expect(result.embedded == 0)
        #expect(result.failed == 0)
        #expect(try attempts(store, "users") == 0)
        #expect(try queued(store) == ["users"])
    }
}
