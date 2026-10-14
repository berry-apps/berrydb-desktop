import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// Run All Safe as the panel wires it: the executor asks the controller
/// through the same adapter `bind` installs, and the controller decides
/// from its own trust which statements skip the card. Auto-run is off, so
/// only that trust can let a statement through.
///
/// Serialized: every test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("AIPanelController Run All Safe", .serialized)
struct AIPanelControllerRunAllSafeTests {
    private final class Finished {
        var value = false
    }

    private func makeController() throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(
            license: license, backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
    }

    private func makeExecutor(controller: AIPanelController) async throws -> (QueryToolExecutor, Session) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-run-all-safe-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        for try await _ in session.connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)") {}
        for try await _ in session.connection.execute("INSERT INTO t (id, name) VALUES (1, 'ann'), (2, 'bob')") {}
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session),
            gate: ApprovalGateAdapter(controller: controller),
            options: .init(autoApproveSelects: false), onPropose: { _, _ in }
        )
        return (executor, session)
    }

    /// Starts `sql` as a `run_sql` call and returns once it either shows a
    /// card or finishes without one.
    private func start(
        _ sql: String, on executor: QueryToolExecutor, controller: AIPanelController
    ) async throws -> Task<String, Never> {
        let finished = Finished()
        let call = Task { @MainActor in
            let outcome = await executor.execute(AIToolCall(id: UUID().uuidString, name: "run_sql", args: ["sql": sql]))
            finished.value = true
            return outcome.status
        }
        for _ in 0..<1_000 where controller.pendingApproval == nil && !finished.value {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return call
    }

    private func rowCount(_ session: Session) async throws -> Int {
        var rows = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rows += batch.count }
        }
        return rows
    }

    @Test func runAllSafeLetsLaterReadsThroughAndStillShowsACardForAWrite() async throws {
        let controller = try makeController()
        let (executor, session) = try await makeExecutor(controller: controller)

        let firstRead = try await start("SELECT id FROM t", on: executor, controller: controller)
        let card = try #require(controller.pendingApproval)
        #expect(card.offersRunAllSafe)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await firstRead.value == "ok")

        let laterRead = try await start("SELECT name FROM t", on: executor, controller: controller)
        #expect(controller.pendingApproval == nil)
        #expect(await laterRead.value == "ok")

        let write = "INSERT INTO t (id, name) VALUES (3, 'cal')"
        let laterWrite = try await start(write, on: executor, controller: controller)
        #expect(controller.pendingApproval?.sql == write)
        controller.resolveApproval(false)
        #expect(await laterWrite.value == "denied")
        #expect(try await rowCount(session) == 2)
    }

    /// The trust is granted only from a card that offered the button, so a
    /// request for it from a write's card leaves later reads asking.
    @Test func trustAskedForFromAWriteCardIsIgnored() async throws {
        let controller = try makeController()
        let (executor, _) = try await makeExecutor(controller: controller)

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
}
