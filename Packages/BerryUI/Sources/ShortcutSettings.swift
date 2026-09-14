import AppKit
import BerryStore
import SwiftUI

/// Customizable menu shortcuts: every remappable action, its default
/// combo, and the persisted overrides. Editor-internal keys (⌘↩ run, ⌃Space
/// completion, ↑↓↩⎋ in the popup) stay fixed.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case run
    case format
    case saveSQL
    case toggleComment
    case newSQLTab
    case splitEditor
    case history
    case savedQueries
    case refreshSchema
    case aiAssistant
    case goToTable
    case commandPalette

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .run: L("Run")
        case .format: L("Format")
        case .saveSQL: L("Save SQL")
        case .toggleComment: L("Toggle Comment")
        case .newSQLTab: L("New SQL Tab")
        case .splitEditor: L("Split Editor")
        case .history: L("History")
        case .savedQueries: L("Saved Queries")
        case .refreshSchema: L("Refresh Schema")
        case .aiAssistant: L("AI Assistant")
        case .goToTable: L("Go to Table…")
        case .commandPalette: L("Command Palette")
        }
    }

    var defaultShortcut: StoredShortcut {
        switch self {
        case .run: StoredShortcut(key: "r", modifiers: ["cmd"])
        case .format: StoredShortcut(key: "f", modifiers: ["cmd", "ctrl"])
        case .saveSQL: StoredShortcut(key: "s", modifiers: ["cmd"])
        case .toggleComment: StoredShortcut(key: "/", modifiers: ["cmd"])
        case .newSQLTab: StoredShortcut(key: "t", modifiers: ["cmd"])
        case .splitEditor: StoredShortcut(key: "\\", modifiers: ["cmd"])
        case .history: StoredShortcut(key: "y", modifiers: ["cmd"])
        case .savedQueries: StoredShortcut(key: "b", modifiers: ["cmd"])
        case .refreshSchema: StoredShortcut(key: "r", modifiers: ["cmd", "shift"])
        case .aiAssistant: StoredShortcut(key: "j", modifiers: ["cmd"])
        case .goToTable: StoredShortcut(key: "p", modifiers: ["cmd"])
        case .commandPalette: StoredShortcut(key: "k", modifiers: ["cmd"])
        }
    }
}

/// One key combo, persistable. `key` is a single character.
public struct StoredShortcut: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains("cmd") { result.insert(.command) }
        if modifiers.contains("shift") { result.insert(.shift) }
        if modifiers.contains("opt") { result.insert(.option) }
        if modifiers.contains("ctrl") { result.insert(.control) }
        return result
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }

    var display: String {
        var text = ""
        if modifiers.contains("ctrl") { text += "⌃" }
        if modifiers.contains("opt") { text += "⌥" }
        if modifiers.contains("shift") { text += "⇧" }
        if modifiers.contains("cmd") { text += "⌘" }
        return text + key.uppercased()
    }
}

/// Persisted shortcut overrides. `berry.shortcutsRev` bumps on every change so
/// the menu (`WorkspaceCommands`) rebuilds with the new combos.
@MainActor
public final class ShortcutStore {
    public static let shared = ShortcutStore()
    private let defaults = UserDefaults.standard
    private let storageKey = "berry.shortcuts"

    private init() {}

    private var overrides: [String: StoredShortcut] {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([String: StoredShortcut].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: storageKey)
            defaults.set(defaults.integer(forKey: "berry.shortcutsRev") + 1, forKey: "berry.shortcutsRev")
        }
    }

    public func shortcut(for action: ShortcutAction) -> StoredShortcut {
        overrides[action.rawValue] ?? action.defaultShortcut
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    public func set(_ shortcut: StoredShortcut, for action: ShortcutAction) {
        var current = overrides
        current[action.rawValue] = shortcut
        overrides = current
    }

    public func reset(_ action: ShortcutAction) {
        var current = overrides
        current[action.rawValue] = nil
        overrides = current
    }

    public func resetAll() {
        overrides = [:]
    }
}

/// The Settings pane (⌘) for remapping shortcuts: click a combo to
/// record the next keystroke; Esc cancels; the arrow restores the default.
public struct ShortcutSettingsView: View {
    @AppStorage("berry.shortcutsRev") private var revision = 0
    @State private var recordingAction: ShortcutAction?
    @State private var monitor: Any?
    @State private var showResetDataConfirm = false
    @State private var resetDataError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Keyboard Shortcuts")).font(.headline)
            Form {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button {
                            recordingAction == action ? stopRecording() : startRecording(action)
                        } label: {
                            Text(recordingAction == action
                                 ? L("Press keys…")
                                 : ShortcutStore.shared.shortcut(for: action).display)
                                .font(.system(.body, design: .monospaced))
                                .frame(minWidth: 76)
                        }
                        .tint(recordingAction == action ? .orange : nil)
                        Button {
                            ShortcutStore.shared.reset(action)
                            revision += 0 // @AppStorage already bumped by the store
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!ShortcutStore.shared.isCustomized(action))
                        .help(L("Reset to default"))
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text(L("Editor keys (⌘↩ run, ⌃Space completion) are fixed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Reset All")) { ShortcutStore.shared.resetAll() }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Local Data")).font(.subheadline).fontWeight(.semibold)
                HStack(alignment: .top) {
                    Text(L("Deletes all saved queries, connection profiles, and AI chat history stored on this Mac. BerryDB will quit — reopen it to start fresh."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Reset Local Data…"), role: .destructive) { showResetDataConfirm = true }
                        .controlSize(.small)
                }
                if let resetDataError {
                    Text(resetDataError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(16)
        .frame(width: 460, height: 560)
        .onDisappear { stopRecording() }
        // Reading `revision` keeps this view refreshing on store changes.
        .id(revision)
        .confirmationDialog(
            L("Reset local data?"),
            isPresented: $showResetDataConfirm,
            titleVisibility: .visible
        ) {
            Button(L("Reset & Quit"), role: .destructive) { resetLocalData() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This permanently deletes all saved queries, connection profiles, and AI chat history on this Mac. This cannot be undone."))
        }
    }

    /// Deletes `store.sqlite` (+ WAL sidecar files) and quits — the running
    /// process's already-open connections keep working against the now-
    /// unlinked file until they close as part of quitting; a fresh
    /// `store.sqlite` is created the next time the app launches
    /// (`BerryStore.open()`). Does not touch `known_hosts`, `license.blob`,
    /// `backups/`, or Keychain secrets — those are separate concerns.
    private func resetLocalData() {
        do {
            let storeURL = try BerryStore.defaultStoreURL()
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] {
                let path = storeURL.path + suffix
                if fm.fileExists(atPath: path) {
                    try fm.removeItem(atPath: path)
                }
            }
            NSApplication.shared.terminate(nil)
        } catch {
            resetDataError = error.localizedDescription
        }
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { return nil } // Esc cancels
            guard let raw = event.charactersIgnoringModifiers?.lowercased(),
                  let character = raw.first, !character.isWhitespace else { return nil }
            var modifiers: [String] = []
            if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
            if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
            if event.modifierFlags.contains(.option) { modifiers.append("opt") }
            if event.modifierFlags.contains(.control) { modifiers.append("ctrl") }
            // Menu shortcuts need at least one chording modifier.
            guard !modifiers.isEmpty else { return nil }
            ShortcutStore.shared.set(
                StoredShortcut(key: String(character), modifiers: modifiers),
                for: action
            )
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingAction = nil
    }
}
