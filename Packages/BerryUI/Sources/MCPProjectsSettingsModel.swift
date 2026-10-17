import BerryCore
import BerryCredentials
import BerryDriverKit
import BerryMCP
import BerryStore
import Combine
import CryptoKit
import Foundation

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
/// through the `berrydb-mcp` helper.
///
/// Every save and delete rotates the access key in one fixed order: read
/// the stored key (abort if the Keychain refuses), build the value from the
/// store's verified editing copy, store a new key, then write rows sealed
/// under the new key with the old one as the re-seal source. Any failure
/// stops at that step and sets `errorMessage`. A saved value is never built
/// from unverified rows, so a `liveRead` written into the store file by
/// another process is never signed by a settings save. A draft turns live
/// reads on only for a profile that passes the rules `save` checks.
@MainActor
public final class MCPProjectsSettingsModel: ObservableObject {
    /// The editable part of a project.
    public struct Draft: Equatable {
        public var id: UUID
        public var name: String
        public var isEnabled: Bool
        public var workspaceRoots: [String]
        /// Assigned connection profiles, in the order they were added.
        public var profileIDs: [UUID]
        /// Live-read settings by profile; a profile without an entry has
        /// live reads off and no redactions. Only entries of `profileIDs`
        /// are saved, so taking a connection out of the project and adding
        /// it back in the same editor keeps what was set for it.
        public var access: [UUID: AccessDraft] = [:]
        /// Confirmations given in the editor. `save` asks for them only for
        /// profiles whose live reads it turns on.
        public var acknowledged: Set<Acknowledgment> = []
        /// Profiles whose live reads were on, and verified, in the editing
        /// copy this draft was made from; empty for a new project. The
        /// editor reads it to tell live reads a save would turn on from live
        /// reads that stay on. `save` does not trust it and reads the
        /// editing copy again.
        public internal(set) var verifiedLiveReads: Set<UUID> = []
    }

    /// One profile's live-read settings as the editor holds them. The store
    /// type lowercases, dedupes and sorts `redactedColumns` when saved.
    public struct AccessDraft: Equatable {
        public var liveRead: Bool = false
        public var redactedColumns: [String] = []
    }

    /// A confirmation a save needs before it turns live reads on.
    public enum Acknowledgment: Hashable {
        /// The redacted columns of this production-labeled profile were
        /// reviewed, and reads on its database accepted.
        case production(UUID)
        /// This profile may serve live reads although the privilege check
        /// found a database user that can write, or could not run.
        case writableRole(UUID)
    }

    /// The privilege check of one profile, run when the editor turns its
    /// live reads on.
    public enum PrivilegeState: Equatable {
        case notChecked
        case checking
        /// The check found no write privilege.
        case readOnlyRole
        /// The write privileges found, as categories from
        /// `MCPPrivilegeCheck`, never grant lines.
        case writableRole([String])
        /// The check could not run; the reason, ready to show.
        case failed(String)
    }

    /// The privilege check of a model built for tests without a checker, so
    /// a test never opens a connection to a real server by accident.
    struct PrivilegeCheckUnavailable: Error {}

    /// The last privilege check of each profile; a profile without an
    /// entry is not checked. Cleared by `reload()`.
    @Published public private(set) var privilegeStates: [UUID: PrivilegeState] = [:]

    /// What the latest check of a profile ran on. `serial` lets only that
    /// check set the profile's state; `endpoint` lets `save` discard a
    /// result once the profile points at another server or account.
    private struct PrivilegeCheck {
        let serial: Int
        let endpoint: ConnectionProfile
    }

    private var privilegeChecks: [UUID: PrivilegeCheck] = [:]
    /// Never reset, so a check started before `reload()` cannot match the
    /// serial of one started after it.
    private var privilegeCheckSerial = 0

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
    private let privilegeChecker: @Sendable (ConnectionProfile) async throws -> [String]
    private let privilegeCheckLimit: Duration
    private var helperURL: URL? {
        guard case let .bundled(url) = helperLocation else { return nil }
        return url
    }

