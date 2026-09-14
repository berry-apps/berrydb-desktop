import BerryStore
import Foundation
import Testing

@testable import BerryAI

/// `get_ui_state`/`query_ui_graph` — an in-memory
/// graph built fresh from a live snapshot + the bounded recent-actions log,
/// never persisted (unlike the DSG's `graph_query`/`get_stats`).
@MainActor
@Suite("UIGraphToolExecutor")
struct UIGraphToolExecutorTests {
    private func decode(_ outcome: ToolOutcome) -> [String: Any] {
        guard let json = outcome.resultJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

    private func sampleSnapshot() -> UIGraphSnapshot {
        UIGraphSnapshot(
            panes: [
                .init(id: "group-1", number: 1, focused: true, tabIDs: ["editor:tab-a", "table:tab-b"]),
                .init(id: "group-2", number: 2, focused: false, tabIDs: ["editor:tab-c"]),
            ],
            tabs: [
                .init(id: "editor:tab-a", kind: "editor", title: "Debug: slow query"),
                .init(id: "table:tab-b", kind: "table", title: "users"),
                .init(id: "editor:tab-c", kind: "editor", title: "scratch.sql"),
            ],
            activeTabID: "editor:tab-a"
        )
    }

    @Test func getUIStateReportsEveryTabPerPaneNotJustTheActiveOne() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_ui_state", args: [:]))

        #expect(outcome.status == "ok")
        let obj = decode(outcome)
        #expect(obj["active_tab_id"] as? String == "editor:tab-a")
        let panes = obj["panes"] as? [[String: Any]] ?? []
        #expect(panes.count == 2)
        #expect((panes[0]["tabs"] as? [String]) == ["editor:tab-a", "table:tab-b"])
        let tabs = obj["tabs"] as? [[String: Any]] ?? []
        #expect(tabs.count == 3)
        #expect(tabs.first { $0["id"] as? String == "editor:tab-a" }?["active"] as? Bool == true)
        #expect(tabs.first { $0["id"] as? String == "table:tab-b" }?["active"] as? Bool == false)
    }

    @Test func getUIStateDegradesGracefullyWithNoSnapshot() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: { nil })

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_ui_state", args: [:]))

        #expect(outcome.status == "ok")
        let obj = decode(outcome)
        #expect((obj["panes"] as? [[String: Any]])?.isEmpty == true)
        #expect((obj["tabs"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func recentActionsFromTheBoundedLogAppearAsStandaloneNodes() async throws {
        let store = try BerryStore(path: ":memory:")
        let profileID = UUID()
        try store.recordWorkspaceAction(WorkspaceActionRecord(
            profileID: profileID, kind: "tab_opened", description: "Opened SQL tab \"Untitled\""
        ))
        let executor = UIGraphToolExecutor(store: store, profileID: profileID, snapshot: { nil })

        let outcome = await executor.execute(AIToolCall(id: "c", name: "get_ui_state", args: [:]))

        let actions = decode(outcome)["recent_actions"] as? [[String: Any]] ?? []
        #expect(actions.count == 1)
        #expect(actions.first?["kind"] as? String == "tab_opened")
        #expect(actions.first?["description"] as? String == "Opened SQL tab \"Untitled\"")
    }

    @Test func neighborsReturnsPaneToTabContainment() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "query_ui_graph", args: ["op": "neighbors", "node": "pane:group-1"])
        )

        #expect(outcome.status == "ok")
        let outgoing = Set(decode(outcome)["outgoing"] as? [String] ?? [])
        #expect(outgoing == ["editor:tab-a", "table:tab-b"])
    }

    @Test func neighborsRejectsAnUnknownNode() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "query_ui_graph", args: ["op": "neighbors", "node": "nope"])
        )

        #expect(outcome.status == "error")
    }

    @Test func pathFindsTheHopChainFromPaneToTab() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "query_ui_graph", args: ["op": "path", "from": "pane:group-1", "to": "table:tab-b"])
        )

        #expect(decode(outcome)["reachable"] as? Bool == true)
        #expect(decode(outcome)["path"] as? [String] == ["pane:group-1", "table:tab-b"])
    }

    @Test func unknownOpIsRejected() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(
            AIToolCall(id: "c", name: "query_ui_graph", args: ["op": "blast_radius"])
        )

        #expect(outcome.status == "error")
    }

    @Test func unknownToolIsNotHandled() async throws {
        let store = try BerryStore(path: ":memory:")
        let executor = UIGraphToolExecutor(store: store, profileID: nil, snapshot: sampleSnapshot)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_sql", args: [:]))

        #expect(outcome.status == "error")
    }
}
