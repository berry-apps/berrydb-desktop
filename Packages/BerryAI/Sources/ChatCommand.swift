import Foundation

/// A built-in chat command shown in the composer's "/" dropdown
/// (docs/superpowers/specs/2026-07-27-chat-command-dropdown-design.md).
/// This is discovery metadata only — dispatch (what actually happens when
/// the command runs) stays hand-written per command in `AISession.send(_:)`.
public struct ChatCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    /// Without the leading "/", e.g. "report".
    public let name: String
    /// Shown in the dropdown, e.g. "/report {message}".
    public let usageHint: String
    public let description: String

    public init(name: String, usageHint: String, description: String) {
        self.name = name
        self.usageHint = usageHint
        self.description = description
    }
}

/// The registry of built-in commands. Adding a new command: append one
/// `ChatCommand` here (for the dropdown to discover it), plus whatever
/// `hasPrefix("/<name> ")` branch its behavior needs in `AISession.send(_:)`.
public enum ChatCommands {
    public static let all: [ChatCommand] = [
        ChatCommand(
            name: "report",
            usageHint: "/report {message}",
            description: "File a bug report from this conversation."
        ),
    ]

    /// Commands whose name starts with `query` (case-insensitive). Empty
    /// query matches everything — used when the user has just typed "/".
    public static func matching(_ query: String) -> [ChatCommand] {
        guard !query.isEmpty else { return all }
        let needle = query.lowercased()
        return all.filter { $0.name.lowercased().hasPrefix(needle) }
    }
}
