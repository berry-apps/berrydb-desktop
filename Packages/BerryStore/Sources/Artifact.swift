import Foundation
import GRDB

/// A durable reference to something the AI agent created or ran — a query/
/// editor tab it wrote, or a schema object (table/view/trigger/function) it
/// touched — so a chat bubble can link back to it and the user (or the agent
/// itself) can reopen/inspect it later, even after conversation history is
/// reloaded from disk.
public struct Artifact: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case editorTab
        case mongoShell
        case qdrantQuery
        case elasticsearchQuery
        case table
        case view
        case trigger
        case function
        case other
    }

    public var id: UUID
    /// Unlike `SavedQuery`, there is no "global" artifact — it always
    /// references something on one specific connection.
    public var profileID: UUID
    public var kind: Kind
    public var title: String
    /// Live-pointer reference for schema-object kinds (table/view/trigger/
    /// function): `SchemaObject.id` (`"<database>.<kind>.<name>"`),
    /// re-resolved against the live catalog at open time rather than a frozen
    /// DDL snapshot. Nil for query/tab kinds, which carry their content via
    /// `ArtifactVersion` instead.
    public var objectRef: String?
    /// The thread/message that produced this artifact, if the AI created it.
    /// Nil for artifacts saved manually by the user.
    public var sourceThreadID: UUID?
    public var sourceMessageID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID,
        kind: Kind,
        title: String,
        objectRef: String? = nil,
        sourceThreadID: UUID? = nil,
        sourceMessageID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.kind = kind
        self.title = title
        self.objectRef = objectRef
        self.sourceThreadID = sourceThreadID
        self.sourceMessageID = sourceMessageID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Artifact: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifact"
}

/// One run/edit of a query-shaped `Artifact` (`.editorTab`/`.mongoShell`/
/// `.qdrantQuery`) — a new version is appended each time the agent (or the
/// user) reruns it, so the artifact's own identity/link never changes but
/// the full history stays traceable.
public struct ArtifactVersion: Identifiable, Codable, Sendable {
    public var id: UUID
    public var artifactID: UUID
    /// Monotonically increasing per artifact, starting at 1.
    public var versionNumber: Int
    /// The SQL/query text run at this version.
    public var payload: String
    /// Bounded JSON result snapshot (columns/rows/truncated flag), or nil if
    /// this version was saved but never actually run.
    public var resultSnapshotJSON: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        artifactID: UUID,
        versionNumber: Int,
        payload: String,
        resultSnapshotJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.artifactID = artifactID
        self.versionNumber = versionNumber
        self.payload = payload
        self.resultSnapshotJSON = resultSnapshotJSON
        self.createdAt = createdAt
    }
}

extension ArtifactVersion: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifact_version"
}
