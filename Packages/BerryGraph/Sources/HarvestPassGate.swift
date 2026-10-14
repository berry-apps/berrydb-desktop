import Foundation

/// Admits the harvest passes and statistics refreshes of every coordinator
/// that shares it: at most `limit` at once, and never two passes of one
/// profile. The app opens one coordinator per window and hands each of them
/// the gate of their store, so two windows on one connection take turns
/// rather than reading the catalog twice and racing each other's writes, and
/// the whole app runs no more passes at once than one coordinator would.
///
/// Waiters are admitted in the order they arrived, skipping one whose profile
/// already has a pass inside. A coordinator orders its own requests by reason
/// before they reach the gate.
public actor HarvestPassGate {
    private struct Waiter {
        let id: UInt64
        let profileID: UUID?
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limit: Int
    private var inside = 0
    private var busyProfiles: Set<UUID> = []
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    public init(limit: Int = 2) {
        precondition(limit > 0, "a gate needs at least one place")
        self.limit = limit
    }

    /// Waits for a place. `profileID` is the profile of a pass, which also
    /// waits while another pass of that profile is inside; a statistics
    /// refresh passes nil and waits for a place only. Throws
    /// `CancellationError`, holding no place, when the calling task is
    /// cancelled while it waits.
    ///
    /// The cancellation handler reaches the actor only once this method has
    /// queued the waiter and suspended, so it always finds the waiter queued
    /// or already admitted. An admitted caller holds its place and gives it
    /// back with `leave(profileID:)` like any other.
    func enter(profileID: UUID?) async throws {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, profileID: profileID, continuation: continuation))
                admit()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Gives back the place `enter(profileID:)` took, with the same profile.
    func leave(profileID: UUID?) {
        inside -= 1
        if let profileID { busyProfiles.remove(profileID) }
        admit()
    }

    /// Lets a test wait until a caller is queued.
    var waitingCount: Int { waiters.count }

    private func admit() {
        var index = 0
        while inside < limit, index < waiters.count {
            let waiter = waiters[index]
            if let profileID = waiter.profileID, busyProfiles.contains(profileID) {
                index += 1
                continue
            }
            waiters.remove(at: index)
            inside += 1
            if let profileID = waiter.profileID { busyProfiles.insert(profileID) }
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
