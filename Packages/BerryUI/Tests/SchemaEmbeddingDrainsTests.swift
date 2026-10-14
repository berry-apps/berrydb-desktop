import BerryAI
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Whether a connection currently allows its names to be embedded; read by
/// the gate on the main actor and changed from inside a transport request.
final class Consent: @unchecked Sendable {
    private let lock = NSLock()
    private var _allowed: Bool

    init(allowed: Bool) { _allowed = allowed }

    var allowed: Bool {
        get { lock.withLock { _allowed } }
        set { lock.withLock { _allowed = newValue } }
    }
}

/// Counts calls made from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Holds embedding requests until the test opens it, so a drain that must
/// still be running when the test looks cannot have emptied its queue first.
actor EmbeddingHold {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// Answers every name with a unit vector, or with an empty one, the way the
/// transport reports any failure, while `failsEverything` is set. Records
/// every name it was asked for, calls `onRequest` with the number of
/// requests so far, and answers only once `hold` is open.
final class NameEmbeddingStub: AITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [String] = []
    private var _failsEverything = false
    private let onRequest: (@Sendable (Int) -> Void)?
    private let hold: EmbeddingHold?

    init(onRequest: (@Sendable (Int) -> Void)? = nil, hold: EmbeddingHold? = nil) {
        self.onRequest = onRequest
        self.hold = hold
    }

    var requests: [String] { lock.withLock { _requests } }
    var failsEverything: Bool {
        get { lock.withLock { _failsEverything } }
        set { lock.withLock { _failsEverything = newValue } }
    }

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
        let (fails, count) = lock.withLock {
            _requests.append(text)
            return (_failsEverything, _requests.count)
        }
        onRequest?(count)
        await hold?.wait()
        guard !fails else { return [] }
        var vector = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        vector[0] = 1
        return vector
    }
}

@MainActor
@Suite("Schema embedding drains")
struct SchemaEmbeddingDrainsTests {
    let profile = UUID()
    let owner = UUID()

