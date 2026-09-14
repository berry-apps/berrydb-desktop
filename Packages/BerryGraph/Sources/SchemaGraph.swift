import Foundation

/// In-memory Directed Schema Graph. Pure value type;
/// pure-Swift algorithms sized for schema graphs (10²–10⁵ nodes, Q8). No UI,
/// no network, no DB — callers feed it harvested metadata and query it.
public struct SchemaGraph: Sendable {
    public enum Direction: Sendable { case outgoing, incoming }

    public private(set) var nodes: [String: GraphNode] = [:]
    public private(set) var edges: [GraphEdge] = []
    /// node id → indices into `edges` (outgoing / incoming), for O(1) adjacency.
    private var outAdjacency: [String: [Int]] = [:]
    private var inAdjacency: [String: [Int]] = [:]

    public init() {}

    public var nodeCount: Int { nodes.count }
    public var edgeCount: Int { edges.count }

    // MARK: - Building

    /// Adds or replaces a node (idempotent by id).
    public mutating func addNode(_ node: GraphNode) {
        nodes[node.id] = node
    }

    /// Adds a directed edge. Endpoints need not exist yet; missing nodes are
    /// simply treated as leaves by the queries.
    public mutating func addEdge(_ edge: GraphEdge) {
        let index = edges.count
        edges.append(edge)
        outAdjacency[edge.src, default: []].append(index)
        inAdjacency[edge.dst, default: []].append(index)
    }

    // MARK: - Adjacency

    /// Immediate neighbours of a node in one direction, optionally restricted to
    /// certain edge kinds.
    public func neighbors(
        of id: String, direction: Direction, kinds: Set<EdgeKind>? = nil
    ) -> [String] {
        let adjacency = direction == .outgoing ? outAdjacency : inAdjacency
        guard let indices = adjacency[id] else { return [] }
        var result: [String] = []
        for index in indices {
            let edge = edges[index]
            if let kinds, !kinds.contains(edge.kind) { continue }
            result.append(direction == .outgoing ? edge.dst : edge.src)
        }
        return result
    }

    // MARK: - Reachability (BFS)

