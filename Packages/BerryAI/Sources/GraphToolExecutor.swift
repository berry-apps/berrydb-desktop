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
    private static let topKDefault = 10

    private let service: BerryGraphQueryService
    private let profileID: UUID

    public init(store: GraphStore, profileID: UUID) {
        self.service = BerryGraphQueryService(store: store)
        self.profileID = profileID
    }

    init(service: BerryGraphQueryService, profileID: UUID) {
        self.service = service
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

        do {
            if call.name == "get_stats" { return try getStats(call.args) }

            switch (call.args["op"] ?? "").lowercased() {
            case "neighbors": return try neighbors(call.args)
            case "path": return try path(call.args)
            case "blast_radius": return try blastRadius(call.args)
            case "scc", "circular_dependencies": return try scc()
            case "top_centrality": return try topCentrality(call.args)
            case let op:
                // Preserve the legacy executor's error precedence: an empty
                // profile reports the missing harvest before an invalid op.
                // Valid operations load exactly one persisted snapshot inside
                // the query service rather than preflighting it here.
                try service.validateSnapshot(profileID: profileID)
                return .failed("graph_query: unknown op '\(op)' " +
                    "(neighbors|path|blast_radius|scc|top_centrality)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await execute(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

    // MARK: - Ops

    private func neighbors(_ args: [String: String]) throws -> ToolOutcome {
        let result = try service.neighbors(
            profileID: profileID, node: args["node"] ?? "", resolution: .legacyFirstStableID
        )
        return .ok(Self.json([
            "node": result.node,
            "depends_on": result.dependsOn,
            "depended_on_by": result.dependedOnBy,
        ]))
    }

    private func path(_ args: [String: String]) throws -> ToolOutcome {
        let result = try service.path(
            profileID: profileID, from: args["from"] ?? "", to: args["to"] ?? "",
            resolution: .legacyFirstStableID
        )
        return .ok(Self.json([
            "from": result.from,
            "to": result.to,
            "reachable": result.reachable,
            "path": result.path,
        ]))
    }

    private func blastRadius(_ args: [String: String]) throws -> ToolOutcome {
        let result = try service.blastRadius(
            profileID: profileID, node: args["node"] ?? "", resolution: .legacyFirstStableID
        )
        return .ok(Self.json([
            "node": result.node,
            "impacted": result.impacted,
            "count": result.count,
        ]))
    }

    private func scc() throws -> ToolOutcome {
        let result = try service.circularDependencies(profileID: profileID)
        return .ok(Self.json([
            "circular_dependencies": result.components,
            "has_cycles": result.hasCycles,
        ]))
    }

    private func topCentrality(_ args: [String: String]) throws -> ToolOutcome {
        let k = args["k"].flatMap(Int.init) ?? Self.topKDefault
        let top = try service.topCentrality(profileID: profileID, limit: k).map {
            ["node": $0.node, "in_degree": $0.inDegree] as [String: Any]
        }
        return .ok(Self.json(["top_by_dependents": top]))
    }

    // MARK: - get_stats

    /// Reads harvested statistics off the persisted DSG node attrs — table size /
    /// rows / scan counts and unused indexes. Metadata only; no DBMS access.
    /// With `table`, returns that table's stats plus its indexes; without,
    /// returns a per-table summary and the list of unused indexes.
    private func getStats(_ args: [String: String]) throws -> ToolOutcome {
        if let name = args["table"], !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let result = try service.statistics(
                profileID: profileID, table: name, resolution: .legacyFirstStableID
            )
            var payload = result.fields as [String: Any]
            payload["table"] = result.table
            payload["indexes"] = result.indexes.map { index -> [String: Any] in
                (["name": index.name] as [String: Any]).merging(index.fields) { _, new in new }
            }
            return .ok(Self.json(payload))
        }

        let result = try service.statistics(profileID: profileID)
        let tables = result.tables.map { table -> [String: Any] in
            (["name": table.name] as [String: Any]).merging(table.fields) { _, new in new }
        }
        return .ok(Self.json(["tables": tables, "unused_indexes": result.unusedIndexes]))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