    private func store(listing names: [String]) throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: names.map { SchemaListedObject(database: nil, name: $0, kind: "table", fingerprint: "f") },
            relations: nil, now: Date(timeIntervalSince1970: 1_000)
        )
        return store
    }

    private func queued(_ store: BerryStore) throws -> [String] {
        try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 1_000).map(\.name)
    }

    @Test func drainsTheWholeQueueInBatches() async throws {
        let store = try store(listing: (0..<250).map { "t\($0)" })
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()

        let indexer = SchemaEmbeddingIndexer(store: store, transport: stub)
        let drain = try #require(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(indexer) })
        await drain.value

        #expect(stub.requests.count == 250)
        #expect(try queued(store).isEmpty)
        #expect(drains.drain(of: profile) == nil)
    }

    /// A drain builds its transport once and sends every batch through it,
    /// asking for consent before each batch, and releases the transport once
    /// it has ended.
    @Test func oneDrainOfSeveralBatchesBuildsOneTransport() async throws {
        let store = try store(listing: (0..<250).map { "t\($0)" })
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()
        let builds = Counter()
        let releases = Counter()
        let asks = Counter()

        let drain = try #require(drains.start(profileID: profile, owner: owner, allowed: {
            asks.increment()
            return true
        }) {
            builds.increment()
            return DrainIndexer(SchemaEmbeddingIndexer(store: store, transport: stub), release: { releases.increment() })
        })
        await drain.value

        #expect(stub.requests.count == 250)
        #expect(builds.value == 1)
        #expect(releases.value == 1)
        #expect(asks.value >= 4, "consent is asked at the start and before each of the three batches")
    }

    /// A batch in which every request failed is how an outage shows; the
    /// profile is then left alone for five minutes, whatever triggers a drain.
    @Test func anOutageSuppressesTheNextDrainForFiveMinutes() async throws {
        let store = try store(listing: ["orders"])
        let stub = NameEmbeddingStub()
        stub.failsEverything = true
        var now = Date(timeIntervalSince1970: 10_000)
        let drains = SchemaEmbeddingDrains(now: { now })
        let indexer = SchemaEmbeddingIndexer(store: store, transport: stub)

        await drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(indexer) }?.value
        #expect(stub.requests == ["orders"])

        stub.failsEverything = false
        now += 299
        #expect(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(indexer) } == nil)
        #expect(stub.requests.count == 1)

        now += 1
        let retry = try #require(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(indexer) })
        await retry.value
        #expect(stub.requests == ["orders", "orders"])
        #expect(try queued(store).isEmpty)
    }

    /// A request made while a drain runs may come after the drain read an
    /// empty queue, so it is not dropped: the drain runs once more, through
    /// that request's gate. The rerun starts while the first drain finishes,
    /// so it has asked its gate by the time the first drain's task returns,
    /// whatever else the machine is doing.
    @Test func aRequestDuringADrainRunsItOnceMore() async throws {
        let store = try store(listing: ["orders"])
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: stub)
        let rerun = Consent(allowed: false)

        let first = try #require(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(indexer) })
        #expect(drains.start(profileID: profile, owner: owner, allowed: {
            rerun.allowed = true
            return true
        }) { DrainIndexer(indexer) } == nil)
        await first.value
        #expect(rerun.allowed)
        while let drain = drains.drain(of: profile) { await drain.value }

        #expect(stub.requests == ["orders"])
    }

    /// Consent is asked for again before every batch, so withdrawing it stops
    /// a drain between two batches, without counting anything against the
    /// names left in the queue.
    @Test func withdrawnConsentStopsTheDrainBeforeTheNextBatch() async throws {
        let store = try store(listing: (0..<150).map { "t\($0)" })
        let consent = Consent(allowed: true)
        let stub = NameEmbeddingStub(onRequest: { count in
            if count == SchemaEmbeddingDrains.batchSize { consent.allowed = false }
        })
        let drains = SchemaEmbeddingDrains()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: stub)

        await drains.start(profileID: profile, owner: owner, allowed: { consent.allowed }) { DrainIndexer(indexer) }?.value

        #expect(stub.requests.count == 100)
        let left = Set(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 1_000).map(\.name))
        #expect(left.count == 50)
        let rows = try store.currentSchemaObjects(profileID: profile).filter { left.contains($0.name) }
        #expect(rows.allSatisfy { $0.embeddingAttempts == 0 })
        #expect(drains.drain(of: profile) == nil)
    }

    /// Windows on one store share the drains, so closing one window stops
    /// the drains it started and leaves another window's alone; a request
    /// another window made while the stopped drain ran is not lost.
    ///
    /// The hand-over drain starts within the stop, and the stopped drain's
    /// own end must not end it. Its requests are held until that end has
    /// been checked: nothing orders the two drains once the test suspends,
    /// so a hand-over drain left to run can empty the queue and end before
    /// the stopped one does.
    @Test func stoppingOneOwnersDrainsHandsAWaitingRequestToTheOther() async throws {
        let store = try store(listing: (0..<300).map { "t\($0)" })
        let consent = Consent(allowed: true)
        let stub = NameEmbeddingStub()
        let hold = EmbeddingHold()
        let drains = SchemaEmbeddingDrains()
        let other = UUID()
        let first = SchemaEmbeddingIndexer(store: store, transport: stub)
        let second = SchemaEmbeddingIndexer(store: store, transport: NameEmbeddingStub(hold: hold))
        let secondAsked = Consent(allowed: false)

        let stopped = try #require(drains.start(profileID: profile, owner: owner, allowed: { consent.allowed }) { DrainIndexer(first) })
        #expect(drains.start(profileID: profile, owner: other, allowed: {
            secondAsked.allowed = true
            return true
        }) { DrainIndexer(second) } == nil)
        secondAsked.allowed = false
        drains.cancelAll(ownedBy: owner)

        let handedOver = try #require(drains.drain(of: profile))
        #expect(handedOver != stopped)
        #expect(secondAsked.allowed)
        await stopped.value
        #expect(drains.drain(of: profile) == handedOver)

        await hold.open()
        await handedOver.value
        #expect(try queued(store).isEmpty)

        let otherProfile = UUID()
        _ = try store.applySchemaListing(
            profileID: otherProfile, objects: [SchemaListedObject(database: nil, name: "x", kind: "table", fingerprint: "f")],
            relations: nil, now: Date(timeIntervalSince1970: 1_000)
        )
        let kept = try #require(drains.start(profileID: otherProfile, owner: other, allowed: { true }) { DrainIndexer(second) })
        drains.cancelAll(ownedBy: owner)
        #expect(drains.drain(of: otherProfile) == kept)
        await kept.value
    }

    /// A window that asked for one more drain while another window's drain ran
    /// and then closed must not have that drain started for it afterwards:
    /// the drain run once more in its place asks the running window's gate,
    /// never the closed window's.
    @Test func aClosedWindowsWaitingRequestStartsNoDrainForIt() async throws {
        let store = try store(listing: (0..<10).map { "t\($0)" })
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()
        let other = UUID()
        let runner = SchemaEmbeddingIndexer(store: store, transport: stub)
        let closing = SchemaEmbeddingIndexer(store: store, transport: stub)
        let closingAsked = Consent(allowed: false)

        let running = try #require(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(runner) })
        #expect(drains.start(profileID: profile, owner: other, allowed: {
            closingAsked.allowed = true
            return true
        }) { DrainIndexer(closing) } == nil)
        closingAsked.allowed = false
        drains.cancelAll(ownedBy: other)
        await running.value
        while let drain = drains.drain(of: profile) { await drain.value }

        #expect(!closingAsked.allowed)
    }

    /// The window running a drain and then another window both ask for one
    /// more drain while it runs, and the later of them closes. Its request,
    /// which replaced the first, may stand for names queued after the drain's
    /// last read, so it passes to the window running the drain instead of
    /// being dropped, and the closed window's gate is never asked. The
    /// running window's gate refuses its first ask after the setup, which
    /// ends the drain with every name still queued, so only a drain run once
    /// more can embed them.
    @Test func aClosingWindowsWaitingRequestPassesToTheRunningDrain() async throws {
        let store = try store(listing: (0..<10).map { "t\($0)" })
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()
        let other = UUID()
        let runner = SchemaEmbeddingIndexer(store: store, transport: stub)
        let closing = SchemaEmbeddingIndexer(store: store, transport: stub)
        let refusesNextAsk = Consent(allowed: false)
        let closingAsked = Consent(allowed: false)

        let running = try #require(drains.start(profileID: profile, owner: owner, allowed: {
            if refusesNextAsk.allowed {
                refusesNextAsk.allowed = false
                return false
            }
            return true
        }) { DrainIndexer(runner) })
        #expect(drains.start(profileID: profile, owner: owner, allowed: { true }) { DrainIndexer(runner) } == nil)
        #expect(drains.start(profileID: profile, owner: other, allowed: {
            closingAsked.allowed = true
            return true
        }) { DrainIndexer(closing) } == nil)
        drains.cancelAll(ownedBy: other)
        refusesNextAsk.allowed = true
        await running.value
        while let drain = drains.drain(of: profile) { await drain.value }

        #expect(!closingAsked.allowed)
        #expect(stub.requests.count == 10)
        #expect(try queued(store).isEmpty)
    }

    @Test func withoutConsentNoDrainStarts() async throws {
        let store = try store(listing: ["orders"])
        let stub = NameEmbeddingStub()
        let drains = SchemaEmbeddingDrains()
        let indexer = SchemaEmbeddingIndexer(store: store, transport: stub)
        let consent = Consent(allowed: false)

        #expect(drains.start(profileID: profile, owner: owner, allowed: { consent.allowed }) { DrainIndexer(indexer) } == nil)
        #expect(stub.requests.isEmpty)
    }
}

