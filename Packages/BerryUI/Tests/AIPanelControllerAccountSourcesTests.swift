@testable import BerryAI
import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// The panel takes the API token and the AI balance from the controller's
/// replaceable sources. A test that binds the panel replaces both, and these
/// tests prove the replacement is what `bind`, `refreshBalance` and the
/// embedding transport use, so no test reads the login Keychain or sends a
/// balance request.
///
/// Serialized: the binding tests register the SQLite driver in the
/// process-wide registry, like the other suites that open an in-process
/// database.
@MainActor
@Suite("AIPanelController token and balance sources", .serialized)
struct AIPanelControllerAccountSourcesTests {
    /// The tokens and URLs the balance fetcher was called with, from
    /// whichever thread called it.
    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _tokens: [String] = []
        private var _backendURLs: [URL] = []

        var tokens: [String] { lock.withLock { _tokens } }
        var backendURLs: [URL] { lock.withLock { _backendURLs } }

        func record(token: String, backendURL: URL) {
            lock.withLock {
                _tokens.append(token)
                _backendURLs.append(backendURL)
            }
        }
    }

    private static let backendURL = URL(string: "https://example.invalid")!

    private static let balance = AIPanelController.Balance(
        plan: "trial", tokenQuota: .init(used: 10, limit: 100), balanceMicros: 0, totalTokensUsed: nil,
        lowBalance: false, totalBudgetUsedPercent: nil, models: [], quotaFallbackActive: true
    )

    private func makeController() throws -> AIPanelController {
        AIPanelController(
            license: LicenseManager(client: LicenseClient(baseURL: Self.backendURL)),
            backendURL: Self.backendURL,
            store: try BerryStore(path: ":memory:")
        )
    }

    private func makeSQLiteSession() async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-ai-account-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        return try await ConnectionManager().open(.sqlite(path: path))
    }

    /// Answers with `Self.balance` and records each call in `log`.
    private func recordingFetcher(_ log: FetchLog) -> @Sendable (String, URL) async -> AIPanelController.Balance? {
        let balance = Self.balance
        return { token, backendURL in
            log.record(token: token, backendURL: backendURL)
            return balance
        }
    }

    @Test func bindBuildsNoSessionWhenTheTokenSourceHasNone() async throws {
        let controller = try makeController()
        controller.apiToken = { nil }
        controller.fetchBalance = { _, _ in nil }

        controller.bind(session: try await makeSQLiteSession(), catalog: nil, objects: [], profileID: nil)

        #expect(!controller.isBuilt)
    }

    /// Guard: with a token the session is built, so the test above fails
    /// for the missing token and not for anything else `bind` needs.
    @Test func bindBuildsTheSessionWhenTheTokenSourceHasOne() async throws {
        let controller = try makeController()
        controller.useOfflineAccount()

        controller.bind(session: try await makeSQLiteSession(), catalog: nil, objects: [], profileID: nil)

        #expect(controller.isBuilt)
    }

    @Test func refreshBalanceFetchesWithTheSourcesToken() async throws {
        let controller = try makeController()
        let log = FetchLog()
        controller.apiToken = { "test-token" }
        controller.fetchBalance = recordingFetcher(log)

        await controller.refreshBalance(force: true)

        #expect(controller.balance == Self.balance)
        #expect(log.tokens == ["test-token"])
        #expect(log.backendURLs == [Self.backendURL])
    }

    /// `bind` refreshes the balance as soon as the panel is usable, through
    /// the same sources.
    @Test func bindFetchesTheBalanceThroughTheSources() async throws {
        let controller = try makeController()
        let log = FetchLog()
        controller.apiToken = { "test-token" }
        controller.fetchBalance = recordingFetcher(log)

        controller.bind(session: try await makeSQLiteSession(), catalog: nil, objects: [], profileID: nil)

        let deadline = ContinuousClock.now + .seconds(60)
        while controller.balance == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.balance == Self.balance)
        #expect(log.tokens == ["test-token"])
    }

    @Test func theEmbeddingTransportSendsTheSourcesToken() throws {
        let controller = try makeController()
        controller.apiToken = { "test-token" }

        let embedding = controller.makeSchemaEmbeddingTransport()
        defer { embedding.release() }

        let client = try #require(embedding.transport as? AIClient)
        #expect(client.tokenProvider() == "test-token")
    }
}
