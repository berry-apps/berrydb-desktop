import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

/// Where a statement that runs without its own approval card goes. Uses the
/// scripted driver of `ReadOnlyConnectionsTests`.
@MainActor
@Suite("Read-only routing", .timeLimit(.minutes(2)))
struct ReadOnlyRouterTests {
    private func router(
        _ pool: ReadOnlyConnections, tracker: SessionStateTracker = SessionStateTracker(),
        transactionIsActive: @escaping @MainActor () -> Bool = { false }
    ) -> ReadOnlyRouter {
        ReadOnlyRouter(connections: pool, tracker: tracker, transactionIsActive: transactionIsActive)
    }

    private nonisolated static func waitForWaiters(_ count: Int, on pool: ReadOnlyConnections) async {
        await ReadOnlyConnectionsTests.waitUntil { await pool.leasesWaiting == count }
    }

    @Test func anEngineWithTheContractGetsItsReadOnlyConnection() async throws {
        let script = ROScript()
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()

        guard case .readOnly(let lease) = await router(pool).route(for: session) else {
            Issue.record("expected the read-only connection")
            await pool.closeAll()
            return
        }
        #expect(lease.connection.id != session.connection.id)
        #expect(await script.connects == 1)
        await lease.finish(failed: false)
        await pool.closeAll()
    }

    /// SQL Server and DynamoDB keep the classifier as the only check.
    @Test func anEngineWithoutTheContractIsNotSupported() async {
        let script = ROScript()
        let session = await ReadOnlyConnectionsTests.session(script: script, main: PlainConnection())
        let pool = ReadOnlyConnectionsTests.pool()

        guard case .notSupported = await router(pool).route(for: session) else {
            Issue.record("expected no read-only connection")
            return
        }
        #expect(await script.connects == 0)
    }

    @Test(arguments: [
        SessionStateTracker.State(hasSessionLocalState: true, hasOpenTransaction: false),
        SessionStateTracker.State(hasSessionLocalState: false, hasOpenTransaction: true),
    ])
    func stateOnTheSessionConnectionSendsTheStatementToTheCard(_ state: SessionStateTracker.State) async {
        let script = ROScript()
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let tracker = SessionStateTracker()
        if state.hasSessionLocalState { tracker.recordSucceeded("CREATE TEMP TABLE x (a int)", sessionID: session.id) }
        if state.hasOpenTransaction { tracker.recordSucceeded("BEGIN", sessionID: session.id) }
        let pool = ReadOnlyConnectionsTests.pool()

        guard case .unavailable(.sessionState) = await router(pool, tracker: tracker).route(for: session) else {
            Issue.record("expected the card")
            return
        }
        #expect(await script.connects == 0)
    }

    /// The editor's manual transaction is read through a closure on every
    /// call: the workspace replaces its transaction controller on every
    /// connect, so a captured one would go stale.
    @Test func theEditorsOpenTransactionSendsTheStatementToTheCard() async {
        let script = ROScript()
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()
        let editor = EditorTransaction()
        let router = router(pool, transactionIsActive: { editor.isOpen })

        guard case .unavailable(.sessionState) = await router.route(for: session) else {
            Issue.record("expected the card")
            return
        }
        editor.isOpen = false
        guard case .readOnly(let lease) = await router.route(for: session) else {
            Issue.record("expected the read-only connection once the transaction ended")
            await pool.closeAll()
            return
        }
        #expect(await script.connects == 1)
        await lease.finish(failed: false)
        await pool.closeAll()
    }

    /// The reason is the driver's own words: `DriverError.readOnlyUnavailable`
    /// already reads "Read-only mode unavailable: ...", which the card's
    /// sentence would otherwise wrap a second time.
    @Test func aSetupThatFailsGivesTheDriversDetailAsTheReason() async {
        let script = ROScript(prepareFailure: "too many connections for role \"app\"")
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()

        guard case .unavailable(.connectionFailed(let reason)) = await router(pool).route(for: session) else {
            Issue.record("expected the card with a reason")
            return
        }
        #expect(reason == "too many connections for role \"app\"")
    }

