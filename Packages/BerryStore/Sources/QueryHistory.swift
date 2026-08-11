import Foundation
import GRDB

/// One executed statement (ED-06) — docs/architecture/07 §3.
/// Privacy: per-profile recording can be disabled; a one-tap "clear all"
/// wipes the table.
public struct QueryHistoryEntry: Identifiable, Codable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    public var sql: String
    public var startedAt: Date
    public var durationMS: Int
    /// "success" | "failed" | "cancelled"
    public var status: String
    public var rowCount: Int?
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        profileID: UUID?,
        sql: String,
        startedAt: Date,
        durationMS: Int,
        status: String,
        rowCount: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.sql = sql
        self.startedAt = startedAt
        self.durationMS = durationMS
        self.status = status
        self.rowCount = rowCount
        self.errorMessage = errorMessage
    }
}

extension QueryHistoryEntry: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "query_history"
}

/// Lightweight schema snapshot — the Digital Twin seed (DI-08,
/// docs/architecture/11 §6): object list + digest per refresh; consecutive
/// identical digests are skipped so the store only grows on real change.
public struct SchemaSnapshotRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    public var takenAt: Date
    /// SHA-256 of the normalized payload — dedupe key.
    public var digest: String
    /// JSON: [{kind, name, database}] — compact by design; richer harvests
    /// (columns, stats) arrive with V1.5 (DI-01).
    public var payload: String

    public init(id: UUID = UUID(), profileID: UUID?, takenAt: Date, digest: String, payload: String) {
        self.id = id
        self.profileID = profileID
        self.takenAt = takenAt
        self.digest = digest
        self.payload = payload
    }
}

extension SchemaSnapshotRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "schema_snapshot"
}

/// Unsaved editor tab content, restored on reconnect (UD-05 — docs/architecture/07 §3).
/// The record id IS the EditorDocument id, so save/restore round-trips 1:1.
public struct EditorSessionRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    public var title: String
    public var text: String
    public var updatedAt: Date
    /// Carries `EditorDocument.savedQueryID`/`artifactID` across a restart
    /// (v25) — without these, a restored tab loses its link and reopening the
    /// same saved query/artifact later creates a duplicate tab instead of
    /// focusing the restored one.
    public var savedQueryID: UUID?
    public var artifactID: UUID?

    public init(
        id: UUID, profileID: UUID?, title: String, text: String, updatedAt: Date = Date(),
        savedQueryID: UUID? = nil, artifactID: UUID? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.text = text
        self.updatedAt = updatedAt
        self.savedQueryID = savedQueryID
        self.artifactID = artifactID
    }
}

extension EditorSessionRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "editor_session"
}
