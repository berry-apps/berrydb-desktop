@testable import BerryMCP
import Foundation
import Synchronization
import Testing

@Suite("MCP live read slots")
struct MCPLiveReadSlotsTests {
    let profile = UUID()

    @Test func callersPastTheCapacityWaitAndAreAdmittedInArrivalOrder() async throws {
        let slots = MCPLiveReadSlots(capacity: 2)
        try await slots.acquire(for: profile)
        try await slots.acquire(for: profile)
        let admitted = Admissions()
        let first = Task {
            try await slots.acquire(for: profile)
            admitted.record("first")
        }
        try await eventually { await slots.waiting == 1 }
        let second = Task {
            try await slots.acquire(for: profile)
            admitted.record("second")
        }
        try await eventually { await slots.waiting == 2 }
        #expect(admitted.names.isEmpty)

        await slots.release()
        try await withDeadline(.seconds(60)) { try await first.value }
        #expect(admitted.names == ["first"])
        #expect(await slots.waiting == 1)
        #expect(await slots.inUse == 2)

        await slots.release()
        try await withDeadline(.seconds(60)) { try await second.value }
        #expect(admitted.names == ["first", "second"])
        #expect(await slots.inUse == 2)
        await slots.release()
        await slots.release()
        #expect(await slots.inUse == 0)
    }

    @Test func aCallerCancelledWhileWaitingThrowsAndTakesNoSlot() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        try await slots.acquire(for: profile)
        let waiter = Task { try await slots.acquire(for: profile) }
        try await eventually { await slots.waiting == 1 }
        waiter.cancel()
        let thrown = try await withDeadline(.seconds(60)) { () -> String in
            do {
                try await waiter.value
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
        await slots.release()
        #expect(await slots.inUse == 0)
        try await slots.acquire(for: profile)
        #expect(await slots.inUse == 1)
    }

    @Test func anAlreadyCancelledCallerTakesNoFreeSlot() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await slots.acquire(for: profile)
        }
        await #expect(throws: CancellationError.self) {
            try await withDeadline(.seconds(60)) { try await cancelled.value }
        }
        #expect(await slots.inUse == 0)
    }

    @Test func onQueuedRunsOnlyForACallerThatWaits() async throws {
        let slots = MCPLiveReadSlots(capacity: 1)
        let queued = Admissions()
        try await slots.acquire(for: profile, onQueued: { queued.record("first") })
        #expect(queued.names.isEmpty)
        let waiter = Task { try await slots.acquire(for: profile, onQueued: { queued.record("second") }) }
        try await eventually { await slots.waiting == 1 }
        #expect(queued.names == ["second"])
        await slots.release()
        try await withDeadline(.seconds(60)) { try await waiter.value }
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
        try await slots.acquire(for: hanging)
        let sameConnection = Task { try await slots.acquire(for: hanging) }
        try await eventually { await slots.waiting == 1 }
        let otherConnection = Task { try await slots.acquire(for: other) }
        try await eventually { await slots.waiting == 2 }

        await slots.abandon(hanging)

        await #expect(throws: MCPLiveReadError.openStillPending) {
            try await withDeadline(.seconds(60)) { try await sameConnection.value }
        }
        try await withDeadline(.seconds(60)) { try await otherConnection.value }
        #expect(await slots.inUse == 1)
        #expect(await slots.waiting == 0)
        #expect(await slots.pendingOpens(of: hanging) == 1)
        await #expect(throws: MCPLiveReadError.openStillPending) {
            try await withDeadline(.seconds(60)) { try await slots.acquire(for: hanging) }
        }

        await slots.settle(hanging)
        #expect(await slots.pendingOpens(of: hanging) == 0)
        await slots.release()
        try await withDeadline(.seconds(60)) { try await slots.acquire(for: hanging) }
        #expect(await slots.inUse == 1)
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
