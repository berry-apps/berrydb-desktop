import Foundation
import Testing

@testable import BerryCredentials
@testable import BerryStore
@testable import BerryUI

/// Agent setup commands embed the helper's absolute path, so the settings
/// pane offers them only for a helper whose path outlives the current launch.
/// The volume check is injected: these tests never mount, eject or inspect a
/// read-only volume, and they run against an in-memory store and key.
@MainActor
@Suite("MCP helper location")
struct MCPHelperLocationTests {
    /// A throwaway `.app` folder, with the helper inside it when asked for.
    private func makeBundle(withHelper: Bool) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-helper-location-\(UUID().uuidString).app", isDirectory: true)
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        if withHelper {
            try Data().write(to: helpers.appendingPathComponent("berrydb-mcp"))
        }
        return bundle
    }

    private func makeModel(_ location: MCPHelperLocation) throws -> MCPProjectsSettingsModel {
        let keyStore = MCPAccessKeyStore(read: { nil }, write: { _ in false })
        return MCPProjectsSettingsModel(store: try BerryStore(path: ":memory:"), keyStore: keyStore, helperLocation: location)
    }

    @Test func aHelperOnAWritableVolumeIsOffered() throws {
        let bundle = try makeBundle(withHelper: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let location = MCPProjectsSettingsModel.helperLocation(in: bundle, isOnReadOnlyVolume: { _ in false })

        #expect(location == .bundled(bundle.appendingPathComponent("Contents/Helpers/berrydb-mcp")))
    }

    @Test func aHelperOnAReadOnlyVolumeIsNotOffered() throws {
        let bundle = try makeBundle(withHelper: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        var checked: [URL] = []

        let location = MCPProjectsSettingsModel.helperLocation(in: bundle) { url in
            checked.append(url)
            return true
        }

        #expect(location == .onReadOnlyVolume)
        #expect(checked == [bundle])
    }

    @Test func aMissingHelperIsReportedAsNotBundledWhateverTheVolume() throws {
        let bundle = try makeBundle(withHelper: false)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(MCPProjectsSettingsModel.helperLocation(in: bundle, isOnReadOnlyVolume: { _ in true }) == .notBundled)
        #expect(MCPProjectsSettingsModel.helperLocation(in: bundle, isOnReadOnlyVolume: { _ in false }) == .notBundled)
    }

    /// The real check must not report every volume as read-only, which would
    /// hide the commands in every installed copy. The temporary directory is
    /// on the writable boot volume whenever the test suite can run at all.
    @Test func theTemporaryDirectoryIsNotOnAReadOnlyVolume() {
        #expect(!MCPProjectsSettingsModel.isOnReadOnlyVolume(FileManager.default.temporaryDirectory))
    }

    @Test func aReadOnlyVolumeOffersNoCommandsAndAsksToMoveTheApp() throws {
        let model = try makeModel(.onReadOnlyVolume)

        #expect(model.configurationSnippets(project: UUID()).isEmpty)
        #expect(model.agentSetupUnavailableReason
            == L("Move BerryDB to the Applications folder and open it from there to set up agents."))
    }

    @Test func aBuildWithoutTheHelperSaysSo() throws {
        let model = try makeModel(.notBundled)

        #expect(model.configurationSnippets(project: UUID()).isEmpty)
        #expect(model.agentSetupUnavailableReason == L("The berrydb-mcp helper is not bundled in this build."))
    }

    @Test func aBundledHelperOffersCommandsAndNoReason() throws {
        let helper = URL(fileURLWithPath: "/Applications/BerryDB.app/Contents/Helpers/berrydb-mcp")
        let model = try makeModel(.bundled(helper))

        #expect(!model.configurationSnippets(project: UUID()).isEmpty)
        #expect(model.agentSetupUnavailableReason == nil)
    }
}
