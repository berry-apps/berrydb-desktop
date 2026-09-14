import BerryDriverKit
import Foundation

/// Outcome of one executed statement, delivered to the history sink.
public struct ExecutedStatement: Sendable {
    public enum Status: String, Sendable {
        case success
        case failed
        case cancelled
    }

    public let profileID: UUID?
    public let sql: String
    public let startedAt: Date
    public let duration: Duration
    public let status: Status
    public let rowCount: Int?
    public let errorMessage: String?

    public init(
        profileID: UUID?, sql: String, startedAt: Date, duration: Duration,
        status: Status, rowCount: Int?, errorMessage: String?
    ) {
        self.profileID = profileID
        self.sql = sql
        self.startedAt = startedAt
        self.duration = duration
        self.status = status
        self.rowCount = rowCount
        self.errorMessage = errorMessage
    }
}

/// History sink — implemented by the persistence layer and wired at startup.
/// BerryCore stays decoupled from BerryStore;
/// the adapter lives in the UI/wiring layer.
public protocol QueryHistorySink: Sendable {
    func record(_ statement: ExecutedStatement)
}

/// Digital Twin seed: receives the object
/// list on every schema refresh; the implementation dedupes by digest.
public protocol SchemaSnapshotSink: Sendable {
    func recordSnapshot(profileID: UUID?, objects: [SchemaObject])
}
