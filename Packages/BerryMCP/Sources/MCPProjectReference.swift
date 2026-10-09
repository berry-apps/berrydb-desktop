import Foundation

/// A project named on the helper's command line with `--project`: by its ID,
/// or by its name.
///
/// A name lets an agent entry that a repository commits keep selecting a
/// project in every clone and for every teammate whose project has the same
/// name; an ID is different in every store.
public enum MCPProjectReference: Equatable, Sendable {
    case id(UUID)
    /// Trimmed of surrounding whitespace and never empty. It selects the
    /// project whose name matches by `MCPProjectSelector.namesMatch`.
    case name(String)

    /// Parses a `--project` value. Surrounding whitespace is trimmed; the
    /// rest is an ID when `UUID(uuidString:)` accepts it and a name
    /// otherwise, so a value shaped like a UUID is only ever an ID, even
    /// when some project is named that way. Nil when nothing is left.
    public init?(argument: String) {
        let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let id = UUID(uuidString: value) {
            self = .id(id)
        } else {
            self = .name(value)
        }
    }
}
