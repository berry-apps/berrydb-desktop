import Foundation
import Testing

/// No test may open the application's default store,
/// `~/Library/Application Support/BerryDB/store.sqlite`. Opening it runs the
/// migrator, so a test that reaches it applies the build's unreleased
/// migrations to the store of whoever runs the suite. Test runs did exactly
/// that through `WorkspaceViewModel`'s parameterless initializer and the
/// store `AIPanelController` opened for itself, and a store that applied a
/// migration a later build changes no longer matches that build.
///
/// The check reads source text only, so it runs in every `swift test`
/// without opening any store and without production code knowing about
/// tests. It has two halves:
/// - every production file that opens the default store is listed with the
///   calls a test reaches it through; a file that starts opening it fails
///   here until its entry points are listed;
/// - a test source that makes one of those calls fails here.
///
/// A production type that builds a `WorkspaceViewModel` without a store, or
/// an `AIPanelController` without one, as `WorkspaceView` does, has its own
/// construction banned in tests as well, found from the type declared before
/// that call in its file.
///
/// It sees only what it lists or derives: a test reaching the default store
/// through any other call passes it, and so does a spelling the patterns do
/// not cover.
@Suite("Default store isolation")
struct DefaultStoreIsolationTests {
    private struct Ban {
        /// Matched against a test file's text without its comment lines.
        let pattern: String
        /// Why the call reaches the default store.
        let reason: String
        /// For a call that is fine with a store argument: an occurrence whose
        /// argument list contains this label is allowed.
        var allowedWithLabel: String? = nil
    }

    /// A call, `Type(` or `Type.init(`, of the type named.
    private static func construction(of type: String) -> String {
        #"\b"# + type + #"\s*(?:\.\s*init\s*)?\("#
    }

