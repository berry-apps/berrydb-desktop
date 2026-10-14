import BerryCore
import BerryDataSourceKit
import BerryDriverKit
import BerryDriverSQLite
import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

private struct NoCollections: DataSourceIntrospector {
    func collections() async throws -> [CollectionRef] { [] }
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] { [:] }
}

/// A document, search or vector connection that is never queried: these
/// tests only bind it.
private actor IdleConnection: DataSourceConnection {
    nonisolated let id = UUID()

    func listCollections() async throws -> [CollectionRef] { [] }
    func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {}

    nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        DataSourceWriteResult(affectedCount: 0)
    }

    nonisolated func cancelCurrentQuery() {}
    nonisolated var introspector: any DataSourceIntrospector { NoCollections() }
    func ping() async -> Bool { true }
    func close() async {}
}

/// What `bind` restores for a connection labeled production, and what the
/// settings menu's toggle records there. Every profile that turned AI on
/// already stores auto-run as on, so that stored value alone proves no
/// choice.
///
/// Serialized: every test registers the SQLite driver in the process-wide
/// registry, like the other suites that open an in-process database.
@MainActor
@Suite("AIPanelController on production connections", .serialized)
struct AIPanelControllerProductionTests {
    private final class SavedSettings {
        var value: AIPanelController.AIConnectionSettings?
    }

    private static let enabledWithAutoRun = AIPanelController.AIConnectionSettings(
        enabled: true, allowSampleRows: false, autoApproveSelects: true, consentGiven: true
    )

    /// A controller whose stored settings are `saved` and whose saves land
    /// in `saves`.
    private func makeController(
        saved: AIPanelController.AIConnectionSettings?, saves: SavedSettings = SavedSettings()
    ) throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        let controller = AIPanelController(
            license: license, backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
        controller.loadSettings = { _ in saved }
        controller.saveSettings = { _, settings in saves.value = settings }
        return controller
    }

    private func makeSQLiteSession(isProduction: Bool) async throws -> Session {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-ai-production-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        return try await ConnectionManager().open(.sqlite(path: path), isProduction: isProduction)
    }

    /// Runs `body` with a fresh profile id and removes the auto-run choice
    /// and consent version it may record from the defaults afterwards.
    private func withProfile(_ body: (UUID) async throws -> Void) async rethrows {
        let profileID = UUID()
        defer {
            UserDefaults.standard.removeObject(forKey: ProductionAutoRun.choiceKey(profileID))
            UserDefaults.standard.removeObject(forKey: AIPanelController.consentVersionKey(profileID))
        }
        try await body(profileID)
    }

