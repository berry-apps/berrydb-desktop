import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

/// Counts the passes inside a stretch of work at once and keeps the highest
/// count seen.
final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highest = 0

    var peak: Int { lock.withLock { highest } }

    func enter() {
        lock.withLock {
            active += 1
            highest = max(highest, active)
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}

/// Several coordinators on one store, as one window each has on the app's
/// store, sharing the gate the app hands them for that store.
@Suite("Harvest pass gate")
struct HarvestPassGateTests {
    let profile = UUID()

    @Test func twoCoordinatorsOnOneStoreNeverOverlapPassesOfOneProfile() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 5); fake.detailDelay = .milliseconds(100)
        let store = try BerryStore(path: ":memory:")
        let gate = HarvestPassGate()
        let first = HarvestCoordinator(store: store, introspector: { _ in fake }, passGate: gate)
        let second = HarvestCoordinator(store: store, introspector: { _ in fake }, passGate: gate)

        async let a = first.request(.userAction, for: profile)
        async let b = second.request(.userAction, for: profile)
        _ = await (a, b)

        // The second pass starts after the first wrote every definition, so it
        // lists the catalog and reads none.
        #expect(fake.calls.map(\.name) == ["token", "summaries", "relations", "details", "token", "summaries", "relations"])
    }

    /// Dropping a dead catalog connection can take a while, when the peer is
    /// gone, and nothing about it needs the place the pass held.
    @Test func aFailedPassFreesItsPlaceBeforeItsConnectionIsDropped() async throws {
        let dead = ScriptedIntrospector(); dead.seed(tables: 2)
        dead.tokenError = DriverError.queryFailed(message: "server closed the connection unexpectedly", code: nil)
        let healthy = ScriptedIntrospector(); healthy.seed(tables: 2)
        let store = try BerryStore(path: ":memory:")
        let gate = HarvestPassGate(limit: 1)
        let closeStarted = ProviderLog()
        let closeHeld = Gate()
        let failing = HarvestCoordinator(
            store: store, introspector: { _ in dead },
            dropConnection: { profile in
                closeStarted.append(profile)
                await closeHeld.wait()
            },
            passGate: gate
        )
        let other = HarvestCoordinator(store: store, introspector: { _ in healthy }, passGate: gate)
        let otherProfile = UUID()

        let failed = Task { await failing.request(.userAction, for: profile) }
        try await waitUntil { closeStarted.profiles == [profile] }
        let result = Task { await other.request(.userAction, for: otherProfile) }
        let finished = Finished()
        Task { _ = await result.value; finished.mark() }
        try await waitUntil { finished.isMarked }

        #expect(finished.isMarked)
        await closeHeld.open()
        #expect(await failed.value == .failed(.introspectionFailed))
    }

    @Test func atMostTwoPassesRunAcrossCoordinators() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let probe = ConcurrencyProbe()
        let store = try BerryStore(path: ":memory:")
        let gate = HarvestPassGate()
        // Long enough that two passes the gate admits together overlap on a
        // loaded machine too.
        let provider: HarvestCoordinator.IntrospectorProvider = { _ in
            probe.enter()
            try? await Task.sleep(for: .milliseconds(300))
            probe.leave()
            return fake
        }
        let coordinators = (0..<3).map { _ in HarvestCoordinator(store: store, introspector: provider, passGate: gate) }
        let profiles = (0..<4).map { _ in UUID() }

        await withTaskGroup(of: HarvestOutcome.self) { group in
            for (index, profileID) in profiles.enumerated() {
                let coordinator = coordinators[index % coordinators.count]
                group.addTask { await coordinator.request(.userAction, for: profileID) }
            }
            for await _ in group {}
        }

        #expect(probe.peak == 2)
        #expect(fake.calls.filter { $0.name == "summaries" }.count == 4)
    }

    /// A refresh takes a place at the gate like a pass, so two passes holding
    /// both places keep a third coordinator's refresh waiting.
    @Test func aStatisticsRefreshWaitsForAPlaceAtTheGate() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let hold = Gate()
        let store = try BerryStore(path: ":memory:")
        let gate = HarvestPassGate()
        let log = ProviderLog()
        let provider: HarvestCoordinator.IntrospectorProvider = { profileID in
            log.append(profileID)
            await hold.wait()
            return fake
        }
        let first = HarvestCoordinator(store: store, introspector: provider, passGate: gate)
        let second = HarvestCoordinator(store: store, introspector: provider, passGate: gate)
        let third = HarvestCoordinator(store: store, introspector: provider, passGate: gate)
        let passes = [
            Task { await first.request(.userAction, for: UUID()) },
            Task { await second.request(.userAction, for: UUID()) },
        ]
        try await waitUntil { log.profiles.count == 2 }

        let profile = profile
        let refresh = Task {
            await third.requestStatistics(
                for: profile, connection: ScriptedConnection(answers: []), driver: .sqlite, scope: .allUserSchemas
            )
        }
        try await waitUntil { await gate.waitingCount == 1 }

        await hold.open()
        for pass in passes { _ = await pass.value }
        _ = await refresh.value
        #expect(await gate.waitingCount == 0)
    }

    /// Cancelling a pass that waits for its place answers its waiters at once
    /// and leaves the gate as it was.
    @Test func aPassWaitingAtTheGateIsCancelled() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let hold = Gate()
        let store = try BerryStore(path: ":memory:")
        let gate = HarvestPassGate()
        let log = ProviderLog()
        let holder = HarvestCoordinator(
            store: store, introspector: { profileID in log.append(profileID); await hold.wait(); return fake }, passGate: gate
        )
        let waiter = HarvestCoordinator(store: store, introspector: { _ in fake }, passGate: gate)
        let held = Task { await holder.request(.userAction, for: profile) }
        try await waitUntil { log.profiles.count == 1 }

        let waiting = Task { await waiter.request(.userAction, for: profile) }
        try await waitUntil { await gate.waitingCount == 1 }
        await waiter.cancel(profileID: profile)

        #expect(await waiting.value == .failed(.cancelled))
        #expect(await gate.waitingCount == 0)
        await hold.open()
        guard case .updated = await held.value else { Issue.record("the holding pass did not complete"); return }
        // The cancelled pass gave up its place in the queue, not a place it
        // never held: the next pass on the profile runs at once.
        guard case .unchanged = await waiter.request(.userAction, for: profile) else {
            Issue.record("a pass after the cancelled one did not run")
            return
        }
    }

    /// Two windows whose passes still overlap, for example with gates of
    /// their own, cannot move the last check back: the pass that started
    /// first and finishes last leaves the later check in place.
    @Test func aPassThatFinishesLastCannotMoveTheCheckBack() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 2)
        let clock = ManualClock()
        let hold = Gate()
        let log = ProviderLog()
        let store = try BerryStore(path: ":memory:")
        let slow = HarvestCoordinator(
            store: store, introspector: { profileID in log.append(profileID); await hold.wait(); return fake },
            now: { clock.now }
        )
        let quick = HarvestCoordinator(store: store, introspector: { _ in fake }, now: { clock.now })
        let started = clock.now
        let stale = Task { await slow.request(.userAction, for: profile) }
        try await waitUntil { log.profiles.count == 1 }

        clock.advance(by: 60)
        guard case .updated = await quick.request(.userAction, for: profile) else {
            Issue.record("the later pass did not complete")
            return
        }
        await hold.open()
        _ = await stale.value

        let checked = try #require(try store.schemaGraphState(profileID: profile)?.lastCheckedAt)
        #expect(checked == started.addingTimeInterval(60))
    }
}

/// Set once from a task, read by a polling test.
final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    var isMarked: Bool { lock.withLock { marked } }
    func mark() { lock.withLock { marked = true } }
}
