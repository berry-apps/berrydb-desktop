import Foundation

/// Bounds how many live reads one helper process runs at once. A caller past
/// the capacity waits, in arrival order, until a slot is released; a caller
/// cancelled while it waits leaves the queue at once and takes no slot.
///
/// A read whose connection is still opening when its caller stops waiting
/// gives its slot up (`abandon`), because an open that the driver or the SSH
/// channel does not abandon when cancelled can hang for as long as the
/// network lets it, and four such opens would otherwise hold every slot.
/// Until that open returns (`settle`), callers of the same connection fail
/// with `MCPLiveReadError.openStillPending`, so retries against a server
/// that never answers do not pile up connection attempts.
actor MCPLiveReadSlots {
    let capacity: Int
    private var held = 0
    private var waiters: [(id: UUID, profileID: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    /// By profile, the opens left behind by callers that stopped waiting;
    /// each `settle` follows the `abandon` it answers.
    private var pending: [UUID: Int] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    var inUse: Int { held }

    var waiting: Int { waiters.count }

    func pendingOpens(of profileID: UUID) -> Int {
        pending[profileID] ?? 0
    }

    /// Takes a slot for a read of `profileID`, waiting for one when all are
    /// held. `onQueued` runs only when the caller has to wait, before it
    /// starts waiting.
    func acquire(for profileID: UUID, onQueued: @Sendable () -> Void = {}) async throws {
        try Task.checkCancellation()
        guard pendingOpens(of: profileID) == 0 else { throw MCPLiveReadError.openStillPending }
        if held < capacity {
            held += 1
            return
        }
        onQueued()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, profileID, continuation))
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    /// Hands the slot to the longest waiting caller, or frees it. Handing it
    /// over directly, rather than freeing it for the next caller to take,
    /// keeps a caller that arrives later from overtaking one that waits.
    func release() {
        guard !waiters.isEmpty else {
            held -= 1
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    /// Frees the slot of a read whose open of `profileID` is still in flight.
    /// Callers of that connection already waiting would open beside it, so
    /// they fail as a new caller does.
    func abandon(_ profileID: UUID) {
        adjustPending(profileID, by: 1)
        for waiter in waiters where waiter.profileID == profileID {
            waiter.continuation.resume(throwing: MCPLiveReadError.openStillPending)
        }
        waiters.removeAll { $0.profileID == profileID }
        release()
    }

    /// The open of `profileID` that a caller left behind has returned, and
    /// the coordinator has closed what it opened.
    func settle(_ profileID: UUID) {
        adjustPending(profileID, by: -1)
    }

    private func adjustPending(_ profileID: UUID, by delta: Int) {
        let count = (pending[profileID] ?? 0) + delta
        pending[profileID] = count == 0 ? nil : count
    }

    /// Runs on this actor after `acquire` queued the caller, since `acquire`
    /// queues it without suspending. It finds nothing to remove when a
    /// release handed the caller the slot first: `acquire` then returns
    /// normally and the caller, cancelled or not, holds a slot to release.
    private func withdraw(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
