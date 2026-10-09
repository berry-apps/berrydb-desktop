import AppKit
import BerryStore
import SwiftUI

/// Sizes of the Settings pane and of the editor sheet presented over it. The
/// sheet must stay inside the Settings window, whose size follows the pane;
/// at 620 points the sheet ran past the window's bottom edge. At the sizes
/// below the sheet fits in the running app and the footer buttons stay in
/// view while the form scrolls.
private enum MCPSettingsLayout {
    static let paneWidth: CGFloat = 560
    static let paneHeight: CGFloat = 560
    static let sheetWidth: CGFloat = 540
    static let sheetHeight: CGFloat = 500
}

/// The "AI Agents" settings tab: the MCP projects that coding agents reach
/// through the `berrydb-mcp` helper. Opens its own store connection
/// the first time the tab appears; the store file allows several
/// connections, the same way the AI panel keeps its own.
public struct MCPProjectsSettingsView: View {
    @State private var model: MCPProjectsSettingsModel?
    @State private var openError: String?

    public init() {}

    public var body: some View {
        Group {
            if let model {
                MCPProjectsPane(model: model)
            } else if let openError {
                Text(openError)
                    .foregroundStyle(.red)
                    .padding(16)
            } else {
                ProgressView()
            }
        }
        .frame(width: MCPSettingsLayout.paneWidth, height: MCPSettingsLayout.paneHeight)
        .onAppear(perform: openOrReload)
    }

    /// Reloads on every appearance so connections saved in the main window
    /// since the tab was last shown are listed.
    private func openOrReload() {
        if let model {
            model.reload()
            return
        }
        do {
            model = MCPProjectsSettingsModel(store: try BerryStore.open())
        } catch {
            openError = L("The BerryDB store could not be opened: \(error.localizedDescription)")
        }
    }
}

/// The project being edited in the sheet; `isNew` hides Delete.
private struct MCPProjectEditorRequest: Identifiable {
    var draft: MCPProjectsSettingsModel.Draft
    var isNew: Bool
    var id: UUID { draft.id }
}