    @Test func aConnectThatFailsGivesTheErrorsOwnTextAsTheReason() async {
        let script = ROScript(failingConnects: 1)
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()

        guard case .unavailable(.connectionFailed(let reason)) = await router(pool).route(for: session) else {
            Issue.record("expected the card with a reason")
            return
        }
        #expect(reason == ROScriptedError.connectFailed.localizedDescription)
    }

    /// Two statements side by side wait on one open; when it fails, each gets
    /// its reason, and neither reports the session as closed.
    @Test func everyCallerWaitingOnAFailedOpenGetsItsReason() async {
        let gate = ROGate()
        let script = ROScript(failingConnects: 1, gate: gate)
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()
        let router = router(pool)

        let first = Task { @MainActor in await router.route(for: session) }
        await gate.waitUntilReached()
        let second = Task { @MainActor in await router.route(for: session) }
        await Self.waitForWaiters(2, on: pool)
        await gate.open()

        let reasons = [await first.value, await second.value].map { route -> String? in
            if case .unavailable(.connectionFailed(let reason)) = route { return reason }
            return nil
        }
        #expect(reasons[0] == ROScriptedError.connectFailed.localizedDescription)
        #expect(reasons[1] == reasons[0])
        #expect(await script.connects == 1)
    }

    /// A session that really closed is the only case that reports a closed
    /// session.
    @Test func aClosedSessionIsReportedAsClosed() async {
        let script = ROScript()
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()
        await pool.close(sessionID: session.id)

        guard case .unavailable(.connectionFailed(let reason)) = await router(pool).route(for: session) else {
            Issue.record("expected the card")
            return
        }
        #expect(reason == "the session is closed")
        #expect(await script.connects == 0)
    }

    /// A caller cancelled while the connection opens is handed no lease: the
    /// pool would hold the connection open for one nobody finishes.
    @Test func aCallerCancelledWhileTheConnectionOpensLeavesNoLeaseBehind() async {
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()
        let router = router(pool)

        let routing = Task { @MainActor in await router.route(for: session) }
        await gate.waitUntilReached()
        routing.cancel()
        await gate.open()

        let route = await routing.value
        if case .readOnly = route { Issue.record("a cancelled caller was handed the connection") }
        await pool.closeAll()
        #expect(await script.closes == 1)
    }

    /// Stop answers at once while the connection still opens, as cancelled
    /// rather than as a closed session.
    @Test func aCallerStoppedWhileTheConnectionOpensIsAnsweredAtOnce() async {
        let gate = ROGate()
        let script = ROScript(gate: gate)
        let session = await ReadOnlyConnectionsTests.session(script: script)
        let pool = ReadOnlyConnectionsTests.pool()
        let router = router(pool)

        let routing = Task { @MainActor in await router.route(for: session) }
        await gate.waitUntilReached()
        await Self.waitForWaiters(1, on: pool)
        routing.cancel()
        let route = await ReadOnlyConnectionsTests.value(of: routing)

        if case .unavailable(.connectionFailed(let detail))? = route {
            #expect(detail == ReadOnlyUnavailableReason.cancelledDetail)
        } else {
            Issue.record("expected a cancelled route before the connection opened, got \(String(describing: route))")
        }
        await gate.open()
        await pool.closeAll()
    }

    /// A caller that was given no routing never runs an automatic statement
    /// on the session's own connection of an engine that has the contract.
    @Test func withoutRoutingAnEngineWithTheContractGetsTheCard() async {
        let withContract = await ReadOnlyConnectionsTests.session(script: ROScript())
        let without = await ReadOnlyConnectionsTests.session(script: ROScript(), main: PlainConnection())

        guard case .unavailable(.connectionFailed) = ReadOnlyRoute.withoutConnections(for: withContract) else {
            Issue.record("expected the card")
            return
        }
        guard case .notSupported = ReadOnlyRoute.withoutConnections(for: without) else {
            Issue.record("expected no read-only connection")
            return
        }
    }
}

/// Stands in for the workspace's current transaction controller.
@MainActor
private final class EditorTransaction {
    var isOpen = true
}
