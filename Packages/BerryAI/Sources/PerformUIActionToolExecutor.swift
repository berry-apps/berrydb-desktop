import Foundation

/// One action `perform_ui_action` can invoke — the exact same registry the
/// ⌘K command palette and menu bar already expose (`CommandPaletteEntry` in
/// BerryUI), re-described here without a BerryUI dependency (dependency
/// direction is one-way: BerryUI -> BerryAI, never the reverse).
public struct UIActionEntry {
    public let action: String
    public let title: String
    public let isEnabled: Bool
    public let perform: () -> Void

    public init(action: String, title: String, isEnabled: Bool, perform: @escaping () -> Void) {
        self.action = action
        self.title = title
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// Client-executed `perform_ui_action`:
/// AI Command Palette NL routing — maps a natural-language request onto one
/// of the same actions already reachable from ⌘K / the menu bar. Harmless by
/// construction: it can only invoke an existing UI action, never read or
/// change database data, so it needs no approval and no dedicated narrow
/// system prompt — the palette instead runs it through an ephemeral
/// `AISession` whose only registered tool is this one
/// (`AIPanelController.routeCommandPaletteQuery`), so there is nothing else
/// for the model to misuse regardless of system prompt.
@MainActor
public final class PerformUIActionToolExecutor: AIToolExecutor {
    /// Resolved fresh on every call — actions/gating flags change as the
    /// workspace's session/license/tabs change.
    private let currentEntries: () -> [UIActionEntry]
    /// Whether an action was actually invoked during this executor's
    /// lifetime, so the caller can decide to dismiss the palette without
    /// having to parse the model's natural-language reply.
    public private(set) var didPerform = false

    public init(currentEntries: @escaping () -> [UIActionEntry]) {
        self.currentEntries = currentEntries
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "perform_ui_action",
            description: "Navigate the BerryDB UI by intent instead of an exact menu item name — opens a panel/view or runs a quick action already reachable from the command palette (Cmd+K) or menu bar. Never reads or changes database data.",
            parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","description":"The action id to perform, from the list of currently available actions."}},"required":["action"]}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        executePerform(call)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return executePerform(call)
    }

    private func executePerform(_ call: AIToolCall) -> ToolOutcome {
        guard call.name == "perform_ui_action" else { return .failed("Unknown tool '\(call.name)'") }
        guard let action = call.args["action"], !action.isEmpty else { return .failed("Missing 'action'") }
        let entries = currentEntries()
        guard let entry = entries.first(where: { $0.action == action }) else {
            return .failed("Unknown action '\(action)'")
        }
        guard entry.isEnabled else {
            return .failed("'\(entry.title)' isn't available right now")
        }
        entry.perform()
        didPerform = true
        return .ok(#"{"performed":true}"#)
    }
}
