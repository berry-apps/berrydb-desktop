import BerryDriverKit
import BerryStore
import Foundation

/// Why a pass was requested, in ascending priority: when every slot is busy,
/// the waiting pass with the highest reason starts first. A statistics
/// refresh waits for a slot as `.statistics`.
public enum HarvestReason: Int, Sendable, Comparable {
    case statistics = 0, ownDDL, userAction

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Why a pass did not complete; the raw value is what the harvest state
/// stores as its last error.
public enum HarvestErrorCode: String, Sendable, Equatable {
    case connectionFailed = "connection_failed"
    case timeout
    case cancelled
    case storeWriteFailed = "store_write_failed"
    case introspectionFailed = "introspection_failed"
}

public enum HarvestOutcome: Sendable, Equatable {
    /// The pass completed and the stored graph already matched the catalog.
    case unchanged(checkedAt: Date)
    /// The pass completed and changed the stored graph. `changeID` is nil
    /// when the only change was writing definitions of objects already known.
    case updated(changeID: Int64?, added: Int, changed: Int, removed: Int, completed: Int)
    /// Cancelled or failed while reading definitions. The first `detailed` of
    /// `total` objects were written and stay; the rest are read next time.
    case partial(detailed: Int, total: Int)
    case failed(HarvestErrorCode)
    /// An earlier failure set a retry time that this request's reason does not
    /// override, so nothing ran.
    case backingOff(until: Date)
}

/// Runs schema harvest passes for every connection profile: one pass per
/// profile at a time, at most `maxConcurrent` across profiles, and waiting
/// passes served by reason, then by when they were first requested. A
/// statistics refresh takes a slot like a pass and ranks as `.statistics`.
///
/// Coordinators that write one store share a `HarvestPassGate`, which holds
/// those limits across all of them: a pass or a refresh that has its slot
/// here still waits there for a place.
///
/// The actor only schedules. Each pass runs in its own task, so a catalog
/// query or a store transaction never keeps the actor from taking another
/// request or a cancellation.
public actor HarvestCoordinator {
    public typealias IntrospectorProvider = @Sendable (UUID) async throws -> any Introspector

    private typealias Waiter = CheckedContinuation<HarvestOutcome, Never>

    /// A pass that is wanted but not running: the highest reason asked for,
    /// the position of its first request, and everyone waiting for it.
    private struct Wanted {
        var reason: HarvestReason
        let order: UInt64
        var waiters: [Waiter]
        /// Runs again because the scope changed under an earlier pass; it is
        /// not run a third time.
        var isScopeRetry = false
    }

    private struct Running {
        let task: Task<Void, Never>
        let waiters: [Waiter]
        let reason: HarvestReason
        let isScopeRetry: Bool
    }

    private struct Profile {
        /// Waiting for a slot; never set while a pass runs.
        var queued: Wanted?
        var running: Running?
        /// Requests made while a pass runs. The running pass may already have
        /// read the catalog before the change that prompted them, so they get
        /// a pass of their own, one for all of them.
        var followUp: Wanted?
        var consecutiveFailures = 0
        var lastPrune: Date?
    }

    private let store: BerryStore
    private let provider: IntrospectorProvider
    private let dropConnection: @Sendable (UUID) async -> Void
    private let passGate: HarvestPassGate
    private let maxConcurrent: Int
    private let chunkSize: Int
    private let now: @Sendable () -> Date
    private var profiles: [UUID: Profile] = [:]
    /// Statistics refreshes waiting for a slot, by the position of their
    /// request among all requests; the continuation receives whether the slot
    /// was granted, false when the caller was cancelled first.
    private var waitingStatistics: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    /// Passes and statistics refreshes holding a slot.
    private var runningCount = 0
    private var requestCount: UInt64 = 0

    /// Retention runs at most this often per profile. It walks the profile's
    /// history indexes, which a pass every minute would repeat for nothing;
    /// history then exceeds the retention limits by at most an hour's worth.
    private static let pruneInterval: TimeInterval = 3_600

    /// A pass that wrote at least this many object and relation rows gives
    /// the store's caches back when it ends. Releasing clears the caches of
    /// every store connection, which the app's next reads fill again, and
    /// waits for reads in flight, so a pass that wrote little keeps them;
    /// memory pressure releases them in any case. Measured with the SQLite
    /// bundled with macOS (3.51.0) and its default 2,000 KiB page cache, the
    /// writer's cache held 511 KiB after a listing that wrote 20 rows, 991 KiB
    /// after 1,000 rows and 1,518 KiB after 2,000, against its bound
    /// (https://www.sqlite.org/pragma.html#pragma_cache_size).
    static let memoryReleaseRows = 1_000

    /// `dropConnection` is called with a pass's profile when the pass failed
    /// getting its connection or reading the catalog through it. A provider
    /// that caches connections drops that profile's there: a server, a
    /// pooler or an SSH tunnel closes an idle connection on its own schedule,
    /// and every later pass would otherwise fail on the dead one. A pass that
    /// was cancelled, timed out or failed writing the store keeps it.
    public init(
        store: BerryStore,
        introspector: @escaping IntrospectorProvider,
        dropConnection: @escaping @Sendable (UUID) async -> Void = { _ in },
        maxConcurrent: Int = 2,
        chunkSize: Int = 500,
        passGate: HarvestPassGate = HarvestPassGate(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        precondition(maxConcurrent > 0 && chunkSize > 0, "a coordinator needs a slot and a non-empty chunk")
        self.store = store
        self.provider = introspector
        self.dropConnection = dropConnection
        self.passGate = passGate
        self.maxConcurrent = maxConcurrent
        self.chunkSize = chunkSize
        self.now = now
    }

    /// Returns the outcome of the pass that serves this request.
    ///
    /// Coalesced: a request for a profile with a running pass waits for a
    /// single follow-up pass carrying the highest requested reason, and a
    /// request for a profile whose pass is still queued joins that pass.
    ///
    /// A pass whose scope is changed while it runs writes nothing more and is
    /// run once again over the new scope; its waiters receive that pass's
    /// outcome.
    public func request(_ reason: HarvestReason, for profileID: UUID) async -> HarvestOutcome {
        await withCheckedContinuation { waiter in
            var profile = profiles[profileID] ?? Profile()
            if profile.running != nil {
                profile.followUp = joining(profile.followUp, reason, waiter)
            } else {
                profile.queued = joining(profile.queued, reason, waiter)
            }
            profiles[profileID] = profile
            startQueued()
        }
    }

    /// Refreshes the profile's statistics rows from `connection`, which should
    /// be the metadata connection, and returns when it is done.
    ///
    /// The refresh takes one of the same `maxConcurrent` slots a pass takes, at
    /// the `.statistics` priority, so a pass the user or the schema is waiting
    /// on starts first and a refresh never makes a third piece of work.
    ///
    /// Statistics are best effort: a query the engine refuses is not reported.
    /// A refresh whose index query fails while its table query succeeds
    /// replaces the stored index counters with none. A refresh that reads no
    /// rows keeps the stored ones rather than erasing them over a transient
    /// failure, so a scope that lists no tables keeps its old statistics until
    /// a refresh returns some. Cancelling the calling task stops the refresh
    /// and writes nothing, whether it is still waiting for a slot or already
    /// reading.
    ///
    /// Returns whether the stored statistics were replaced.
    @discardableResult
    public func requestStatistics(
        for profileID: UUID, connection: any DriverConnection, driver: DriverID, scope: SchemaScope
    ) async -> Bool {
        requestCount += 1
        let ticket = requestCount
        let granted: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                waitingStatistics[ticket] = waiter
                startQueued()
            }
        } onCancel: {
            Task { await self.dropWaitingStatistics(ticket) }
        }
        guard granted else { return false }
        guard !Task.isCancelled else {
            releaseSlot()
            return false
        }
        // Detached for the same reason a pass is: the store transaction must
        // not run on this actor. It takes a place at the gate as a pass does,
        // without excluding the profile's pass, whose writes it never touches.
        let gate = passGate
        let work = Task.detached { [store, now] () -> Bool in
            guard (try? await gate.enter(profileID: nil)) != nil else { return false }
            // A bounded Postgres metadata connection reads both statistics
            // queries in one transaction.
            let rows: [SchemaStatsRecord]
            if let scoping = connection as? any CatalogReadScoping {
                rows = (try? await scoping.withCatalogReads {
                    await StatsHarvester.harvest(profileID: profileID, connection: connection, driver: driver, scope: scope, now: now())
                }) ?? []
            } else {
                rows = await StatsHarvester.harvest(
                    profileID: profileID, connection: connection, driver: driver, scope: scope, now: now()
                )
            }
            let replaced = !Task.isCancelled && !rows.isEmpty
                && (try? store.replaceSchemaStats(profileID: profileID, rows: rows)) != nil
            await gate.leave(profileID: nil)
            return replaced
        }
        let replaced = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        releaseSlot()
        return replaced
    }

