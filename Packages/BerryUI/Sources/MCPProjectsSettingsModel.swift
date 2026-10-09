import BerryCredentials
import BerryMCP
import BerryStore
import Combine
import CryptoKit
import Foundation

/// Creates, edits and deletes the MCP projects that coding agents reach
/// through the `berrydb-mcp` helper.
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
        // An agent entry can name a project with `--project <name>`, and
        // the helper selects every project whose name matches; two such
        // projects would leave every entry naming either one ambiguous.
        let nameTaken = others.contains { MCPProjectSelector.namesMatch($0.name, draft.name) }
        if nameTaken {
            return fail(L("Another project already uses this name. Agent entries can select a project by its name."))
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

    /// A notice to show under the name field, or nil. An agent entry can
    /// name a project with `--project <name>`, so renaming a saved project
    /// leaves every entry naming the old name selecting nothing. A change of
    /// letter case or surrounding whitespace still matches the old name by
    /// the helper's name rule and gets no notice, and neither does a cleared
    /// field, which cannot be saved.
    public func renameNotice(for draft: Draft) -> String? {
        guard let saved = projects.first(where: { $0.id == draft.id }),
              !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !MCPProjectSelector.namesMatch(saved.name, draft.name)
        else { return nil }
        return L("Agent entries that name “\(saved.name)” stop selecting this project until they use the new name.")
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

    /// One entry of the Agent Setup section: what to run, or what to add
    /// to a configuration file, for one host.
    public struct AgentSetupEntry: Equatable {
        public var host: String
        /// The command or configuration text, copied as shown.
        public var text: String
        /// Where the text goes and what the host does with it, when the
        /// section's general captions do not already say so.
        public var caption: String?

        init(host: String, text: String, caption: String? = nil) {
            self.host = host
            self.text = text
            self.caption = caption
        }
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
    /// `--project` and serves that project from any folder. It is installed
    /// at the same user level as the shared entry, so its label says it
    /// always serves the project rather than suggesting a narrower scope.
    /// An unsaved project gets none, since its ID means nothing to the
    /// helper yet. The `--` before the helper keeps `--project` an argument
    /// of the helper: `agy mcp add --help` (1.3.1) requires `--` before
    /// arguments that begin with `-`. The helper path is double-quoted for a
    /// POSIX shell so an install path with spaces stays one argument.
    ///
    /// A saved project then gets one per-repository entry for Claude Code
    /// and one for Codex, each passing `--project <name>` with the saved
    /// name, so a file committed to the repository selects a project of
    /// that name in every clone and for every teammate. Both hosts gate
    /// configuration a repository defines behind the user's trust.
    /// - Claude Code asks for approval in an interactive session before it
    ///   uses a server from `.mcp.json`, and loads it without asking in a
    ///   `claude -p` run (https://code.claude.com/docs/en/mcp#project-scope).
    ///   Observed with Claude Code 2.1.295 and a throwaway home directory:
    ///   `claude mcp add --scope project` wrote `.mcp.json` in the current
    ///   folder with the arguments as given, and `claude mcp list` showed the
    ///   entry as pending approval. With a user-level `berrydb` entry also
    ///   present, `claude mcp get` and `claude mcp list` used the user-level
    ///   entry while the repository's was pending, and the repository's once
    ///   the approval was recorded in `~/.claude.json`, the order that page
    ///   gives (https://code.claude.com/docs/en/mcp#scope-hierarchy-and-precedence).
    ///   The caption therefore says which entry applies before and after
    ///   approval rather than asking for the user-level entry's removal.
    /// - codex-cli 0.157.1, observed with a throwaway home directory:
    ///   `[mcp_servers.berrydb]` in a repository's `.codex/config.toml`
    ///   replaced the user-level entry for `codex mcp get` run inside the
    ///   repository only while the user configuration marked the folder
    ///   trusted, and was ignored otherwise.
    /// - Antigravity gets no such entry: agy 1.3.1 listed only its user-level
    ///   server inside a folder holding `.agents/mcp_config.json`, and its
    ///   embedded documentation names only `~/.gemini/config/mcp_config.json`
    ///   and plugin configuration.
    public func configurationSnippets(project: UUID) -> [AgentSetupEntry] {
        guard let helperURL else { return [] }
        let helper = Self.shellQuoted(helperURL.path)
        let commands = [
            AgentSetupEntry(host: "Claude Code", text: "claude mcp add --scope user berrydb -- \(helper)"),
            AgentSetupEntry(host: "Codex", text: "codex mcp add berrydb -- \(helper)"),
            AgentSetupEntry(host: "Antigravity", text: "agy mcp add berrydb -- \(helper)"),
        ]
        guard let saved = projects.first(where: { $0.id == project }) else { return commands }
        let pinned = " --project \(project.uuidString.lowercased())"
        let repository = [
            AgentSetupEntry(
                host: L("\("Claude Code"), this repository"),
                text: "claude mcp add --scope project berrydb -- \(helper) --project \(Self.shellQuoted(saved.name))",
                caption: L("Run it in the repository’s top folder. It writes .mcp.json there, which can be committed. Once you approve the entry in Claude Code, Claude Code uses it in this repository instead of a user-level berrydb entry; until then, it uses the user-level entry.")
            ),
            AgentSetupEntry(
                host: L("\("Codex"), this repository"),
                text: """
                [mcp_servers.berrydb]
                command = \(Self.tomlQuoted(helperURL.path))
                args = ["--project", \(Self.tomlQuoted(saved.name))]
                """,
                caption: L("Add it to .codex/config.toml in the repository. Codex reads that file only once the project is trusted, and there it takes precedence over the user-level berrydb entry.")
            ),
        ]
        return commands
            + commands.map { AgentSetupEntry(host: L("\($0.host), always this project"), text: $0.text + pinned) }
            + repository
    }

    /// `value` as a TOML basic string: in double quotes, with `"` and `\`
    /// escaped and every control character written as an escape, the short
    /// form where TOML 1.0 has one and `\uXXXX` otherwise
    /// (https://toml.io/en/v1.0.0#string). Scalars are escaped one by one,
    /// so a CR LF pair, which Swift counts as one character, becomes `\r\n`.
    nonisolated static func tomlQuoted(_ value: String) -> String {
        var quoted = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\u{08}": quoted += "\\b"
            case "\t": quoted += "\\t"
            case "\n": quoted += "\\n"
            case "\u{0C}": quoted += "\\f"
            case "\r": quoted += "\\r"
            case "\u{00}" ... "\u{1F}", "\u{7F}": quoted += String(format: "\\u%04X", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        quoted += "\""
        return quoted
    }

    private static let keyReadFailure = L(
        "BerryDB could not read its MCP access key from the Keychain. Nothing was changed."
    )
    private static let keyWriteFailure = L(
        "BerryDB could not update its MCP access key in the Keychain. Nothing was changed."
    )

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
    /// and not escaped; an app bundle path or a project name containing `!`
    /// would need editing.
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
