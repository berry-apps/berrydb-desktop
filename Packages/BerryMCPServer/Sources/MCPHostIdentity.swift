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
    public static func sanitized(_ raw: String) -> String {
        let kept = raw.filter { character in
            !character.isNewline
                && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        let capped = String(kept.trimmingCharacters(in: .whitespaces).prefix(64)).trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? "unknown" : capped
    }
}
