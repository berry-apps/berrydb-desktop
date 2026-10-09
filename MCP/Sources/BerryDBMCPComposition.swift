import BerryCredentials
import BerryDriverBootstrap
import BerryMCP
import BerryMCPServer
import BerryStore
import Foundation
import GRDB

/// Process composition root for the BerryDB MCP helper.
///
/// Registers exactly the same built-in drivers as the desktop app, and wires
/// the protocol server to the app's store opened read-only. Nothing composed
/// here connects to a user's database or reads connection credentials; the
/// only Keychain item read is the integrity key, on every tool or resource
/// request once selection has chosen a project, whether or not that project
/// is enabled.
public enum BerryDBMCPComposition {
    @discardableResult
    public static func registerDrivers(
        using registrar: BerryDriverRegistrar = .live
    ) -> BerryDriverRegistration {
        BerryDriverBootstrap.registerAll(using: registrar)
    }

    /// `~/Library/Application Support/BerryDB/store.sqlite`, the file the app
    /// writes. Computed without creating the directory: the helper must never
    /// leave files behind on a machine where the app has not run.
    static func defaultStorePath() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BerryDB", isDirectory: true)
            .appendingPathComponent("store.sqlite")
            .path
    }

    /// The version reported to hosts: the short version string of
    /// `Bundle.main`, the bundle containing the current executable
    /// (https://developer.apple.com/documentation/foundation/bundle/main).
    /// Only an executable in an app's `Contents/MacOS` gets the app as its
    /// main bundle; one in `Contents/Helpers`, where the settings pane looks
    /// for the helper, gets that folder and no version (observed on macOS 26.6
    /// with a probe executable copied into both folders of one app), so
    /// packaging must embed an Info.plist or pass the version another way. A
    /// build run from `.build` has no Info.plist and reports "dev"; the stdio
    /// tests observe that value.
    static var serverVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Why the store could not be opened, in words that never include the
    /// store path or SQLite's own message text, so standard error stays free
    /// of local file names.
    static func openFailureReason(_ error: Error) -> String {
        switch error {
        case BerryStore.ReadOnlyOpenError.schemaMismatch:
            return "it was written by a different version of BerryDB"
        case let error as DatabaseError where error.resultCode == .SQLITE_CANTOPEN:
            return "the file does not exist or cannot be read"
        case let error as DatabaseError:
            return "SQLite error \(error.resultCode.rawValue)"
        default:
            return "unexpected error"
        }
    }

    /// The server's dependencies over `store`. The integrity key is loaded
    /// inside `verify`, which runs on every tool or resource request once
    /// selection has chosen a project, including while that project is
    /// disabled or after it was deleted, because the key is read before the
    /// project row. A key rotated in the app therefore applies to the next
    /// request, and a session whose selection chose no project never touches
    /// the Keychain.
    static func dependencies(
        store: BerryStore, explicitProject: UUID?, workingDirectory: String
    ) -> BerryMCPServerFactory.Dependencies {
        let metadata = MCPMetadataService(store: store)
        let resolver = MCPProjectContextResolver(
            loadProjects: { try store.mcpProjects() },
            verify: { try store.verifiedMCPProject(id: $0, key: MCPAccessKeyStore.keychain.load()) }
        )
        return BerryMCPServerFactory.Dependencies(
            resolver: resolver,
            metadata: metadata,
            explicitProject: explicitProject,
            workingDirectory: workingDirectory,
            version: serverVersion
        )
    }

    /// Writes one line to standard error. Standard output carries only
    /// JSON-RPC messages, so every diagnostic of the helper goes here.
    static func diagnose(_ message: String) {
        MCPSessionContext.standardError("berrydb-mcp: \(message)")
    }
}