    /// The constructions that build a view model or a panel controller on the
    /// default store, in tests and, to find the types that do so, in
    /// production code.
    private static let defaultStoreBuilders = [
        Ban(pattern: construction(of: "WorkspaceViewModel") + #"\s*\)"#, reason: "opens the default store; use init(storePath:)"),
        Ban(
            pattern: #":\s*WorkspaceViewModel[?!]?\s*=\s*\.init\s*\(\s*\)"#,
            reason: "opens the default store; use init(storePath:)"
        ),
        Ban(
            pattern: construction(of: "AIPanelController"),
            reason: "opens the default store unless it is given one; pass store:",
            allowedWithLabel: "store:"
        ),
    ]

    private static let bannedInTests = [
        Ban(pattern: #"BerryStore\s*\.\s*open\s*\("#, reason: "opens the default store"),
        Ban(pattern: #"defaultStoreURL\s*\("#, reason: "is the default store's path"),
        Ban(pattern: #"defaultStorePath\s*\("#, reason: "is the default store's path"),
        Ban(pattern: construction(of: "MCPProjectsSettingsView"), reason: "opens the default store when it appears"),
        Ban(pattern: construction(of: "ShortcutSettingsView"), reason: "its reset action deletes the default store"),
    ] + defaultStoreBuilders

    /// Production files that open or locate the default store, and nothing
    /// else does. Each one's entry points are in `bannedInTests`.
    private static let defaultStoreOpeners: Set<String> = [
        "Packages/BerryStore/Sources/BerryStore.swift",
        "Packages/BerryUI/Sources/WorkspaceViewModel.swift",
        "Packages/BerryUI/Sources/AIPanelController.swift",
        "Packages/BerryUI/Sources/MCPProjectsSettingsView.swift",
        "Packages/BerryUI/Sources/ShortcutSettings.swift",
        // The helper executable's top-level code; its tests always pass
        // --store-path, and `defaultStorePath(` is banned in tests.
        "MCP/Sources/main.swift",
        "MCP/Sources/BerryDBMCPComposition.swift",
    ]

    private static let openerPattern = #"BerryStore\s*\.\s*open\s*\(|defaultStoreURL\s*\(|defaultStorePath\s*\("#

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // BerryStore
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()

    @Test func noTestReachesTheDefaultStore() throws {
        let ownPath = URL(fileURLWithPath: #filePath).standardizedFileURL.path
        let bans = Self.bannedInTests + (try Self.typesBuildingOnTheDefaultStore()).map {
            Ban(pattern: Self.construction(of: $0), reason: "builds a view model or a panel controller on the default store")
        }
        var violations: [String] = []
        for file in try Self.swiftFiles(where: Self.isTestSource) where file.path != ownPath {
            let text = Self.withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            for ban in bans {
                for range in Self.violations(of: ban, in: text) {
                    violations.append("\(Self.relative(file)):\(Self.line(of: range.lowerBound, in: text)): \(ban.reason)")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    /// `WorkspaceView` builds its view model with `WorkspaceViewModel()`, so
    /// it must be among the types derived from production code.
    @Test func theTypesBuildingOnTheDefaultStoreAreFoundInProductionCode() throws {
        #expect(try Self.typesBuildingOnTheDefaultStore().contains("WorkspaceView"))
    }

    /// The type declared last before each production call in
    /// `defaultStoreBuilders`. A nested type declared between the outer type
    /// and the call would be taken instead; none is today.
    private static func typesBuildingOnTheDefaultStore() throws -> Set<String> {
        let declaration = #"(?m)^[ \t]*(?:(?:public|private|fileprivate|internal|open|final|nonisolated)[ \t]+)*(?:struct|class|actor|enum|extension)[ \t]+(\w+)"#
        guard let declarations = try? NSRegularExpression(pattern: declaration) else { return [] }
        var types: Set<String> = []
        for file in try swiftFiles(where: isProductionSource) {
            let text = withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            let declared = declarations.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).map { (start: $0.lowerBound, name: String(text[$0])) }
            }
            for ban in defaultStoreBuilders {
                for range in violations(of: ban, in: text) {
                    if let type = declared.last(where: { $0.start < range.lowerBound })?.name { types.insert(type) }
                }
            }
        }
        return types
    }

    /// The matches of `ban` in `text`, less those whose argument list has the
    /// label it allows.
    private static func violations(of ban: Ban, in text: String) -> [Range<String.Index>] {
        matches(of: ban.pattern, in: text).filter { range in
            guard let label = ban.allowedWithLabel else { return true }
            return argumentList(in: text, openingParenthesisBefore: range.upperBound)?.contains(label) != true
        }
    }

    @Test func everyProductionPathToTheDefaultStoreIsListed() throws {
        var openers: Set<String> = []
        for file in try Self.swiftFiles(where: Self.isProductionSource) {
            let text = Self.withoutCommentLines(try String(contentsOf: file, encoding: .utf8))
            if !Self.matches(of: Self.openerPattern, in: text).isEmpty { openers.insert(Self.relative(file)) }
        }
        #expect(
            openers == Self.defaultStoreOpeners,
            "a production file started or stopped opening the default store; list its entry points in bannedInTests"
        )
    }

    // MARK: - Source scanning

    private static func isTestSource(_ relativePath: String) -> Bool {
        relativePath.hasPrefix("Benchmarks/") || relativePath.contains("/Tests/") || relativePath.hasPrefix("Tests/")
    }

    private static func isProductionSource(_ relativePath: String) -> Bool {
        relativePath.contains("/Sources/") && !relativePath.contains("/Tests/")
    }

    private static func swiftFiles(where include: (String) -> Bool) throws -> [URL] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            let relative = String(path.dropFirst(rootPath.count + 1))
            // Build products and the static site hold no package sources.
            if relative == "webapp" || relative == "deploy" { enumerator.skipDescendants() }
            if url.pathExtension == "swift", include(relative) { files.append(url.standardizedFileURL) }
        }
        #expect(!files.isEmpty, "found no sources under \(rootPath)")
        return files
    }

    private static func relative(_ file: URL) -> String {
        String(file.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    /// Drops whole-line comments, which name these calls when they explain
    /// why a test avoids them. A call after code on the same line is kept.
    private static func withoutCommentLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }

    private static func matches(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("invalid pattern \(pattern)")
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// The text between the parenthesis that ends at `end` and the one that
    /// closes it, across lines.
    private static func argumentList(in text: String, openingParenthesisBefore end: String.Index) -> String? {
        var depth = 1
        var index = end
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return String(text[end..<index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func line(of index: String.Index, in text: String) -> Int {
        text[..<index].reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
    }
}
