import BerryCredentials
import BerryDriverBootstrap
import BerryGraph
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
/// only Keychain item read is the integrity key, and only once a project has
/// been selected.
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

    /// The version reported to hosts. Run from an app bundle's
    /// `Contents/MacOS`, `Bundle.main` is that app, the bundle containing the
    /// current executable
    /// (https://developer.apple.com/documentation/foundation/bundle/main),
    /// and its short version string is the release version. A build run from
    /// `.build` has no Info.plist and reports "dev" rather than a release
    /// number it does not have; the stdio tests observe that value.
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
    /// inside `verify`, which runs on every request that serves a selected
    /// project, so a key rotated in the app applies to the next request and
    /// a session that selects no project never touches the Keychain.
    static func dependencies(
        store: BerryStore, explicitProject: UUID?, workingDirectory: String
    ) -> BerryMCPServerFactory.Dependencies {
        let graphStore = GraphStore(store: store)
        let metadata = MCPMetadataService(
            profiles: { try store.allProfiles() },
            graph: BerryGraphQueryService(store: graphStore),
            harvestedAt: { try graphStore.snapshots(profileID: $0).map(\.takenAt).max() },
            loadGraph: { try graphStore.loadGraph(profileID: $0) }
        )
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
