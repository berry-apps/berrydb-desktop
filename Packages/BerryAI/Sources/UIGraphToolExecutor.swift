import BerryGraph
import BerryStore
import Foundation

/// Live tab/pane state handed from BerryUI to build the UI-state graph
/// Declared here (not BerryUI) for the same reason
/// as `ActiveTabSnapshot`/`OpenTabsSnapshot`: `UIGraphToolExecutor` serializes
/// it; BerryUI must not leak `WorkspaceViewModel`/`WorkspaceTab` types across
/// the one-way module boundary.
public struct UIGraphSnapshot: Sendable {
    public struct Pane: Sendable {
        public let id: String
        /// The pane number the UI shows (1 = top).
        public let number: Int
        public let focused: Bool
        /// Every tab open in this pane's strip, not just the active one.
        public let tabIDs: [String]

        public init(id: String, number: Int, focused: Bool, tabIDs: [String]) {
            self.id = id
            self.number = number
            self.focused = focused
            self.tabIDs = tabIDs
        }
    }

    public struct Tab: Sendable {
        /// `WorkspaceTab.id`, the existing scheme unchanged.
        public let id: String
        /// "editor" | "table" | "tool" | "alterTable" | "collection" | "mongoShell" | "qdrantQuery"
        public let kind: String
        public let title: String

        public init(id: String, kind: String, title: String) {
            self.id = id
            self.kind = kind
            self.title = title
        }
    }

    public let panes: [Pane]
    public let tabs: [Tab]
    public let activeTabID: String?

    public init(panes: [Pane], tabs: [Tab], activeTabID: String?) {
        self.panes = panes
        self.tabs = tabs
        self.activeTabID = activeTabID
    }
}

/// Answers `get_ui_state`/`query_ui_graph`
/// mirrors `GraphToolExecutor`'s get_stats/graph_query split, but over a
/// graph built FRESH on every call from live UI state + the bounded
/// recent-actions log, never persisted (unlike the DSG). Not
/// entitlement-gated: tab awareness is base "ai" capability, not Intelligence
///
@MainActor
public final class UIGraphToolExecutor: AIToolExecutor {
    private static let actionLimit = 50

    private let store: BerryStore
    private let profileID: UUID?
    private let snapshot: () -> UIGraphSnapshot?

    public init(store: BerryStore, profileID: UUID?, snapshot: @escaping () -> UIGraphSnapshot?) {
        self.store = store
        self.profileID = profileID
        self.snapshot = snapshot
    }

    public var toolSpecs: [AIToolSpec] {
        [
            AIToolSpec(
                name: "get_ui_state",
                description: "Return every open tab across every pane (not just each pane's active tab), which pane holds which tabs, the single globally-active tab, and the most recent tab/pane actions (survives app relaunch). Call this whenever the user says \"this tab\"/\"that query\" and it's ambiguous, or asks what they were doing earlier.",
                parametersJSON: #"{"type":"object","properties":{}}"#
            ),
            AIToolSpec(
                name: "query_ui_graph",
                description: "Traverse the workspace UI graph directly. op=neighbors returns what a pane/tab/action node connects to; op=path returns the hop chain between two node ids (use ids from get_ui_state).",
                parametersJSON: #"{"type":"object","properties":{"op":{"type":"string","enum":["neighbors","path"]},"node":{"type":"string"},"from":{"type":"string"},"to":{"type":"string"}},"required":["op"]}"#
            ),
        ]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        guard call.name == "get_ui_state" || call.name == "query_ui_graph" else {
            return .failed("Unknown tool '\(call.name)'")
        }
        let graph = buildGraph()
        if call.name == "get_ui_state" { return getUIState(graph) }
        switch (call.args["op"] ?? "").lowercased() {
        case "neighbors": return neighbors(graph, call.args)
        case "path": return path(graph, call.args)
        case let op: return .failed("query_ui_graph: unknown op '\(op)' (neighbors|path)")
        }
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await execute(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

    // MARK: - Graph construction

    private func buildGraph() -> SchemaGraph {
        var graph = SchemaGraph()
        if let snapshot = snapshot() {
            for pane in snapshot.panes {
                let paneID = "pane:\(pane.id)"
                graph.addNode(GraphNode(
                    id: paneID, kind: .pane, name: "Pane \(pane.number)",
                    attrs: ["number": "\(pane.number)", "focused": "\(pane.focused)"]
                ))
                for tabID in pane.tabIDs {
                    graph.addEdge(GraphEdge(src: paneID, dst: tabID, kind: .hasTab))
                }
            }
            for tab in snapshot.tabs {
                var attrs = ["kind": tab.kind]
                if tab.id == snapshot.activeTabID { attrs["active"] = "true" }
                graph.addNode(GraphNode(id: tab.id, kind: .tab, name: tab.title, attrs: attrs))
            }
        }
        let actions = (try? store.recentWorkspaceActions(profileID: profileID, limit: Self.actionLimit)) ?? []
        let iso = ISO8601DateFormatter()
        for action in actions {
            graph.addNode(GraphNode(
                id: "action:\(action.id.uuidString)", kind: .action, name: action.description,
                attrs: ["kind": action.kind, "created_at": iso.string(from: action.createdAt)]
            ))
        }
        return graph
    }

    // MARK: - get_ui_state (friendly structured dump, not a raw node/edge blob)

    private func getUIState(_ graph: SchemaGraph) -> ToolOutcome {
        let snapshot = snapshot()
        let panes = (snapshot?.panes ?? []).map { pane -> [String: Any] in
            ["pane": pane.number, "focused": pane.focused, "tabs": pane.tabIDs]
        }
        let tabs = (snapshot?.tabs ?? []).map { tab -> [String: Any] in
            ["id": tab.id, "kind": tab.kind, "title": tab.title, "active": tab.id == snapshot?.activeTabID]
        }
        let recentActions = graph.nodes.values
            .filter { $0.kind == .action }
            .sorted { ($0.attrs["created_at"] ?? "") > ($1.attrs["created_at"] ?? "") }
            .map { ["kind": $0.attrs["kind"] ?? "", "description": $0.name, "at": $0.attrs["created_at"] ?? ""] as [String: Any] }
        return .ok(Self.json([
            "active_tab_id": snapshot?.activeTabID as Any,
            "panes": panes,
            "tabs": tabs,
            "recent_actions": recentActions,
        ]))
    }

    // MARK: - query_ui_graph

    private func neighbors(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        guard let node = args["node"], graph.nodes[node] != nil else {
            return .failed("Unknown node id '\(args["node"] ?? "")'")
        }
        return .ok(Self.json([
            "node": node,
            "outgoing": graph.neighbors(of: node, direction: .outgoing),
            "incoming": graph.neighbors(of: node, direction: .incoming),
        ]))
    }

    private func path(_ graph: SchemaGraph, _ args: [String: String]) -> ToolOutcome {
        guard let from = args["from"], let to = args["to"] else {
            return .failed("query_ui_graph path requires 'from' and 'to'")
        }
        // Containment (pane→tab) isn't uniformly one-directional like DSG
        // dependency edges, so try both directions — the graph is tiny.
        let chain = graph.shortestPath(from: from, to: to, direction: .outgoing)
            ?? graph.shortestPath(from: from, to: to, direction: .incoming)
        return .ok(Self.json(["from": from, "to": to, "reachable": chain != nil, "path": chain ?? []]))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
