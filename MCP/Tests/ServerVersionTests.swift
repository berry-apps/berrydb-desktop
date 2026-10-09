import BerryDBMCP
import Foundation
import Testing

/// The version the helper reports to hosts. A packaged helper sits in
/// `Contents/Helpers`, where it has no `Info.plist` of its own, so it reads
/// the version of the app around it. Every layout here is a throwaway
/// directory; no real app bundle is read.
struct ServerVersionTests {
    /// A temporary directory removed when the test ends.
    private final class Sandbox {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("berrydb-server-version-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Creates `<name>.app/Contents/<folder>/berrydb-mcp`, with
        /// `Contents/Info.plist` holding `plist` when it is not nil, and
        /// returns the executable's URL.
        func app(
            _ name: String = "BerryDB", folder: String = "Helpers", plist: [String: Any]?
        ) throws -> URL {
            let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            let directory = contents.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let plist {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
            }
            let executable = directory.appendingPathComponent("berrydb-mcp")
            try Data().write(to: executable)
            return executable
        }
    }

    @Test
    func aHelperInsideAnAppReportsTheAppsVersion() throws {
        let sandbox = try Sandbox()
        let helper = try sandbox.app(plist: ["CFBundleShortVersionString": "1.2.3"])

        #expect(BerryDBMCPComposition.serverVersion(executableURL: helper, mainBundleVersion: nil) == "1.2.3")
    }

    @Test
    func aSymbolicLinkToThePackagedHelperReportsTheAppsVersion() throws {
        let sandbox = try Sandbox()
        let helper = try sandbox.app(plist: ["CFBundleShortVersionString": "1.2.3"])
        let link = sandbox.root.appendingPathComponent("bin/berrydb-mcp")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: helper)

        #expect(BerryDBMCPComposition.serverVersion(executableURL: link, mainBundleVersion: nil) == "1.2.3")
    }

    @Test
    func anAppWithoutAnInfoPlistFallsBackToDev() throws {
        let sandbox = try Sandbox()
        let helper = try sandbox.app(plist: nil)

        #expect(BerryDBMCPComposition.serverVersion(executableURL: helper, mainBundleVersion: nil) == "dev")
    }

    @Test
    func anInfoPlistWithoutAVersionFallsBackToDev() throws {
        let sandbox = try Sandbox()
        let helper = try sandbox.app(plist: ["CFBundleIdentifier": "dev.berrydb.app"])

        #expect(BerryDBMCPComposition.serverVersion(executableURL: helper, mainBundleVersion: nil) == "dev")
    }

    /// Only `Contents/Helpers` borrows the app's version. Elsewhere, such as
    /// `.build/debug` or an unrelated folder beside an `Info.plist`, the
    /// executable's own main bundle decides, as it did before packaging.
    @Test
    func anExecutableOutsideContentsHelpersUsesItsMainBundleVersion() throws {
        let sandbox = try Sandbox()
        let tool = try sandbox.app(folder: "Tools", plist: ["CFBundleShortVersionString": "1.2.3"])

        #expect(BerryDBMCPComposition.serverVersion(executableURL: tool, mainBundleVersion: nil) == "dev")
        #expect(BerryDBMCPComposition.serverVersion(executableURL: tool, mainBundleVersion: "4.5.6") == "4.5.6")
        #expect(BerryDBMCPComposition.serverVersion(executableURL: nil, mainBundleVersion: nil) == "dev")
    }

    /// The `Helpers` folder must sit in an app's `Contents`, so a helper
    /// copied into some other `Contents/Helpers` folder borrows no version.
    @Test
    func aHelpersFolderOutsideAnAppBundleIsIgnored() throws {
        let sandbox = try Sandbox()
        let contents = sandbox.root.appendingPathComponent("NotAnApp/Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("Helpers", isDirectory: true), withIntermediateDirectories: true
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.2.3"], format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let helper = contents.appendingPathComponent("Helpers/berrydb-mcp")
        try Data().write(to: helper)

        #expect(BerryDBMCPComposition.serverVersion(executableURL: helper, mainBundleVersion: nil) == "dev")
    }
}
