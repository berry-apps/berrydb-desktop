import BerryStore
import Foundation
import Testing
@testable import BerryAI

@Suite("get_slow_queries client tool (docs/feature/07 §14)")
struct GetSlowQueriesToolExecutorTests {
    private func entry(sql: String, ms: Int) -> QueryHistoryEntry {
        QueryHistoryEntry(profileID: nil, sql: sql, startedAt: Date(), durationMS: ms, status: "success")
    }

    @MainActor
    @Test func returnsTheGivenQueriesAsFormattedJSON() async {
        var seenLimit: Int?
        let executor = GetSlowQueriesToolExecutor(slowestQueries: { limit in
            seenLimit = limit
            return [self.entry(sql: "SELECT * FROM orders", ms: 420)]
        })

        let outcome = await executor.execute(AIToolCall(id: "c1", name: "get_slow_queries", args: [:]))

        #expect(outcome.status == "ok")
        #expect(seenLimit == 10) // default
        #expect(outcome.resultJSON?.contains("orders") == true)
        #expect(outcome.resultJSON?.contains("\"duration_ms\":420") == true)
    }

    @MainActor
    @Test func clampsAnOutOfRangeLimitArgument() async {
        var seenLimit: Int?
        let executor = GetSlowQueriesToolExecutor(slowestQueries: { limit in
            seenLimit = limit
            return []
        })

        _ = await executor.execute(AIToolCall(id: "c1", name: "get_slow_queries", args: ["limit": "500"]))
        #expect(seenLimit == 50) // clamped to the max

        _ = await executor.execute(AIToolCall(id: "c2", name: "get_slow_queries", args: ["limit": "0"]))
        #expect(seenLimit == 1) // clamped to the min
    }

    @MainActor
    @Test func aDeniedLeaseNeverInvokesTheQuery() async {
        var invoked = false
        let executor = GetSlowQueriesToolExecutor(slowestQueries: { _ in
            invoked = true
            return []
        })
        let deniedLease = AIExecutionLease(validate: { false })

        let outcome = await executor.execute(
            AIToolCall(id: "c1", name: "get_slow_queries", args: [:]), lease: deniedLease
        )

        #expect(outcome == .denied)
        #expect(invoked == false)
    }
}
