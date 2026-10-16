import BerryAI
@testable import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Run All Safe as the panel wires it: the executor asks the controller
/// through the same adapter `bind` installs, and the controller decides
/// from its own trust which statements skip the card. A statement that
/// skips its card goes where the app sends it, through the controller to
/// the workspace's read-only connection. Auto-run is off, so only that trust
/// can let a statement through.
///
/// Serialized: every test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("AIPanelController Run All Safe", .serialized)
struct AIPanelControllerRunAllSafeTests {
    private final class Finished {
        var value = false
    }

    /// An executor, its session, and the workspace that owns the session's
    /// read-only connection.
    private struct Wiring {
        let executor: QueryToolExecutor
        let session: Session
        let workspace: WorkspaceViewModel
    }

    private let store = TemporaryStoreFile()

    private func makeController() throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(
            license: license, backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
    }

    /// The executor as `bind` builds it, with the controller's route set the
    /// way `WorkspaceView` sets it.
    private func makeExecutor(controller: AIPanelController) async throws -> Wiring {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-run-all-safe-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let workspace = try WorkspaceViewModel(storePath: store.path)
        await workspace.openSQLiteFile(at: URL(fileURLWithPath: path))
        let session = try #require(workspace.session)
        for try await _ in session.connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)") {}
        for try await _ in session.connection.execute("INSERT INTO t (id, name) VALUES (1, 'ann'), (2, 'bob')") {}
        controller.readOnlyRoute = { session in await workspace.readOnlyRoute(for: session) }
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session),
            gate: ApprovalGateAdapter(controller: controller),
            options: .init(autoApproveSelects: false), onPropose: { _, _ in },
            readOnlyRoute: { [weak controller] session in
                await controller?.automaticRunRoute(for: session) ?? ReadOnlyRoute.withoutConnections(for: session)
            }
        )
        return Wiring(executor: executor, session: session, workspace: workspace)
    }

    /// Starts `sql` as a `run_sql` call and returns once it either shows a
    /// card or finishes without one, waiting up to 60 seconds.
    private func start(
        _ sql: String, on executor: QueryToolExecutor, controller: AIPanelController
    ) async throws -> Task<String, Never> {
        let finished = Finished()
        let call = Task { @MainActor in
            let outcome = await executor.execute(AIToolCall(id: UUID().uuidString, name: "run_sql", args: ["sql": sql]))
            finished.value = true
            return outcome.status
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while controller.pendingApproval == nil, !finished.value, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return call
    }

    /// Denies a card a failed expectation left showing, so the call behind
    /// it ends now instead of at the card's timeout.
    private func denyAnyCard(_ controller: AIPanelController) {
        if controller.pendingApproval != nil { controller.resolveApproval(false) }
    }

    private func rowCount(_ session: Session) async throws -> Int {
        var rows = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rows += batch.count }
        }
        return rows
    }

    @Test func runAllSafeLetsLaterReadsThroughAndStillShowsACardForAWrite() async throws {
        defer { store.remove() }
        let controller = try makeController()
        let wiring = try await makeExecutor(controller: controller)
        let executor = wiring.executor

        let firstRead = try await start("SELECT id FROM t", on: executor, controller: controller)
        let card = try #require(controller.pendingApproval)
        #expect(card.offersRunAllSafe)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await firstRead.value == "ok")

        let laterRead = try await start("SELECT name FROM t", on: executor, controller: controller)
        #expect(controller.pendingApproval == nil)
        denyAnyCard(controller)
        #expect(await laterRead.value == "ok")

        let write = "INSERT INTO t (id, name) VALUES (3, 'cal')"
        let laterWrite = try await start(write, on: executor, controller: controller)
        #expect(controller.pendingApproval?.sql == write)
        controller.resolveApproval(false)
        #expect(await laterWrite.value == "denied")
        #expect(try await rowCount(wiring.session) == 2)
    }

    /// The trust is granted only from a card that offered the button, so a
    /// request for it from a write's card leaves later reads asking.
    @Test func trustAskedForFromAWriteCardIsIgnored() async throws {
        defer { store.remove() }
        let controller = try makeController()
        let executor = try await makeExecutor(controller: controller).executor

        let update = try await start("UPDATE t SET name = 'x' WHERE id = 1", on: executor, controller: controller)
        let card = try #require(controller.pendingApproval)
        #expect(!card.offersRunAllSafe)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await update.value == "ok")

        let read = "SELECT id FROM t"
        let laterRead = try await start(read, on: executor, controller: controller)
        #expect(controller.pendingApproval?.sql == read)
        controller.resolveApproval(false)
        #expect(await laterRead.value == "denied")
    }

    /// A read the trust lets through is an automatic run, so it goes to the
    /// session's read-only connection; the read approved on its own card
    /// stays on the session's connection.
    @Test func aTrustedReadRunsOnTheReadOnlyConnection() async throws {
        defer { store.remove() }
        let controller = try makeController()
        let wiring = try await makeExecutor(controller: controller)

        let firstRead = try await start("SELECT id FROM t", on: wiring.executor, controller: controller)
        try #require(controller.pendingApproval != nil)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await firstRead.value == "ok")
        #expect(await wiring.workspace.readOnlyConnections.cachedSessionCount == 0)

        let laterRead = try await start("SELECT name FROM t", on: wiring.executor, controller: controller)

        #expect(controller.pendingApproval == nil)
        denyAnyCard(controller)
        #expect(await laterRead.value == "ok")
        #expect(await wiring.workspace.readOnlyConnections.cachedSessionCount == 1)
    }

    /// The trust skips a statement's own card, never the card saying the
    /// read-only connection cannot take it, here because the editor holds a
    /// transaction open. That card offers no Run All Safe.
    @Test func aTrustedReadTheReadOnlyConnectionCannotTakeStillShowsItsCard() async throws {
        defer { store.remove() }
        let controller = try makeController()
        let wiring = try await makeExecutor(controller: controller)
        #expect(await wiring.workspace.transaction.begin(session: wiring.session))

        let firstRead = try await start("SELECT id FROM t", on: wiring.executor, controller: controller)
        try #require(controller.pendingApproval != nil)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await firstRead.value == "ok")

        let read = "SELECT name FROM t"
        let laterRead = try await start(read, on: wiring.executor, controller: controller)

        let card = try #require(controller.pendingApproval)
        #expect(card.sql == read)
        #expect(card.notAutoRunReason == .sessionState)
        #expect(!card.offersRunAllSafe)
        controller.resolveApproval(false)
        #expect(await laterRead.value == "denied")
        #expect(await wiring.workspace.transaction.rollback(session: wiring.session))
    }

    /// Run All Safe on a card covers later reads of the turn, and only reads.
    @Test func thePanelTrustsReadsOnlyAfterRunAllSafe() async throws {
        let controller = try makeController()
        #expect(!controller.trustsSafeStatement(danger: .safe))

        let pending = Task { @MainActor in
            await controller.requestApproval(sql: "SELECT 1", danger: .safe, readOnly: true, timeoutSeconds: 120)
        }
        let deadline = ContinuousClock.now + .seconds(60)
        while controller.pendingApproval == nil, ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)

        #expect(await pending.value)
        #expect(controller.trustsSafeStatement(danger: .safe))
        #expect(!controller.trustsSafeStatement(danger: .confirm(.deleteData)))
    }
}
