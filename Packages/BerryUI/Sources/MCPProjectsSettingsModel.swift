import BerryCredentials
import BerryMCP
import BerryStore
import Combine
import CryptoKit
import Foundation

/// What linking one chosen folder did. Each case carries the path of that
/// folder's link file, `<folder>/.berrydb.json`.
public enum MCPRepositoryLinkResult: Equatable, Sendable {
    /// The file now holds the link naming the project.
    case written(String)
    /// The file already selects the project, by the name rule the helper
    /// applies, and was not rewritten.
    case unchanged(String)
    /// Something else is there and was left as it is; linking again with
    /// `overwrite` replaces it. `existingProject` is the name a regular file
    /// of the user's holds; nil when that file names none or cannot be
    /// parsed, and for a symbolic link or a file another user owns, neither
    /// of which is read.
    case needsOverwrite(String, existingProject: String?)
    /// Nothing was written, for the ready-to-show `reason`.
    case rejected(String, reason: String)
}

/// Whether the settings pane can offer setup commands for the `berrydb-mcp`
/// helper, which the commands launch by absolute path.
public enum MCPHelperLocation: Equatable, Sendable {
    /// The helper inside an app on a writable volume, at a path that stays
    /// valid while the app is not moved.
    case bundled(URL)
    /// This build ships no helper.
    case notBundled
    /// The app runs from a read-only volume, where the helper's path does not
    /// last: a mounted disk image's path is gone once it is ejected, and
    /// Gatekeeper runs an app downloaded outside the Mac App Store from "a
    /// randomized read-only location" until the user moves it, usually to
    /// /Applications
    /// (https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/providertranslocated).
    case onReadOnlyVolume
}

/// Creates, edits and deletes the MCP projects that coding agents reach
/// through the `berrydb-mcp` helper, and links repositories to them.
///
/// Every save and delete rotates the access key in one fixed order: read
/// the stored key (abort if the Keychain refuses), build the value from the
/// store's verified editing copy, store a new key, then write rows sealed
/// under the new key with the old one as the re-seal source. Any failure
/// stops at that step and sets `errorMessage`. A saved value is never built
/// from unverified rows, so a `liveRead` written into the store file by
/// another process is never signed by a settings save; this model exposes
/// no way to turn `liveRead` on.
@MainActor
public final class MCPProjectsSettingsModel: ObservableObject {
    /// The editable part of a project. Holds no `liveRead` or redaction
    /// settings: those are carried over from the verified editing copy when
    /// the draft is saved.
    public struct Draft: Equatable {
        public var id: UUID
        public var name: String
        public var isEnabled: Bool
        public var workspaceRoots: [String]
        /// Assigned connection profiles, in the order they were added.
        public var profileIDs: [UUID]
    }

    @Published public private(set) var projects: [MCPProject] = []
    @Published public private(set) var profiles: [ConnectionProfile] = []
    /// Projects whose own integrity tag does not verify under the stored
    /// key, or every project when no key can be read. The helper still
    /// selects such a project by its stored enabled flag and serves its
    /// schema and graph metadata, which the store file exposes anyway, with
    /// live reads off and integrity reported as unavailable. Its editing
    /// copy comes back disabled, so saving re-seals it enabled only when
    /// the user turns it on again. The list marks these projects rather
    /// than showing the stored enabled flag unqualified.
    @Published public private(set) var unverifiedProjectIDs: Set<UUID> = []
    /// The last failure of a load, save or delete, ready to show; cleared
    /// by the next `reload()`, which every successful save or delete runs.
    @Published public var errorMessage: String?

    private let store: BerryStore
    private let keyStore: MCPAccessKeyStore
    private let helperLocation: MCPHelperLocation
    private var helperURL: URL? {
        guard case let .bundled(url) = helperLocation else { return nil }
        return url
    }
    /// Writes one link file. The app uses `atomicLinkWrite`, which replaces
    /// the file in one step. Tests replace it to refuse every write their
    /// case must not make, so a regression in the checks before it fails the
    /// test instead of writing outside its temporary folders, at the disk
    /// root for one.
    var linkWriter: (Data, URL) throws -> Void = MCPProjectsSettingsModel.atomicLinkWrite

