import BerryStore
import Foundation

/// Persists a `SchemaGraph` per profile and reconstructs it as-of any snapshot
/// (docs/architecture/11 §5/§6 — the Digital Twin). Maps the graph to
/// BerryStore's temporal rows; the store handles the SQL. Quick-open (profileless)
/// connections aren't persisted.
public struct GraphStore: Sendable {
    private let store: BerryStore

    public init(store: BerryStore) {
        self.store = store
    }

    /// Records the current graph as a snapshot at `now`. Existing elements keep
    /// their original firstSeen (temporal accumulation, §6).
    public func persist(_ graph: SchemaGraph, profileID: UUID, now: Date) throws {
        let nodes = graph.nodes.values.map { node in
            GraphNodeRecord(
                profileID: profileID, nodeID: node.id, kind: node.kind.rawValue,
                name: node.name, database: node.database, attrs: Self.encode(node.attrs),
                firstSeen: now, lastSeen: now
            )
        }
        let edges = graph.edges.map { edge in
            GraphEdgeRecord(
                profileID: profileID, src: edge.src, dst: edge.dst, kind: edge.kind.rawValue,
                weight: edge.weight, attrs: Self.encode(edge.attrs), firstSeen: now, lastSeen: now
            )
        }
        try store.saveGraph(
            profileID: profileID, nodes: nodes, edges: edges,
            takenAt: now, digest: Self.digest(graph)
        )
    }

    /// Rebuilds the graph as it was at `asOf` (default: the latest snapshot).
    /// Empty graph when the profile has no snapshots.
    public func loadGraph(profileID: UUID, asOf: Date? = nil) throws -> SchemaGraph {
        let at: Date
        if let asOf {
            at = asOf
        } else if let latest = try store.latestGraphSnapshot(profileID: profileID) {
            at = latest.takenAt
        } else {
            return SchemaGraph()
        }

        var graph = SchemaGraph()
        for row in try store.graphNodes(profileID: profileID, asOf: at) {
            graph.addNode(GraphNode(
                id: row.nodeID, kind: NodeKind(rawValue: row.kind) ?? .table,
                name: row.name, database: row.database, attrs: Self.decode(row.attrs)
            ))
        }
        for row in try store.graphEdges(profileID: profileID, asOf: at) {
            graph.addEdge(GraphEdge(
                src: row.src, dst: row.dst, kind: EdgeKind(rawValue: row.kind) ?? .references,
                weight: row.weight, attrs: Self.decode(row.attrs)
            ))
        }
        return graph
    }

    public func snapshots(profileID: UUID) throws -> [GraphSnapshotRecord] {
        try store.graphSnapshots(profileID: profileID)
    }

    // MARK: - Encoding + digest

    private static func encode(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty,
              let data = try? JSONEncoder().encode(attrs),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private static func decode(_ json: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    /// Deterministic content digest (stable across runs, no crypto dep so the
    /// module stays Linux-clean per 04 §5) — lets callers skip a redundant
    /// snapshot when the graph is unchanged. FNV-1a over a canonical form.
    static func digest(_ graph: SchemaGraph) -> String {
        var canonical = ""
        for id in graph.nodes.keys.sorted() {
            let node = graph.nodes[id]!
            canonical += "N|\(id)|\(node.kind.rawValue)|\(node.name)|\(node.database ?? "")\n"
        }
        for edge in graph.edges.map({ "E|\($0.src)|\($0.dst)|\($0.kind.rawValue)" }).sorted() {
            canonical += edge + "\n"
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
