import BerryStore
import Foundation

/// The outcome of choosing the project a helper process serves. Only
/// `.selected` names a project; `.noMatch` and `.ambiguous` leave the helper
/// serving no project, and `.ambiguous` lists the tied candidates instead of
/// picking one. Selection is not authorization (see `MCPProjectSelector`).
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
///
/// A workspace root that canonicalizes to `/` is never used for matching: it
/// would select that project for every workspace on the machine. A project
/// with `/` among its roots still matches through any other root it lists.
public struct MCPProjectSelector: Sendable {
    private let canonicalize: @Sendable (String) -> String

    /// - Parameter canonicalize: How a path is resolved before comparison.
    ///   Defaults to `canonicalPath`; tests substitute an identity function
    ///   to assert on path containment without touching the file system.
    public init(canonicalize: @escaping @Sendable (String) -> String = MCPProjectSelector.canonicalPath) {
        self.canonicalize = canonicalize
    }

    /// Selects the project whose `workspaceRoots` contain `workspace`.
    ///
    /// Both sides are canonicalized, then compared as path components: a
    /// root matches only at a component boundary, so `/work/a` does not
    /// match a workspace at `/work/ab`. When more than one root matches, the
    /// longest (most specific) root wins. When the longest matching root is
    /// tied in length across two or more distinct projects, the result is
    /// `.ambiguous`, never a silent pick of either one. Covers enabled and
    /// disabled projects alike; the resolver is what reports
    /// `projectDisabled`.
    public func select(workspace: String, projects: [MCPProject]) -> MCPProjectSelection {
        let target = components(canonicalize(workspace))
        var best: (length: Int, ids: [UUID]) = (0, [])
        for project in projects {
            for root in project.workspaceRoots {
                let canonicalRoot = canonicalize(root)
                guard canonicalRoot != "/" else { continue }
                let rootComponents = components(canonicalRoot)
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

    /// Selects `id` when it names one of `projects`, regardless of its
    /// `workspaceRoots` or `isEnabled` state — an explicit choice bypasses
    /// workspace matching entirely. The resolver is what reports
    /// `projectDisabled` for a disabled project selected this way.
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
