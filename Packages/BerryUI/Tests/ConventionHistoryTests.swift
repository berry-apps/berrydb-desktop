import Foundation
import Synchronization
import Testing

@testable import BerryUI

/// Counts the instances alive, and the most seen at once.
private final class LiveGraph: Sendable {
    static let counts = Mutex((live: 0, most: 0))

    init() {
        Self.counts.withLock {
            $0.live += 1
            $0.most = max($0.most, $0.live)
        }
    }

    deinit {
        Self.counts.withLock { $0.live -= 1 }
    }
}

@MainActor
@Suite("Convention history", .serialized)
struct ConventionHistoryTests {
    /// Insights hold the current full graph while they judge the earlier
    /// ones, and a 20,000-table full graph takes hundreds of megabytes, so
    /// each earlier graph is judged and released before the next one loads:
    /// never more than one of them, two graphs with the current one.
    @Test func earlierGraphsAreJudgedOneAtATime() {
        let marks = (1...3).map { Date(timeIntervalSince1970: Double($0) * 1_000) }
        LiveGraph.counts.withLock { $0 = (live: 0, most: 0) }

        let held = WorkspaceViewModel.conventionHeld(at: marks, load: { _ in LiveGraph() }, judge: { _ in true })

        #expect(held == [true, true, true])
        #expect(LiveGraph.counts.withLock { $0.most } == 1)
        #expect(LiveGraph.counts.withLock { $0.live } == 0)
    }
}