private struct MCPProjectsPane: View {
    @ObservedObject var model: MCPProjectsSettingsModel
    @State private var editing: MCPProjectEditorRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("AI Agents")).font(.headline)
            Text(L("Coding agents read schema and graph metadata of the connections assigned to a project through the berrydb-mcp helper. The folder an agent works in selects the project."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The helper declares no `listChanged` tools capability, so it
            // sends no list-changed notification
            // (https://modelcontextprotocol.io/specification/2025-11-25/server/tools#capabilities),
            // and a host that keeps the tool list it fetched at session start
            // never learns that a project became available.
            Text(L("An agent can keep the tool list it loaded when its session started. If it does not see BerryDB’s tools after a change here, start a new agent session."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(model.projects) { project in
                row(project)
            }
            .overlay {
                if model.projects.isEmpty {
                    Text(L("No MCP projects yet")).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(L("New Project…")) {
                    model.errorMessage = nil
                    editing = MCPProjectEditorRequest(draft: model.draftForNewProject(), isNew: true)
                }
                Spacer()
            }
            if let error = model.errorMessage, editing == nil {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .sheet(item: $editing) { request in
            MCPProjectEditorSheet(model: model, draft: request.draft, isNew: request.isNew)
        }
    }

    private func row(_ project: MCPProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(L("Connections: \(project.profiles.count)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.unverifiedProjectIDs.contains(project.id) {
                // The stored enabled flag is unverified. The helper still
                // selects the project and serves its metadata, with live
                // reads off and integrity reported as unavailable. The
                // editing copy opens disabled, and saving keeps it disabled
                // unless Enabled is turned on first, as the editor says.
                Text(L("Not verified — save to confirm"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(project.isEnabled ? L("Enabled") : L("Disabled"))
                    .font(.caption)
                    .foregroundStyle(project.isEnabled ? Color.green : Color.secondary)
            }
            Button(L("Edit…")) { edit(project) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { edit(project) }
    }

    private func edit(_ project: MCPProject) {
        model.errorMessage = nil
        guard let draft = model.draft(for: project.id) else { return }
        editing = MCPProjectEditorRequest(draft: draft, isNew: false)
    }
}

private struct MCPProjectEditorSheet: View {
    @ObservedObject var model: MCPProjectsSettingsModel
    @State var draft: MCPProjectsSettingsModel.Draft
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rootError: String?
    @State private var confirmDelete = false
    /// The outcome of the last link, one entry per chosen folder.
    @State private var linkResults: [MCPRepositoryLinkResult] = []
    /// Folders whose existing file the replace dialog lists, in the order
    /// their `needsOverwrite` entries appear in `linkResults`.
    @State private var foldersToReplace: [URL] = []
    @State private var confirmReplace = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                TextField(L("Name"), text: $draft.name)
                if let notice = model.renameLinkNotice(for: draft) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L("Enabled"), isOn: $draft.isEnabled)
                if model.unverifiedProjectIDs.contains(draft.id) {
                    Text(L("This project opened disabled because its saved settings could not be verified. Turn Enabled on and save to confirm them."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                rootsSection
                repositoryLinksSection
                connectionsSection
                snippetsSection
            }
            .formStyle(.grouped)
            .confirmationDialog(L("Replace existing link files?"), isPresented: $confirmReplace, titleVisibility: .visible) {
                Button(L("Replace"), role: .destructive, action: replaceConfirmedLinks)
                Button(L("Cancel"), role: .cancel) { foldersToReplace = [] }
            } message: {
                Text(replaceMessage)
            }
            Divider()
            footer
        }
        .frame(width: MCPSettingsLayout.sheetWidth, height: MCPSettingsLayout.sheetHeight)
        .confirmationDialog(L("Delete this MCP project?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                if model.delete(id: draft.id) { dismiss() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Coding agents working in its folders will no longer find a project."))
        }
    }

    private var header: some View {
        HStack {
            Text(isNew ? L("New MCP Project") : L("Edit MCP Project")).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if !isNew {
                    Button(L("Delete…"), role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) {
                    // Clears an error left by a failed save and refreshes the
                    // verification marks after a key that save may already
                    // have rotated. A successful Save or Delete reloads
                    // inside the model instead, so each path reloads once.
                    model.reload()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    if model.save(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private var rootsSection: some View {
        Section(L("Workspace Folders")) {
            Text(L("Add every folder whose code uses these connections. Subfolders and worktrees inside a folder are included, unless a .berrydb.json in or above them decides first."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(draft.workspaceRoots, id: \.self) { root in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(root)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(root)
                        Spacer()
                        Button {
                            draft.workspaceRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Remove"))
                        .accessibilityLabel(L("Remove"))
                    }
                    if MCPProjectsSettingsModel.isHomeDirectory(root) {
                        Text(L("This is your home folder: every repository inside it selects this project, unless a .berrydb.json or another project’s more specific folder decides first."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Button(L("Add Folder…"), action: addFolder)
            if let rootError {
                Text(rootError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var repositoryLinksSection: some View {
        Section(L("Repository Links")) {
            Text(L("Writes .berrydb.json naming this project. Commit it so clones and teammates select a project with the same name in their BerryDB, or add it to .gitignore to keep it local."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A link file can name any project and decides its workspace
            // before the registered folders, so a repository from someone
            // else selects this project as surely as one linked here.
            Text(L("Any repository whose .berrydb.json names this project, including one cloned from someone else, selects it for agents working there."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let unavailable = model.repositoryLinkUnavailableReason(for: draft)
            Button(L("Link Repository…"), action: chooseRepositories)
                .disabled(unavailable != nil)
            if let unavailable {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(linkResults.enumerated()), id: \.offset) { _, result in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.outcome(of: result))
                        .font(.caption)
                        .foregroundStyle(Self.outcomeColor(of: result))
                        .fixedSize(horizontal: false, vertical: true)
                    if let warning = MCPProjectsSettingsModel.homeFolderLinkWarning(for: result) {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var connectionsSection: some View {
        Section(L("Connections")) {
            if model.profiles.isEmpty {
                Text(L("No saved connections yet.")).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                let detail = MCPProjectsSettingsModel.connectionRowDetail(for: profile)
                Toggle(isOn: membership(of: profile.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                            if detail.isProduction {
                                ProductionBadge()
                            }
                        }
                        Text(detail.text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(L("Schema and graph metadata of these connections becomes visible to coding agents you configure, and to their model providers."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var snippetsSection: some View {
        Section(L("Agent Setup")) {
            let snippets = model.configurationSnippets(project: draft.id)
            if let unavailable = model.agentSetupUnavailableReason {
                Text(unavailable)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Run one command once per agent; it adds an entry named berrydb to the agent’s user configuration. The shared entry works in every repository and selects the project from the agent’s folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isSaved(draft.id) {
                    Text(L("An entry marked “always this project” serves this project in every folder the agent works in, whatever .berrydb.json or workspace folders would select."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(snippets.enumerated()), id: \.offset) { _, snippet in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.host).font(.caption).fontWeight(.semibold)
                            Spacer()
                            Button(L("Copy")) { copy(snippet.text) }
                                .buttonStyle(.borderless)
                        }
                        Text(snippet.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func membership(of profileID: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.profileIDs.contains(profileID) },
            set: { isOn in
                if !isOn {
                    draft.profileIDs.removeAll { $0 == profileID }
                } else if !draft.profileIDs.contains(profileID) {
                    draft.profileIDs.append(profileID)
                }
            }
        )
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let addition = MCPProjectsSettingsModel.addingRoots(panel.urls.map(\.path), to: draft.workspaceRoots)
        draft.workspaceRoots = addition.roots
        rootError = addition.rejections.isEmpty ? nil : addition.rejections.joined(separator: "\n")
    }

    /// Links the chosen folders without replacing anything, then asks before
    /// replacing the files that are in the way.
    private func chooseRepositories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let folders = panel.urls
        linkResults = model.linkRepositories(folders, projectID: draft.id, overwrite: false)
        foldersToReplace = zip(folders, linkResults).compactMap { folder, result in
            guard case .needsOverwrite = result else { return nil }
            return folder
        }
        confirmReplace = !foldersToReplace.isEmpty
    }

    /// Relinks the listed folders with `overwrite` and puts each new result
    /// in place of the `needsOverwrite` entry it answers; both lists are in
    /// the same order.
    private func replaceConfirmedLinks() {
        var replaced = model.linkRepositories(foldersToReplace, projectID: draft.id, overwrite: true).makeIterator()
        linkResults = linkResults.map { result in
            guard case .needsOverwrite = result, let next = replaced.next() else { return result }
            return next
        }
        foldersToReplace = []
    }

    private var replaceMessage: String {
        let files = linkResults.compactMap { result -> String? in
            guard case let .needsOverwrite(path, existingProject) = result else { return nil }
            guard let existingProject else { return L("\(path) (could not be read as a link file)") }
            return L("\(path) (names “\(existingProject)”)")
        }
        return ([L("These files will be replaced:")] + files).joined(separator: "\n")
    }

    private static func outcome(of result: MCPRepositoryLinkResult) -> String {
        switch result {
        case let .written(path): L("Wrote \(path)")
        case let .unchanged(path): L("\(path) already links this project")
        case let .needsOverwrite(path, _): L("\(path) was not replaced")
        case let .rejected(path, reason): "\(path): \(reason)"
        }
    }

    private static func outcomeColor(of result: MCPRepositoryLinkResult) -> Color {
        switch result {
        case .written, .unchanged: .secondary
        case .needsOverwrite: .orange
        case .rejected: .red
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
