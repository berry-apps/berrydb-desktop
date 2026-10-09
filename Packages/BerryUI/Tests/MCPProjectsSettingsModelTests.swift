import BerryMCP
import CryptoKit
import Foundation
import Testing

@testable import BerryCredentials
@testable import BerryStore
@testable import BerryUI

/// The settings model is the only writer of MCP projects, so every save and
/// delete must follow the key-rotation order exactly: read the stored key,
/// build the value from the verified editing copy, store a new key, then
/// write rows sealed under it. These tests run against an in-memory store and
/// an in-memory key, never the user's store file or Keychain.
@MainActor
@Suite("MCP projects settings model")
struct MCPProjectsSettingsModelTests {
    /// In-memory stand-in for the Keychain item behind `MCPAccessKeyStore`.
    final class KeyBox: @unchecked Sendable {
        var data: Data?
        var readError: Error?
        var writeSucceeds = true
        var writeCount = 0

        var keyStore: MCPAccessKeyStore {
            MCPAccessKeyStore(
                read: {
                    if let error = self.readError {
                        throw error
                    }
                    return self.data
                },
                write: { data in
                    self.writeCount += 1
                    guard self.writeSucceeds else { return false }
                    self.data = data
                    return true
                }
            )
        }

        var key: SymmetricKey? { data.map { SymmetricKey(data: $0) } }
    }

    private struct InjectedReadFailure: Error {}

    private func makeStore() throws -> (BerryStore, ConnectionProfile, ConnectionProfile) {
        let store = try BerryStore(path: ":memory:")
        let orders = ConnectionProfile(driverID: "postgres", name: "Orders")
        let events = ConnectionProfile(driverID: "dynamodb", name: "Events")
        try store.save(orders)
        try store.save(events)
        return (store, orders, events)
    }

    private func makeModel(_ store: BerryStore, _ box: KeyBox, helperURL: URL? = nil) -> MCPProjectsSettingsModel {
        MCPProjectsSettingsModel(store: store, keyStore: box.keyStore, helperURL: helperURL)
    }

    @Test func newProjectIsSealedAndVerifies() throws {
        let (store, orders, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)

        var draft = model.draftForNewProject()
        draft.name = "Billing"
        draft.isEnabled = true
        draft.workspaceRoots = ["/work/billing"]
        draft.profileIDs = [orders.id]
        #expect(model.save(draft))

        let key = try #require(box.key)
        let verified = try #require(try store.verifiedMCPProject(id: draft.id, key: key))
        #expect(verified.projectTagValid)
        #expect(verified.project.name == "Billing")
        #expect(verified.project.isEnabled)
        #expect(verified.project.profiles == [MCPProfileAccess(profileID: orders.id)])
        #expect(model.projects.map(\.id) == [draft.id])
        #expect(model.errorMessage == nil)
    }

    @Test func savedRootsResolveSymbolicLinks() throws {
        let (store, _, _) = try makeStore()
        let model = makeModel(store, KeyBox())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)

        var draft = model.draftForNewProject()
        draft.name = "Scratch"
        draft.workspaceRoots = [alias.path + "/"]
        #expect(model.save(draft))

