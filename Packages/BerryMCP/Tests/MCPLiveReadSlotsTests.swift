@testable import BerryMCP
import Foundation
import Synchronization
import Testing

@Suite("MCP live read slots")
struct MCPLiveReadSlotsTests {
    let profile = UUID()

    @Test func callersPastTheCapacityWaitAndAreAdmittedInArrivalOrder() async throws {
        let slots = MCPLiveReadSlots(capacity: 2)
        let a = try await slots.acquire(for: profile)
        let b = try await slots.acquire(for: profile)
        let admitted = Admissions()
        let first = Task {
            let ticket = try await slots.acquire(for: profile)
            admitted.record("first")
            return ticket
        }
        try await eventually { await slots.waiting == 1 }
        let second = Task {
            let ticket = try await slots.acquire(for: profile)
            admitted.record("second")
            return ticket
        }
        try await eventually { await slots.waiting == 2 }
        #expect(admitted.names.isEmpty)

        await slots.release(a)
        let c = try await withDeadline(.seconds(60)) { try await first.value }
        #expect(admitted.names == ["first"])
        #expect(await slots.waiting == 1)
        #expect(await slots.inUse == 2)

        await slots.release(b)
        let d = try await withDeadline(.seconds(60)) { try await second.value }
        #expect(admitted.names == ["first", "second"])
        #expect(await slots.inUse == 2)
        await slots.release(c)
        await slots.release(d)
        #expect(await slots.inUse == 0)
    }

    @Test func aCallerCancelledWhileWaitingThrowsAndTakesNoSlot() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let held = try await slots.acquire(for: profile)
        let waiter = Task { try await slots.acquire(for: profile) }
        try await eventually { await slots.waiting == 1 }
        waiter.cancel()
        let thrown = try await withDeadline(.seconds(60)) { () -> String in
            do {
                _ = try await waiter.value
                return "acquired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }
        #expect(thrown == "cancelled")
        try await eventually { await slots.waiting == 0 }
        // The released slot is free again, not handed to the cancelled caller.
        await slots.release(held)
        #expect(await slots.inUse == 0)
        _ = try await slots.acquire(for: profile)
        #expect(await slots.inUse == 1)
    }

    @Test func anAlreadyCancelledCallerTakesNoFreeSlot() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await slots.acquire(for: profile)
        }
        await #expect(throws: CancellationError.self) {
            try await withDeadline(.seconds(60)) { try await cancelled.value }
        }
        #expect(await slots.inUse == 0)
    }

    @Test func onQueuedRunsOnlyForACallerThatWaits() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let queued = Admissions()
        let held = try await slots.acquire(for: profile, onQueued: { queued.record("first") })
        #expect(queued.names.isEmpty)
        let waiter = Task { try await slots.acquire(for: profile, onQueued: { queued.record("second") }) }
        try await eventually { await slots.waiting == 1 }
        #expect(queued.names == ["second"])
        await slots.release(held)
        _ = try await withDeadline(.seconds(60)) { try await waiter.value }
        #expect(queued.names == ["second"])
    }
}

extension MCPLiveReadSlotsTests {
    /// A caller whose open is still in flight gives its slot up: callers of
    /// another connection go on, callers of the same connection fail, queued
    /// or new, until that open returns.
    @Test func anAbandonedOpenFreesItsSlotAndHoldsBackOnlyItsConnection() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let hanging = UUID()
        let other = UUID()
        let opening = try await slots.acquire(for: hanging)
        let sameConnection = Task { try await slots.acquire(for: hanging) }
        try await eventually { await slots.waiting == 1 }
        let otherConnection = Task { try await slots.acquire(for: other) }
        try await eventually { await slots.waiting == 2 }

        await slots.abandon(opening)

        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await withDeadline(.seconds(60)) { try await sameConnection.value }
        }
        let otherTicket = try await withDeadline(.seconds(60)) { try await otherConnection.value }
        #expect(await slots.inUse == 1)
        #expect(await slots.waiting == 0)
        #expect(await slots.pendingOpens(of: hanging) == 1)
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await withDeadline(.seconds(60)) { try await slots.acquire(for: hanging) }
        }

        await slots.settle(hanging)
        #expect(await slots.pendingOpens(of: hanging) == 0)
        await slots.release(otherTicket)
        _ = try await withDeadline(.seconds(60)) { try await slots.acquire(for: hanging) }
        #expect(await slots.inUse == 1)
    }
}

