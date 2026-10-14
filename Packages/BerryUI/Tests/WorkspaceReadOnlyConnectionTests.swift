@testable import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryUI

/// The workspace owns one read-only connection per session and closes it
/// with the session, and forgets what the session's own connection held.
/// A temporary store and SQLite file; no Keychain.
///
/// Serialized: every test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("Workspace read-only connections", .serialized)
struct WorkspaceReadOnlyConnectionTests {
    private let store = TemporaryStoreFile()

    private func tempDatabase() -> URL {
        let path = NSTemporaryDirectory() + "berry-readonly-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        return URL(fileURLWithPath: path)
    }

    private func openWorkspace() async throws -> (WorkspaceViewModel, Session) {
        DriverRegistry.register(SQLiteDriver.self)
        let viewModel = try WorkspaceViewModel(storePath: store.path)
        await viewModel.openSQLiteFile(at: tempDatabase())
        return (viewModel, try #require(viewModel.session))
    }

    /// Runs `sql` on the session's own connection the way the editor does,
    /// through the statement path that feeds the session state tracker.
    private func runInEditor(_ sql: String, on session: Session) async throws {
        for try await _ in QueryService.execute(sql, on: session, autoLimit: nil) {}
    }

    /// Waits up to 60 seconds for work the workspace runs on a task it does
    /// not keep, such as disconnect's rollback.
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(what) did not happen within 60 seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func aSessionHasItsReadOnlyConnectionUntilItDisconnects() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()

        guard case .readOnly(let lease) = await viewModel.readOnlyRoute(for: session) else {
            Issue.record("expected the read-only connection")
            return
        }
        #expect(lease.connection.id != session.connection.id)
        await lease.finish(failed: false)
        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 1)

        viewModel.disconnect()
        await viewModel.closingGraphWork?.value

        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 0)
        guard case .unavailable = await viewModel.readOnlyRoute(for: session) else {
            Issue.record("a closed session got a connection again")
            return
        }
    }

    @Test func openingAnotherConnectionClosesTheOldSessionsOne() async throws {
        defer { store.remove() }
        let (viewModel, first) = try await openWorkspace()
        if case .readOnly(let lease) = await viewModel.readOnlyRoute(for: first) { await lease.finish(failed: false) }
        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 1)

        await viewModel.openSQLiteFile(at: tempDatabase())
        await viewModel.closingGraphWork?.value

        let second = try #require(viewModel.session)
        #expect(second.id != first.id)
        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 0)
        guard case .readOnly(let lease) = await viewModel.readOnlyRoute(for: second) else {
            Issue.record("expected the new session's read-only connection")
            return
        }
        await lease.finish(failed: false)
    }

    /// The route reads the editor's transaction from the workspace, not only
    /// from the statements the tracker saw: the tracker's record of the
    /// BEGIN is dropped here, so only the transaction controller can still
    /// send automatic runs to the card.
    @Test func anOpenEditorTransactionSendsAutomaticRunsToTheCard() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()

        #expect(await viewModel.transaction.begin(session: session))
        SessionStateTracker.shared.forget(sessionID: session.id)
        guard case .unavailable(.sessionState) = await viewModel.readOnlyRoute(for: session) else {
            Issue.record("expected the card while the transaction is open")
            return
        }
        #expect(await viewModel.transaction.rollback(session: session))
        guard case .readOnly(let lease) = await viewModel.readOnlyRoute(for: session) else {
            Issue.record("expected the read-only connection once the transaction ended")
            return
        }
        await lease.finish(failed: false)
    }

    /// Every connect gives the workspace a new transaction controller, and
    /// the route reads the current one: a transaction the old session left
    /// open does not hold the new session's runs back. The old session is
    /// routed once first, so a route that kept the controller it first saw
    /// would keep the old one.
    @Test func aTransactionLeftOnTheOldSessionDoesNotHoldTheNewOne() async throws {
        defer { store.remove() }
        let (viewModel, first) = try await openWorkspace()
        if case .readOnly(let lease) = await viewModel.readOnlyRoute(for: first) { await lease.finish(failed: false) }
        let old = viewModel.transaction
        #expect(await old.begin(session: first))

        await viewModel.openSQLiteFile(at: tempDatabase())

        #expect(old.isActive)
        let second = try #require(viewModel.session)
        guard case .readOnly(let lease) = await viewModel.readOnlyRoute(for: second) else {
            Issue.record("expected the new session's read-only connection")
            return
        }
        await lease.finish(failed: false)
    }

    @Test func closingTheWindowClosesTheReadOnlyConnections() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()
        if case .readOnly(let lease) = await viewModel.readOnlyRoute(for: session) { await lease.finish(failed: false) }
        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 1)

        viewModel.closeWorkspace()
        await viewModel.closingGraphWork?.value

        #expect(await viewModel.readOnlyConnections.cachedSessionCount == 0)
    }

    // MARK: What the session's own connection held

    @Test func disconnectingForgetsWhatTheSessionHeld() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()
        try await runInEditor("CREATE TEMP TABLE scratch (id INTEGER)", on: session)
        #expect(SessionStateTracker.shared.state(for: session.id).hasSessionLocalState)

        viewModel.disconnect()

        await waitUntil("forgetting the temporary table") {
            !SessionStateTracker.shared.state(for: session.id).hasSessionLocalState
        }
    }

    @Test func openingAnotherConnectionForgetsWhatTheOldSessionHeld() async throws {
        defer { store.remove() }
        let (viewModel, first) = try await openWorkspace()
        try await runInEditor("CREATE TEMP TABLE scratch (id INTEGER)", on: first)
        #expect(SessionStateTracker.shared.state(for: first.id).hasSessionLocalState)

        await viewModel.openSQLiteFile(at: tempDatabase())
        await viewModel.closingGraphWork?.value

        #expect(!SessionStateTracker.shared.isTracking(sessionID: first.id))
    }

    /// Disconnecting rolls an open editor transaction back through the
    /// statement path that feeds the tracker. The session is forgotten only
    /// after that rollback, which would otherwise record it again for good.
    @Test func aSessionClosedWithAnOpenTransactionIsNotRecordedAgain() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()
        let transaction = viewModel.transaction
        #expect(await transaction.begin(session: session))
        #expect(SessionStateTracker.shared.isTracking(sessionID: session.id))

        viewModel.disconnect()

        await waitUntil("the rollback, then forgetting the session") {
            !transaction.isActive && !SessionStateTracker.shared.isTracking(sessionID: session.id)
        }
    }

    @Test func closingTheWindowForgetsWhatTheSessionHeld() async throws {
        defer { store.remove() }
        let (viewModel, session) = try await openWorkspace()
        try await runInEditor("CREATE TEMP TABLE scratch (id INTEGER)", on: session)
        #expect(SessionStateTracker.shared.state(for: session.id).hasSessionLocalState)

        viewModel.closeWorkspace()
        await viewModel.closingGraphWork?.value

        #expect(!SessionStateTracker.shared.isTracking(sessionID: session.id))
    }
}
