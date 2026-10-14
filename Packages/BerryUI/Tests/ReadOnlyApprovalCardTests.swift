import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// The line an approval card shows when its statement would have run
/// without it but the read-only connection could not take it.
///
/// Serialized: one test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("Approval card for a statement that could not run read-only", .serialized)
struct ReadOnlyApprovalCardTests {
    private typealias Card = AIPanelController.PendingApproval
    private static let sessionStateKey =
        "Not run automatically: this session has a temporary table or an open transaction that a read-only connection can't see."
    private static let connectionKey = "Not run automatically: BerryDB couldn't open a read-only connection (%@)."
    private static let vietnameseConnectionPrefix = "Không tự chạy: BerryDB không mở được kết nối chỉ đọc ("

    /// One localization of the BerryUI resource bundle, so a test can read
    /// the Vietnamese text in a process that runs in English.
    private func localization(_ language: String) throws -> Bundle {
        let path = try #require(berryModuleBundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// The text for `key` in one localization of the BerryUI resource bundle,
    /// or nil when that localization has no entry for it.
    private func localized(_ key: String, in language: String) -> String? {
        guard let bundle = try? localization(language) else { return nil }
        let missing = "\u{0}missing"
        let value = bundle.localizedString(forKey: key, value: missing, table: nil)
        return value == missing ? nil : value
    }

    private func makeController() throws -> AIPanelController {
        AIPanelController(
            license: LicenseManager(client: LicenseClient(baseURL: URL(string: "https://example.invalid")!)),
            backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
    }

    /// Waits for the card a task asked for, up to 60 seconds.
    private func waitForCard(on controller: AIPanelController) async {
        let deadline = ContinuousClock.now + .seconds(60)
        while controller.pendingApproval == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("no card within 60 seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func aCardForAnyOtherStatementSaysNothingMore() {
        #expect(Card(sql: "SELECT 1", danger: .safe).notAutoRunMessage == nil)
        #expect(Card(sql: "DELETE FROM t", danger: .confirm(.deleteWithoutWhere)).notAutoRunMessage == nil)
    }

    @Test func eachReasonHasItsLine() {
        let state = Card(sql: "SELECT 1", danger: .safe, notAutoRunReason: .sessionState)
        let failed = Card(sql: "SELECT 1", danger: .safe, notAutoRunReason: .connectionFailed("too many clients already"))

        #expect(state.notAutoRunMessage == L("Not run automatically: this session has a temporary table or an open transaction that a read-only connection can't see."))
        #expect(failed.notAutoRunMessage == L("Not run automatically: BerryDB couldn't open a read-only connection (\("too many clients already"))."))
        #expect(!state.offersRunAllSafe)
    }

    @Test func bothLinesAreTranslated() throws {
        for key in [Self.sessionStateKey, Self.connectionKey] {
            #expect(localized(key, in: "en") == key)
            let vietnamese = try #require(localized(key, in: "vi"), "vi.lproj has no entry for \(key)")
            #expect(vietnamese != key)
        }
        #expect(localized(Self.connectionKey, in: "vi")?.contains("%@") == true)
    }

    /// A server's words go into the line as they came, like every other
    /// database error the app shows; the reasons BerryDB gives itself are in
    /// the card's language. Taken from the router itself where it can be
    /// made to give them, so the card follows the words it actually uses.
    @Test func noEnglishReasonOfBerryDBsOwnReachesAVietnameseCard() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-card-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))
        let pool = ReadOnlyConnections()
        await pool.close(sessionID: session.id)
        let router = ReadOnlyRouter(connections: pool, tracker: SessionStateTracker(), transactionIsActive: { false })
        let closedSessionRoute = await router.route(for: session)
        var reasons: [ReadOnlyUnavailableReason] = [.connectionFailed(ReadOnlyUnavailableReason.cancelledDetail)]
        for route in [ReadOnlyRoute.withoutConnections(for: session), closedSessionRoute] {
            guard case .unavailable(let reason) = route else {
                Issue.record("expected the card's route, got \(route)")
                continue
            }
            reasons.append(reason)
        }
        let vietnamese = try localization("vi")

        for reason in reasons {
            guard case .connectionFailed(let detail) = reason else { continue }
            let line = try #require(Card(sql: "SELECT 1", danger: .safe, notAutoRunReason: reason).notAutoRunMessage(in: vietnamese))
            #expect(line.hasPrefix(Self.vietnameseConnectionPrefix))
            #expect(!line.contains(detail), "\(line)")
        }
        let server = Card(sql: "SELECT 1", danger: .safe, notAutoRunReason: .connectionFailed("too many clients already"))
        #expect(server.notAutoRunMessage(in: vietnamese) == Self.vietnameseConnectionPrefix + "too many clients already).")
        await manager.close(session.id)
    }

    /// The panel puts the reason on the pending card and offers no Run All
    /// Safe there.
    @Test func thePanelShowsTheReasonOnTheCard() async throws {
        let controller = try makeController()
        let pending = Task { @MainActor in
            await controller.requestApproval(
                sql: "SELECT 1", danger: .safe, readOnly: false, timeoutSeconds: 120, notAutoRunReason: .sessionState
            )
        }
        await waitForCard(on: controller)

        #expect(controller.pendingApproval?.notAutoRunReason == .sessionState)
        #expect(controller.pendingApproval?.offersRunAllSafe == false)
        controller.resolveApproval(false)
        #expect(await pending.value == false)
    }

    /// After Run All Safe the gate trusts later reads, yet the card saying
    /// the read-only connection cannot take one still shows, without the
    /// button that would only bring the statement back to it.
    @Test func theReasonCardShowsEvenAfterRunAllSafe() async throws {
        let controller = try makeController()
        let gate = ApprovalGateAdapter(controller: controller)
        let first = Task { @MainActor in
            await controller.requestApproval(sql: "SELECT 1", danger: .safe, readOnly: true, timeoutSeconds: 120)
        }
        await waitForCard(on: controller)
        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
        #expect(await first.value)
        #expect(gate.trustsWithoutCard(sql: "SELECT 2", danger: .safe))

        let carded = Task { @MainActor in
            await gate.approveOnSessionConnection(sql: "SELECT 2", danger: .safe, reason: .sessionState, timeoutSeconds: 120)
        }
        await waitForCard(on: controller)

        #expect(controller.pendingApproval?.notAutoRunReason == .sessionState)
        #expect(controller.pendingApproval?.offersRunAllSafe == false)
        controller.resolveApproval(false)
        #expect(await carded.value == false)
    }
}
