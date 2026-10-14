import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryUI

@MainActor
private final class RecordingGate: AIApprovalGate {
    private(set) var cards: [String] = []

    func approve(sql: String, danger: DangerLevel, autoApprovable: Bool) async -> Bool {
        cards.append(sql)
        return false
    }
}

/// Auto-run of read-only statements starts off on a production connection
/// and stays on only after a choice made there. Every profile that turned AI
/// on already stores `true`, so a stored `true` alone proves no choice.
///
/// Serialized: the executor test registers the SQLite driver in the
/// process-wide registry, like the other suites that open a database.
@MainActor
@Suite("Auto-run on production connections", .serialized)
struct ProductionAutoRunTests {
    /// A throwaway defaults domain, so no test reads or writes the app's own
    /// preferences. Each test removes it with `removePersistentDomain`.
    private func makeDefaults() throws -> (defaults: UserDefaults, name: String) {
        let name = "berrydb-tests-auto-run-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func productionWithoutAChoiceShowsTheCardForAPlainSelect() async throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let autoRun = ProductionAutoRun.restored(stored: true, isProduction: true, profileID: UUID(), defaults: defaults)
        #expect(!autoRun)

        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-auto-run-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path), isProduction: true)
        for try await _ in session.connection.execute("CREATE TABLE t (id INTEGER)") {}
        let gate = RecordingGate()
        let executor = QueryToolExecutor(
            session: session, catalog: SchemaCatalog(session: session), gate: gate,
            options: .init(autoApproveSelects: autoRun), onPropose: { _, _ in }
        )

        _ = await executor.execute(AIToolCall(id: "c", name: "run_sql", args: ["sql": "SELECT id FROM t"]))

        #expect(gate.cards == ["SELECT id FROM t"])
    }

    @Test func productionWithAnOptInAutoRuns() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let profileID = UUID()

        ProductionAutoRun.recordChoice(isProduction: true, profileID: profileID, defaults: defaults)

        #expect(ProductionAutoRun.restored(stored: true, isProduction: true, profileID: profileID, defaults: defaults))
    }

    /// The off-by-default restore does not come back after an opt-in, and an
    /// opt-out made on production holds too.
    @Test func choiceOnProductionKeepsHolding() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let profileID = UUID()

        ProductionAutoRun.recordChoice(isProduction: true, profileID: profileID, defaults: defaults)

        for _ in 0..<3 {
            #expect(ProductionAutoRun.restored(stored: true, isProduction: true, profileID: profileID, defaults: defaults))
        }
        #expect(!ProductionAutoRun.restored(stored: false, isProduction: true, profileID: profileID, defaults: defaults))
    }

    /// A choice made while the connection was not production does not count
    /// once it is labeled production.
    @Test func choiceOffProductionDoesNotCarryOver() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let profileID = UUID()

        ProductionAutoRun.recordChoice(isProduction: false, profileID: profileID, defaults: defaults)

        #expect(!ProductionAutoRun.restored(stored: true, isProduction: true, profileID: profileID, defaults: defaults))
    }

    /// Guard: other connections keep the stored value, on by default.
    @Test func nonProductionIsUnchanged() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let profileID = UUID()

        #expect(ProductionAutoRun.restored(stored: nil, isProduction: false, profileID: profileID, defaults: defaults))
        #expect(ProductionAutoRun.restored(stored: true, isProduction: false, profileID: profileID, defaults: defaults))
        #expect(!ProductionAutoRun.restored(stored: false, isProduction: false, profileID: profileID, defaults: defaults))
        #expect(ProductionAutoRun.restored(stored: nil, isProduction: false, profileID: nil, defaults: defaults))
    }
}
