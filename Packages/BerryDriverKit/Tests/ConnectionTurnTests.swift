import Foundation
import Testing

@testable import BerryDriverKit

@Suite("Connection turn")
struct ConnectionTurnTests {
    private actor Log {
        var entries: [String] = []
        func append(_ entry: String) { entries.append(entry) }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    /// Whether `body` finishes within a minute. A turn that is never given
    /// back leaves its waiters suspended for good, and a waiting test would
    /// hang the run instead of failing.
    private func finishes(_ body: @escaping @Sendable () async -> Void) async -> Bool {
        let done = Flag()
        Task {
            await body()
            done.raise()
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while !done.isRaised, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done.isRaised
    }

    /// Takers that arrive together run one at a time: each one's start is
    /// followed by its own end before the next one starts.
    @Test func takersRunOneAtATime() async {
        let turn = ConnectionTurn()
        let log = Log()

        let finished = await finishes {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<10 {
                    group.addTask {
                        await turn.take()
                        await log.append("start \(index)")
                        try? await Task.sleep(for: .milliseconds(5))
                        await log.append("end \(index)")
                        turn.give()
                    }
                }
            }
        }

        #expect(finished)
        let entries = await log.entries
        #expect(entries.count == 20)
        for pair in stride(from: 0, to: entries.count - 1, by: 2) {
            let started = entries[pair]
            #expect(started.hasPrefix("start "), "\(entries)")
            #expect(entries[pair + 1] == "end " + started.dropFirst("start ".count), "\(entries)")
        }
    }

    /// A turn given back with no one waiting can be taken again at once.
    @Test func aGivenTurnCanBeTakenAgain() async {
        let turn = ConnectionTurn()

        let finished = await finishes {
            await turn.take()
            turn.give()
            await turn.take()
            turn.give()
        }

        #expect(finished)
    }
}

@Suite("Read-only statement turn")
struct ReadOnlyTurnTests {
    @Test func aStatementCancelledWhileItWaitsNeverRunsAndSendsNoCancel() {
        let turn = ReadOnlyTurn()

        #expect(turn.cancel() == false)
        #expect(turn.begin() == false)
    }

    @Test func aCancelReachesTheStatementHoldingTheTurn() {
        let turn = ReadOnlyTurn()

        #expect(turn.begin())
        #expect(turn.cancel())
    }

    @Test func aCancelAfterTheStatementEndedSendsNothing() {
        let turn = ReadOnlyTurn()

        #expect(turn.begin())
        turn.end()
        #expect(turn.cancel() == false)
    }
}

@Suite("Driver error detail")
struct DriverErrorDetailTests {
    /// The server's message alone, without the "Query failed" wrapper, so a
    /// read-only refusal does not read "Read-only mode unavailable: Query
    /// failed: …".
    @Test func aFailedQueryGivesTheServersMessage() {
        let error = DriverError.queryFailed(message: "Access denied for user", code: 1045)

        #expect(error.detail == "Access denied for user")
    }

    @Test func anyOtherErrorGivesItsDescription() {
        #expect(DriverError.cancelled.detail == DriverError.cancelled.localizedDescription)
        #expect(DriverError.notConnected.detail == DriverError.notConnected.localizedDescription)
    }
}