    /// Stops the profile's running pass, whose waiters then receive what it
    /// managed to write, and drops its queued and follow-up passes, whose
    /// waiters receive `.failed(.cancelled)`. Statistics refreshes are not
    /// covered; they stop when the task that requested them is cancelled.
    public func cancel(profileID: UUID) {
        guard var profile = profiles[profileID] else { return }
        profile.running?.task.cancel()
        let dropped = (profile.queued?.waiters ?? []) + (profile.followUp?.waiters ?? [])
        profile.queued = nil
        profile.followUp = nil
        profiles[profileID] = profile
        for waiter in dropped { waiter.resume(returning: .failed(.cancelled)) }
    }

    /// Cancels every profile as `cancel(profileID:)` does, so statistics
    /// refreshes are not covered either.
    public func cancelAll() {
        for profileID in profiles.keys { cancel(profileID: profileID) }
    }

    /// Requests waiting for a slot, passes and statistics refreshes alike; lets
    /// a test make requests in a known order.
    var waitingCount: Int {
        profiles.values.reduce(waitingStatistics.count) {
            $0 + ($1.queued?.waiters.count ?? 0) + ($1.followUp?.waiters.count ?? 0)
        }
    }

    private func joining(_ wanted: Wanted?, _ reason: HarvestReason, _ waiter: Waiter) -> Wanted {
        guard var wanted else {
            requestCount += 1
            return Wanted(reason: reason, order: requestCount, waiters: [waiter])
        }
        wanted.reason = max(wanted.reason, reason)
        wanted.waiters.append(waiter)
        return wanted
    }

