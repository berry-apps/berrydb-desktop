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
    /// The file already held exactly that link and was not rewritten.
    case unchanged(String)
    /// Something else is there and was left as it is; linking again with
    /// `overwrite` replaces it. `existingProject` is the name it holds, or
    /// nil when it names no project.
    case needsOverwrite(String, existingProject: String?)
    /// Nothing was written, for the ready-to-show `reason`.
    case rejected(String, reason: String)
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
    private let helperURL: URL?

    /// `keyStore` defaults to the Keychain item the helper reads; the
    /// helper path is looked up once, inside the running app's bundle.
    public convenience init(store: BerryStore, keyStore: MCPAccessKeyStore = .keychain) {
        self.init(store: store, keyStore: keyStore, helperURL: Self.bundledHelperURL(in: Bundle.main.bundleURL))
    }

    init(store: BerryStore, keyStore: MCPAccessKeyStore, helperURL: URL?) {
        self.store = store
        self.keyStore = keyStore
        self.helperURL = helperURL
        reload()
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
    /// `errorMessage` set when a root is invalid, another project already
    /// uses the name, the key cannot be read or written, or the store
    /// refuses the write. Roots and the name are checked before the key is
    /// read, so an invalid draft changes nothing.
    public func save(_ draft: Draft) -> Bool {
        if let invalidRoot = draft.workspaceRoots.lazy.compactMap(Self.validateRoot).first {
            return fail(invalidRoot)
        }
        let stored: [MCPProject]
        do {
            stored = try store.mcpProjects()
        } catch {
            return fail(L("The MCP project could not be saved: \(error.localizedDescription)"))
        }
        // A link file names a project, and the helper selects every project
        // whose name that link matches; two such projects would make every
        // link to either one ambiguous.
        let nameTaken = stored.contains {
            $0.id != draft.id && MCPRepositoryLink.matches(projectName: $0.name, linkedName: draft.name)
        }
        if nameTaken {
            return fail(L("Another project already uses this name. Repository links select projects by name."))
        }
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

    /// Links each folder of `folders` to the saved project `projectID` by
    /// writing `MCPRepositoryLink.contents(projectName:)` for its saved name
    /// to `.berrydb.json` at the folder's top, and returns one result per
    /// folder in the same order.
    ///
    /// Nothing else is written: no other file, no git configuration and no
    /// `.gitignore`. A project not saved as of the last `reload()` links
    /// nothing. A file already holding exactly that link is left untouched,
    /// any other entry of that name is replaced only when `overwrite` is
    /// true, and a folder of that name never is. The disk's root and
    /// anything that is not a folder are rejected.
    public func linkRepositories(_ folders: [URL], projectID: UUID, overwrite: Bool) -> [MCPRepositoryLinkResult] {
        guard let project = projects.first(where: { $0.id == projectID }) else {
            return folders.map { .rejected(Self.linkFilePath(in: $0), reason: Self.saveBeforeLinking) }
        }
        let contents = MCPRepositoryLink.contents(projectName: project.name)
        return folders.map { Self.link($0, contents: contents, overwrite: overwrite) }
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
    /// Two profiles with the same name stay distinguishable by it.
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

    /// The helper inside `bundleURL`, or nil when this build does not ship it.
    nonisolated static func bundledHelperURL(in bundleURL: URL) -> URL? {
        let helper = bundleURL.appendingPathComponent("Contents/Helpers/berrydb-mcp")
        return FileManager.default.fileExists(atPath: helper.path) ? helper : nil
    }

    /// Host commands that register the bundled helper; empty when the helper
    /// is not bundled. Each command writes one entry to the host's user-level
    /// configuration, so the shared entry serves every repository and the
    /// helper selects the project from the host's workspace. Claude Code
    /// needs `--scope user` for that, since its default scope is the current
    /// directory only. Checked against throwaway home directories with
    /// Claude Code 2.1.294 (`~/.claude.json` user `mcpServers`), codex-cli
    /// 0.157.1 (`config.toml`, "Added global MCP server") and agy 1.3.1
    /// (`~/.gemini/config/mcp_config.json`).
    ///
    /// A saved `project` also gets one pinned entry per host, which passes
    /// `--project` and serves that project from any folder. An unsaved
    /// project gets none, since its ID means nothing to the helper yet. The
    /// `--` before the helper keeps `--project` an argument of the helper:
    /// `agy mcp add --help` (1.3.1) requires `--` before arguments that
    /// begin with `-`. The helper path is double-quoted for a POSIX shell so
    /// an install path with spaces stays one argument.
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
        return commands + commands.map { (host: L("\($0.host), this project only"), text: $0.text + pinned) }
    }

    private static let keyReadFailure = L(
        "BerryDB could not read its MCP access key from the Keychain. Nothing was changed."
    )
    private static let keyWriteFailure = L(
        "BerryDB could not update its MCP access key in the Keychain. Nothing was changed."
    )
    private static let saveBeforeLinking = L("Save the project before linking repositories.")

    nonisolated private static func linkFilePath(in folder: URL) -> String {
        folder.appendingPathComponent(MCPRepositoryLink.fileName).path
    }

    /// Writes `contents` as the link file of `folder`, following the rules
    /// `linkRepositories` states.
    ///
    /// The root is refused because the helper never reads a link file there.
    /// An existing entry is read with the helper's own bounded reader, which
    /// follows a symbolic link and never blocks on a FIFO. An atomic write
    /// writes an auxiliary file and then replaces the entry with it
    /// (https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic).
    /// Observed with Foundation on macOS 26.6: a symbolic link is replaced by
    /// the new file and its target is left as it was, and a folder of that
    /// name makes the write fail. A folder is therefore reported as in the
    /// way rather than offered for replacement.
    nonisolated private static func link(_ folder: URL, contents: Data, overwrite: Bool) -> MCPRepositoryLinkResult {
        let file = folder.appendingPathComponent(MCPRepositoryLink.fileName)
        let path = file.path
        guard canonicalRoot(folder.path) != "/" else {
            return .rejected(path, reason: L("The whole disk cannot be linked to a project."))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return .rejected(path, reason: L("Only a folder can be linked to a project."))
        }
        if let existing = MCPRepositoryLink.readBounded(path) {
            if existing == contents {
                return .unchanged(path)
            }
            var entry = stat()
            if lstat(path, &entry) == 0, entry.st_mode & S_IFMT == S_IFDIR {
                return .rejected(path, reason: L("A folder named .berrydb.json is in the way."))
            }
            if !overwrite {
                return .needsOverwrite(path, existingProject: MCPRepositoryLink.projectName(in: existing))
            }
        }
        do {
            try contents.write(to: file, options: .atomic)
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
