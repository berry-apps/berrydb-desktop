import Foundation
import GRDB

/// Persisted DSG rows (docs/architecture/11 §5). Temporal: `firstSeen`/`lastSeen`
/// track when each element appeared and was last confirmed, so the Digital Twin
/// (§6) reconstructs the graph as-of any snapshot without storing a full copy
/// each time. Local only; never leaves the machine (07 §3). BerryStore owns
/// these row types; BerryGraph maps its `SchemaGraph` to/from them.
public struct GraphNodeRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var profileID: UUID
    public var nodeID: String
    public var kind: String
    public var name: String
    public var database: String?
    /// JSON-encoded attribute map.
    public var attrs: String
    public var firstSeen: Date
    public var lastSeen: Date

    public static let databaseTableName = "graph_node"

    public init(profileID: UUID, nodeID: String, kind: String, name: String,
                database: String?, attrs: String, firstSeen: Date, lastSeen: Date) {
        self.profileID = profileID
        self.nodeID = nodeID
        self.kind = kind
        self.name = name
        self.database = database
        self.attrs = attrs
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct GraphEdgeRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    public var profileID: UUID
    public var src: String
    public var dst: String
    public var kind: String
    public var weight: Double
    public var attrs: String
    public var firstSeen: Date
    public var lastSeen: Date

    public static let databaseTableName = "graph_edge"

    public init(profileID: UUID, src: String, dst: String, kind: String, weight: Double,
                attrs: String, firstSeen: Date, lastSeen: Date) {
        self.profileID = profileID
        self.src = src
        self.dst = dst
        self.kind = kind
        self.weight = weight
        self.attrs = attrs
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

public struct GraphSnapshotRecord: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var takenAt: Date
    public var nodeCount: Int
    public var edgeCount: Int
    public var digest: String

    public static let databaseTableName = "graph_snapshot"

    public init(id: UUID = UUID(), profileID: UUID, takenAt: Date,
                nodeCount: Int, edgeCount: Int, digest: String) {
        self.id = id
        self.profileID = profileID
        self.takenAt = takenAt
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
        self.digest = digest
    }
}