    /// `keyStore` defaults to the Keychain item the helper reads; the
    /// helper is looked up once, inside the running app's bundle.
    public convenience init(store: BerryStore, keyStore: MCPAccessKeyStore = .keychain) {
        let location = Self.helperLocation(in: Bundle.main.bundleURL, isOnReadOnlyVolume: Self.isOnReadOnlyVolume)
        self.init(store: store, keyStore: keyStore, helperLocation: location)
    }

    /// A model whose helper is at `helperURL`, or that has none when it is nil.
    convenience init(store: BerryStore, keyStore: MCPAccessKeyStore, helperURL: URL?) {
        self.init(
            store: store, keyStore: keyStore,
            helperLocation: helperURL.map(MCPHelperLocation.bundled) ?? .notBundled
        )
    }

    init(store: BerryStore, keyStore: MCPAccessKeyStore, helperLocation: MCPHelperLocation) {
        self.store = store
        self.keyStore = keyStore
        self.helperLocation = helperLocation
        reload()
    }

    /// Why the pane offers no setup commands, ready to show; nil when
    /// `configurationSnippets` has commands to offer.
    public var agentSetupUnavailableReason: String? {
        switch helperLocation {
        case .bundled:
            nil
        case .notBundled:
            L("The berrydb-mcp helper is not bundled in this build.")
        case .onReadOnlyVolume:
            L("Move BerryDB to the Applications folder and open it from there to set up agents.")
        }
    }

    /// Where `bundleURL` keeps the helper, and whether setup commands may
    /// embed that path. A missing helper is reported as such whatever the
    /// volume, since moving the app would not help.
    nonisolated static func helperLocation(
        in bundleURL: URL, isOnReadOnlyVolume: (URL) -> Bool
    ) -> MCPHelperLocation {
        guard let helper = bundledHelperURL(in: bundleURL) else { return .notBundled }
        return isOnReadOnlyVolume(bundleURL) ? .onReadOnlyVolume : .bundled(helper)
    }

    /// True when the volume holding `url` is mounted read-only. A volume
    /// whose state cannot be read counts as writable, which keeps the setup
    /// commands available.
    nonisolated static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    /// Re-reads projects, their verification state and connection profiles,
    /// reading the key once for all projects.
    public func reload() {
        errorMessage = nil
        do {
            let stored = try store.mcpProjects()
            let key = keyStore.load()
            let unverified = try stored.filter {
                try store.verifiedMCPProject(id: $0.id, key: key)?.projectTagValid == false
            }
            projects = stored
            unverifiedProjectIDs = Set(unverified.map(\.id))
            profiles = try store.allProfiles()
        } catch {
            errorMessage = L("MCP projects could not be loaded: \(error.localizedDescription)")
        }
    }

    /// An unsaved project; disabled until the user turns it on, like every
    /// project the store creates.
    public func draftForNewProject() -> Draft {
        Draft(id: UUID(), name: "", isEnabled: false, workspaceRoots: [], profileIDs: [])
    }