    /// All nodes reachable from `id` following `direction`, excluding `id`
    /// itself. Restrict traversal to `kinds` when given.
    public func reachable(
        from id: String, direction: Direction, kinds: Set<EdgeKind>? = nil
    ) -> Set<String> {
        var visited: Set<String> = [id]
        var queue = [id]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for next in neighbors(of: current, direction: direction, kinds: kinds) where !visited.contains(next) {
                visited.insert(next)
                queue.append(next)
            }
        }
        visited.remove(id)
        return visited
    }

 /// Blast radius: everything that depends on `id` and would break if
    /// it were dropped — i.e. reverse reachability over dependency edges. By
    /// default follows FK and view-derivation; pass workload kinds once they are
    /// harvested to include queries that read/write the object.
    public func blastRadius(
        of id: String, following kinds: Set<EdgeKind> = [.references, .derivesFrom]
    ) -> Set<String> {
        reachable(from: id, direction: .incoming, kinds: kinds)
    }

    /// Shortest directed path from `from` to `to` (inclusive of both), or nil if
    /// unreachable. BFS → fewest hops.
    public func shortestPath(
        from: String, to: String, direction: Direction = .outgoing, kinds: Set<EdgeKind>? = nil
    ) -> [String]? {
        if from == to { return [from] }
        var predecessor: [String: String] = [:]
        var visited: Set<String> = [from]
        var queue = [from]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for next in neighbors(of: current, direction: direction, kinds: kinds) where !visited.contains(next) {
                visited.insert(next)
                predecessor[next] = current
                if next == to {
                    var path = [to]
                    var step = to
                    while let prev = predecessor[step] {
                        path.append(prev)
                        step = prev
                    }
                    return path.reversed()
                }
                queue.append(next)
            }
        }
        return nil
    }

    // MARK: - Centrality (DI, Insight Panel)

    /// In/out degree per node — a cheap importance proxy (a table referenced by
    /// many others has high in-degree).
    public func degreeCentrality(kinds: Set<EdgeKind>? = nil) -> [String: (inDegree: Int, outDegree: Int)] {
        var result: [String: (inDegree: Int, outDegree: Int)] = [:]
        for id in nodes.keys {
            let inDeg = neighbors(of: id, direction: .incoming, kinds: kinds).count
            let outDeg = neighbors(of: id, direction: .outgoing, kinds: kinds).count
            result[id] = (inDeg, outDeg)
        }
        return result
    }

    /// Top-k nodes by in-degree (most depended-upon), highest first.
    public func topByInDegree(_ k: Int, kinds: Set<EdgeKind>? = nil) -> [(id: String, inDegree: Int)] {
        nodes.keys
            .map { (id: $0, inDegree: neighbors(of: $0, direction: .incoming, kinds: kinds).count) }
            .sorted { $0.inDegree != $1.inDegree ? $0.inDegree > $1.inDegree : $0.id < $1.id }
            .prefix(k)
            .map { $0 }
    }

    // MARK: - Strongly connected components (Tarjan, iterative)

    /// SCCs over the chosen edge kinds. Iterative to stay safe on deep graphs
    /// (Q8: up to 10⁵ nodes). Every node appears in exactly one component.
    public func stronglyConnectedComponents(following kinds: Set<EdgeKind>? = nil) -> [[String]] {
        var index = 0
        var indices: [String: Int] = [:]
        var lowlink: [String: Int] = [:]
        var onStack: Set<String> = []
        var componentStack: [String] = []
        var result: [[String]] = []
        var neighborCache: [String: [String]] = [:]

        func outgoing(_ node: String) -> [String] {
            if let cached = neighborCache[node] { return cached }
            let n = neighbors(of: node, direction: .outgoing, kinds: kinds)
            neighborCache[node] = n
            return n
        }

        for start in nodes.keys where indices[start] == nil {
            var work: [(node: String, next: Int)] = [(start, 0)]
            indices[start] = index; lowlink[start] = index; index += 1
            componentStack.append(start); onStack.insert(start)

            while let top = work.last {
                let v = top.node
                let vNeighbors = outgoing(v)
                if top.next < vNeighbors.count {
                    work[work.count - 1].next += 1
                    let w = vNeighbors[top.next]
                    if indices[w] == nil {
                        indices[w] = index; lowlink[w] = index; index += 1
                        componentStack.append(w); onStack.insert(w)
                        work.append((w, 0))
                    } else if onStack.contains(w) {
                        lowlink[v] = min(lowlink[v]!, indices[w]!)
                    }
                } else {
                    if lowlink[v] == indices[v] {
                        var component: [String] = []
                        while let w = componentStack.popLast() {
                            onStack.remove(w)
                            component.append(w)
                            if w == v { break }
                        }
                        result.append(component)
                    }
                    work.removeLast()
                    if let parent = work.last?.node {
                        lowlink[parent] = min(lowlink[parent]!, lowlink[v]!)
                    }
                }
            }
        }
        return result
    }

 /// Circular dependencies (Schema Analyzer): SCCs of ≥2 nodes over FK
    /// edges — a genuine reference cycle.
    public func circularDependencies() -> [[String]] {
        stronglyConnectedComponents(following: [.references]).filter { $0.count > 1 }
    }

 // MARK: - Removal (hypothetical/preview graphs)

    /// Removes a node and every edge touching it (either direction). No-op if
    /// the node doesn't exist. Used to replace part of a graph with a
    /// hypothetical version — e.g. swapping a table's columns for an edited
 /// design before it's applied.
    public mutating func removeNode(_ id: String) {
        guard nodes.removeValue(forKey: id) != nil else { return }
        edges.removeAll { $0.src == id || $0.dst == id }
        rebuildAdjacency()
    }

    /// Removes every edge from `id` of the given kind, keeping the node — used
    /// to drop a table's old foreign keys before re-adding an edited set.
    public mutating func removeEdges(from id: String, kind: EdgeKind) {
        edges.removeAll { $0.src == id && $0.kind == kind }
        rebuildAdjacency()
    }

    private mutating func rebuildAdjacency() {
        outAdjacency.removeAll(keepingCapacity: true)
        inAdjacency.removeAll(keepingCapacity: true)
        for (index, edge) in edges.enumerated() {
            outAdjacency[edge.src, default: []].append(index)
            inAdjacency[edge.dst, default: []].append(index)
        }
    }
}
