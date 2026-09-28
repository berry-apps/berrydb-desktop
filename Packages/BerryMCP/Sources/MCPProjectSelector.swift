import BerryStore
import Foundation

public enum MCPProjectSelection: Equatable, Sendable {
    case selected(UUID)
    case noMatch
    case ambiguous([UUID])
}

/// Chooses the project a helper process serves from the host's workspace.
///
/// Matching is by path containment on component boundaries after resolving
/// symlinks and the file system's own spelling of the path, so `/tmp/x`,
/// `/private/tmp/x/` and a differently cased path on a case-insensitive
/// volume select the same project. This is a convenience, not authorization
/// (spec §4): any project can also be named explicitly.
public struct MCPProjectSelector: Sendable {
    private let canonicalize: @Sendable (String) -> String

    public init(canonicalize: @escaping @Sendable (String) -> String = MCPProjectSelector.canonicalPath) {
        self.canonicalize = canonicalize
    }

    public func select(workspace: String, projects: [MCPProject]) -> MCPProjectSelection {
        let target = components(canonicalize(workspace))
        var best: (length: Int, ids: [UUID]) = (0, [])
        for project in projects {
            for root in project.workspaceRoots {
                let rootComponents = components(canonicalize(root))
                guard !rootComponents.isEmpty, target.starts(with: rootComponents) else { continue }
                if rootComponents.count > best.length {
                    best = (rootComponents.count, [project.id])
                } else if rootComponents.count == best.length, !best.ids.contains(project.id) {
                    best.ids.append(project.id)
                }
            }
        }
        switch best.ids.count {
        case 0: return .noMatch
        case 1: return .selected(best.ids[0])
        default: return .ambiguous(best.ids)
        }
    }

    public func select(explicit id: UUID, projects: [MCPProject]) -> MCPProjectSelection {
        projects.contains { $0.id == id } ? .selected(id) : .noMatch
    }

    /// Resolves symlinks and asks the file system for its canonical spelling,
    /// which also normalizes letter case on case-insensitive volumes. Paths
    /// that do not exist fall back to lexical standardization.
    public static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        if let canonical = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return canonical
        }
        return url.path
    }

    private func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
