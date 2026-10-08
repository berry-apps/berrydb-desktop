import AppKit
import BerryStore
import SwiftUI

/// The "AI Agents" settings tab: the MCP projects that coding agents reach
/// through the bundled `berrydb-mcp` helper. Opens its own store connection
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
        .frame(width: 560, height: 560)
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
                // reads off and integrity reported as unavailable; the
                // editing copy is disabled until the user saves it.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? L("New MCP Project") : L("Edit MCP Project")).font(.headline)
            Form {
                TextField(L("Name"), text: $draft.name)
                Toggle(L("Enabled"), isOn: $draft.isEnabled)
                rootsSection
                connectionsSection
                snippetsSection
            }
            .formStyle(.grouped)
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
        .padding(16)
        .frame(width: 540, height: 620)
        .confirmationDialog(L("Delete this MCP project?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                if model.delete(id: draft.id) { dismiss() }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Coding agents working in its folders will no longer find a project."))
        }
    }

    private var rootsSection: some View {
        Section(L("Workspace Folders")) {
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
                    }
                    if MCPProjectsSettingsModel.isHomeDirectory(root) {
                        Text(L("This is your home folder: every repository inside it selects this project unless another project has a more specific folder."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Button(L("Add Folder…"), action: addFolder)
            if let rootError {
                Text(rootError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var connectionsSection: some View {
        Section(L("Connections")) {
            if model.profiles.isEmpty {
                Text(L("No saved connections yet.")).foregroundStyle(.secondary)
            }
            ForEach(model.profiles) { profile in
                Toggle(isOn: membership(of: profile.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.name)
                        Text(profile.driverID).font(.caption).foregroundStyle(.secondary)
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
            if snippets.isEmpty {
                Text(L("The berrydb-mcp helper is not bundled in this build."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("Run one command once per agent; it adds an entry named berrydb to the agent’s user configuration. The shared entry works in every repository and selects the project from the agent’s folder."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isSaved(draft.id) {
                    Text(L("An entry marked “this project only” always serves this project, whichever folder the agent works in."))
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
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let message = MCPProjectsSettingsModel.validateRoot(url.path) {
            rootError = message
            return
        }
        rootError = nil
        let root = MCPProjectsSettingsModel.canonicalRoot(url.path)
        if !draft.workspaceRoots.contains(root) {
            draft.workspaceRoots.append(root)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