extension MCPLiveReadSlotsTests {
    /// An open that does not return would hold its connection back for the
    /// rest of the helper's life, even after the server recovered. Two
    /// minutes after an open was given up, one read may try the connection
    /// again while the others are refused; the refusal says how long is left.
    @Test func aHeldBackConnectionLetsOneReadTryAgainAfterTwoMinutes() async throws {
        let clock = ManualClock()
        let slots = MCPLiveReadSlots(capacity: 4, now: { clock.now })
        let hanging = UUID()
        await slots.abandon(try await slots.acquire(for: hanging))

        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await slots.acquire(for: hanging)
        }
        clock.advance(by: .seconds(119.5))
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 1)) {
            try await slots.acquire(for: hanging)
        }
        clock.advance(by: .seconds(0.5))
        let retry = try await slots.acquire(for: hanging)
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await slots.acquire(for: hanging)
        }

        // The retry hangs too: the connection is held back for two minutes
        // from then, not from when the retry started.
        clock.advance(by: .seconds(15))
        await slots.abandon(retry)
        #expect(await slots.pendingOpens(of: hanging) == 2)
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await slots.acquire(for: hanging)
        }

        // The next retry opens: the connection is no longer held back,
        // though the earlier opens are still in flight.
        clock.advance(by: .seconds(120))
        let opened = try await slots.acquire(for: hanging)
        await slots.opened(opened)
        _ = try await slots.acquire(for: hanging)
        #expect(await slots.pendingOpens(of: hanging) == 2)
        #expect(await slots.inUse == 2)
    }

    /// A retry that ends without opening anything, and without hanging,
    /// leaves no open behind for the wait to cover: the next read may try
    /// at once.
    @Test(arguments: RetryEnd.allCases)
    func aRetryThatOpensNothingLetsTheNextReadTryAtOnce(end: RetryEnd) async throws {
        let clock = ManualClock()
        let slots = MCPLiveReadSlots(capacity: 2, now: { clock.now })
        let hanging = UUID()
        let other = UUID()
        await slots.abandon(try await slots.acquire(for: hanging))
        clock.advance(by: .seconds(120))

        switch end {
        case .released:
            await slots.release(try await slots.acquire(for: hanging))
        case .cancelledWhileQueued:
            let blockers = [try await slots.acquire(for: other), try await slots.acquire(for: other)]
            let queued = Task { try await slots.acquire(for: hanging) }
            try await eventually { await slots.waiting == 1 }
            queued.cancel()
            await #expect(throws: CancellationError.self) {
                try await withDeadline(.seconds(60)) { try await queued.value }
            }
            try await eventually { await slots.waiting == 0 }
            for blocker in blockers { await slots.release(blocker) }
        }

        _ = try await withDeadline(.seconds(60)) { try await slots.acquire(for: hanging) }
    }

    enum RetryEnd: CaseIterable, Sendable {
        case released, cancelledWhileQueued
    }

    /// The opens a connection leaves behind are bounded whatever its reads
    /// do in between: with as many in flight as there are slots, it opens
    /// nothing more, even after a read of it opened and the two minutes
    /// passed.
    @Test func aConnectionWithAsManyOpensInFlightAsSlotsOpensNoMore() async throws {
        let clock = ManualClock()
        let slots = MCPLiveReadSlots(capacity: 2, now: { clock.now })
        let flapping = UUID()
        await slots.abandon(try await slots.acquire(for: flapping))
        clock.advance(by: .seconds(120))
        let retry = try await slots.acquire(for: flapping)
        await slots.opened(retry)
        await slots.release(retry)
        await slots.abandon(try await slots.acquire(for: flapping))
        #expect(await slots.pendingOpens(of: flapping) == 2)

        clock.advance(by: .seconds(120))
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await slots.acquire(for: flapping)
        }

        // One of them returns: the connection may be tried again.
        await slots.settle(flapping)
        await slots.release(try await slots.acquire(for: flapping))
    }

    /// A given-up open that returns while another is still in flight leaves
    /// the connection held back.
    @Test func aSettleWithOpensStillInFlightKeepsTheConnectionHeldBack() async throws {
        let slots = MCPLiveReadSlots(capacity: 4)
        let hanging = UUID()
        let first = try await slots.acquire(for: hanging)
        let second = try await slots.acquire(for: hanging)
        await slots.abandon(first)
        await slots.abandon(second)
        #expect(await slots.pendingOpens(of: hanging) == 2)

        await slots.settle(hanging)
        await #expect(throws: MCPLiveReadError.openStillPending(retryAfterSeconds: 120)) {
            try await slots.acquire(for: hanging)
        }
        await slots.settle(hanging)
        _ = try await slots.acquire(for: hanging)
    }
}

/// A clock a test moves by hand.
private final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}

/// Names recorded in order, readable from any task.
private final class Admissions: Sendable {
    private let recorded = Mutex<[String]>([])

    var names: [String] { recorded.withLock { $0 } }

    func record(_ name: String) {
        recorded.withLock { $0.append(name) }
    }
}
