import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryUI

/// The panel's gate for a turn in which Run All Safe was already used: a
/// statement the trust covers skips its card, every other card is recorded
/// and denied.
@MainActor
private final class TrustedTurnGate: AIApprovalGate {
    private(set) var cards: [String] = []

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        if RunAllSafeTrust.skipsCard(danger: danger, readOnly: autoApprovable, trustedThisTurn: true) {
            return true
        }
        cards.append(sql)
        return false
    }
}

/// Serialized: every test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("Run All Safe trust", .serialized)
struct RunAllSafeTrustTests {
    /// Auto-run is off so only the trust can let a statement through.
    private func makeExecutor(gate: TrustedTurnGate) async throws -> (QueryToolExecutor, Session) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-trust-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        for try await _ in session.connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)") {}
        for try await _ in session.connection.execute("INSERT INTO t (id, name) VALUES (1, 'ann'), (2, 'bob')") {}
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: gate,
            options: .init(autoApproveSelects: false), onPropose: { _, _ in }
        )
        return (executor, session)
    }

    @Test func laterReadSkipsItsCard() async throws {
        let gate = TrustedTurnGate()
        let (executor, _) = try await makeExecutor(gate: gate)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_sql", args: ["sql": "SELECT id FROM t"]))

        #expect(outcome.status == "ok")
        #expect(gate.cards.isEmpty)
    }

    @Test(arguments: [
        "INSERT INTO t (id, name) VALUES (3, 'cal')",
        "UPDATE t SET name = 'x' WHERE id = 1",
        "CREATE TABLE u (id INTEGER)",
        "ALTER TABLE t ADD COLUMN note TEXT",
        "GRANT SELECT ON t TO reader",
        "SELECT id FROM t; DELETE FROM t",
    ])
    func laterWriteStillShowsACard(_ sql: String) async throws {
        let gate = TrustedTurnGate()
        let (executor, session) = try await makeExecutor(gate: gate)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "run_sql", args: ["sql": sql]))

        #expect(outcome.status == "denied")
        #expect(gate.cards.count == 1)
        #expect(gate.cards.first == sql)
        var rows = 0
        for try await event in session.connection.execute("SELECT id FROM t") {
            if case let .rows(batch) = event { rows += batch.count }
        }
        #expect(rows == 2)
    }

    @Test func buttonAppearsOnlyOnAReadOnlyCard() {
        typealias Card = AIPanelController.PendingApproval
        #expect(Card(sql: "SELECT 1", danger: .safe, readOnly: true).offersRunAllSafe)
        #expect(!Card(sql: "INSERT INTO t VALUES (1)", danger: .safe, readOnly: false).offersRunAllSafe)
        #expect(!Card(sql: "UPDATE t SET a = 1 WHERE id = 2", danger: .safe, readOnly: false).offersRunAllSafe)
        #expect(!Card(sql: "DELETE FROM t", danger: .confirm(.deleteWithoutWhere), readOnly: false).offersRunAllSafe)
    }
}
