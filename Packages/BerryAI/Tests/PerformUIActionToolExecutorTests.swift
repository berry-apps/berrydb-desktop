import Testing
@testable import BerryAI

@Suite("perform_ui_action client tool")
struct PerformUIActionToolExecutorTests {
    @MainActor
    @Test func performsTheMatchingEnabledAction() async {
        final class Box { var ran: [String] = [] }
        let box = Box()
        let executor = PerformUIActionToolExecutor(currentEntries: {
            [
                UIActionEntry(action: "insights", title: "Insights", isEnabled: true, perform: { box.ran.append("insights") }),
                UIActionEntry(action: "graph_explorer", title: "Graph Explorer", isEnabled: true, perform: { box.ran.append("graph_explorer") }),
            ]
        })

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "perform_ui_action", args: ["action": "insights"]))

        #expect(outcome.status == "ok")
        #expect(box.ran == ["insights"])
        #expect(executor.didPerform == true)
    }

    @MainActor
    @Test func rejectsAMissingActionArgument() async {
        let executor = PerformUIActionToolExecutor(currentEntries: { [] })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "perform_ui_action", args: [:]))
        #expect(outcome.status == "error")
        #expect(executor.didPerform == false)
    }

    @MainActor
    @Test func rejectsAnUnknownActionID() async {
        let executor = PerformUIActionToolExecutor(currentEntries: {
            [UIActionEntry(action: "insights", title: "Insights", isEnabled: true, perform: {})]
        })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "perform_ui_action", args: ["action": "delete_everything"]))
        #expect(outcome.status == "error")
        #expect(executor.didPerform == false)
    }

    @MainActor
    @Test func refusesADisabledAction() async {
        final class Box { var ran = false }
        let box = Box()
        let executor = PerformUIActionToolExecutor(currentEntries: {
            [UIActionEntry(action: "new_table", title: "New Table…", isEnabled: false, perform: { box.ran = true })]
        })
        let outcome = await executor.execute(AIToolCall(id: "c1", name: "perform_ui_action", args: ["action": "new_table"]))
        #expect(outcome.status == "error")
        #expect(box.ran == false)
        #expect(executor.didPerform == false)
    }

    @MainActor
    @Test func aDeniedLeaseNeverInvokesTheAction() async {
        final class Box { var ran = false }
        let box = Box()
        let executor = PerformUIActionToolExecutor(currentEntries: {
            [UIActionEntry(action: "insights", title: "Insights", isEnabled: true, perform: { box.ran = true })]
        })
        let deniedLease = AIExecutionLease(validate: { false })

        let outcome = await executor.execute(
            AIToolCall(id: "c1", name: "perform_ui_action", args: ["action": "insights"]), lease: deniedLease
        )

        #expect(outcome == .denied)
        #expect(box.ran == false)
    }

    @MainActor
    @Test func resolvesActionsFreshOnEveryCallRatherThanCachingTheFirstSnapshot() async {
        final class Box { var enabled = false; var ran = false }
        let box = Box()
        let executor = PerformUIActionToolExecutor(currentEntries: {
            [UIActionEntry(action: "new_table", title: "New Table…", isEnabled: box.enabled, perform: { box.ran = true })]
        })

        let first = await executor.execute(AIToolCall(id: "c1", name: "perform_ui_action", args: ["action": "new_table"]))
        #expect(first.status == "error")

        box.enabled = true
        let second = await executor.execute(AIToolCall(id: "c2", name: "perform_ui_action", args: ["action": "new_table"]))
        #expect(second.status == "ok")
        #expect(box.ran == true)
    }
}