    @Test func productionStartsWithAutoRunOffDespiteAStoredOn() async throws {
        try await withProfile { profileID in
            let controller = try makeController(saved: Self.enabledWithAutoRun)

            controller.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)

            #expect(!controller.autoApproveSelects)
        }
    }

    @Test func aChoiceMadeOnProductionHoldsWhenTheConnectionIsBoundAgain() async throws {
        try await withProfile { profileID in
            let saves = SavedSettings()
            let controller = try makeController(saved: Self.enabledWithAutoRun, saves: saves)
            controller.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)

            controller.autoApproveSelects = true

            let reopened = try makeController(saved: saves.value)
            reopened.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)
            #expect(reopened.autoApproveSelects)
        }
    }

    /// Guard: off production the stored value comes back as it was.
    @Test(arguments: [true, false])
    func nonProductionRestoresTheStoredValue(_ stored: Bool) async throws {
        try await withProfile { profileID in
            var saved = Self.enabledWithAutoRun
            saved.autoApproveSelects = stored
            let controller = try makeController(saved: saved)

            controller.bind(session: try await makeSQLiteSession(isProduction: false), catalog: nil, objects: [], profileID: profileID)

            #expect(controller.autoApproveSelects == stored)
        }
    }

    // MARK: Saving

    /// Auto-run off on production is a default, not a choice. Saving another
    /// setting must not store it, or auto-run would stay off once the
    /// production label is removed.
    @Test func anotherSettingSavedOnProductionKeepsTheStoredAutoRun() async throws {
        try await withProfile { profileID in
            let saves = SavedSettings()
            let controller = try makeController(saved: Self.enabledWithAutoRun, saves: saves)
            controller.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)
            #expect(!controller.autoApproveSelects)

            controller.allowSampleRows = true

            #expect(saves.value?.allowSampleRows == true)
            #expect(saves.value?.autoApproveSelects == true)
        }
    }

    /// The same holds for a production connection with nothing stored yet,
    /// whose first save is the consent.
    @Test func consentOnANewProductionConnectionStoresNoAutoRunChoice() async throws {
        try await withProfile { profileID in
            let saves = SavedSettings()
            let controller = try makeController(saved: nil, saves: saves)
            controller.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)

            controller.giveConsentAndEnable()

            #expect(saves.value?.consentGiven == true)
            #expect(saves.value?.autoApproveSelects == true)
            #expect(!controller.autoApproveSelects)
        }
    }

    /// Guard: what the toggle is set to is stored, and later saves of other
    /// settings keep it.
    @Test(arguments: [true, false])
    func theToggleStoresItsValue(_ isProduction: Bool) async throws {
        try await withProfile { profileID in
            let saves = SavedSettings()
            let controller = try makeController(saved: Self.enabledWithAutoRun, saves: saves)
            controller.bind(
                session: try await makeSQLiteSession(isProduction: isProduction), catalog: nil, objects: [], profileID: profileID
            )

            controller.autoApproveSelects = true
            #expect(saves.value?.autoApproveSelects == true)
            controller.autoApproveSelects = false
            #expect(saves.value?.autoApproveSelects == false)
            controller.allowSampleRows = true
            #expect(saves.value?.autoApproveSelects == false)
        }
    }

    // MARK: AI on or off by default

    private func makeDataSourceSession(_ kind: DataSourceKind, isProduction: Bool) -> DataSourceSession {
        DataSourceSession(
            profileID: nil, isProduction: isProduction, connection: IdleConnection(), kind: kind,
            capabilities: DataSourceCapabilities(write: true), driverDisplayName: kind.rawValue, displayName: "test"
        )
    }

    /// A licensed controller with nothing stored for the connection.
    private func makeLicensedController() throws -> AIPanelController {
        let controller = try makeController(saved: nil)
        controller.licenseStatus = { .trial(daysLeft: 5) }
        return controller
    }

    /// A connection labeled production starts with AI off and says why,
    /// whatever its engine.
    @Test(arguments: [DataSourceKind.document, .search, .vector])
    func productionDocumentSearchOrVectorConnectionStartsWithAIOff(_ kind: DataSourceKind) async throws {
        try await withProfile { profileID in
            let controller = try makeLicensedController()

            controller.bind(
                session: nil, dataSourceSession: makeDataSourceSession(kind, isProduction: true),
                catalog: nil, objects: [], profileID: profileID
            )

            #expect(controller.isProduction)
            #expect(!controller.enabledForConnection)
            #expect(controller.availability == .disabledForConnection)
        }
    }

    @Test func productionSQLConnectionStartsWithAIOff() async throws {
        try await withProfile { profileID in
            let controller = try makeLicensedController()

            controller.bind(session: try await makeSQLiteSession(isProduction: true), catalog: nil, objects: [], profileID: profileID)

            #expect(controller.isProduction)
            #expect(!controller.enabledForConnection)
        }
    }

    /// Guard: every other connection still starts with AI on.
    @Test(arguments: [DataSourceKind.document, .search, .vector])
    func otherDocumentSearchOrVectorConnectionStartsWithAIOn(_ kind: DataSourceKind) async throws {
        try await withProfile { profileID in
            let controller = try makeLicensedController()

            controller.bind(
                session: nil, dataSourceSession: makeDataSourceSession(kind, isProduction: false),
                catalog: nil, objects: [], profileID: profileID
            )

            #expect(!controller.isProduction)
            #expect(controller.enabledForConnection)
            #expect(controller.availability == .needsConsent)
        }
    }

    @Test func otherSQLConnectionStartsWithAIOn() async throws {
        try await withProfile { profileID in
            let controller = try makeLicensedController()

            controller.bind(session: try await makeSQLiteSession(isProduction: false), catalog: nil, objects: [], profileID: profileID)

            #expect(!controller.isProduction)
            #expect(controller.enabledForConnection)
        }
    }
}
