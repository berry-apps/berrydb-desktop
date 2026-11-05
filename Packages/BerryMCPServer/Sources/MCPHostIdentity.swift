import Foundation
import Synchronization

/// The name the host gave in `initialize`, as the audit log records it.
/// Written once by the initialize hook and read by tool calls on other tasks.
public final class MCPHostIdentity: Sendable {
    private let clientName = Mutex<String?>(nil)

    public init() {}

    /// "unknown" until the host has initialized, since a request may be
    /// served before `initialize` arrives.
    public var name: String {
        clientName.withLock { $0 } ?? "unknown"
    }

    public func set(clientName name: String) {
        let sanitized = Self.sanitized(name)
        clientName.withLock { $0 = sanitized }
    }

    /// The host chooses this text freely. Line breaks and other control
    /// characters are removed so a record stays on one line of the audit
    /// file, and the length is capped so a host cannot inflate every record.
    /// The cap counts unicode scalars as well as characters: one character
    /// can carry any number of combining marks, so a character cap alone
    /// bounds nothing.
    public static func sanitized(_ raw: String) -> String {
        let kept = raw.filter { character in
            !character.isNewline
                && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        let characters = String(kept.trimmingCharacters(in: .whitespaces).prefix(64))
        let scalars = String(String.UnicodeScalarView(characters.unicodeScalars.prefix(64)))
        let capped = scalars.trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "unknown" : capped
    }
}
