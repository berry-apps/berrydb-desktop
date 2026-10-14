import BerryCore
import BerryDriverKit
import BerryDriverPostgres
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryGraph
@testable import BerryStore

/// Scripted catalog: the coordinator sees exactly what the test puts here,
/// and the test sees every call the coordinator made.
final class ScriptedIntrospector: Introspector, CatalogReadScoping, @unchecked Sendable {
    struct Call: Equatable { let name: String; let count: Int }
    private let lock = NSLock()
    var token: String?
    var tokenError: (any Error)?
    var summaries: [SchemaObjectSummary] = []
    var relations: [ForeignKeyRelation] = []
    var details: [TableRef: TableDetail] = [:]
    var bulk = true
    var detailDelay: Duration = .zero
    /// Returns from a detail read on cancellation instead of throwing, the
    /// way a driver without a cancel path finishes its statement.
    var ignoresCancellation = false
    var failDetailsAfterChunk: Int?
    private var recorded: [Call] = []
    private var listedScopes: [SchemaScope] = []
    /// Whether it opens a catalog read scope, as a bounded Postgres
    /// connection does.
    var scopesReads = false
    private var opened: [CatalogReadScope] = []
    private var ended: [(scope: CatalogReadScope, commit: Bool)] = []
    private var readScopes: [CatalogReadScope?] = []
    /// Runs inside the pass after each call is recorded, with the call's name
    /// and how many calls of that name there have been, so a test can change
    /// the store at an exact point of a pass.
    var onCall: (@Sendable (_ name: String, _ nth: Int) -> Void)?

    /// Read under the lock: a test polls it while a pass is appending.
    var calls: [Call] { lock.withLock { recorded } }
    var scopes: [SchemaScope] { lock.withLock { listedScopes } }

    var openedScopes: [CatalogReadScope] { lock.withLock { opened } }
    var endedScopes: [(scope: CatalogReadScope, commit: Bool)] { lock.withLock { ended } }
    /// The scope each recorded call read in.
    var scopesRead: [CatalogReadScope?] { lock.withLock { readScopes } }

    func beginCatalogReads() async throws -> CatalogReadScope? {
        guard scopesReads else { return nil }
        let scope = CatalogReadScope()
        lock.withLock { opened.append(scope) }
        return scope
    }

    func endCatalogReads(_ scope: CatalogReadScope, commit: Bool) async {
        lock.withLock { ended.append((scope, commit)) }
    }

    func record(_ name: String, _ count: Int = 0) {
        let scope = CatalogReadScope.current
        let nth = lock.withLock {
            recorded.append(Call(name: name, count: count))
            readScopes.append(scope)
            return recorded.filter { $0.name == name }.count
        }
        onCall?(name, nth)
    }

    func databases() async throws -> [DatabaseInfo] { [] }
    func objects(in database: String?) async throws -> [SchemaObject] { [] }
    func tableDetail(_ ref: TableRef) async throws -> TableDetail { details[ref]! }
    func tableStats(_ ref: TableRef) async throws -> TableStats { TableStats(estimatedRowCount: nil, sizeBytes: nil, engine: nil, comment: nil) }
    func ddl(of object: SchemaObject) async throws -> String { "" }
    func schemaVersionToken(scope: SchemaScope) async throws -> String? {
        record("token")
        if let tokenError { throw tokenError }
        return token
    }
    /// Lists only the schemas a scope names, as a catalog query filtered by
    /// schema does.
    func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] {
        lock.withLock { listedScopes.append(scope) }
        record("summaries")
        guard case let .schemas(names) = scope else { return summaries }
        return summaries.filter { names.contains($0.ref.database ?? "") }
    }
    func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] { record("relations"); return relations }
    func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        record("details", refs.count)
        if let limit = failDetailsAfterChunk, calls.filter({ $0.name == "details" }).count > limit {
            throw DriverError.queryFailed(message: "boom", code: nil)
        }
        if ignoresCancellation {
            try? await Task.sleep(for: detailDelay)
        } else {
            try await Task.sleep(for: detailDelay)
        }
        return refs.compactMap { details[$0] }
    }
    var bulkIntrospection: Bool { bulk }

    func seed(tables: Int, fingerprint: String = "fp") {
        summaries = (0..<tables).map { SchemaObjectSummary(ref: TableRef(database: "shop", name: "t\($0)"), kind: .table, fingerprint: fingerprint) }
        for s in summaries {
            details[s.ref] = TableDetail(ref: s.ref, columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)], indexes: [], foreignKeys: [])
        }
    }
}

/// The profiles whose introspector was requested, in the order the passes
/// asked for it.
final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [UUID] = []
    var profiles: [UUID] { lock.withLock { recorded } }
    func append(_ profile: UUID) { lock.withLock { recorded.append(profile) } }
}

