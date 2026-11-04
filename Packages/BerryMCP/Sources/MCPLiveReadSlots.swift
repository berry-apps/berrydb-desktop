import Foundation

/// Bounds how many live reads one helper process runs at once. A caller past
/// the capacity waits, in arrival order, until a slot is released; a caller
/// cancelled while it waits leaves the queue at once and takes no slot.
///
/// A read whose connection is still opening when its caller stops waiting
/// gives its slot up (`abandon`), because an open that the driver or the SSH
/// channel does not abandon when cancelled can hang for as long as the
/// network lets it, and four such opens would otherwise hold every slot.
/// Callers of the same connection are then refused with
/// `MCPLiveReadError.openStillPending`, so retries against a server that
/// never answers do not pile up connection attempts.
///
/// Such an open need not return at all: a PostgreSQL connection opened
/// with PostgresNIO over a Citadel SSH tunnel, to a listener that accepts
/// the connection and never answers, had not returned 40 seconds after it
/// was cancelled (checked against the linuxserver openssh-server bastion of
/// the test containers). So the
/// connection is held back until that open returns or for `holdBack`,
/// whichever comes first; one read may then try it again while the others
/// are refused, and once a read of it opens (`opened`) it is no longer held
/// back. Whatever its reads do, a connection never has more opens left
/// behind than there are slots.
actor MCPLiveReadSlots {
    /// One caller's hold on a slot, or its place in the queue.
    struct Ticket: Equatable, Sendable {
        let id: UUID
        let profileID: UUID
    }

    static let holdBack: Duration = .seconds(120)
    let capacity: Int
    private let now: @Sendable () -> ContinuousClock.Instant
    private var held = 0
    private var waiters: [(ticket: Ticket, continuation: CheckedContinuation<Void, Error>)] = []
    /// By profile, the opens left behind by callers that stopped waiting;
    /// each `settle` follows the `abandon` it answers.
    private var pending: [UUID: Int] = [:]
    /// By profile, until when new reads of the connection are refused: set
    /// when an open of it is given up, and when one read is let through to
    /// try it again; cleared once a read of it opens or every open left
    /// behind has returned.
    private var heldBackUntil: [UUID: ContinuousClock.Instant] = [:]
    /// By profile, the read let through to try a held-back connection.
    private var retries: [UUID: Ticket] = [:]

    init(capacity: Int, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.capacity = capacity
        self.now = now
    }

    var inUse: Int { held }

    var waiting: Int { waiters.count }

    func pendingOpens(of profileID: UUID) -> Int {
        pending[profileID] ?? 0
    }

    /// Takes a slot for a read of `profileID`, waiting for one when all are
    /// held. `onQueued` runs only when the caller has to wait, before it
    /// starts waiting.
    @discardableResult
    func acquire(for profileID: UUID, onQueued: @Sendable () -> Void = {}) async throws -> Ticket {
        try Task.checkCancellation()
        let ticket = Ticket(id: UUID(), profileID: profileID)
        try admitToConnection(ticket)
        if held < capacity {
            held += 1
            return ticket
        }
        onQueued()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((ticket, continuation))
            }
        } onCancel: {
            Task { await self.withdraw(ticket) }
        }
        return ticket
    }

    /// Releases the slot `ticket` holds, handing it to the longest waiting
    /// caller or freeing it. Handing it over directly, rather than freeing it
    /// for the next caller to take, keeps a caller that arrives later from
    /// overtaking one that waits.
    func release(_ ticket: Ticket) {
        endRetry(ticket)
        handOver()
    }

    /// Frees the slot of `ticket`, whose open is still in flight, and holds
    /// its connection back. Callers of that connection already waiting would
    /// open beside it, so they are refused as a new caller is.
    func abandon(_ ticket: Ticket) {
        let profileID = ticket.profileID
        retries[profileID] = nil
        adjustPending(profileID, by: 1)
        heldBackUntil[profileID] = now() + Self.holdBack
        let refusal = Self.refusal(after: Self.holdBack)
        for waiter in waiters where waiter.ticket.profileID == profileID {
            waiter.continuation.resume(throwing: refusal)
        }
        waiters.removeAll { $0.ticket.profileID == profileID }
        handOver()
    }

    /// An open of `profileID` that a caller left behind has returned, and
    /// the coordinator has closed what it opened.
    func settle(_ profileID: UUID) {
        adjustPending(profileID, by: -1)
        if pending[profileID] == nil { heldBackUntil[profileID] = nil }
    }

    /// The read holding `ticket` opened its connection, so the connection is
    /// no longer held back by time, though opens left behind earlier may
    /// still be in flight and still count against its bound.
    func opened(_ ticket: Ticket) {
        heldBackUntil[ticket.profileID] = nil
        endRetry(ticket)
    }

    private func admitToConnection(_ ticket: Ticket) throws {
        let profileID = ticket.profileID
        guard pendingOpens(of: profileID) < capacity else { throw Self.refusal(after: Self.holdBack) }
        guard let until = heldBackUntil[profileID] else { return }
        let left = until - now()
        guard left <= .zero else { throw Self.refusal(after: left) }
        // This read tries the connection again; the others are refused
        // until it opens, hangs or ends.
        retries[profileID] = ticket
        heldBackUntil[profileID] = now() + Self.holdBack
    }

    /// A retry that ended without opening and without hanging, cancelled,
    /// refused or failed, leaves nothing for the hold-back to wait for: the
    /// next read may try at once.
    private func endRetry(_ ticket: Ticket) {
        guard retries[ticket.profileID] == ticket else { return }
        retries[ticket.profileID] = nil
        if heldBackUntil[ticket.profileID] != nil { heldBackUntil[ticket.profileID] = now() }
    }

    private func handOver() {
        guard !waiters.isEmpty else {
            held -= 1
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    private func adjustPending(_ profileID: UUID, by delta: Int) {
        let count = (pending[profileID] ?? 0) + delta
        pending[profileID] = count == 0 ? nil : count
    }

    private static func refusal(after wait: Duration) -> MCPLiveReadError {
        .openStillPending(retryAfterSeconds: MCPRequestDeadline.wholeSeconds(wait))
    }

    /// Runs on this actor after `acquire` queued the caller, since `acquire`
    /// queues it without suspending. It finds nothing to remove when a
    /// release handed the caller the slot first: `acquire` then returns
    /// normally and the caller, cancelled or not, holds a slot to release.
    private func withdraw(_ ticket: Ticket) {
        guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        endRetry(ticket)
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