        // The store applies its own `standardizedFileURL` on top, which turns
        // `/private/var/…` back into `/var/…`; the last component shows
        // whether the link itself was resolved.
        let stored = try #require(try store.mcpProject(id: draft.id)?.workspaceRoots.first)
        #expect(URL(fileURLWithPath: stored).lastPathComponent == "checkout")
        #expect(stored == URL(fileURLWithPath: MCPProjectsSettingsModel.canonicalRoot(checkout.path)).standardizedFileURL.path)
    }

    @Test func saveRotatesTheKey() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let initial = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        box.data = initial
        let model = makeModel(store, box)

        var draft = model.draftForNewProject()
        draft.name = "Billing"
        #expect(model.save(draft))
        let afterFirst = try #require(box.data)
        #expect(afterFirst != initial)
        #expect(afterFirst.count == 32)

        draft.name = "Billing API"
        #expect(model.save(draft))
        #expect(try #require(box.data) != afterFirst)
        let verified = try #require(try store.verifiedMCPProject(id: draft.id, key: box.key))
        #expect(verified.projectTagValid)
    }

    @Test func keyReadFailureAbortsSaveWithoutWriting() throws {
        let (store, orders, _) = try makeStore()
        let box = KeyBox()
        box.readError = InjectedReadFailure()
        let model = makeModel(store, box)

        var draft = model.draftForNewProject()
        draft.name = "Billing"
        draft.profileIDs = [orders.id]
        #expect(model.save(draft) == false)

        #expect(model.errorMessage != nil)
        #expect(try store.mcpProjects().isEmpty)
        #expect(box.writeCount == 0)
    }

    @Test func keyWriteFailureAbortsSaveWithoutWriting() throws {
        let (store, orders, _) = try makeStore()
        let box = KeyBox()
        box.writeSucceeds = false
        let model = makeModel(store, box)

        var draft = model.draftForNewProject()
        draft.name = "Billing"
        draft.profileIDs = [orders.id]
        #expect(model.save(draft) == false)

        #expect(model.errorMessage != nil)
        #expect(try store.mcpProjects().isEmpty)
    }

    /// The store refuses an access row for a missing profile only after the
    /// new key is stored, which would leave every other project sealed under
    /// a key that is gone. A connection deleted while its project's editor
    /// is open therefore has to leave the draft before the key is read.
    @Test func aConnectionDeletedWhileEditingIsDroppedAndOtherProjectsStillVerify() throws {
        let (store, orders, events) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var ledger = model.draftForNewProject()
        ledger.name = "Ledger"
        ledger.isEnabled = true
        ledger.workspaceRoots = ["/work/ledger"]
        #expect(model.save(ledger))
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        billing.isEnabled = true
        billing.profileIDs = [orders.id, events.id]
        #expect(model.save(billing))
        let stale = try #require(model.draft(for: billing.id))
        try store.deleteProfile(id: orders.id)

        #expect(model.save(stale))

        #expect(model.errorMessage == nil)
        let saved = try #require(try store.verifiedMCPProject(id: billing.id, key: box.key))
        #expect(saved.projectTagValid)
        #expect(saved.project.profiles.map(\.profileID) == [events.id])
        let other = try #require(try store.verifiedMCPProject(id: ledger.id, key: box.key))
        #expect(other.projectTagValid)
        #expect(model.unverifiedProjectIDs.isEmpty)
    }

    @Test func editPreservesVerifiedLiveReadAndDropsUnverified() throws {
        let (store, orders, events) = try makeStore()
        let reporting = ConnectionProfile(driverID: "mysql", name: "Reporting")
        try store.save(reporting)
        let box = KeyBox()
        let sealedKey = SymmetricKey(size: .bits256)
        box.data = sealedKey.withUnsafeBytes { Data($0) }
        let seeded = MCPProject(name: "Billing", isEnabled: true, workspaceRoots: ["/work/billing"], profiles: [
            MCPProfileAccess(profileID: orders.id, liveRead: true, redactedColumns: ["email"]),
            MCPProfileAccess(profileID: events.id, liveRead: false),
        ])
        try store.saveMCPProject(seeded, sealingKey: sealedKey, previousKey: nil)
        // A same-user process flips another row on directly in the file.
        try store.executeForTesting(
            "UPDATE mcp_project_profile SET liveRead = 1 WHERE profileID = ?",
            arguments: [events.id]
        )
        let model = makeModel(store, box)

        var draft = try #require(model.draft(for: seeded.id))
        draft.name = "Billing API"
        draft.profileIDs.append(reporting.id)
        #expect(model.save(draft))

        let verified = try #require(try store.verifiedMCPProject(id: seeded.id, key: box.key))
        #expect(verified.project.name == "Billing API")
        #expect(verified.liveReadProfileIDs == [orders.id])
        let saved = Dictionary(uniqueKeysWithValues: verified.project.profiles.map { ($0.profileID, $0) })
        #expect(saved[orders.id] == MCPProfileAccess(profileID: orders.id, liveRead: true, redactedColumns: ["email"]))
        #expect(saved[events.id]?.liveRead == false)
        #expect(saved[reporting.id] == MCPProfileAccess(profileID: reporting.id))
    }

    @Test func deleteRotatesAndRemoves() throws {
        let (store, orders, events) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        billing.profileIDs = [orders.id]
        var analytics = model.draftForNewProject()
        analytics.name = "Analytics"
        analytics.profileIDs = [events.id]
        #expect(model.save(billing))
        #expect(model.save(analytics))
        let beforeDelete = try #require(box.data)

        #expect(model.delete(id: billing.id))

        #expect(try store.mcpProject(id: billing.id) == nil)
        #expect(model.projects.map(\.id) == [analytics.id])
        #expect(try #require(box.data) != beforeDelete)
        let remaining = try #require(try store.verifiedMCPProject(id: analytics.id, key: box.key))
        #expect(remaining.projectTagValid)
    }

    @Test func keyReadFailureAbortsDeleteWithoutWriting() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var draft = model.draftForNewProject()
        draft.name = "Billing"
        #expect(model.save(draft))
        let writesBefore = box.writeCount
        box.readError = InjectedReadFailure()

        #expect(model.delete(id: draft.id) == false)

        #expect(model.errorMessage != nil)
        #expect(try store.mcpProject(id: draft.id) != nil)
        #expect(box.writeCount == writesBefore)
    }

    @Test func keyWriteFailureAbortsDeleteWithoutDeleting() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var draft = model.draftForNewProject()
        draft.name = "Billing"
        #expect(model.save(draft))
        let keyBefore = box.data
        box.writeSucceeds = false

        #expect(model.delete(id: draft.id) == false)

        #expect(model.errorMessage != nil)
        #expect(try store.mcpProject(id: draft.id) != nil)
        #expect(box.data == keyBefore)
    }

    @Test func draftOfAnUnverifiedProjectIsDisabledAndStaysDisabledWhenSaved() throws {
        let (store, orders, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var draft = model.draftForNewProject()
        draft.name = "Billing"
        draft.isEnabled = true
        draft.workspaceRoots = ["/work/billing"]
        draft.profileIDs = [orders.id]
        #expect(model.save(draft))
        // Another process points the enabled project at a different folder
        // without the key; the row still claims to be enabled.
        try store.executeForTesting(
            #"UPDATE mcp_project SET workspaceRootsJSON = '["/work/elsewhere"]' WHERE id = ?"#,
            arguments: [draft.id]
        )
        #expect(try store.mcpProject(id: draft.id)?.isEnabled == true)

        var edited = try #require(model.draft(for: draft.id))
        #expect(edited.isEnabled == false)
        edited.name = "Billing API"
        #expect(model.save(edited))

        #expect(try store.mcpProject(id: draft.id)?.isEnabled == false)
        let verified = try #require(try store.verifiedMCPProject(id: draft.id, key: box.key))
        #expect(verified.projectTagValid)
        #expect(verified.project.isEnabled == false)
    }

    /// The editor tells the user of an unverified project that turning
    /// Enabled on and saving confirms it; this is what makes that true.
    @Test func anUnverifiedProjectTurnedOnAndSavedIsVerifiedAndEnabled() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var draft = model.draftForNewProject()
        draft.name = "Billing"
        draft.isEnabled = true
        draft.workspaceRoots = ["/work/billing"]
        #expect(model.save(draft))
        try store.executeForTesting(
            #"UPDATE mcp_project SET workspaceRootsJSON = '["/work/elsewhere"]' WHERE id = ?"#,
            arguments: [draft.id]
        )
        model.reload()
        #expect(model.unverifiedProjectIDs == [draft.id])

        var edited = try #require(model.draft(for: draft.id))
        #expect(edited.isEnabled == false)
        edited.isEnabled = true
        #expect(model.save(edited))

        let verified = try #require(try store.verifiedMCPProject(id: draft.id, key: box.key))
        #expect(verified.projectTagValid)
        #expect(verified.project.isEnabled)
        #expect(model.unverifiedProjectIDs.isEmpty)
    }

    @Test func projectsWhoseTagDoesNotVerifyAreMarkedUnverified() throws {
        let (store, _, _) = try makeStore()
        let model = makeModel(store, KeyBox())
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        billing.workspaceRoots = ["/work/billing"]
        var analytics = model.draftForNewProject()
        analytics.name = "Analytics"
        #expect(model.save(billing))
        #expect(model.save(analytics))
        #expect(model.unverifiedProjectIDs.isEmpty)

        try store.executeForTesting(
            #"UPDATE mcp_project SET workspaceRootsJSON = '["/work/elsewhere"]' WHERE id = ?"#,
            arguments: [billing.id]
        )
        model.reload()

        #expect(model.unverifiedProjectIDs == [billing.id])
    }

    @Test func reloadClearsAStaleError() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        box.readError = InjectedReadFailure()
        let model = makeModel(store, box)
        var draft = model.draftForNewProject()
        draft.name = "Billing"
        #expect(model.save(draft) == false)
        #expect(model.errorMessage != nil)

        model.reload()

        #expect(model.errorMessage == nil)
    }

    @Test func rootValidation() throws {
        let wholeDisk = L("A workspace root cannot be the whole disk.")
        #expect(MCPProjectsSettingsModel.validateRoot("/") == wholeDisk)
        #expect(MCPProjectsSettingsModel.validateRoot("/private/tmp/../..") == wholeDisk)
        #expect(MCPProjectsSettingsModel.validateRoot("//") == wholeDisk)
        #expect(MCPProjectsSettingsModel.validateRoot("work/billing") != nil)
        #expect(MCPProjectsSettingsModel.validateRoot("") != nil)
        #expect(MCPProjectsSettingsModel.validateRoot("~/work/billing") == L("A workspace root must be an absolute path."))
        #expect(MCPProjectsSettingsModel.validateRoot("/work/billing") == nil)
        #expect(MCPProjectsSettingsModel.validateRoot("/work/billing/api") == nil)

        let home = NSHomeDirectory()
        #expect(MCPProjectsSettingsModel.validateRoot(home) == nil)
        #expect(MCPProjectsSettingsModel.isHomeDirectory(home))
        #expect(MCPProjectsSettingsModel.isHomeDirectory(home + "/"))
        #expect(!MCPProjectsSettingsModel.isHomeDirectory(home + "/Projects"))
    }

    @Test func nestedRootsSaveButWholeDiskRootIsRefusedBeforeTheKeyIsTouched() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)

        var outer = model.draftForNewProject()
        outer.name = "Monorepo"
        outer.workspaceRoots = ["/work/monorepo"]
        var inner = model.draftForNewProject()
        inner.name = "Monorepo API"
        inner.workspaceRoots = ["/work/monorepo/api"]
        #expect(model.save(outer))
        #expect(model.save(inner))
        #expect(try store.mcpProjects().count == 2)

        let writesBefore = box.writeCount
        var disk = model.draftForNewProject()
        disk.name = "Everything"
        disk.workspaceRoots = ["/work/other", "/private/tmp/../.."]
        #expect(model.save(disk) == false)
        #expect(model.errorMessage == L("A workspace root cannot be the whole disk."))
        #expect(try store.mcpProject(id: disk.id) == nil)
        #expect(box.writeCount == writesBefore)
    }

    /// Two projects with the same folder tie for every workspace inside it,
    /// and the helper then serves neither. The comparison follows symbolic
    /// links and drops a trailing slash, as the store and the helper do.
    @Test func aWorkspaceFolderAnotherProjectUsesIsRefusedBeforeTheKeyIsTouched() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout", isDirectory: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        billing.workspaceRoots = ["/work/billing", checkout.path]
        #expect(model.save(billing))
        let keyBefore = try #require(box.data)
        let writesBefore = box.writeCount

        for root in ["/work/billing/", alias.path] {
            var staging = model.draftForNewProject()
            staging.name = "Staging \(root)"
            staging.workspaceRoots = ["/work/staging", root]
            #expect(model.save(staging) == false)
            #expect(model.errorMessage == L("Another project already uses the workspace folder \(root). Agents working there would get neither project."))
            #expect(try store.mcpProjects().map(\.id) == [billing.id])
            #expect(box.data == keyBefore)
            #expect(box.writeCount == writesBefore)
        }
    }

    @Test func snippetsAbsentWithoutBundledHelper() throws {
        let (store, _, _) = try makeStore()
        // The test runner's main bundle never contains the helper, so the
        // default lookup must find nothing.
        let model = MCPProjectsSettingsModel(store: store, keyStore: KeyBox().keyStore)
        #expect(model.configurationSnippets(project: UUID()).isEmpty)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-helper-lookup-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Helpers", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(MCPProjectsSettingsModel.bundledHelperURL(in: bundle) == nil)

        let helper = bundle.appendingPathComponent("Contents/Helpers/berrydb-mcp")
        try Data().write(to: helper)
        #expect(MCPProjectsSettingsModel.bundledHelperURL(in: bundle)?.path == helper.path)
    }

    @Test func snippetsQuoteTheHelperPath() throws {
        let (store, _, _) = try makeStore()
        let helper = URL(fileURLWithPath: "/Applications/Berry DB.app/Contents/Helpers/berrydb-mcp")
        let model = makeModel(store, KeyBox(), helperURL: helper)
        var draft = model.draftForNewProject()
        draft.id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        draft.name = "Billing"
        #expect(model.save(draft))

        let snippets = model.configurationSnippets(project: draft.id)

        let quoted = "'/Applications/Berry DB.app/Contents/Helpers/berrydb-mcp'"
        let explicit = " --project 6f9619ff-8b86-d011-b42d-00c04fc964ff"
        #expect(Array(snippets.map(\.text).prefix(6)) == [
            "claude mcp add --scope user berrydb -- \(quoted)",
            "codex mcp add berrydb -- \(quoted)",
            "agy mcp add berrydb -- \(quoted)",
            "claude mcp add --scope user berrydb -- \(quoted)\(explicit)",
            "codex mcp add berrydb -- \(quoted)\(explicit)",
            "agy mcp add berrydb -- \(quoted)\(explicit)",
        ])
        #expect(Array(snippets.map(\.host).prefix(3)) == ["Claude Code", "Codex", "Antigravity"])
        // The pinned entries are installed at the same user scope, so their
        // label must not read as a narrower scope.
        #expect(Array(snippets.map(\.host)[3 ..< 6])
            == ["Claude Code", "Codex", "Antigravity"].map { L("\($0), always this project") })
        #expect(Array(snippets.map(\.caption).prefix(6)) == Array(repeating: nil, count: 6))
    }

    @Test func pinnedSnippetsOnlyForASavedProject() throws {
        let (store, _, _) = try makeStore()
        let helper = URL(fileURLWithPath: "/Applications/BerryDB.app/Contents/Helpers/berrydb-mcp")
        let model = makeModel(store, KeyBox(), helperURL: helper)
        var draft = model.draftForNewProject()
        draft.name = "Billing"

        #expect(!model.isSaved(draft.id))
        let unsaved = model.configurationSnippets(project: draft.id)
        #expect(unsaved.count == 3)
        #expect(!unsaved.contains { $0.text.contains("--project") })

        #expect(model.save(draft))
        #expect(model.isSaved(draft.id))
        let saved = model.configurationSnippets(project: draft.id)
        #expect(saved.count == 8)
        #expect(saved.filter { $0.text.hasSuffix("--project \(draft.id.uuidString.lowercased())") }.count == 3)
    }

    /// Inside POSIX single quotes every character is literal, including
    /// `"`, `\`, `$`, a backtick and the `!` that bash and zsh expand inside
    /// double quotes in an interactive shell; only `'` itself has to close
    /// the quotes, be escaped, and reopen them.
    @Test func snippetsQuoteTheHelperPathInSingleQuotes() throws {
        let (store, _, _) = try makeStore()
        let helper = URL(fileURLWithPath: #"/Users/a"b/$HOME/`x`/it's!!/back\slash/berrydb-mcp"#)
        let model = makeModel(store, KeyBox(), helperURL: helper)

        let first = try #require(model.configurationSnippets(project: UUID()).first)

        #expect(first.text == #"claude mcp add --scope user berrydb -- '/Users/a"b/$HOME/`x`/it'\''s!!/back\slash/berrydb-mcp'"#)
    }

    // MARK: Per-repository entries

    private static let claudeRepositoryCaption = L("Run it in the repository’s top folder. It writes .mcp.json there, which can be committed. Once you approve the entry in Claude Code, Claude Code uses it in this repository instead of a user-level berrydb entry; until then, it uses the user-level entry.")
    private static let codexRepositoryCaption = L("Add it to .codex/config.toml in the repository. Codex reads that file only once the project is trusted, and there it takes precedence over the user-level berrydb entry.")

    /// The entries name the project by its saved name, so a committed file
    /// keeps working in every clone and for a teammate whose project has
    /// the same name.
    @Test func aSavedProjectGetsPerRepositoryEntriesThatNameIt() throws {
        let (store, _, _) = try makeStore()
        let helper = URL(fileURLWithPath: "/Applications/Berry DB.app/Contents/Helpers/berrydb-mcp")
        let model = makeModel(store, KeyBox(), helperURL: helper)
        let billing = try savedDraft(named: "  Billing API ", in: model)

        let entries = Array(model.configurationSnippets(project: billing.id).suffix(2))

        #expect(entries == [
            MCPProjectsSettingsModel.AgentSetupEntry(
                host: L("\("Claude Code"), this repository"),
                text: "claude mcp add --scope project berrydb -- '/Applications/Berry DB.app/Contents/Helpers/berrydb-mcp' --project 'Billing API'",
                caption: Self.claudeRepositoryCaption
            ),
            MCPProjectsSettingsModel.AgentSetupEntry(
                host: L("\("Codex"), this repository"),
                text: #"""
                [mcp_servers.berrydb]
                command = "/Applications/Berry DB.app/Contents/Helpers/berrydb-mcp"
                args = ["--project", "Billing API"]
                """#,
                caption: Self.codexRepositoryCaption
            ),
        ])
    }

    /// The name and the helper path are written as given, inside the
    /// quoting each format needs: POSIX single quotes for the command, TOML
    /// basic strings for the Codex file.
    @Test func perRepositoryEntriesQuoteTheNameForTheShellAndForTOML() throws {
        let (store, _, _) = try makeStore()
        let helper = URL(fileURLWithPath: #"/Users/a"b/it's!/back\slash/berrydb-mcp"#)
        let model = makeModel(store, KeyBox(), helperURL: helper)
        let draft = try savedDraft(named: "a\"b\\c $HOME `x` it's !! y\nz", in: model)

        let entries = model.configurationSnippets(project: draft.id).suffix(2).map(\.text)

        #expect(entries.first == #"claude mcp add --scope project berrydb -- '/Users/a"b/it'\''s!/back\slash/berrydb-mcp' --project 'a"b\c $HOME `x` it'\''s !! y"#
            + "\n" + #"z'"#)
        #expect(entries.last == #"""
            [mcp_servers.berrydb]
            command = "/Users/a\"b/it's!/back\\slash/berrydb-mcp"
            args = ["--project", "a\"b\\c $HOME `x` it's !! y\nz"]
            """#)
    }

    /// TOML 1.0 basic strings escape `"` and `\` and every control
    /// character, with the short form where one exists
    /// (https://toml.io/en/v1.0.0#string).
    @Test func tomlQuotingEscapesQuotesBackslashesAndControlCharacters() {
        #expect(MCPProjectsSettingsModel.tomlQuoted("Billing API") == #""Billing API""#)
        #expect(MCPProjectsSettingsModel.tomlQuoted(#"a"b\c $x `y`"#) == #""a\"b\\c $x `y`""#)
        #expect(MCPProjectsSettingsModel.tomlQuoted("\u{08}\t\n\u{0C}\r") == #""\b\t\n\f\r""#)
        #expect(MCPProjectsSettingsModel.tomlQuoted("a\r\nb") == #""a\r\nb""#)
        #expect(MCPProjectsSettingsModel.tomlQuoted("\u{00}\u{1B}\u{1F}\u{7F}") == #""\u0000\u001B\u001F\u007F""#)
        #expect(MCPProjectsSettingsModel.tomlQuoted("Café ☕") == #""Café ☕""#)
    }

    @Test func checklistRowShowsDriverAndGroupSoSameNamedProfilesDiffer() {
        let local = ConnectionProfile(driverID: "postgres", name: "Berry DA Tool")
        let remote = ConnectionProfile(
            driverID: "postgres",
            name: "Berry DA Tool",
            groupName: "Production Remote Server",
            envColor: "production"
        )

        let localDetail = MCPProjectsSettingsModel.connectionRowDetail(for: local)
        let remoteDetail = MCPProjectsSettingsModel.connectionRowDetail(for: remote)

        #expect(localDetail.text == "postgres")
        #expect(remoteDetail.text == "postgres · Production Remote Server")
        #expect(localDetail != remoteDetail)
    }

    @Test func checklistRowOmitsABlankGroupName() {
        let blank = ConnectionProfile(driverID: "mysql", name: "Reporting", groupName: "  ")
        let padded = ConnectionProfile(driverID: "mysql", name: "Reporting", groupName: " Staging ")

        #expect(MCPProjectsSettingsModel.connectionRowDetail(for: blank).text == "mysql")
        #expect(MCPProjectsSettingsModel.connectionRowDetail(for: padded).text == "mysql · Staging")
    }

    @Test func checklistRowFlagsOnlyTheProductionLabel() {
        func isProduction(_ envColor: String?) -> Bool {
            let profile = ConnectionProfile(driverID: "postgres", name: "Orders", envColor: envColor)
            return MCPProjectsSettingsModel.connectionRowDetail(for: profile).isProduction
        }

        #expect(isProduction("production"))
        #expect(!isProduction(nil))
        #expect(!isProduction("staging"))
        #expect(!isProduction(""))
    }

    @Test func severalChosenFoldersAreAllAdded() {
        let result = MCPProjectsSettingsModel.addingRoots(
            ["/work/billing", "/work/billing-api", "/work/ledger"],
            to: ["/work/existing"]
        )

        #expect(result.roots == ["/work/existing", "/work/billing", "/work/billing-api", "/work/ledger"])
        #expect(result.rejections.isEmpty)
    }

    @Test func aRejectedFolderIsReportedWithoutDroppingTheAcceptedOnes() {
        let result = MCPProjectsSettingsModel.addingRoots(["/work/billing", "/", "/work/ledger"], to: [])

        #expect(result.roots == ["/work/billing", "/work/ledger"])
        #expect(result.rejections == ["/: " + L("A workspace root cannot be the whole disk.")])
    }

    @Test func everyRejectedFolderGetsItsOwnLine() {
        let result = MCPProjectsSettingsModel.addingRoots(["/", "relative/path"], to: ["/work/existing"])

        #expect(result.roots == ["/work/existing"])
        #expect(result.rejections == [
            "/: " + L("A workspace root cannot be the whole disk."),
            "relative/path: " + L("A workspace root must be an absolute path."),
        ])
    }

    @Test func foldersAlreadyInTheDraftOrRepeatedInTheSelectionAreAddedOnce() {
        let result = MCPProjectsSettingsModel.addingRoots(
            ["/work/billing", "/work/billing/", "/work/ledger", "/work/ledger"],
            to: ["/work/billing"]
        )

        #expect(result.roots == ["/work/billing", "/work/ledger"])
        #expect(result.rejections.isEmpty)
    }

    // MARK: Unique names

    private static let duplicateName = L("Another project already uses this name. Agent entries can select a project by its name.")

    @Test func aNameAnotherProjectUsesIsRefusedBeforeTheKeyIsTouched() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        #expect(model.save(billing))
        let keyBefore = try #require(box.data)
        let writesBefore = box.writeCount

        var duplicate = model.draftForNewProject()
        duplicate.name = "  BILLING "
        #expect(model.save(duplicate) == false)

        #expect(model.errorMessage == Self.duplicateName)
        #expect(try store.mcpProjects().map(\.id) == [billing.id])
        #expect(box.data == keyBefore)
        #expect(box.writeCount == writesBefore)
    }

    @Test func renamingOntoAnotherProjectsNameIsRefusedButRecasingItsOwnIsNot() throws {
        let (store, _, _) = try makeStore()
        let model = makeModel(store, KeyBox())
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        var analytics = model.draftForNewProject()
        analytics.name = "Analytics"
        #expect(model.save(billing))
        #expect(model.save(analytics))

        var renamed = try #require(model.draft(for: analytics.id))
        renamed.name = "billing"
        #expect(model.save(renamed) == false)
        #expect(model.errorMessage == Self.duplicateName)
        #expect(try store.mcpProject(id: analytics.id)?.name == "Analytics")

        var recased = try #require(model.draft(for: billing.id))
        recased.name = "BILLING"
        #expect(model.save(recased))
        #expect(try store.mcpProject(id: billing.id)?.name == "BILLING")
    }

    /// The helper reads a `--project` value shaped like a UUID as an ID, so
    /// an agent entry naming such a project could never select it, and
    /// could select another project whose ID that is.
    @Test func aNameShapedLikeAProjectIDIsRefusedBeforeTheKeyIsTouched() throws {
        let (store, _, _) = try makeStore()
        let box = KeyBox()
        let model = makeModel(store, box)
        var billing = model.draftForNewProject()
        billing.name = "Billing"
        #expect(model.save(billing))
        let keyBefore = try #require(box.data)
        let writesBefore = box.writeCount
        let message = L("A project name cannot have the form of a project ID.")

        var shapedLikeAnID = model.draftForNewProject()
        shapedLikeAnID.name = " 6f9619ff-8b86-d011-b42d-00c04fc964ff\n"
        #expect(model.save(shapedLikeAnID) == false)
        #expect(model.errorMessage == message)
        var renamed = try #require(model.draft(for: billing.id))
        renamed.name = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        #expect(model.save(renamed) == false)
        #expect(model.errorMessage == message)

        #expect(try store.mcpProjects().map(\.name) == ["Billing"])
        #expect(box.data == keyBefore)
        #expect(box.writeCount == writesBefore)

        var almost = model.draftForNewProject()
        almost.name = "6F9619FF-8B86-D011-B42D"
        #expect(model.save(almost))
    }

    @Test func aNameIsSavedTrimmed() throws {
        let (store, _, _) = try makeStore()
        let model = makeModel(store, KeyBox())
        var draft = model.draftForNewProject()
        draft.name = "  Billing \n"

        #expect(model.save(draft))

        #expect(try store.mcpProject(id: draft.id)?.name == "Billing")
    }

    /// An agent entry can name the project with `--project <name>`, so a
    /// rename that the name rule does not absorb leaves every such entry
    /// selecting nothing.
    @Test func renamingASavedProjectWarnsThatEntriesNamingTheOldNameStopSelectingIt() throws {
        let (store, _, _) = try makeStore()
        let model = makeModel(store, KeyBox())
        let billing = try savedDraft(named: "Billing", in: model)
        let notice = L("Agent entries that name “\("Billing")” stop selecting this project until they use the new name.")

        var renamed = billing
        renamed.name = "Billing API"
        #expect(model.renameNotice(for: renamed) == notice)
        var recased = billing
        recased.name = " BILLING "
        #expect(model.renameNotice(for: recased) == nil)
        #expect(model.renameNotice(for: billing) == nil)
        var cleared = billing
        cleared.name = "  "
        #expect(model.renameNotice(for: cleared) == nil)
        var unsaved = model.draftForNewProject()
        unsaved.name = "Ledger"
        #expect(model.renameNotice(for: unsaved) == nil)
    }

    /// A saved project called `name`, as the editor opens it.
    private func savedDraft(named name: String, in model: MCPProjectsSettingsModel) throws -> MCPProjectsSettingsModel.Draft {
        var draft = model.draftForNewProject()
        draft.name = name
        #expect(model.save(draft))
        return try #require(model.draft(for: draft.id))
    }
}
