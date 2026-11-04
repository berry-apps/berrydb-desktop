import Foundation
import Synchronization

/// Where one request stands with its slot. The request's own work and
/// its caller both report to it, from different tasks; each transition
/// happens under one lock, so the slot is released, or given up as
/// abandoned, exactly once.
final class MCPLiveReadAdmission: Sendable {
    private enum State {
        case idle, waiting, admitted, opened, finished
        /// The caller stopped waiting before a slot was granted.
        case left
        /// The caller is giving the slot up while the connection opens;
        /// `finishedWhileAbandoning` is the work finishing meanwhile.
        case abandoning, finishedWhileAbandoning, abandoned
    }
    private struct Record {
        var state = State.idle
        var waited = false
        var ticket: MCPLiveReadSlots.Ticket?
    }
    private let record = Mutex(Record())

    /// True once the request waited for a slot, whether it got one since.
    var waited: Bool { record.withLock { $0.waited } }

    func queue() {
        record.withLock {
            if $0.state == .idle { $0.state = .waiting }
            $0.waited = true
        }
    }

    /// False when the caller already left: a slot granted in the moment
    /// before the cancel reached the request is then handed back, since
    /// nobody would give it up if its open hung.
    func admit(_ ticket: MCPLiveReadSlots.Ticket) -> Bool {
        record.withLock {
            guard $0.state != .left else { return false }
            $0.state = .admitted
            $0.ticket = ticket
            return true
        }
    }

    /// Records that the session opened and tells the slots, which stop
    /// holding the connection back. A request already given up while
    /// opening no longer holds the slot it would report for.
    func opened(with slots: MCPLiveReadSlots) async {
        let ticket = record.withLock { record -> MCPLiveReadSlots.Ticket? in
            guard record.state == .admitted else { return nil }
            record.state = .opened
            return record.ticket
        }
        if let ticket { await slots.opened(ticket) }
    }

    /// Runs once the coordinator has closed the session or given up
    /// opening it: releases a slot the request holds, or settles one it
    /// gave up while its connection was opening. A settle waits for the
    /// abandon it answers, so a connection is never briefly free while
    /// an open of it is still in flight.
    func finish(with slots: MCPLiveReadSlots) async {
        enum Action { case release, settle, none }
        let (action, ticket) = record.withLock { record -> (Action, MCPLiveReadSlots.Ticket?) in
            switch record.state {
            case .admitted, .opened:
                record.state = .finished
                return (.release, record.ticket)
            case .abandoned:
                record.state = .finished
                return (.settle, record.ticket)
            case .abandoning:
                record.state = .finishedWhileAbandoning
                return (.none, nil)
            case .finishedWhileAbandoning:
                return (.none, nil)
            case .idle, .waiting, .left, .finished:
                record.state = .finished
                return (.none, nil)
            }
        }
        guard let ticket else { return }
        switch action {
        case .release: await slots.release(ticket)
        case .settle: await slots.settle(ticket.profileID)
        case .none: break
        }
    }

    /// Runs when the caller stopped waiting. A connection still opening
    /// then gives its slot up and holds back further reads of its
    /// connection until `finish`; one already open keeps its slot until
    /// it is closed, since the statement's own cancel ends it.
    func abandonIfOpening(with slots: MCPLiveReadSlots) async {
        let ticket = record.withLock { record -> MCPLiveReadSlots.Ticket? in
            switch record.state {
            case .idle, .waiting:
                record.state = .left
                return nil
            case .admitted:
                record.state = .abandoning
                return record.ticket
            default:
                return nil
            }
        }
        guard let ticket else { return }
        await slots.abandon(ticket)
        let finished = record.withLock { record -> Bool in
            guard record.state == .finishedWhileAbandoning else {
                record.state = .abandoned
                return false
            }
            record.state = .finished
            return true
        }
        if finished { await slots.settle(ticket.profileID) }
    }
}

extension MCPLiveReadAdmission {
    /// Wraps an error raised once the session was open, so it is told apart
    /// from one raised while resolving or opening, which can name the host,
    /// the user or a file path and is never forwarded.
    struct ReadFailure: Error {
        let underlying: Error
    }

    /// Runs one live read under the helper's shared cap and deadlines: takes
    /// a slot once the profile is resolved and `check` admits it, opens the
    /// session through `open`, and runs `operation` on it. `openBudget`
    /// bounds resolving, waiting for a slot and opening; `statementBudget`
    /// is the longest the operation itself may take once the session is
    /// open. An error from `operation` arrives wrapped in `ReadFailure`;
    /// every other error arrives as raised, except that a request that
    /// waited for a slot and then ran out of its open budget throws
    /// `MCPLiveReadError.tooManyConcurrentReads`. Callers map the rest.
    static func run<Session: Sendable, T: Sendable>(
        profileID: UUID,
        slots: MCPLiveReadSlots,
        openBudget: Duration,
        statementBudget: Duration,
        check: @escaping @Sendable (MCPConnectionProfile) throws -> Void,
        open: @escaping @Sendable (
            _ requestID: String,
            _ beforeOpening: @escaping @Sendable (MCPConnectionProfile) async throws -> Void,
            _ operation: @escaping @Sendable (Session) async throws -> T
        ) async throws -> T,
        operation: @escaping @Sendable (Session, MCPRequestDeadline.Opening) async throws -> T
    ) async throws -> T {
        let requestID = UUID().uuidString
        let admission = MCPLiveReadAdmission()
        do {
            // The statement's own bound already has a second for the server's
            // bound to fire first; two more cover building the result and
            // closing the session.
            return try await MCPRequestDeadline.run(
                openBudget + statementBudget + .seconds(2), opening: openBudget
            ) { opening in
                // The slot is released once the coordinator has closed the
                // session or given up opening it, which can be after the
                // caller had its timeout or cancellation; a connection still
                // opening when the caller stops waiting gives its slot up
                // then instead (`abandonIfOpening`).
                do {
                    let result = try await open(
                        requestID,
                        { profile in
                            try check(profile)
                            let ticket = try await slots.acquire(for: profileID, onQueued: { admission.queue() })
                            guard admission.admit(ticket) else {
                                await slots.release(ticket)
                                throw CancellationError()
                            }
                        },
                        { session in
                            await admission.opened(with: slots)
                            do {
                                return try await operation(session, opening)
                            } catch {
                                throw ReadFailure(underlying: error)
                            }
                        }
                    )
                    await admission.finish(with: slots)
                    return result
                } catch {
                    await admission.finish(with: slots)
                    throw error
                }
            }
        } catch {
            // The caller stopped waiting, at the open budget or on a
            // cancellation, while its connection may still be opening.
            await admission.abandonIfOpening(with: slots)
            // The wait for a slot counts against the open budget, so a read
            // that waited and then ran out of it lost the budget to the cap,
            // not to the network; a retry that does not wait gets the open's
            // own text.
            if case MCPLiveReadError.openTimedOut = error, admission.waited, !Task.isCancelled {
                throw MCPLiveReadError.tooManyConcurrentReads(limit: slots.capacity)
            }
            throw error
        }
    }
}