    /// `keyStore` defaults to the Keychain item the helper reads; the
    /// helper is looked up once, inside the running app's bundle. Privilege
    /// checks connect to the profile's server.
    public convenience init(store: BerryStore, keyStore: MCPAccessKeyStore = .keychain) {
        let location = Self.helperLocation(in: Bundle.main.bundleURL, isOnReadOnlyVolume: Self.isOnReadOnlyVolume)
        self.init(
            store: store, keyStore: keyStore, helperLocation: location,
            privilegeChecker: { try await MCPProjectsSettingsModel.livePrivilegeChecker($0) }
        )
    }

    /// A model whose helper is at `helperURL`, or that has none when it is nil.
    convenience init(
        store: BerryStore, keyStore: MCPAccessKeyStore, helperURL: URL?,
        privilegeCheckLimit: Duration = defaultPrivilegeCheckLimit,
        privilegeChecker: @escaping @Sendable (ConnectionProfile) async throws -> [String] = { _ in
            throw PrivilegeCheckUnavailable()
        }
    ) {
        self.init(
            store: store, keyStore: keyStore,
            helperLocation: helperURL.map(MCPHelperLocation.bundled) ?? .notBundled,
            privilegeChecker: privilegeChecker,
            privilegeCheckLimit: privilegeCheckLimit
        )
    }

    init(
        store: BerryStore, keyStore: MCPAccessKeyStore, helperLocation: MCPHelperLocation,
        privilegeChecker: @escaping @Sendable (ConnectionProfile) async throws -> [String],
        privilegeCheckLimit: Duration = defaultPrivilegeCheckLimit
    ) {
        self.store = store
        self.keyStore = keyStore
        self.helperLocation = helperLocation
        self.privilegeChecker = privilegeChecker
        self.privilegeCheckLimit = privilegeCheckLimit
        reload()
    }

    /// How long a privilege check may take before it is reported as failed:
    /// the default request limit of a live read, so a server that answers
    /// the helper in time also answers the check in time.
    nonisolated static let defaultPrivilegeCheckLimit: Duration = .seconds(30)

    /// Runs the privilege check of `profileID` on the profile as stored now,
    /// publishing `.checking` and then the result: `.readOnlyRole` without
    /// findings, `.writableRole` with them, `.failed` when the check throws
    /// or is still running once `privilegeCheckLimit` has passed. A check
    /// past its limit is cancelled and left to unwind, which closes its
    /// connection. A check that another check of the same profile, or
    /// `reload()`, has superseded by the time it finishes sets nothing. A
    /// profile that is no longer stored, or a store that cannot be read, is
    /// left alone.
    public func checkPrivileges(of profileID: UUID) async {
        guard let profile = (try? store.allProfiles())?.first(where: { $0.id == profileID }) else { return }
        privilegeCheckSerial += 1
        let serial = privilegeCheckSerial
        privilegeChecks[profileID] = PrivilegeCheck(serial: serial, endpoint: Self.endpoint(of: profile))
        privilegeStates[profileID] = .checking
        let checker = privilegeChecker
        let state: PrivilegeState
        switch await Self.result(within: privilegeCheckLimit, of: { try await checker(profile) }) {
        case let .success(findings)?:
            state = findings.isEmpty ? .readOnlyRole : .writableRole(findings)
        case let .failure(error)?:
            state = .failed(error.localizedDescription)
        case nil:
            state = .failed(L("The check did not finish in time."))
        }
        guard privilegeChecks[profileID]?.serial == serial else { return }
        privilegeStates[profileID] = state
    }