    /// The draft of a stored project, built from the verified editing copy:
    /// a project whose own tag does not verify under the stored key comes
    /// back disabled.
    public func draft(for id: UUID) -> Draft? {
        do {
            guard let project = try store.mcpProjectForEditing(id: id, key: keyStore.load()) else { return nil }
            return Draft(
                id: project.id,
                name: project.name,
                isEnabled: project.isEnabled,
                workspaceRoots: project.workspaceRoots,
                profileIDs: project.profiles.map(\.profileID)
            )
        } catch {
            errorMessage = L("MCP projects could not be loaded: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves `draft` under a newly rotated key. Returns false with
    /// `errorMessage` set when a root is invalid or is also a root of
    /// another project, another project already uses the name, the key
    /// cannot be read or written, or the store refuses the write. Roots and
    /// the name are checked before the key is read, so an invalid draft
    /// changes nothing.
    ///
    /// A connection deleted since the draft was made is dropped from it
    /// before the key is read, since deleting a connection removes its
    /// access. Kept, it would fail the store's foreign key only after the
    /// new key is stored, leaving every project sealed under a key that is
    /// gone.
    public func save(_ draft: Draft) -> Bool {
        if let invalidRoot = draft.workspaceRoots.lazy.compactMap(Self.validateRoot).first {
            return fail(invalidRoot)
        }
        let others: [MCPProject]
        let savedProfileIDs: Set<UUID>
        do {
            others = try store.mcpProjects().filter { $0.id != draft.id }
            savedProfileIDs = Set(try store.allProfiles().map(\.id))
        } catch {
            return fail(L("The MCP project could not be saved: \(error.localizedDescription)"))
        }
        // A link file names a project, and the helper selects every project
        // whose name that link matches; two such projects would make every
        // link to either one ambiguous.
        let nameTaken = others.contains {
            MCPRepositoryLink.matches(projectName: $0.name, linkedName: draft.name)
        }
        if nameTaken {
            return fail(L("Another project already uses this name. Repository links select projects by name."))
        }
        // Two projects with the same root tie for every workspace inside it,
        // and the helper serves neither of them there. Nested roots stay
        // allowed, since the longer one wins.
        let otherRoots = Set(others.flatMap(\.workspaceRoots).map(Self.storedRoot))
        if let sharedRoot = draft.workspaceRoots.first(where: { otherRoots.contains(Self.storedRoot($0)) }) {
            return fail(L("Another project already uses the workspace folder \(sharedRoot). Agents working there would get neither project."))
        }
        var draft = draft
        draft.profileIDs.removeAll { !savedProfileIDs.contains($0) }
        let previousKey: SymmetricKey?
        do {
            previousKey = try keyStore.loadForRotation()
        } catch {
            return fail(Self.keyReadFailure)
        }
        let project: MCPProject
        do {
            project = try editedProject(from: draft, previousKey: previousKey)
        } catch {
            return fail(L("The MCP project could not be saved: \(error.localizedDescription)"))
        }
        let sealingKey = SymmetricKey(size: .bits256)
        do {
            try keyStore.replace(with: sealingKey)
        } catch {
            return fail(Self.keyWriteFailure)
        }
        do {
            try store.saveMCPProject(project, sealingKey: sealingKey, previousKey: previousKey)
        } catch {
            return fail(L("The MCP project could not be saved: \(error.localizedDescription)"))
        }
        reload()
        return true
    }

    /// Deletes a project under a newly rotated key, so a copy of its rows
    /// restored into the store file no longer verifies. Same failure rules
    /// as `save`.
    public func delete(id: UUID) -> Bool {
        let previousKey: SymmetricKey?
        do {
            previousKey = try keyStore.loadForRotation()
        } catch {
            return fail(Self.keyReadFailure)
        }
        let sealingKey = SymmetricKey(size: .bits256)
        do {
            try keyStore.replace(with: sealingKey)
        } catch {
            return fail(Self.keyWriteFailure)
        }
        do {
            try store.deleteMCPProject(id: id, sealingKey: sealingKey, previousKey: previousKey)
        } catch {
            return fail(L("The MCP project could not be deleted: \(error.localizedDescription)"))
        }
        reload()
        return true
    }

    /// True when `projectID` is a stored project as of the last `reload()`;
    /// only such a project gets pinned host entries.
    public func isSaved(_ projectID: UUID) -> Bool {
        projects.contains { $0.id == projectID }
    }

    /// Nil when repositories can be linked to the project `draft` edits;
    /// otherwise the reason to show. Linking writes the saved name, so it is
    /// offered only for a saved project whose name field still holds that
    /// name once trimmed, as saving would store it: a link written while a
    /// rename is pending would name a project the editor no longer shows.
    public func repositoryLinkUnavailableReason(for draft: Draft) -> String? {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard projects.contains(where: { $0.id == draft.id && $0.name == name }) else {
            return Self.saveBeforeLinking
        }
        return nil
    }

    /// A notice to show under the name field, or nil. Link files name a
    /// project, and the helper decides a workspace with a link file by that
    /// file alone, so renaming a saved project leaves every repository
    /// linked to the old name selecting nothing. A change of letter case or
    /// surrounding whitespace still matches the old name by the link rule
    /// and gets no notice, and neither does a cleared field, which cannot be
    /// saved.
    public func renameLinkNotice(for draft: Draft) -> String? {
        guard let saved = projects.first(where: { $0.id == draft.id }),
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !MCPRepositoryLink.matches(projectName: saved.name, linkedName: draft.name)
        else { return nil }
        return L("Repositories linked to “\(saved.name)” stop selecting this project until they are linked again.")
    }

    /// Links each folder of `folders` to the saved project `projectID` by
    /// writing `MCPRepositoryLink.contents(projectName:)` for its saved name
    /// to `.berrydb.json` at the folder's top, and returns one result per
    /// folder in the same order.
    ///
    /// Nothing else is written: no other file, no git configuration and no
    /// `.gitignore`. A project not saved as of the last `reload()` links
    /// nothing. A regular file of the user's that already selects the
    /// project is left untouched, whatever its formatting, extra keys or
    /// capitalization. A symbolic link is never followed and a file another
    /// user owns is never read, even when either names the project; like
    /// any other entry of that name, they are replaced only when `overwrite`
    /// is true. Replacing writes a regular file and leaves a link's target
    /// untouched. A folder of that name is never replaced. The disk's root
    /// and anything that is not a folder are rejected.
    public func linkRepositories(_ folders: [URL], projectID: UUID, overwrite: Bool) -> [MCPRepositoryLinkResult] {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return folders.map { .rejected(Self.linkFilePath(in: $0), reason: Self.saveBeforeLinking) }
        }
        return folders.map { Self.link($0, projectName: project.name, overwrite: overwrite, write: linkWriter) }
    }

    /// A localized reason `path` cannot be a workspace root, or nil. A root
    /// must be absolute and must not canonicalize to `/`, which would select
    /// the project for every directory on the disk. Nested roots and the
    /// home directory are allowed; the helper prefers the longest root.
    nonisolated public static func validateRoot(_ path: String) -> String? {
        // `NSString.isAbsolutePath` is also true for `~/…` (checked with
        // Foundation on macOS 26.6), whose expansion depends on the caller;
        // a root must name the same directory for the app and the helper.
        guard path.hasPrefix("/") else { return L("A workspace root must be an absolute path.") }
        guard canonicalRoot(path) != "/" else { return L("A workspace root cannot be the whole disk.") }
        return nil
    }

    /// What the connection checklist shows for a profile besides its name.
    /// It tells apart two profiles with the same name when their driver,
    /// group or production label differs; profiles alike in all of these
    /// still look the same.
    public struct ConnectionRowDetail: Equatable {
        /// The driver ID, then the group name when the profile has one.
        public var text: String
        /// True for the profiles the sidebar marks with its production badge.
        public var isProduction: Bool
    }

    /// The checklist detail for `profile`: its driver and group name joined
    /// by " · ", and whether it carries the production label. A blank group
    /// name counts as none, and only the exact `production` label is flagged,
    /// the same test the sidebar applies.
    nonisolated public static func connectionRowDetail(for profile: ConnectionProfile) -> ConnectionRowDetail {
        let group = profile.groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ConnectionRowDetail(
            text: group.isEmpty ? profile.driverID : "\(profile.driverID) · \(group)",
            isProduction: profile.envColor == "production"
        )
    }

    /// The outcome of adding folders chosen in the open panel to a draft.
    public struct RootAddition: Equatable {
        /// The draft's roots after the addition.
        public var roots: [String]
        /// One ready-to-show line per rejected folder.
        public var rejections: [String]
    }

    /// Adds every valid folder of `paths` to `existing`, in selection order,
    /// in the canonical form `canonicalRoot` produces. A rejected folder never
    /// blocks the others: it is reported on its own line, naming the folder
    /// and the `validateRoot` reason. A folder already present, or repeated
    /// in `paths`, is added once.
    nonisolated public static func addingRoots(_ paths: [String], to existing: [String]) -> RootAddition {
        var roots = existing
        var rejections: [String] = []
        for path in paths {
            if let message = validateRoot(path) {
                rejections.append("\(path): \(message)")
                continue
            }
            let root = canonicalRoot(path)
            if !roots.contains(root) {
                roots.append(root)
            }
        }
        return RootAddition(roots: roots, rejections: rejections)
    }

    /// True when `path` is the user's home directory itself, a root the view
    /// accepts but warns about because every repository under it matches.
    nonisolated public static func isHomeDirectory(_ path: String) -> Bool {
        canonicalRoot(path) == canonicalRoot(NSHomeDirectory())
    }

    /// The form a root is saved in: symbolic links resolved by the function
    /// the helper applies to roots and workspaces before matching them. The
    /// store standardizes it again on write, which can drop a leading
    /// `/private`; matching is unaffected because the helper re-resolves it.
    nonisolated public static func canonicalRoot(_ path: String) -> String {
        MCPProjectSelector.canonicalPath(path)
    }

    /// `path` in the form the store keeps a saved root: `canonicalRoot`, then
    /// the store's own standardization. Applied to both sides of a
    /// comparison, two spellings of one folder, through a symbolic link, a
    /// trailing slash or a leading `/private`, compare equal.
    nonisolated private static func storedRoot(_ path: String) -> String {
        URL(fileURLWithPath: canonicalRoot(path)).standardizedFileURL.path
    }

    /// The helper inside `bundleURL`, or nil when this build does not ship it.
    nonisolated static func bundledHelperURL(in bundleURL: URL) -> URL? {
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/berrydb-mcp")
        return FileManager.default.fileExists(atPath: helper.path) ? helper : nil
    }

    /// Host commands that register the bundled helper; empty whenever
    /// `agentSetupUnavailableReason` gives a reason. Each command writes one
    /// entry to the host's user-level
    /// configuration, so the shared entry serves every repository and the
    /// helper selects the project from the host's workspace. Claude Code
    /// needs `--scope user` for that, since its default scope is the current
    /// directory only. Checked against throwaway home directories with
    /// Claude Code 2.1.294 (`~/.claude.json` user `mcpServers`), codex-cli
    /// 0.157.1 (`config.toml`, "Added global MCP server") and agy 1.3.1
    /// (`~/.gemini/config/mcp_config.json`).
    ///
    /// A saved `project` also gets one pinned entry per host, which passes
    /// `--project` and serves that project from any folder. It is installed
    /// at the same user level as the shared entry, so its label says it
    /// always serves the project rather than suggesting a narrower scope.
    /// An unsaved project gets none, since its ID means nothing to the
    /// helper yet. The `--` before the helper keeps `--project` an argument
    /// of the helper: `agy mcp add --help` (1.3.1) requires `--` before
    /// arguments that begin with `-`. The helper path is double-quoted for a
    /// POSIX shell so an install path with spaces stays one argument.
    public func configurationSnippets(project: UUID) -> [(host: String, text: String)] {
        guard let helperURL else { return [] }
        let helper = Self.shellQuoted(helperURL.path)
        let commands = [
            (host: "Claude Code", text: "claude mcp add --scope user berrydb -- \(helper)"),
            (host: "Codex", text: "codex mcp add berrydb -- \(helper)"),
            (host: "Antigravity", text: "agy mcp add berrydb -- \(helper)"),
        ]
        guard isSaved(project) else { return commands }
        let pinned = " --project \(project.uuidString.lowercased())"
        return commands + commands.map { (host: L("\($0.host), always this project"), text: $0.text + pinned) }
    }

    private static let keyReadFailure = L(
        "BerryDB could not read its MCP access key from the Keychain. Nothing was changed."
    )
    private static let keyWriteFailure = L(
        "BerryDB could not update its MCP access key in the Keychain. Nothing was changed."
    )
    private static let saveBeforeLinking = L("Save the project before linking repositories.")

    /// A warning to show under a result that left a link file in the home
    /// directory itself, or nil. The helper takes the nearest link file at or
    /// above a workspace before it looks at registered workspace folders, so
    /// a link at home selects this project for every folder inside it that
    /// has no nearer link, including other projects' workspace folders.
    /// Linking there stays allowed, as a home workspace folder does.
    nonisolated public static func homeFolderLinkWarning(for result: MCPRepositoryLinkResult) -> String? {
        let path: String
        switch result {
        case let .written(file), let .unchanged(file):
            path = file
        case .needsOverwrite, .rejected:
            return nil
        }
        guard isHomeDirectory((path as NSString).deletingLastPathComponent) else { return nil }
        return L("This links your home folder: every folder inside it without a nearer .berrydb.json selects this project, even another project’s workspace folder.")
    }

    nonisolated static func atomicLinkWrite(_ contents: Data, to file: URL) throws {
        try contents.write(to: file, options: .atomic)
    }

    nonisolated private static func linkFilePath(in folder: URL) -> String {
        folder.appendingPathComponent(MCPRepositoryLink.fileName).path
    }

    /// Links `folder` to the project called `projectName`, following the
    /// rules `linkRepositories` states.
    ///
    /// The existing entry is read with the helper's own bounded reader, so a
    /// folder counts as linked exactly when the helper would select the
    /// project from it. A regular file of the user's that selects the
    /// project by the helper's name rule, not only one whose bytes match, is
    /// left untouched: repositories that reformat JSON on commit would
    /// otherwise be offered a replacement on every clone, and replacing would
    /// drop extra keys. Every other entry is replaced only with `overwrite`:
    /// - a file naming another project or none, reported with that name;
    /// - a symbolic link, which the reader never follows, so the name its
    ///   target holds is neither read nor reported;
    /// - a file another user owns, which the reader ignores as if absent;
    ///   it is still never replaced without confirmation, and its name is
    ///   not reported.
    /// The reader never blocks on a FIFO.
    ///
    /// The root is refused because the helper never reads a link file there.
    /// An atomic write writes an auxiliary file and then replaces the entry
    /// with it
    /// (https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic).
    /// Observed with Foundation on macOS 26.6: a symbolic link is replaced by
    /// the new file and its target is left as it was, and a folder of that
    /// name makes the write fail. A folder is therefore reported as in the
    /// way rather than offered for replacement.
    ///
    /// - Parameter owner: The user whose link files are trusted; the current
    ///   user unless replaced.
    nonisolated static func link(
        _ folder: URL, projectName: String, overwrite: Bool, write: (Data, URL) throws -> Void,
        owner: uid_t = getuid()
    ) -> MCPRepositoryLinkResult {
        let contents = MCPRepositoryLink.contents(projectName: projectName)
        let file = folder.appendingPathComponent(MCPRepositoryLink.fileName)
        let path = file.path
        guard canonicalRoot(folder.path) != "/" else {
            return .rejected(path, reason: L("The whole disk cannot be linked to a project."))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .rejected(path, reason: L("Only a folder can be linked to a project."))
        }
        let existing = MCPRepositoryLink.readBounded(path, owner: owner)
        let existingProject = existing.flatMap(MCPRepositoryLink.projectName(in:))
        if let existing {
            let selectsProject = existingProject.map {
                MCPRepositoryLink.matches(projectName: projectName, linkedName: $0)
            } == true
            if existing == contents || selectsProject {
                return .unchanged(path)
            }
        }
        var entry = stat()
        if lstat(path, &entry) == 0 {
            if entry.st_mode & S_IFMT == S_IFDIR {
                return .rejected(path, reason: L("A folder named .berrydb.json is in the way."))
            }
            if !overwrite {
                return .needsOverwrite(path, existingProject: existingProject)
            }
        }
        do {
            try write(contents, file)
        } catch {
            return .rejected(path, reason: L("The link file could not be written: \(error.localizedDescription)"))
        }
        return .written(path)
    }

    /// The value to seal: the verified editing copy of a stored project, or
    /// a new project, with the draft applied. A profile kept from the stored
    /// project keeps its verified access settings; a newly added one starts
    /// with every access switch off.
    private func editedProject(from draft: Draft, previousKey: SymmetricKey?) throws -> MCPProject {
        var project = try store.mcpProjectForEditing(id: draft.id, key: previousKey)
            ?? MCPProject(id: draft.id, name: draft.name)
        let kept = Dictionary(project.profiles.map { ($0.profileID, $0) }, uniquingKeysWith: { first, _ in first })
        project.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.isEnabled = draft.isEnabled
        project.workspaceRoots = draft.workspaceRoots.map(Self.canonicalRoot)
        project.profiles = draft.profileIDs.map { kept[$0] ?? MCPProfileAccess(profileID: $0) }
        project.updatedAt = Date()
        return project
    }

    private func fail(_ message: String) -> Bool {
        errorMessage = message
        return false
    }

    /// Wraps `value` in double quotes, escaping the four characters a POSIX
    /// shell still interprets inside them (`"`, `\`, `$`, backtick), per
    /// https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_02_03.
    /// Interactive history expansion of `!` in bash and zsh is outside POSIX
    /// and not escaped; an app bundle path containing `!` would need editing.
    private static func shellQuoted(_ value: String) -> String {
        var quoted = "\""
        for character in value {
            if "\"\\$`".contains(character) {
                quoted.append("\\")
            }
            quoted.append(character)
        }
        quoted.append("\"")
        return quoted
    }
}
