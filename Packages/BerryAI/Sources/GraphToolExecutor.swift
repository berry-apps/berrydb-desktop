import BerryGraph
import Foundation

/// Answers the `graph_query` tool against the
/// persisted DSG. **Metadata only, runs entirely local** — never touches the
/// DBMS: it loads the latest harvested snapshot for the active profile via
/// `GraphStore.loadGraph` and runs the pure-Swift graph algorithms. Callers
/// name tables/views by their plain name; the executor resolves them to node
/// ids and answers with names so the model never sees internal keys.
///
/// Ops: `neighbors`, `path`, `blast_radius`, `scc`, `top_centrality`.
@MainActor
public final class GraphToolExecutor: AIToolExecutor {
    /// Dependency edges that matter for impact analysis — FK and view
    /// derivation. Columns/indexes are excluded (get_schema covers those).
    private static let dependencyKinds: Set<EdgeKind> = [.references, .derivesFrom]
    private static let topKDefault = 10

    private let store: GraphStore
    private let profileID: UUID

    public init(store: GraphStore, profileID: UUID) {
        self.store = store
        self.profileID = profileID
    }

    public var toolSpecs: [AIToolSpec] {
        [
            AIToolSpec(name: "get_stats", description: "Summary statistics of the schema dependency graph (node/edge counts, top objects).", parametersJSON: #"{"type":"object","properties":{}}"#),
            AIToolSpec(name: "graph_query", description: "Query the schema dependency graph. op: neighbors|path|blast_radius|circular_dependencies|top_centrality.", parametersJSON: #"{"type":"object","properties":{"op":{"type":"string","enum":["neighbors","path","blast_radius","circular_dependencies","top_centrality"]},"table":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"}},"required":["op"]}"#),
        ]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        guard call.name == "graph_query" || call.name == "get_stats" else {
            return .failed("Unknown tool '\(call.name)'")
        }

        let graph: SchemaGraph
        do {
            graph = try store.loadGraph(profileID: profileID)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard graph.nodeCount > 0 else {
            return .failed("No schema graph has been harvested yet for this connection.")
        }

        if call.name == "get_stats" { return getStats(graph, call.args) }

        switch (call.args["op"] ?? "").lowercased() {
        case "neighbors": return neighbors(graph, call.args)
        case "path": return path(graph, call.args)
        case "blast_radius": return blastRadius(graph, call.args)
        case "scc", "circular_dependencies": return scc(graph)
        case "top_centrality": return topCentrality(graph, call.args)
        case let op:
            return .failed("graph_query: unknown op '\(op)' " +
                "(neighbors|path|blast_radius|scc|top_centrality)")
        }
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await execute(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

    // MARK: - Ops

    private func neighbors(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        guard let node = node(named: args["node"], in: graph) else {
            return notFound(args["node"], in: graph)
        }
        let kinds = Self.dependencyKinds
        let dependsOn = names(graph.neighbors(of: node.id, direction: .outgoing, kinds: kinds), in: graph)
        let dependedOnBy = names(graph.neighbors(of: node.id, direction: .incoming, kinds: kinds), in: graph)
        return .ok(Self.json([
            "node": node.name,
            "depends_on": dependsOn,
            "depended_on_by": dependedOnBy,
        ]))
    }

    private func path(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        guard let from = node(named: args["from"], in: graph) else { return notFound(args["from"], in: graph) }
        guard let to = node(named: args["to"], in: graph) else { return notFound(args["to"], in: graph) }
        let chain = graph.shortestPath(
            from: from.id, to: to.id, direction: .outgoing, kinds: Self.dependencyKinds
        )
        // Order is meaningful here — map to names without sorting.
        return .ok(Self.json([
            "from": from.name,
            "to": to.name,
            "reachable": chain != nil,
            "path": chain?.map { graph.nodes[$0]?.name ?? $0 } ?? [],
        ]))
    }

    private func blastRadius(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        guard let node = node(named: args["node"], in: graph) else {
            return notFound(args["node"], in: graph)
        }
        let impacted = graph.blastRadius(of: node.id).sorted()
        return .ok(Self.json([
            "node": node.name,
            "impacted": names(impacted, in: graph),
            "count": impacted.count,
        ]))
    }

    private func scc(_ graph: SchemaGraph) -> ToolOutcome {
        let cycles = graph.circularDependencies().map { names($0, in: graph) }
        return .ok(Self.json([
            "circular_dependencies": cycles,
            "has_cycles": !cycles.isEmpty,
        ]))
    }

    private func topCentrality(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        let k = args["k"].flatMap(Int.init) ?? Self.topKDefault
        let top = graph.topByInDegree(max(1, k), kinds: Self.dependencyKinds).map {
            ["node": graph.nodes[$0.id]?.name ?? $0.id, "in_degree": $0.inDegree] as [String: Any]
        }
        return .ok(Self.json(["top_by_dependents": top]))
    }

 // MARK: - get_stats

    /// Reads harvested statistics off the persisted DSG node attrs — table size /
    /// rows / scan counts and unused indexes. Metadata only; no DBMS access.
    /// With `table`, returns that table's stats plus its indexes; without,
    /// returns a per-table summary and the list of unused indexes.
    private func getStats(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        if let name = args["table"], !name.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let node = node(named: name, in: graph) else { return notFound(name, in: graph) }
            var payload = statFields(node.attrs)
            payload["table"] = node.name
            payload["indexes"] = graph.neighbors(of: node.id, direction: .outgoing, kinds: [.hasIndex])
                .compactMap { graph.nodes[$0] }
                .sorted { $0.name < $1.name }
                .map { idx -> [String: Any] in
                    (["name": idx.name] as [String: Any]).merging(statFields(idx.attrs)) { _, new in new }
                }
            return .ok(Self.json(payload))
        }

        let tables = graph.nodes.values
            .filter { $0.kind == .table }
            .sorted { $0.name < $1.name }
            .map { t -> [String: Any] in
                (["name": t.name] as [String: Any]).merging(statFields(t.attrs)) { _, new in new }
            }
        let unusedIndexes = graph.nodes.values
            .filter { $0.kind == .index && $0.attrs["unused"] == "true" }
            .map(\.name).sorted()
        return .ok(Self.json(["tables": tables, "unused_indexes": unusedIndexes]))
    }

    /// The harvested stat attrs present on a node (skips structural attrs like
    /// column type). Values are the stringified numbers the harvester stored.
    private func statFields(_ attrs: [String: String]) -> [String: Any] {
        let keys = ["rows", "size_bytes", "seq_scan", "idx_scan", "unused"]
        return attrs.filter { keys.contains($0.key) }
    }

    // MARK: - Name resolution

    /// Resolves a caller-supplied name to a node: an exact id, else a table/view
    /// by name (case-insensitive), else any node by name.
    private func node(named raw: String?, in graph: SchemaGraph) -> GraphNode? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let exact = graph.nodes[raw] { return exact }
        let key = raw.lowercased()
        return graph.nodes.values.first { ($0.kind == .table || $0.kind == .view) && $0.name.lowercased() == key }
            ?? graph.nodes.values.first { $0.name.lowercased() == key }
    }

    private func names(_ ids: [String], in graph: SchemaGraph) -> [String] {
        ids.map { graph.nodes[$0]?.name ?? $0 }.sorted()
    }

    private func notFound(_ name: String?, in graph: SchemaGraph) -> ToolOutcome {
        let tables = graph.nodes.values
            .filter { $0.kind == .table || $0.kind == .view }
            .map(\.name).sorted()
        return .failed("Node '\(name ?? "")' not found. Available: " +
            tables.prefix(50).joined(separator: ", "))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
