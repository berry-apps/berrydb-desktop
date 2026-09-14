import Foundation

/// Structural difference between two DSG snapshots:
/// what appeared and what disappeared. Powers "what changed since last week?"
/// and before/after-migration views. Edge identity is (src, dst, kind).
public struct GraphDiff: Sendable, Equatable {
    public var addedNodes: Set<String>
    public var removedNodes: Set<String>
    public var addedEdges: Set<GraphEdge>
    public var removedEdges: Set<GraphEdge>

    public var isEmpty: Bool {
        addedNodes.isEmpty && removedNodes.isEmpty && addedEdges.isEmpty && removedEdges.isEmpty
    }
}

extension SchemaGraph {
    /// Diff from this graph (earlier) to `other` (later).
    public func diff(to other: SchemaGraph) -> GraphDiff {
        let here = Set(nodes.keys)
        let there = Set(other.nodes.keys)

        func key(_ edge: GraphEdge) -> String { "\(edge.src)\u{0}\(edge.dst)\u{0}\(edge.kind.rawValue)" }
        let hereEdges = Dictionary(edges.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let thereEdges = Dictionary(other.edges.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })

        return GraphDiff(
            addedNodes: there.subtracting(here),
            removedNodes: here.subtracting(there),
            addedEdges: Set(thereEdges.filter { hereEdges[$0.key] == nil }.values),
            removedEdges: Set(hereEdges.filter { thereEdges[$0.key] == nil }.values)
        )
    }
}