    private func startQueued() {
        while runningCount < maxConcurrent, let next = nextQueued() {
            switch next {
            case .pass(let profileID):
                start(profileID)
            case .statistics(let ticket):
                runningCount += 1
                waitingStatistics.removeValue(forKey: ticket)?.resume(returning: true)
            }
        }
    }

    private enum Next {
        case pass(UUID)
        case statistics(UInt64)
    }

    /// The waiting piece of work that goes next: the highest reason, and among
    /// equal reasons the earliest request. A refresh waits as `.statistics`.
    private func nextQueued() -> Next? {
        var best: (next: Next, reason: HarvestReason, order: UInt64)?
        func consider(_ next: Next, _ reason: HarvestReason, _ order: UInt64) {
            if let current = best, reason < current.reason || (reason == current.reason && order > current.order) {
                return
            }
            best = (next, reason, order)
        }
        for (profileID, profile) in profiles {
            if let wanted = profile.queued { consider(.pass(profileID), wanted.reason, wanted.order) }
        }
        for ticket in waitingStatistics.keys { consider(.statistics(ticket), .statistics, ticket) }
        return best?.next
    }

    private func dropWaitingStatistics(_ ticket: UInt64) {
        waitingStatistics.removeValue(forKey: ticket)?.resume(returning: false)
    }

    private func releaseSlot() {
        runningCount -= 1
        startQueued()
    }

    private func start(_ profileID: UUID) {
        guard var profile = profiles[profileID], let wanted = profile.queued else { return }
        let startedAt = now()
        let pass = HarvestPass(
            store: store, introspector: provider, chunkSize: chunkSize, now: now,
            profileID: profileID, reason: wanted.reason,
            consecutiveFailures: profile.consecutiveFailures,
            pruneDue: profile.lastPrune.map { startedAt.timeIntervalSince($0) >= Self.pruneInterval } ?? true
        )
        // Detached so the pass never runs on this actor, whatever isolation
        // the caller's context would otherwise give the task. The gate covers
        // the whole pass, from reading the stored state to recording the
        // check, so a pass of another coordinator on the profile starts from
        // what this one wrote.
        let gate = passGate
        let dropConnection = dropConnection
        let task = Task.detached { [self] in
            let result: PassResult
            do {
                try await gate.enter(profileID: profileID)
                result = await pass.run()
                await gate.leave(profileID: profileID)
                // After the place is given back: closing a connection whose
                // peer is gone can take a while, and holds nothing the next
                // pass needs.
                if result.failure == .connectionFailed || result.failure == .introspectionFailed {
                    await dropConnection(profileID)
                }
            } catch {
                // Cancelled while it waited for a place: nothing was read or
                // written, so nothing is recorded either.
                result = PassResult(outcome: .failed(.cancelled), isFailure: false, prunedAt: nil)
            }
            await finish(profileID, result)
        }
        profile.queued = nil
        profile.running = Running(
            task: task, waiters: wanted.waiters, reason: wanted.reason, isScopeRetry: wanted.isScopeRetry
        )
        profiles[profileID] = profile
        runningCount += 1
    }

