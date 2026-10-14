import BerryDriverKit
import Foundation

/// Why a statement that would have run without its own approval card waits
/// for one instead.
public enum ReadOnlyUnavailableReason: Sendable, Equatable {
    /// The session's own connection holds a temporary object, a session
    /// setting or an open transaction that the read-only connection would
    /// not see.
    case sessionState
    /// The read-only connection could not be opened or set up, or is not
    /// there. Carries the bare words of the driver or the server, or one of
    /// BerryDB's own details below, with no wrapper of their own, for the
    /// card's sentence to put in context.
    case connectionFailed(String)

    /// The details of `connectionFailed` that BerryDB gives itself rather
    /// than a driver or a server, named so the card can say them in the
    /// user's language.
    public static let notSetUpDetail = "no read-only connection is set up for this session"
    public static let sessionClosedDetail = "the session is closed"
    public static let cancelledDetail = "cancelled"
}

/// Where a statement that runs without its own approval card goes.
public enum ReadOnlyRoute: Sendable {
    /// The session's read-only connection, for this one statement. The
    /// receiver finishes the lease.
    case readOnly(ReadOnlyLease)
    /// The engine has no read-only connection (SQL Server, DynamoDB): the
    /// statement runs on the session's own connection, its read-only
    /// classification the only check, as before.
    case notSupported
    /// The engine has one, but the statement cannot use it now; it needs a
    /// card, and once approved runs on the session's own connection.
    case unavailable(ReadOnlyUnavailableReason)

    /// The route when no routing was supplied: an engine with the read-only
    /// contract still never runs such a statement on its own connection
    /// without a card.
    public static func withoutConnections(for session: Session) -> ReadOnlyRoute {
        ReadOnlyConnections.supports(session)
            ? .unavailable(.connectionFailed(ReadOnlyUnavailableReason.notSetUpDetail))
            : .notSupported
    }
}

/// Decides the route from what the session's own connection holds, the
/// editor's manual transaction and the state of the read-only connection.
@MainActor
public struct ReadOnlyRouter {
    private let connections: ReadOnlyConnections
    private let tracker: SessionStateTracker
    private let transactionIsActive: @MainActor () -> Bool

    /// `transactionIsActive` is read on every call because the workspace
    /// replaces its transaction controller on every connect.
    public init(
        connections: ReadOnlyConnections,
        tracker: SessionStateTracker = .shared,
        transactionIsActive: @escaping @MainActor () -> Bool
    ) {
        self.connections = connections
        self.tracker = tracker
        self.transactionIsActive = transactionIsActive
    }

    /// Answers from what is known at once, the engine, the session's state
    /// and the transaction, and only then waits for the connection, which it
    /// opens on first use. A `.readOnly` route carries a lease its receiver
    /// must finish; no other route holds one.
    public func route(for session: Session) async -> ReadOnlyRoute {
        guard ReadOnlyConnections.supports(session) else { return .notSupported }
        if transactionIsActive() || tracker.state(for: session.id).isHiddenFromOtherConnections {
            return .unavailable(.sessionState)
        }
        do {
            let lease = try await connections.lease(for: session)
            // The pool hands the lease out even to a caller cancelled while
            // it waited, and a lease nobody finishes keeps the connection
            // open for good.
            guard !Task.isCancelled else {
                await lease.finish(failed: false)
                return .unavailable(.connectionFailed(ReadOnlyUnavailableReason.cancelledDetail))
            }
            return .readOnly(lease)
        } catch let unavailable as ReadOnlyConnectionUnavailable {
            return .unavailable(.connectionFailed(unavailable.reason))
        } catch {
            // Only a session that closed makes the pool throw anything else.
            return .unavailable(.connectionFailed(ReadOnlyUnavailableReason.sessionClosedDetail))
        }
    }
}