/// When a connection's table names may be sent to the backend for embedding.
@MainActor
@Suite("Schema embedding consent")
struct SchemaEmbeddingConsentTests {
    let profile = UUID()

    private func allows(
        _ availability: AIPanelController.Availability = .ready, current: UUID? = nil,
        license: LicenseStatus = .active(plan: "pro", daysLeft: 30), onDevice: Bool = false
    ) -> Bool {
        AIPanelController.allowsSchemaEmbedding(
            profileID: profile, currentProfileID: current ?? profile, availability: availability,
            license: license, onDevice: onDevice
        )
    }

    @Test func aReadyLicensedConnectionAllowsIt() {
        #expect(allows())
        #expect(allows(license: .trial(daysLeft: 3)))
        #expect(allows(license: .grace(plan: "pro", daysOver: 2)))
    }

    @Test func anythingShortOfThatRefusesIt() {
        #expect(!allows(current: UUID()))
        #expect(!allows(.disabledForConnection))
        #expect(!allows(.needsConsent))
        #expect(!allows(.unlicensed))
        #expect(!allows(.noConnection))
        #expect(!allows(onDevice: true))
        // An expired trial still reaches a ready panel, to show its top-up
        // prompt; it does not make names leave the machine.
        #expect(!allows(license: .trialExpired(version: "1.0")))
        #expect(!allows(license: .fallback(version: "1.0")))
        #expect(!allows(license: .none))
    }
}