    private func finish(_ profileID: UUID, _ result: PassResult) {
        guard var profile = profiles[profileID], let running = profile.running else { return }
        profile.running = nil
        runningCount -= 1
        switch result.outcome {
        case .unchanged, .updated: profile.consecutiveFailures = 0
        case .partial, .failed, .backingOff: if result.isFailure { profile.consecutiveFailures += 1 }
        }
        if let prunedAt = result.prunedAt { profile.lastPrune = prunedAt }
        // Checked here rather than in the pass, so a cancel that lands after
        // the refused write, while the pass reports back, still stands.
        if result.scopeChanged, !running.isScopeRetry, !running.task.isCancelled {
            // The pass's waiters, and every request made meanwhile, are served
            // by one pass over the new scope instead of an outcome that
            // describes nothing.
            requestCount += 1
            var retry = Wanted(reason: running.reason, order: requestCount, waiters: running.waiters, isScopeRetry: true)
            if let followUp = profile.followUp {
                retry.reason = max(retry.reason, followUp.reason)
                retry.waiters += followUp.waiters
            }
            profile.queued = retry
            profile.followUp = nil
            profiles[profileID] = profile
            startQueued()
            return
        }
        profile.queued = profile.followUp
        profile.followUp = nil
        profiles[profileID] = profile
        for waiter in running.waiters { waiter.resume(returning: result.outcome) }
        startQueued()
    }
}

private struct PassResult: Sendable {
    let outcome: HarvestOutcome
    /// Whether the pass failed for a reason other than cancellation, so the
    /// next failure backs off longer.
    let isFailure: Bool
    let prunedAt: Date?
    /// Whether a write was refused because the scope changed during the pass.
    var scopeChanged = false
    /// Why the pass stopped, when it failed; a partial outcome does not say.
    var failure: HarvestErrorCode?
}

/// What a pass wrote before it stopped, kept outside the throwing work so a
/// failure can report and finish it.
private struct PassProgress {
    var listing: SchemaListingOutcome?
    var changeID: Int64?
    var changed = 0
    var completed = 0
    /// Relations taken from table details, for an engine without bulk
    /// introspection; a bulk engine's relations are counted by the listing.
    var relationsAdded = 0
    var relationsRemoved = 0
    var detailed = 0
    var total = 0

    /// Object and relation rows the pass inserted, closed or completed; a new
    /// version closes one row and inserts another.
    var rowsWritten: Int {
        let listed = (listing?.added ?? 0) + (listing?.removed ?? 0)
            + (listing?.relationsAdded ?? 0) + (listing?.relationsRemoved ?? 0)
        return listed + changed * 2 + completed + relationsAdded + relationsRemoved
    }
}

/// A failure of the introspector provider: the connection could not be had.
private struct ProviderFailure: Error {
    let underlying: any Error
}

/// A failure of a store call. Errors are attributed to the store by where
/// they were thrown, because the store throws both its own errors and its
/// database library's, and this module does not depend on that library.
private struct StoreFailure: Error {
    let underlying: any Error
}

/// One pass over one profile's catalog: the version token, then the listing
/// with fingerprints, then the definitions of the objects whose fingerprint
/// moved, one chunk per store transaction.
private struct HarvestPass: Sendable {
    let store: BerryStore
    let introspector: HarvestCoordinator.IntrospectorProvider
    let chunkSize: Int
    let now: @Sendable () -> Date
    let profileID: UUID
    let reason: HarvestReason
    let consecutiveFailures: Int
    let pruneDue: Bool

    /// Above this many objects a whole-catalog pass is long enough that the
    /// user is asked to pick the schemas to index.
    static let selectSchemasThreshold = 20_000
    static let historyRetention: TimeInterval = 90 * 86_400
    static let historyCap = 50_000