/// Harvest states a test captured from inside a pass.
final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SchemaGraphStateRecord?] = []
    private var _detailed = 0
    var states: [SchemaGraphStateRecord?] { lock.withLock { recorded } }
    func append(_ state: SchemaGraphStateRecord?) { lock.withLock { recorded.append(state) } }
    var detailed: Int {
        get { lock.withLock { _detailed } }
        set { lock.withLock { _detailed = newValue } }
    }
}

/// A clock the test moves by hand, so a backoff interval can be compared
/// exactly.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// Holds a pass inside the introspector provider until the test opens it, so
/// that pass keeps its slot for as long as the test needs.
actor Gate {
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

/// Polls `condition` until it holds. Gives up after ten seconds, so a broken
/// coordinator fails the test instead of hanging it.
func waitUntil(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("the awaited condition never held")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@Suite("Harvest coordinator")
struct HarvestCoordinatorTests {
    let profile = UUID()

    func make(_ introspector: ScriptedIntrospector, chunk: Int = 500, maxConcurrent: Int = 2) throws -> (BerryStore, HarvestCoordinator) {
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in introspector }, maxConcurrent: maxConcurrent, chunkSize: chunk)
        return (store, coordinator)
    }

    @Test func firstPassListsAndFetchesEveryTableInChunks() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1_200)
        let (store, coordinator) = try make(fake)
        let outcome = await coordinator.request(.userAction, for: profile)
        guard case let .updated(_, added, changed, _, completed) = outcome else { Issue.record("expected updated, got \(outcome)"); return }
        // The listing adds every table without a definition, and the detail
        // pass completes those rows in place rather than versioning them.
        #expect(added == 1_200 && completed == 1_200 && changed == 0)
        #expect(fake.calls.filter { $0.name == "details" }.map(\.count) == [500, 500, 200])
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.detailedCount == 1_200 && state?.lastCheckedAt != nil && state?.versionToken == nil)
    }

    @Test func unchangedTokenStopsAtTierOne() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 3); fake.token = "v1"
        let (_, coordinator) = try make(fake)
        _ = await coordinator.request(.userAction, for: profile)
        let second = await coordinator.request(.userAction, for: profile)
        guard case .unchanged = second else { Issue.record("expected unchanged, got \(second)"); return }
        #expect(fake.calls.filter { $0.name == "summaries" }.count == 1)
    }

    @Test func changedTokenFetchesOnlyMismatchedFingerprints() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 10); fake.token = "v1"
        let (store, coordinator) = try make(fake)
        _ = await coordinator.request(.userAction, for: profile)
        fake.token = "v2"
        fake.summaries[3] = SchemaObjectSummary(ref: fake.summaries[3].ref, kind: .table, fingerprint: "fp-new")
        let outcome = await coordinator.request(.userAction, for: profile)
        // Same definition: the fingerprint is refreshed, no version or change
        // row is written, so the pass reports nothing changed.
        guard case .unchanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(try store.schemaChangeMarks(profileID: profile).count == 1)
        #expect(fake.calls.last == .init(name: "details", count: 1))
    }

    @Test func cancellationAfterListingKeepsRemovalsAndLeavesCheckedAtUntouched() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 600)
        let (store, coordinator) = try make(fake, chunk: 100)
        _ = await coordinator.request(.userAction, for: profile)
        let before = try store.schemaGraphState(profileID: profile)?.lastCheckedAt
        fake.summaries.removeLast()                       // one table dropped
        fake.summaries = fake.summaries.map { SchemaObjectSummary(ref: $0.ref, kind: .table, fingerprint: "fp2") }
        let firstPassCalls = fake.calls.count
        // The first chunk is read at once and written; the second sleeps
        // until the cancel interrupts it, so the cancel lands mid-detail with
        // progress kept however loaded the machine is.
        let earlierDetails = fake.calls.filter { $0.name == "details" }.count
        fake.onCall = { name, nth in
            if name == "details", nth == earlierDetails + 2 { fake.detailDelay = .seconds(30) }
        }
        let task = Task { await coordinator.request(.userAction, for: profile) }
        // The second chunk's fetch starts only after the first chunk was
        // written, so cancelling then lands mid-detail with progress kept.
        try await waitUntil { fake.calls.dropFirst(firstPassCalls).filter { $0.name == "details" }.count >= 2 }
        await coordinator.cancel(profileID: profile)
        let outcome = await task.value
        guard case let .partial(detailed, total) = outcome else { Issue.record("\(outcome)"); return }
        #expect(total == 599 && detailed >= 100 && detailed < total)
        #expect(try store.currentSchemaObjectNames(profileID: profile).count == 599)
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.lastCheckedAt == before)
        #expect(state?.lastErrorCode == "cancelled" && state?.retryAfter == nil)
        // Unfetched tables keep the old fingerprint and are fetched next time.
        fake.detailDelay = .zero
        let cancelledPassCalls = fake.calls.count
        let resumed = await coordinator.request(.userAction, for: profile)
        guard case .unchanged = resumed else { Issue.record("\(resumed)"); return }
        let refetched = fake.calls.dropFirst(cancelledPassCalls).filter { $0.name == "details" }.map(\.count).reduce(0, +)
        #expect(refetched == total - detailed)
        #expect(try store.schemaGraphState(profileID: profile)?.lastCheckedAt != before)
    }

    /// A pass stamps its change and, when it completes, the last check with
    /// the same instant, and a stopped pass leaves the check where it was. So
    /// the change feed, which lists changes up to the last check, shows a
    /// completed pass's change, hides a stopped pass's change, and shows that
    /// one too once a later pass completes. The Time Machine marks follow the
    /// same gate.
    @Test func theChangeFeedListsOnlyChangesOfCompletedPasses() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 300)
        let clock = ManualClock()
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in fake }, chunkSize: 100, now: { clock.now })
        let reader = GraphReader(store: store)
        _ = await coordinator.request(.userAction, for: profile)
        let first = try #require(try reader.changeMarks(profileID: profile).first)
        #expect(first.at == (try store.schemaGraphState(profileID: profile)?.lastCheckedAt))
        #expect(try reader.changes(profileID: profile, since: "id:\(try #require(first.id))", limit: 200).entries.count == 200)

        clock.advance(by: 60)
        fake.summaries = fake.summaries.dropLast().map { SchemaObjectSummary(ref: $0.ref, kind: .table, fingerprint: "fp2") }
        // The detail read sleeps until the cancel interrupts it; a short
        // delay let a loaded machine finish the read before the cancel came.
        fake.detailDelay = .seconds(30)
        let before = fake.calls.count
        let stopped = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.dropFirst(before).contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        _ = await stopped.value
        // The marks share the feed's gate, so the stopped pass's change is not
        // a mark yet either.
        #expect(try reader.changeMarks(profileID: profile).count == 1)
        let second = try #require(try store.schemaChangeMarks(profileID: profile).first?.id)
        #expect(second != first.id)
        #expect(try reader.changes(profileID: profile, since: "id:\(second)", limit: 200).entries.isEmpty)

        clock.advance(by: 60)
        fake.detailDelay = .zero
        _ = await coordinator.request(.userAction, for: profile)
        let listed = try reader.changes(profileID: profile, since: "id:\(second)", limit: 200).entries
        #expect(listed.contains { $0.kind == .removed && $0.name == "t299" })
        #expect(try reader.changeMarks(profileID: profile).compactMap(\.id).contains(second))
    }

    /// The scope changes after the listing: the detail chunk read under the
    /// old scope is not written, the pass ends as cancelled without a backoff
    /// or a recorded error, and one pass over the new scope runs for the same
    /// waiters.
    @Test func aScopeChangedAfterTheListingDiscardsTheChunkAndRunsAgain() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4)
        let (store, coordinator) = try make(fake, chunk: 2)
        let profile = profile
        let seen = StateLog()
        fake.onCall = { name, nth in
            if name == "details", nth == 1 {
                try? store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop"]"# }
            }
            if name == "summaries", nth == 2 {
                seen.append(try? store.schemaGraphState(profileID: profile))
                seen.detailed = (try? store.currentSchemaObjects(profileID: profile).filter { $0.definition != nil }.count) ?? -1
            }
        }

        let outcome = await coordinator.request(.userAction, for: profile)

        guard case .updated = outcome else { Issue.record("\(outcome)"); return }
        #expect(fake.scopes == [.allUserSchemas, .schemas(["shop"])])
        let stale = try #require(seen.states.first ?? nil)
        #expect(stale.lastCheckedAt == nil)
        #expect(stale.lastErrorCode == nil)
        #expect(stale.retryAfter == nil)
        #expect(seen.detailed == 0)
        #expect(try store.schemaGraphState(profileID: profile)?.lastCheckedAt != nil)
    }

    /// A bounded Postgres connection reads a pass's catalog in one
    /// transaction: every read of the pass is made in the scope it opened,
    /// which is committed once the pass completes.
    @Test func aPassReadsTheCatalogInOneScopeAndCommitsIt() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4); fake.scopesReads = true
        let (_, coordinator) = try make(fake, chunk: 2)

        _ = await coordinator.request(.userAction, for: profile)

        let opened = fake.openedScopes
        #expect(opened.count == 1)
        #expect(fake.endedScopes.map(\.commit) == [true])
        #expect(fake.scopesRead.count == fake.calls.count && fake.calls.contains { $0.name == "details" })
        #expect(fake.scopesRead.allSatisfy { $0 != nil && $0 == opened.first })
    }

    @Test func aFailedPassRollsItsScopeBack() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4); fake.scopesReads = true
        fake.failDetailsAfterChunk = 1
        let (_, coordinator) = try make(fake, chunk: 2)

        _ = await coordinator.request(.userAction, for: profile)

        #expect(fake.openedScopes.count == 1)
        #expect(fake.endedScopes.map(\.commit) == [false])
    }

    @Test func aCancelledPassRollsItsScopeBack() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4); fake.scopesReads = true
        fake.detailDelay = .seconds(30)
        let (_, coordinator) = try make(fake, chunk: 2)

        let request = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        _ = await request.value

        #expect(fake.openedScopes.count == 1)
        #expect(fake.endedScopes.map(\.commit) == [false])
    }

    /// Releasing clears the caches of every store connection, which the
    /// app's next reads fill again, so a pass that wrote little leaves them:
    /// an unchanged pass writes one state row.
    @Test func aPassThatWritesLittleKeepsTheStoresCaches() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4)
        let (store, coordinator) = try make(fake)

        _ = await coordinator.request(.userAction, for: profile)
        _ = await coordinator.request(.userAction, for: profile)

        #expect(store.releaseCount == 0)
    }

    /// A first pass writes a row for every table and then its definition.
    @Test func aPassThatWritesALotReleasesTheStoresCachesOnce() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: HarvestCoordinator.memoryReleaseRows / 2)
        let (store, coordinator) = try make(fake)

        _ = await coordinator.request(.userAction, for: profile)
        #expect(store.releaseCount == 1)
        _ = await coordinator.request(.userAction, for: profile)
        #expect(store.releaseCount == 1)
    }

    /// The scope sheet narrows the scope after the listing was written: it
    /// deletes the rows outside the new scope, some of them added by this
    /// pass, and the pass's next write is refused. The change row then counts
    /// what is left of it, as its entries do, not the listing it wrote.
    @Test func aScopeShrunkAfterTheListingLeavesTheChangeCountingItsEntries() async throws {
        let fake = ScriptedIntrospector()
        for (schema, name) in [("shop", "orders"), ("shop", "customers"), ("archive", "old"), ("archive", "older")] {
            let ref = TableRef(database: schema, name: name)
            fake.summaries.append(SchemaObjectSummary(ref: ref, kind: .table, fingerprint: "fp"))
            fake.details[ref] = TableDetail(
                ref: ref, columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
                indexes: [], foreignKeys: []
            )
        }
        let (store, coordinator) = try make(fake, chunk: 2)
        let profile = profile
        fake.onCall = { name, nth in
            if name == "details", nth == 1 {
                try? store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: Date())
            }
        }

        _ = await coordinator.request(.userAction, for: profile)

        let changes = try store.schemaChanges(profileID: profile, afterID: nil, since: nil, limit: 10)
        let first = try #require(changes.first)
        let entries = try store.schemaObjectChangeEntries(profileID: profile, changeID: try #require(first.id), from: nil, limit: 100)
        #expect(entries.count == 2)
        #expect(first.added == entries.count)
        #expect(first.removed == 0)
    }

    /// The scope changes after the last chunk: the final state write of the
    /// old scope's pass is refused, so its version token never stands for the
    /// new scope.
    @Test func aScopeChangedBeforeTheFinalWriteLeavesTheVersionTokenCleared() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 4); fake.token = "v1"
        // The second chunk's tables are gone by the time their details are
        // read, so that chunk writes nothing and the next write is the state.
        fake.details[TableRef(database: "shop", name: "t2")] = nil
        fake.details[TableRef(database: "shop", name: "t3")] = nil
        let (store, coordinator) = try make(fake, chunk: 2)
        let profile = profile
        let seen = StateLog()
        fake.onCall = { name, nth in
            if name == "details", nth == 2 {
                try? store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop"]"# }
            }
            if name == "token", nth == 2 {
                seen.append(try? store.schemaGraphState(profileID: profile))
            }
        }

        _ = await coordinator.request(.userAction, for: profile)

        let beforeRetry = try #require(seen.states.first ?? nil)
        #expect(beforeRetry.versionToken == nil)
        #expect(beforeRetry.lastCheckedAt == nil)
        #expect(fake.calls.filter { $0.name == "token" }.count == 2)
    }

    /// The scope narrows while the pass lists the catalog, as the scope sheet
    /// does it: selection first, then the rows outside it deleted. The
    /// listing of every schema is refused, so the objects the sheet removed
    /// are neither brought back nor, by the pass that follows over the
    /// narrower scope, recorded as dropped from the database.
    @Test func aScopeChangedWhileListingWritesNoListingAndRunsAgain() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 2)
        let archived = TableRef(database: "archive", name: "old")
        fake.summaries.append(SchemaObjectSummary(ref: archived, kind: .table, fingerprint: "fp"))
        fake.details[archived] = TableDetail(ref: archived, columns: [], indexes: [], foreignKeys: [])
        let store = try BerryStore(path: ":memory:")
        let earlier = Date(timeIntervalSince1970: 1_000)
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: fake.summaries.map {
                SchemaListedObject(database: $0.ref.database, name: $0.ref.name, kind: "table", fingerprint: "fp")
            },
            relations: [], now: earlier
        )
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = earlier }
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in fake })
        let profile = profile
        let seen = StateLog()
        fake.onCall = { name, nth in
            if name == "summaries", nth == 1 {
                try? store.saveSchemaScope(profileID: profile, selectedSchemas: ["shop"], now: earlier.addingTimeInterval(1))
            }
            if name == "summaries", nth == 2 {
                seen.append(try? store.schemaGraphState(profileID: profile))
            }
        }

        let outcome = await coordinator.request(.userAction, for: profile)

        #expect(fake.scopes == [.allUserSchemas, .schemas(["shop"])])
        let marks = try store.schemaChangeMarks(profileID: profile)
        #expect(marks.count == 1)
        #expect(marks.allSatisfy { $0.removed == 0 })
        #expect(try store.currentSchemaObjectNames(profileID: profile).map(\.name) == ["t0", "t1"])
        let beforeRetry = try #require(seen.states.first ?? nil)
        #expect(beforeRetry.lastErrorCode == nil)
        #expect(beforeRetry.retryAfter == nil)
        #expect(try store.schemaGraphState(profileID: profile)?.lastCheckedAt != earlier)
        guard case .updated = outcome else { Issue.record("\(outcome)"); return }
    }

    /// A cancel that reaches a pass which then hits a changed scope stands: no
    /// pass over the new scope is queued behind it.
    @Test func aCancelledPassThatHitAChangedScopeQueuesNoRetry() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 2)
        // The read finishes despite the cancel, the way a driver without a
        // cancel path does, so the pass reaches its write.
        fake.ignoresCancellation = true
        fake.detailDelay = .seconds(5)
        let (store, coordinator) = try make(fake)
        let profile = profile
        fake.onCall = { name, nth in
            if name == "details", nth == 1 {
                try? store.updateSchemaGraphState(profileID: profile) { $0.selectedSchemas = #"["shop"]"# }
            }
        }

        let running = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        let outcome = await running.value

        #expect(outcome == .failed(.cancelled))
        #expect(fake.calls.filter { $0.name == "token" }.count == 1)
        #expect(await coordinator.waitingCount == 0)
    }

    @Test func aCancelDuringTheLastFetchStopsThePassWhenTheDriverIgnoresIt() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 5); fake.detailDelay = .seconds(5); fake.ignoresCancellation = true
        let (store, coordinator) = try make(fake)
        let pass = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        // The chunk that came back is kept, but the pass is not complete.
        #expect(await pass.value == .partial(detailed: 5, total: 5))
        #expect(try store.schemaGraphState(profileID: profile)?.lastCheckedAt == nil)
    }

    @Test func aStoppedPassForgetsTheTokenSoAnEarlierTokenCannotHideItsChanges() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 300); fake.token = "v1"
        let (store, coordinator) = try make(fake, chunk: 100)
        _ = await coordinator.request(.userAction, for: profile)
        let original = fake.summaries
        // v2 drops a table and touches the rest; the pass stops after the
        // listing has recorded the drop.
        fake.token = "v2"
        fake.summaries = original.dropLast().map { SchemaObjectSummary(ref: $0.ref, kind: .table, fingerprint: "fp2") }
        // Interrupted by the cancel, so the pass stops whatever the load.
        fake.detailDelay = .seconds(30)
        let before = fake.calls.count
        let stopped = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.dropFirst(before).contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        _ = await stopped.value
        #expect(try store.currentSchemaObjectNames(profileID: profile).count == 299)
        // The catalog goes back to what the first token described; the stored
        // graph no longer does, so the pass must list again.
        fake.token = "v1"
        fake.summaries = original
        fake.detailDelay = .zero
        let resumed = await coordinator.request(.userAction, for: profile)
        guard case let .updated(_, added, _, _, _) = resumed else { Issue.record("\(resumed)"); return }
        #expect(added == 1)
        #expect(try store.currentSchemaObjectNames(profileID: profile).count == 300)
    }

    @Test func aCancelDuringBackoffKeepsTheFailureOnRecord() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 10); fake.failDetailsAfterChunk = 0
        let (store, coordinator) = try make(fake)
        _ = await coordinator.request(.statistics, for: profile)
        let failure = try #require(try store.schemaGraphState(profileID: profile))
        fake.failDetailsAfterChunk = nil
        // Interrupted by the cancel, as in the change-feed test.
        fake.detailDelay = .seconds(30)
        let before = fake.calls.count
        let bypass = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.dropFirst(before).contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        #expect(await bypass.value == .failed(.cancelled))
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.lastErrorCode == "introspection_failed")
        #expect(state?.lastErrorAt == failure.lastErrorAt && state?.retryAfter == failure.retryAfter)
    }

    @Test func requestsDuringAPassCoalesceIntoOneFollowUp() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 50); fake.detailDelay = .milliseconds(100)
        let (_, coordinator) = try make(fake)
        async let a = coordinator.request(.statistics, for: profile)
        // The later requests must arrive while the first pass runs.
        try await waitUntil { fake.calls.contains { $0.name == "token" } }
        async let b = coordinator.request(.userAction, for: profile)
        async let c = coordinator.request(.ownDDL, for: profile)
        _ = await (a, b, c)
        #expect(fake.calls.filter { $0.name == "summaries" }.count == 2)
        // The follow-up starts only after the first pass wrote every
        // definition, so it reads none: the two passes never overlapped.
        #expect(fake.calls.map(\.name) == ["token", "summaries", "relations", "details", "token", "summaries", "relations"])
    }

    @Test func atMostTwoPassesRunConcurrentlyByPriority() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 20); fake.detailDelay = .milliseconds(150)
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in fake }, maxConcurrent: 2, chunkSize: 500)
        let profiles = (0..<4).map { _ in UUID() }
        let started = ContinuousClock.now
        async let p0 = coordinator.request(.statistics, for: profiles[0])
        async let p1 = coordinator.request(.statistics, for: profiles[1])
        try await waitUntil { fake.calls.filter { $0.name == "token" }.count == 2 }
        async let p2 = coordinator.request(.statistics, for: profiles[2])
        async let p3 = coordinator.request(.userAction, for: profiles[3])
        _ = await (p0, p1, p2, p3)
        // Two slots: the two queued passes start only after the first two
        // finish (≥150 ms each), so the whole run takes at least two rounds.
        #expect(ContinuousClock.now - started >= .milliseconds(290))
        let order = fake.calls.filter { $0.name == "summaries" }
        #expect(order.count == 4)
    }

    @Test func queuedPassesStartByPriorityThenAge() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let log = ProviderLog()
        let gate = Gate()
        let profiles = (0..<5).map { _ in UUID() }
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(
            store: store,
            introspector: { profileID in
                log.append(profileID)
                if profileID == profiles[0] { await gate.wait() }
                return fake
            },
            maxConcurrent: 1, chunkSize: 500
        )
        var requests = [Task { await coordinator.request(.statistics, for: profiles[0]) }]
        try await waitUntil { log.profiles == [profiles[0]] }
        // Each request is queued before the next one is made, so the order
        // of equal reasons is known.
        let queued: [(index: Int, reason: HarvestReason)] = [(1, .statistics), (2, .ownDDL), (3, .userAction), (4, .ownDDL)]
        for (index, reason) in queued {
            requests.append(Task { await coordinator.request(reason, for: profiles[index]) })
            try await waitUntil { await coordinator.waitingCount == index }
        }
        await gate.open()
        for request in requests { _ = await request.value }
        // One slot, so passes run one after another in the order they were
        // picked: highest reason first, the earlier request among equals.
        #expect(log.profiles == [profiles[0], profiles[3], profiles[2], profiles[4], profiles[1]])
    }

    /// A catalog connection the server closed fails every pass that reuses
    /// it, so a pass that fails reading the catalog, or getting the
    /// connection, has the provider drop it; the next pass then reconnects.
    @Test func aPassThatFailsReadingTheCatalogDropsItsConnection() async throws {
        let dropped = ProviderLog()
        let failing = ScriptedIntrospector(); failing.seed(tables: 3)
        failing.tokenError = DriverError.queryFailed(message: "server closed the connection unexpectedly", code: nil)
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(
            store: store, introspector: { _ in failing }, dropConnection: { dropped.append($0) }
        )
        #expect(await coordinator.request(.userAction, for: profile) == .failed(.introspectionFailed))
        #expect(dropped.profiles == [profile])

        // Failing after some definitions were written drops it as well.
        let midway = ScriptedIntrospector(); midway.seed(tables: 3); midway.failDetailsAfterChunk = 1
        let other = UUID()
        let partial = HarvestCoordinator(
            store: store, introspector: { _ in midway }, dropConnection: { dropped.append($0) }, chunkSize: 1
        )
        guard case .partial = await partial.request(.userAction, for: other) else { Issue.record("expected a partial pass"); return }
        #expect(dropped.profiles == [profile, other])

        let unreachable = HarvestCoordinator(
            store: store, introspector: { _ in throw DriverError.connectionFailed("refused") },
            dropConnection: { dropped.append($0) }
        )
        let third = UUID()
        #expect(await unreachable.request(.userAction, for: third) == .failed(.connectionFailed))
        #expect(dropped.profiles == [profile, other, third])
    }

    /// Cancelling says nothing about the connection, and neither does a
    /// store that refuses a write, so both keep it.
    @Test func aCancelledPassOrAFailedWriteKeepsTheConnection() async throws {
        let dropped = ProviderLog()
        let fake = ScriptedIntrospector(); fake.seed(tables: 3); fake.detailDelay = .seconds(30)
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(
            store: store, introspector: { _ in fake }, dropConnection: { dropped.append($0) }
        )
        let cancelled = Task { await coordinator.request(.userAction, for: profile) }
        try await waitUntil { fake.calls.contains { $0.name == "details" } }
        await coordinator.cancel(profileID: profile)
        #expect(await cancelled.value == .failed(.cancelled))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        _ = try BerryStore(path: path)
        let listed = ScriptedIntrospector(); listed.seed(tables: 1)
        let readOnly = HarvestCoordinator(
            store: try BerryStore.openReadOnly(path: path), introspector: { _ in listed }, dropConnection: { dropped.append($0) }
        )
        #expect(await readOnly.request(.userAction, for: profile) == .failed(.storeWriteFailed))
        #expect(dropped.profiles.isEmpty)
    }

    @Test func failureRecordsCodeAndBackoffAndUserActionBypassesIt() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 10); fake.failDetailsAfterChunk = 0
        let (store, coordinator) = try make(fake)
        let outcome = await coordinator.request(.statistics, for: profile)
        guard case .failed(.introspectionFailed) = outcome else { Issue.record("\(outcome)"); return }
        let state = try store.schemaGraphState(profileID: profile)
        #expect(state?.lastErrorCode == "introspection_failed")
        #expect(state?.retryAfter != nil)
        guard case .backingOff = await coordinator.request(.statistics, for: profile) else { Issue.record("a background pass must back off"); return }
        fake.failDetailsAfterChunk = nil
        guard case .updated = await coordinator.request(.userAction, for: profile) else { Issue.record("user action must bypass backoff"); return }
        #expect(try store.schemaGraphState(profileID: profile)?.lastErrorCode == nil)
    }

    @Test func backoffGrowsFromOneToFiveToFifteenMinutesAndResetsOnSuccess() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 2)
        fake.tokenError = DriverError.queryFailed(message: "boom", code: nil)
        let clock = ManualClock()
        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in fake }, now: { clock.now })
        func backoff() throws -> TimeInterval? {
            let state = try store.schemaGraphState(profileID: profile)
            guard let retryAfter = state?.retryAfter, let failedAt = state?.lastErrorAt else { return nil }
            return retryAfter.timeIntervalSince(failedAt)
        }
        var steps: [TimeInterval?] = []
        for _ in 0..<4 {
            _ = await coordinator.request(.userAction, for: profile)
            steps.append(try backoff())
            clock.advance(by: 1)
        }
        #expect(steps == [60, 300, 900, 900])
        fake.tokenError = nil
        guard case .updated = await coordinator.request(.userAction, for: profile) else { Issue.record("expected a clean pass"); return }
        #expect(try backoff() == nil)
        fake.tokenError = DriverError.queryFailed(message: "boom", code: nil)
        _ = await coordinator.request(.userAction, for: profile)
        #expect(try backoff() == 60)
    }

    @Test func errorsAreClassifiedByWhereTheyCameFrom() async throws {
        func code(
            introspector provider: @escaping HarvestCoordinator.IntrospectorProvider, store: BerryStore? = nil
        ) async throws -> HarvestOutcome {
            let coordinator = HarvestCoordinator(store: try store ?? BerryStore(path: ":memory:"), introspector: provider)
            return await coordinator.request(.userAction, for: profile)
        }
        let statementTimeout = ScriptedIntrospector()
        statementTimeout.tokenError = DriverError.queryFailed(message: "canceling statement due to statement timeout", code: nil)
        #expect(try await code(introspector: { _ in statementTimeout }) == .failed(.timeout))

        let httpTimeout = ScriptedIntrospector()
        httpTimeout.tokenError = URLError(.timedOut)
        #expect(try await code(introspector: { _ in httpTimeout }) == .failed(.timeout))

        #expect(try await code(introspector: { _ in throw DriverError.connectionFailed("refused") }) == .failed(.connectionFailed))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("store.sqlite").path
        _ = try BerryStore(path: path)
        let listed = ScriptedIntrospector(); listed.seed(tables: 1)
        let readOnly = try BerryStore.openReadOnly(path: path)
        #expect(try await code(introspector: { _ in listed }, store: readOnly) == .failed(.storeWriteFailed))
    }

    @Test func largeUnscopedListingSetsTheSelectSchemasHint() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 20_001)
        fake.details = [:]   // skeleton only: details come back empty, hint is set from the listing
        let (store, coordinator) = try make(fake)
        _ = await coordinator.request(.userAction, for: profile)
        #expect(try store.schemaGraphState(profileID: profile)?.hint == "selectSchemas")
    }

    @Test func perTableDriverRefetchesEveryTableOnEachPass() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 5, fingerprint: "ignored"); fake.bulk = false
        let child = fake.summaries[1].ref
        fake.details[child] = TableDetail(ref: child, columns: fake.details[child]!.columns, indexes: [], foreignKeys: [
            ForeignKeyInfo(column: "parent_id", referencedSchema: nil, referencedTable: "t0", referencedColumn: "id"),
        ])
        let (store, coordinator) = try make(fake)
        _ = await coordinator.request(.userAction, for: profile)
        _ = await coordinator.request(.userAction, for: profile)
        #expect(fake.calls.filter { $0.name == "details" }.map(\.count) == [5, 5])
        // Listing foreign keys separately would read every table's detail a
        // second time; the relations come from the details already read.
        #expect(!fake.calls.contains { $0.name == "relations" })
        let relations = try store.currentSchemaRelations(profileID: profile)
        #expect(relations.map { "\($0.srcName).\($0.srcColumn) -> \($0.dstDatabase ?? "").\($0.dstName)" } == ["t1.parent_id -> shop.t0"])
        let marks = try store.schemaChangeMarks(profileID: profile)
        #expect(marks.count == 1 && marks.first?.relationsAdded == 1)
    }
}

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`; skipped when
/// the variable is unset.
@Suite("Harvest on Postgres", .serialized, .enabled(if: TestServer.postgres != nil))
struct HarvestOnPostgresTests {
    /// A pass reads through the bounded metadata connection in one
    /// transaction, so the server session keeps its own `statement_timeout`.
    @Test func aPassLeavesTheSessionsStatementTimeoutUnchanged() async throws {
        DriverRegistry.register(PostgresDriver.self)
        let server = TestServer.postgres!
        let manager = ConnectionManager()
        let session = try await manager.open(ConnectionConfig(
            driver: .postgres, name: "harvest", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
        defer { Task { await manager.close(session.id) } }
        func exec(_ sql: String) async throws { for try await _ in session.connection.execute(sql) {} }
        try await exec("DROP SCHEMA IF EXISTS bd_scope CASCADE")
        try await exec("CREATE SCHEMA bd_scope")
        try await exec("CREATE TABLE bd_scope.a (id int PRIMARY KEY)")
        try await exec("CREATE TABLE bd_scope.b (id int PRIMARY KEY, a_id int REFERENCES bd_scope.a(id))")
        let pool = MetadataConnections()
        let metadata = try await pool.connection(for: session)
        let store = try BerryStore(path: ":memory:")
        let profile = UUID()
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["bd_scope"], now: Date())
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in metadata.introspector })

        let outcome = await coordinator.request(.userAction, for: profile)

        guard case .updated = outcome else { Issue.record("\(outcome)"); return }
        #expect(Set(try store.currentSchemaObjectNames(profileID: profile).map(\.name)) == ["a", "b"])
        var timeout: BerryValue?
        for try await event in metadata.execute("SELECT current_setting('statement_timeout')") {
            if case let .rows(rows) = event { timeout = rows.first?.first }
        }
        #expect(timeout == .text("0"))
        await pool.closeAll()
        try await exec("DROP SCHEMA IF EXISTS bd_scope CASCADE")
    }

    /// A server that refuses the pass's scope still has its catalog read,
    /// unscoped and unbounded. A bound outside PostgreSQL's range makes it
    /// refuse SET LOCAL.
    @Test func aPassWhoseScopeIsRefusedReadsUnscopedAndCompletes() async throws {
        let server = TestServer.postgres!
        let connection = try await PostgresDriverConnection(config: ConnectionConfig(
            driver: .postgres, name: "refused", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
        defer { Task { await connection.close() } }
        func exec(_ sql: String) async throws { for try await _ in connection.execute(sql) {} }
        try await exec("DROP SCHEMA IF EXISTS bd_refused CASCADE")
        try await exec("CREATE SCHEMA bd_refused")
        try await exec("CREATE TABLE bd_refused.a (id int PRIMARY KEY)")
        #expect(await connection.boundEachStatement(by: .milliseconds(-200)))
        let store = try BerryStore(path: ":memory:")
        let profile = UUID()
        try store.saveSchemaScope(profileID: profile, selectedSchemas: ["bd_refused"], now: Date())
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in connection.introspector })

        let outcome = await coordinator.request(.userAction, for: profile)

        guard case .updated = outcome else { Issue.record("\(outcome)"); return }
        #expect(try store.currentSchemaObjectNames(profileID: profile).map(\.name) == ["a"])
        try await exec("DROP SCHEMA IF EXISTS bd_refused CASCADE")
    }
}
