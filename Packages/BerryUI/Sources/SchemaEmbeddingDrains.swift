import BerryAI
import Foundation

/// Drains each connection profile's queue of table names that still need an
/// embedding, one drain per profile at a time, batch after batch until the
/// queue is empty. The queue is kept in the store, so a drain stopped by a
/// closed connection or by quitting resumes on a later pass.
///
/// Every batch first asks the caller, on the main actor, whether the names may
/// still be sent, and the drain stops when they may not: withdrawing consent
/// or choosing the on-device model takes effect before the next batch rather
/// than after the whole queue.
///
/// The transport reports every failed request the same way, so the only sign
/// of an outage is a batch in which every request failed. A drain that ends
/// that way leaves the profile alone for five minutes, so a provider that is
/// down is not asked again after every harvest pass.
///
/// Every window on one store shares one instance, so a profile open in two
/// windows is drained once, not once per window. Each drain belongs to the
/// window that started it, which stops only its own drains when it closes.
@MainActor
final class SchemaEmbeddingDrains {
    typealias ConsentGate = @MainActor @Sendable () -> Bool
    typealias IndexerFactory = @MainActor @Sendable () -> DrainIndexer?

    nonisolated static let batchSize = 100
    static let outageBackoff: TimeInterval = 300

    private struct Requester {
        let owner: UUID
        let allowed: ConsentGate
        let indexer: IndexerFactory
    }

    private struct Running {
        let id: UUID
        let task: Task<Void, Never>
        let requester: Requester
        /// The latest request made while the drain ran. The drain may already
        /// have found the queue empty before the pass behind that request
        /// queued new names, so it runs once more, for that requester.
        var again: Requester?
    }

    private let now: () -> Date
    private var running: [UUID: Running] = [:]
    private var retryAfter: [UUID: Date] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Starts draining the profile's queue for `owner`, while `allowed`
    /// says the names may be sent, asked before every batch. Returns nil
    /// when they may not, when the profile's outage backoff has not passed,
    /// or when a drain of the profile is running, which then runs once more
    /// for this request.
    @discardableResult
    func start(
        profileID: UUID, owner: UUID, allowed: @escaping ConsentGate, indexer: @escaping IndexerFactory
    ) -> Task<Void, Never>? {
        let requester = Requester(owner: owner, allowed: allowed, indexer: indexer)
        if running[profileID] != nil {
            running[profileID]?.again = requester
            return nil
        }
        if let until = retryAfter[profileID], now() < until { return nil }
        guard allowed() else { return nil }
        let id = UUID()
        let batch = Self.batchSize
        // One transport for the whole drain, released once its last batch is
        // done: the batches never overlap, so nothing sends through it
        // afterwards.
        let task = Task.detached(priority: .utility) { [weak self] in
            var unavailable = false
            if let built = await indexer() {
                while !Task.isCancelled, await allowed() {
                    let result = await built.indexer.drain(profileID: profileID, batch: batch)
                    if result.unavailable {
                        unavailable = true
                        break
                    }
                    if result.embedded == 0, result.failed == 0 { break }
                }
                built.release()
            }
            await self?.finish(profileID: profileID, id: id, unavailable: unavailable)
        }
        running[profileID] = Running(id: id, task: task, requester: requester)
        return task
    }

    /// The drain in progress for the profile, so a caller can wait for it.
    func drain(of profileID: UUID) -> Task<Void, Never>? {
        running[profileID]?.task
    }

    /// Stops the profile's drain, whichever window started it, as a change
    /// of what allows its names to be embedded requires. Names whose request
    /// was cancelled stay queued and count no failed attempt.
    func cancel(profileID: UUID) {
        running.removeValue(forKey: profileID)?.task.cancel()
    }

    /// Stops the profile's drain if `owner` started it. A request another
    /// window made while it ran starts a drain of its own. A request `owner`
    /// made while another window's drain ran passes to the window running
    /// that drain: it holds the only waiting request, which may stand for
    /// names queued after the drain's last read, including those of a window
    /// whose request it replaced, and a window that has closed must not
    /// start a drain. A drain more than needed costs one read of the queue.
    func cancel(profileID: UUID, ownedBy owner: UUID) {
        guard let stopped = running[profileID] else { return }
        guard stopped.requester.owner == owner else {
            if stopped.again?.owner == owner { running[profileID]?.again = stopped.requester }
            return
        }
        running[profileID] = nil
        stopped.task.cancel()
        if let waiting = stopped.again, waiting.owner != owner {
            start(profileID: profileID, owner: waiting.owner, allowed: waiting.allowed, indexer: waiting.indexer)
        }
    }

    func cancelAll() {
        for profileID in Array(running.keys) { cancel(profileID: profileID) }
    }

    func cancelAll(ownedBy owner: UUID) {
        for profileID in Array(running.keys) { cancel(profileID: profileID, ownedBy: owner) }
    }

    private func finish(profileID: UUID, id: UUID, unavailable: Bool) {
        // A drain cancelled and replaced by a newer one must not end that one.
        guard let finished = running[profileID], finished.id == id else { return }
        running[profileID] = nil
        if unavailable {
            retryAfter[profileID] = now().addingTimeInterval(Self.outageBackoff)
        } else if let waiting = finished.again {
            start(profileID: profileID, owner: waiting.owner, allowed: waiting.allowed, indexer: waiting.indexer)
        }
    }
}

/// A transport built for one embedding drain, and what releases it once the
/// drain has ended.
public struct SchemaEmbeddingTransport: Sendable {
    public let transport: any AITransport
    public let release: @Sendable () -> Void

    public init(transport: any AITransport, release: @escaping @Sendable () -> Void = {}) {
        self.transport = transport
        self.release = release
    }
}

/// The indexer one drain embeds with, and what releases its transport once
/// the drain has ended.
struct DrainIndexer: Sendable {
    let indexer: SchemaEmbeddingIndexer
    let release: @Sendable () -> Void

    init(_ indexer: SchemaEmbeddingIndexer, release: @escaping @Sendable () -> Void = {}) {
        self.indexer = indexer
        self.release = release
    }
}