    func run() async -> PassResult {
        var progress = PassProgress()
        let state: SchemaGraphStateRecord?
        do {
            state = try stored { try store.schemaGraphState(profileID: profileID) }
        } catch {
            return failed(error, progress: progress)
        }
        let checkedAt = now()
        // A user or an own DDL statement is waiting on this pass; only a pass
        // asked for with the background reason respects the backoff.
        if reason < .ownDDL, let retryAfter = state?.retryAfter, retryAfter > checkedAt {
            return PassResult(outcome: .backingOff(until: retryAfter), isFailure: false, prunedAt: nil)
        }
        defer {
            store.checkpoint()
            if progress.rowsWritten >= HarvestCoordinator.memoryReleaseRows { store.releaseMemory() }
        }
        do {
            let outcome = try await harvest(state: state, checkedAt: checkedAt, progress: &progress)
            return PassResult(outcome: outcome, isFailure: false, prunedAt: pruneDue ? prune(at: checkedAt) : nil)
        } catch {
            return failed(error, progress: progress)
        }
    }

    private func harvest(
        state: SchemaGraphStateRecord?, checkedAt: Date, progress: inout PassProgress
    ) async throws -> HarvestOutcome {
        let introspector: any Introspector
        do {
            introspector = try await self.introspector(profileID)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ProviderFailure(underlying: error)
        }
        // A bounded Postgres metadata connection reads the whole pass in one
        // transaction, rolled back when the pass fails or is cancelled.
        if let scoping = introspector as? any CatalogReadScoping {
            return try await scoping.withCatalogReads {
                try await read(introspector, state: state, checkedAt: checkedAt, progress: &progress)
            }
        }
        return try await read(introspector, state: state, checkedAt: checkedAt, progress: &progress)
    }

    private func read(
        _ introspector: any Introspector, state: SchemaGraphStateRecord?, checkedAt: Date, progress: inout PassProgress
    ) async throws -> HarvestOutcome {
        let scope = Self.scope(selected: state?.selectedSchemas)
        // Every write below is refused once the stored scope is another, so a
        // pass over the old scope cannot bring back what the new one left out.
        let passScope = PassScope(selectedSchemas: state?.selectedSchemas)

        // Read before the listing, so a change made while the pass lists is
        // newer than the token stored at the end and the next pass lists again.
        let token = try await introspector.schemaVersionToken(scope: scope)
        try Task.checkCancellation()
        if let token, token == state?.versionToken, state?.lastCheckedAt != nil {
            try stored {
                try store.updateSchemaGraphState(profileID: profileID, scope: passScope) { Self.markChecked(&$0, at: checkedAt) }
            }
            return .unchanged(checkedAt: checkedAt)
        }

        let bulk = introspector.bulkIntrospection
        let objects = try await introspector.objectSummaries(scope: scope).map {
            SchemaListedObject(database: $0.ref.database, name: $0.ref.name, kind: $0.kind.rawValue, fingerprint: $0.fingerprint)
        }
        try Task.checkCancellation()
        // Without bulk introspection, listing foreign keys reads every table's
        // detail, which the detail reads below repeat; the relations are taken
        // from those reads instead, and the listing leaves relations alone.
        var relations: [SchemaListedRelation]?
        if bulk {
            relations = try await introspector.foreignKeys(scope: scope).map {
                SchemaListedRelation(
                    srcDatabase: $0.source.database, srcName: $0.source.name, srcColumn: $0.column,
                    dstDatabase: $0.target.database, dstName: $0.target.name, dstColumn: $0.referencedColumn,
                    constraintName: $0.constraintName
                )
            }
            try Task.checkCancellation()
        }
        // The listing is complete here, so removals are recorded now; a pass
        // that stops during the detail reads still records every drop it saw.
        let listing = try stored {
            try store.applySchemaListing(
                profileID: profileID, objects: objects, relations: relations, now: checkedAt, scope: passScope
            )
        }
        progress.listing = listing
        progress.changeID = listing.changeID
        let hint = objects.count > Self.selectSchemasThreshold && scope == .allUserSchemas ? "selectSchemas" : nil
        if hint != state?.hint {
            try stored { try store.updateSchemaGraphState(profileID: profileID, scope: passScope) { $0.hint = hint } }
        }

        // Without bulk introspection the fingerprints prove nothing, so every
        // object is read again.
        let needed = bulk ? listing.detailNeeded : objects
        progress.total = needed.count
        var detailRelations: [SchemaListedRelation] = []
        for start in stride(from: 0, to: needed.count, by: chunkSize) {
            try Task.checkCancellation()
            let chunk = needed[start..<min(start + chunkSize, needed.count)]
            let details = try await introspector.tableDetails(chunk.map { TableRef(database: $0.database, name: $0.name) })
            let writes = try Self.detailWrites(for: chunk, details: details)
            if !bulk { detailRelations += details.flatMap(Self.relations(of:)) }
            if !writes.isEmpty {
                let outcome = try stored {
                    try store.applySchemaDetails(
                        profileID: profileID, details: writes, now: checkedAt, changeID: progress.changeID, scope: passScope
                    )
                }
                progress.changeID = outcome.changeID ?? progress.changeID
                progress.changed += outcome.changed
                progress.completed += outcome.completed
            }
            progress.detailed += chunk.count
        }
        // The last fetch can return after a cancel without noticing it; the pass
        // must not then record itself as complete.
        try Task.checkCancellation()
        if !bulk {
            let outcome = try stored {
                try store.applySchemaRelations(
                    profileID: profileID, relations: detailRelations, now: checkedAt, changeID: progress.changeID,
                    scope: passScope
                )
            }
            progress.changeID = outcome.changeID ?? progress.changeID
            progress.relationsAdded = outcome.added
            progress.relationsRemoved = outcome.removed
        }

        try stored { try finishChange(progress) }
        // Every addition, removal and new version is stamped with a change
        // row; a first definition is written in place without one.
        let changedAnything = progress.changeID != nil || progress.completed > 0
        try stored {
            try store.updateSchemaGraphState(profileID: profileID, scope: passScope) { state in
                Self.markChecked(&state, at: checkedAt)
                state.versionToken = token
                if changedAnything { state.lastChangedAt = checkedAt }
            }
        }
        guard changedAnything else { return .unchanged(checkedAt: checkedAt) }
        return .updated(
            changeID: progress.changeID, added: listing.added, changed: progress.changed,
            removed: listing.removed, completed: progress.completed
        )
    }

