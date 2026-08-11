import Foundation

/// Database Semantic Graph node/edge model (docs/architecture/11 §5). V1.5
/// covers the structural graph harvested from DB metadata; workload/plan/
/// migration nodes arrive with the harvesters (later chunk).
public enum NodeKind: String, Sendable, Hashable, Codable {
    case database, schema, table, column, index, constraint
    case view, trigger, function
    case query, plan, migration
    // UI-state only (docs/feature/08, AI-27) — built fresh per AI tool call
    // from live WorkspaceViewModel state + the bounded workspace_action log.
    // NEVER written via GraphStore/store.sqlite's graph_node/graph_edge
    // tables (those stay DB-schema-only so DSG analyzers iterating by
    // profileID aren't mixed with UI nodes).
    case pane, tab, action
}

public enum EdgeKind: String, Sendable, Hashable, Codable {
    // Structural (built from schema metadata).
    case hasColumn      // table → column
    case hasIndex       // table → index
    case references     // FK: child table → parent table
    case derivesFrom    // view → source table
    // Workload / plan / migration (harvested later).
    case joins, reads, writes, usesIndex, migratedBy
    /// UI-state only (docs/feature/08): pane → tab containment.
    case hasTab
}

/// A DSG node. `id` is a stable, deterministic key (see `GraphID`).
public struct GraphNode: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let kind: NodeKind
    public let name: String
    /// Database/schema the object lives in — nil for SQLite (one file).
    public let database: String?
    /// Free-form harvested attributes (row counts, sizes…), all stringified.
    public var attrs: [String: String]

    public init(id: String, kind: NodeKind, name: String, database: String? = nil, attrs: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.name = name
        self.database = database
        self.attrs = attrs
    }
}

/// A directed DSG edge from `src` to `dst`.
public struct GraphEdge: Sendable, Hashable, Codable {
    public let src: String
    public let dst: String
    public let kind: EdgeKind
    /// Multiplicity / confidence (e.g. JOIN frequency). 1 for structural edges.
    public var weight: Double
    public var attrs: [String: String]

    public init(src: String, dst: String, kind: EdgeKind, weight: Double = 1, attrs: [String: String] = [:]) {
        self.src = src
        self.dst = dst
        self.kind = kind
        self.weight = weight
        self.attrs = attrs
    }
}

/// Deterministic node identifiers so the same object always maps to one node
/// across refreshes (docs/architecture/11 §5/§6).
public enum GraphID {
    public static func node(_ kind: NodeKind, database: String?, name: String, in container: String? = nil) -> String {
        let db = database ?? ""
        if let container {
            return "\(kind.rawValue):\(db).\(container).\(name)"
        }
        return "\(kind.rawValue):\(db).\(name)"
    }
}