    /// The result of `operation`, or nil once `limit` has passed or the
    /// caller is cancelled; the operation is then cancelled and not awaited.
    /// A task group cannot give this bound: it waits for every child, so an
    /// operation that ignores cancellation would hold it past the limit.
    nonisolated static func result<T: Sendable>(
        within limit: Duration, of operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, Error>? {
        let (outcomes, sink) = AsyncStream<Result<T, Error>?>.makeStream()
        let work = Task {
            do {
                sink.yield(.success(try await operation()))
            } catch {
                sink.yield(.failure(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            sink.yield(nil)
        }
        var iterator = outcomes.makeAsyncIterator()
        let first = await iterator.next() ?? nil
        sink.finish()
        timer.cancel()
        work.cancel()
        return first
    }

    /// Runs `check` on a connection from `open` and passes the connection to
    /// `close` on every path: after `check` returns or throws, and without
    /// running `check` when the task was cancelled while the connection
    /// opened. A check past its limit is cancelled and left to unwind, so
    /// this is what closes its connection then.
    nonisolated static func withOwnConnection<Connection: Sendable>(
        open: @Sendable () async throws -> Connection,
        close: @Sendable (Connection) async -> Void,
        _ check: @Sendable (Connection) async throws -> [String]
    ) async throws -> [String] {
        let connection = try await open()
        do {
            try Task.checkCancellation()
            let findings = try await check(connection)
            await close(connection)
            return findings
        } catch {
            await close(connection)
            throw error
        }
    }

    /// `profile` with the fields blanked that only label it: the ones the
    /// store's integrity seal also leaves out of a profile's endpoint, since
    /// they do not decide which server and account a connection reaches.
    /// Every other field counts, so a connection field added to profiles
    /// later invalidates a check by default.
    nonisolated private static func endpoint(of profile: ConnectionProfile) -> ConnectionProfile {
        var endpoint = profile
        endpoint.name = ""
        endpoint.groupName = nil
        endpoint.envColor = nil
        endpoint.sortOrder = 0
        endpoint.createdAt = .distantPast
        endpoint.historyEnabled = false
        return endpoint
    }

    /// True for the drivers the helper serves live reads for, each opened in
    /// a read-only mode its server enforces: PostgreSQL, MySQL and MariaDB
    /// (driver `mysql`), and SQLite. The editor offers live reads only for
    /// these, and `save` refuses to turn them on for any other.
    nonisolated public static func supportsLiveRead(_ profile: ConnectionProfile) -> Bool {
        switch profile.driver {
        case .postgres, .mysql, .sqlite: true
        default: false
        }
    }

    /// True when saving `draft` turns live reads on for `profileID`: on in
    /// the draft and not in `verifiedLiveReads`. Only such a profile needs
    /// the production consent, a privilege check and, for a database user
    /// that can write, the confirmation to use it anyway.
    nonisolated public static func turnsLiveReadsOn(_ profileID: UUID, in draft: Draft) -> Bool {
        draft.access[profileID]?.liveRead == true && !draft.verifiedLiveReads.contains(profileID)
    }

    /// True when the editor starts the privilege check of `profile`: `draft`
    /// turns its live reads on, and its driver has database users to check.
    /// Switching off and on again live reads that were already on starts
    /// none.
    nonisolated public static func startsPrivilegeCheck(for profile: ConnectionProfile, in draft: Draft) -> Bool {
        needsPrivilegeCheck(profile) && turnsLiveReadsOn(profile.id, in: draft)
    }

    /// True for the drivers whose database users can hold the write
    /// privileges `MCPPrivilegeCheck` looks for; a SQLite file has no users.
    nonisolated public static func needsPrivilegeCheck(_ profile: ConnectionProfile) -> Bool {
        switch profile.driver {
        case .postgres, .mysql: true
        default: false
        }
    }

    /// The column names of `text`, a comma-separated list as typed in the
    /// editor, each trimmed, empty entries dropped. Letter case and
    /// duplicates are left to `MCPProfileAccess`, which normalizes both.
    nonisolated public static func redactedColumns(from text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Runs `MCPPrivilegeCheck` on a connection opened for it alone and
    /// closed on every path (`withOwnConnection`): the MySQL check runs `SET ROLE ALL`, which changes the privileges of the
    /// session it runs in (https://dev.mysql.com/doc/refman/8.4/en/set-role.html).
    /// Secrets are read off the main actor, as the workspace reads them
    /// before connecting: `SecItemCopyMatching` blocks its calling thread
    /// (https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)).
    nonisolated static func livePrivilegeChecker(_ profile: ConnectionProfile) async throws -> [String] {
        guard let driver = profile.driver else {
            throw DriverError.unsupported("Driver \(profile.driverID) is not registered")
        }
        let profileID = profile.id
        let (password, sshPassword, sshPassphrase) = await Task.detached {
            (
                KeychainService.readPassword(kind: .database, profileID: profileID),
                KeychainService.readPassword(kind: .ssh, profileID: profileID),
                KeychainService.readPassword(kind: .sshPassphrase, profileID: profileID)
            )
        }.value
        let config = profile.makeConfig(password: password, sshPassword: sshPassword, sshPassphrase: sshPassphrase)
        let isProduction = profile.envColor == "production"
        let manager = ConnectionManager()
        return try await withOwnConnection(
            open: {
                try await manager.open(config, profileID: profileID, isProduction: isProduction, recordHistory: false)
            },
            close: { await manager.close($0.id) },
            { try await MCPPrivilegeCheck.findings(on: $0.connection, driver: driver) }
        )
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
    /// reading the key once for all projects. Forgets the privilege checks:
    /// a result describes a profile as it was when checked, and a profile
    /// can be edited in the main window before the next editor opens.
    public func reload() {
        errorMessage = nil
        privilegeStates = [:]
        privilegeChecks = [:]
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
    /// back disabled, and a profile's live reads come back off unless its
    /// own row verifies.
    public func draft(for id: UUID) -> Draft? {
        do {
            guard let project = try store.mcpProjectForEditing(id: id, key: keyStore.load()) else { return nil }
            let access = project.profiles.map {
                ($0.profileID, AccessDraft(liveRead: $0.liveRead, redactedColumns: $0.redactedColumns))
            }
            return Draft(
                id: project.id,
                name: project.name,
                isEnabled: project.isEnabled,
                workspaceRoots: project.workspaceRoots,
                profileIDs: project.profiles.map(\.profileID),
                access: Dictionary(access, uniquingKeysWith: { first, _ in first }),
                verifiedLiveReads: Set(project.profiles.filter(\.liveRead).map(\.profileID))
            )
        } catch {
            errorMessage = L("MCP projects could not be loaded: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves `draft` under a newly rotated key. Returns false with
    /// `errorMessage` set when a root is invalid or is also a root of
    /// another project, the name has the form of a project ID or another
    /// project already uses it, the key cannot be read or written, or the
    /// store refuses the write. Roots and the name are checked before the
    /// key is read, so an invalid draft changes nothing.
    ///
    /// It also returns false for a draft that turns live reads on, off in
    /// the verified editing copy and on in the draft, for an assigned
    /// profile when its driver has none (`supportsLiveRead`), when it is
    /// production-labeled and `acknowledged` lacks `.production`, or when
    /// it needs a privilege check whose state is not `.readOnlyRole` and is
    /// not a `.writableRole` or `.failed` result that `acknowledged`
    /// accepts with `.writableRole`. A result counts only while the stored
    /// profile still reaches the server and account it was checked on. Live
    /// reads that stay on are not checked again. These rules compare with the verified editing copy, which
    /// takes the stored key to read, so they run after the key is read and
    /// before a new one is stored: a refused draft changes nothing either.
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
        // The helper reads a `--project` value that parses as a UUID as an
        // ID, never as a name, so an agent entry naming such a project could
        // never select it, and could select another project with that ID.
        if case .id = MCPProjectReference(argument: draft.name) {
            return fail(L("A project name cannot have the form of a project ID."))
        }
        let others: [MCPProject]
        let savedProfiles: [UUID: ConnectionProfile]
        do {
            others = try store.mcpProjects().filter { $0.id != draft.id }
            savedProfiles = Dictionary(
                try store.allProfiles().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
            )
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
        draft.profileIDs.removeAll { savedProfiles[$0] == nil }
        let previousKey: SymmetricKey?
        do {
            previousKey = try keyStore.loadForRotation()
        } catch {
            return fail(Self.keyReadFailure)
        }
        let editing: MCPProject?
        do {
            editing = try store.mcpProjectForEditing(id: draft.id, key: previousKey)
        } catch {
            return fail(L("The MCP project could not be saved: \(error.localizedDescription)"))
        }
        if let refusal = liveReadRefusal(for: draft, editing: editing, profiles: savedProfiles) {
            return fail(refusal)
        }
        let project = editedProject(from: draft, editing: editing)
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
    /// arguments that begin with `-`. The helper path, and a project name
    /// below, are single-quoted for a POSIX shell (`shellQuoted`), so a path
    /// or name with spaces or shell characters stays one literal argument.
    ///
    /// A saved project then gets one per-repository entry for Claude Code
    /// and one for Codex, each passing `--project <name>` with the saved
    /// name, so a file committed to the repository selects a project of
    /// that name in every clone and for every teammate. In interactive use
    /// both hosts gate configuration a repository defines behind the user's
    /// trust.
    /// - Claude Code asks for approval in an interactive session before it
    ///   uses a server from `.mcp.json`, and loads it without asking in
    ///   `claude -p` runs, Agent SDK sessions and cloud sessions
    ///   (https://code.claude.com/docs/en/mcp#project-scope).
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
                caption: L("Run it in the repository’s top folder. It writes .mcp.json there, which can be committed. Once you approve the entry in an interactive Claude Code session, Claude Code uses it in this repository instead of a user-level berrydb entry; until then, it uses the user-level entry.")
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

    /// Why `draft` cannot be saved, for the first assigned profile whose live
    /// reads it turns on against `editing`, or nil. The live reads already
    /// on come from `editing`, never from the draft's own record of them.
    /// `profiles` holds every saved profile, and the draft only profiles
    /// found there.
    private func liveReadRefusal(
        for draft: Draft, editing: MCPProject?, profiles: [UUID: ConnectionProfile]
    ) -> String? {
        var current = draft
        current.verifiedLiveReads = Set(editing?.profiles.filter(\.liveRead).map(\.profileID) ?? [])
        let turnedOn = draft.profileIDs.compactMap { profiles[$0] }.filter {
            Self.turnsLiveReadsOn($0.id, in: current)
        }
        for profile in turnedOn {
            guard Self.supportsLiveRead(profile) else {
                return L("Live reads are not available for \(profile.name).")
            }
            if profile.envColor == "production", !draft.acknowledged.contains(.production(profile.id)) {
                return L("Live reads on \(profile.name) need your confirmation that you reviewed its redacted columns and accept reads on this production database.")
            }
            guard Self.needsPrivilegeCheck(profile) else { continue }
            let checkedAsStored = privilegeChecks[profile.id]?.endpoint == Self.endpoint(of: profile)
            switch checkedAsStored ? privilegeStates[profile.id] ?? .notChecked : .notChecked {
            case .readOnlyRole:
                break
            case .writableRole, .failed:
                if !draft.acknowledged.contains(.writableRole(profile.id)) {
                    return L("Live reads on \(profile.name) need your confirmation to use this connection anyway, since its privileges were not found read-only.")
                }
            case .notChecked, .checking:
                return L("Live reads on \(profile.name) need a finished privilege check. Save again once it is done.")
            }
        }
        return nil
    }

    /// The value to seal: the verified editing copy of a stored project, or
    /// a new project, with the draft applied, the draft's live-read settings
    /// included.
    private func editedProject(from draft: Draft, editing: MCPProject?) -> MCPProject {
        var project = editing ?? MCPProject(id: draft.id, name: draft.name)
        project.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.isEnabled = draft.isEnabled
        project.workspaceRoots = draft.workspaceRoots.map(Self.canonicalRoot)
        project.profiles = draft.profileIDs.map { id in
            let access = draft.access[id] ?? AccessDraft()
            return MCPProfileAccess(profileID: id, liveRead: access.liveRead, redactedColumns: access.redactedColumns)
        }
        project.updatedAt = Date()
        return project
    }

    private func fail(_ message: String) -> Bool {
        errorMessage = message
        return false
    }

    /// Wraps `value` in single quotes, inside which a POSIX shell keeps
    /// every character literal and a single quote cannot occur
    /// (https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html#tag_19_02_02),
    /// so each `'` is written as `'\''`: close the quotes, an escaped quote,
    /// reopen them. Double quotes are not enough: an interactive bash or zsh
    /// still expands `!` inside them, and escaping it there does not help
    /// in bash, which keeps the backslash. Observed with /bin/bash 3.2.57
    /// and zsh 5.9 on macOS 26.6.2 reading commands interactively:
    /// `"it!!s"` became the previous command spliced in, bash printed
    /// `"a\!b"` as `a\!b`, and `'it!!s'` stayed as written in both.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