    /// The writes for one chunk. A detail is matched to its listed object by
    /// reference, because the introspector omits a table dropped since the
    /// listing; the listed fingerprint is stored with it, so a later pass
    /// skips the object while the fingerprint holds.
    private static func detailWrites(
        for chunk: ArraySlice<SchemaListedObject>, details: [TableDetail]
    ) throws -> [SchemaDetailWrite] {
        let byRef = Dictionary(details.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        return try chunk.compactMap { object in
            guard let detail = byRef[TableRef(database: object.database, name: object.name)] else { return nil }
            let definition = SchemaDefinition(detail: detail)
            // Encoded once: the stored text is the one hashed.
            let json = try definition.json()
            return SchemaDetailWrite(
                database: object.database, name: object.name, kind: object.kind, fingerprint: object.fingerprint,
                definitionHash: ContentHash.fnv1a64(json), definition: json,
                columnText: definition.columnText, indexText: definition.indexText
            )
        }
    }

    /// The foreign keys of one table as relations. A key without a referenced
    /// schema points into the table's own namespace, which is how an engine
    /// with a single namespace reports it.
    private static func relations(of detail: TableDetail) -> [SchemaListedRelation] {
        detail.foreignKeys.map { key in
            SchemaListedRelation(
                srcDatabase: detail.ref.database, srcName: detail.ref.name, srcColumn: key.column,
                dstDatabase: key.referencedSchema ?? detail.ref.database, dstName: key.referencedTable,
                dstColumn: key.referencedColumn, constraintName: nil
            )
        }
    }

    /// Records why the pass stopped. `lastCheckedAt` stays as it was, so a
    /// reader can tell the schema was not verified again. The state write is
    /// best effort: when the store itself is failing there is nowhere else to
    /// record it, and the outcome still carries the code.
    private func failed(_ error: any Error, progress: PassProgress) -> PassResult {
        let code = Self.code(for: error)
        let failedAt = now()
        // A changed scope says nothing about the database either, and the
        // change already cleared the version token: nothing is recorded, and
        // the coordinator runs the pass again over the new scope unless the
        // pass was cancelled. The scope save deleted the rows outside the new
        // scope, some of them stamped with this pass's change, so the change
        // row counts what is left of it rather than what the pass wrote.
        if (error as? StoreFailure)?.underlying is ScopeChanged {
            if let changeID = progress.changeID {
                try? store.recountSchemaChange(id: changeID, profileID: profileID)
            }
            let outcome: HarvestOutcome = progress.detailed > 0
                ? .partial(detailed: progress.detailed, total: progress.total)
                : .failed(.cancelled)
            return PassResult(outcome: outcome, isFailure: false, prunedAt: nil, scopeChanged: true)
        }
        // The rows the pass did write are stamped with its change row, whose
        // counts must describe them although the pass stopped.
        try? finishChange(progress)
        try? store.updateSchemaGraphState(profileID: profileID) { state in
            // A stored token must describe the stored graph. Once the listing is
            // written the graph has moved past the token, and a catalog token
            // can return to an earlier value, for example when a change is
            // undone, which would stop the next pass before it lists.
            if progress.listing != nil { state.versionToken = nil }
            // Cancelling says nothing about the database: it neither starts nor
            // extends a backoff, and while a backoff runs it leaves the failure
            // that started it on record.
            if code == .cancelled, let retryAfter = state.retryAfter, retryAfter > failedAt { return }
            state.lastErrorCode = code.rawValue
            state.lastErrorAt = failedAt
            if code != .cancelled {
                state.retryAfter = failedAt.addingTimeInterval(Self.backoff(afterFailures: consecutiveFailures + 1))
            }
        }
        let outcome: HarvestOutcome = progress.detailed > 0
            ? .partial(detailed: progress.detailed, total: progress.total)
            : .failed(code)
        return PassResult(outcome: outcome, isFailure: code != .cancelled, prunedAt: nil, failure: code)
    }

    private func finishChange(_ progress: PassProgress) throws {
        guard let changeID = progress.changeID, let listing = progress.listing else { return }
        try store.finishSchemaChange(
            id: changeID, added: listing.added, changed: progress.changed, removed: listing.removed,
            relationsAdded: listing.relationsAdded + progress.relationsAdded,
            relationsRemoved: listing.relationsRemoved + progress.relationsRemoved
        )
    }

    /// The pass's own writes are committed before this runs. A failed prune
    /// only leaves extra history, and returning no time makes the next pass
    /// try again.
    private func prune(at date: Date) -> Date? {
        do {
            try store.pruneSchemaHistory(
                profileID: profileID, olderThan: date.addingTimeInterval(-Self.historyRetention), keepingAtMost: Self.historyCap
            )
            return date
        } catch {
            return nil
        }
    }

    private func stored<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw StoreFailure(underlying: error)
        }
    }

    /// The check only moves forward. Passes of one profile do not overlap
    /// when their coordinators share a gate; should two overlap anyway, the
    /// one that started first and finishes last must not move the check back
    /// and hide a change the feed already listed.
    private static func markChecked(_ state: inout SchemaGraphStateRecord, at date: Date) {
        state.lastCheckedAt = max(state.lastCheckedAt ?? date, date)
        state.lastErrorCode = nil
        state.lastErrorAt = nil
        state.retryAfter = nil
    }

    /// `selectedSchemas` is a JSON array of schema names. A value that does
    /// not decode counts as no selection, the driver's default scope.
    private static func scope(selected: String?) -> SchemaScope {
        guard let selected, let names = try? JSONDecoder().decode([String].self, from: Data(selected.utf8)) else {
            return .allUserSchemas
        }
        return .schemas(names)
    }

    /// One, five, then fifteen minutes: a database that stays down is not
    /// queried on every background trigger, and one that recovers is picked
    /// up within a quarter of an hour.
    static func backoff(afterFailures count: Int) -> TimeInterval {
        switch count {
        case ...1: 60
        case 2: 300
        default: 900
        }
    }

    /// Cancellation wins over whatever error it surfaced as, since a driver
    /// interrupted mid-statement may report the interruption its own way. A
    /// driver error counts as a timeout by its text, because drivers report
    /// statement and network timeouts as ordinary query or connection
    /// failures.
    static func code(for error: any Error) -> HarvestErrorCode {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if (error as? StoreFailure)?.underlying is ScopeChanged { return .cancelled }
        switch error {
        case is ProviderFailure:
            return .connectionFailed
        case is StoreFailure:
            return .storeWriteFailed
        case let error as URLError where error.code == .timedOut:
            return .timeout
        case is DriverError:
            let text = String(describing: error).lowercased()
            return text.contains("timeout") || text.contains("timed out") ? .timeout : .introspectionFailed
        default:
            return .introspectionFailed
        }
    }
}
