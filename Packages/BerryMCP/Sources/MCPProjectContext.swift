import BerryStore
import Foundation

/// Which input decided the project a session serves. The raw values are
/// reported verbatim by the status tool.
public enum MCPSelectionSource: String, Codable, Sendable {
    case explicit
    case roots
    case workingDirectory = "working_directory"
}

/// Why a session serves no project. The raw values are reported verbatim by
/// the status tool.
public enum MCPUnconfiguredReason: String, Codable, Sendable {
    case noMatchingProject = "no_matching_project"
    case ambiguousProjects = "ambiguous_projects"
    case explicitProjectNotFound = "explicit_project_not_found"
    case projectDisabled = "project_disabled"
    case integrityUnavailable = "integrity_unavailable"
}

/// The project a session serves, or the reason it serves none.
public enum MCPProjectContext: Equatable, Sendable {
    case selected(MCPVerifiedProject, source: MCPSelectionSource)
    case unconfigured(MCPUnconfiguredReason, workspace: String?)
}

/// Decides which project a host session serves, independent of any wire
/// protocol: an explicit project id wins, then the host's workspace roots,
/// then the process working directory.
///
/// Selection is a convenience, not authorization: verification of the
/// selected project decides what is served. An unverifiable integrity tag
/// removes live reads but not selection: schema and graph metadata expose
/// nothing beyond what the store file already holds, so the resolved context
/// carries `projectTagValid` for the caller to report instead.
///
/// Roots that name different projects are ambiguous and are never resolved
/// by falling back to the working directory. Roots that match no project do
/// fall back, since a host may open a folder BerryDB does not know about.
public struct MCPProjectContextResolver: Sendable {
    private let loadProjects: @Sendable () throws -> [MCPProject]
    private let verify: @Sendable (UUID) throws -> MCPVerifiedProject?
    private let selector: MCPProjectSelector

    /// - Parameters:
    ///   - loadProjects: Reads the stored projects used for matching.
    ///   - verify: Returns the verified view of one project, or nil when it
    ///     no longer exists.
    ///   - selector: How workspaces are matched to projects.
    public init(
        loadProjects: @escaping @Sendable () throws -> [MCPProject],
        verify: @escaping @Sendable (UUID) throws -> MCPVerifiedProject?,
        selector: MCPProjectSelector = MCPProjectSelector()
    ) {
        self.loadProjects = loadProjects
        self.verify = verify
        self.selector = selector
    }

    /// Resolves the project for one session. `roots` are file-URI strings
    /// from `roots/list`, nil when the host has no roots capability.
    /// `.unconfigured` carries the working directory as `workspace` only when
    /// the working directory was the input that failed; explicit and roots
    /// failures report nil.
    public func resolve(explicit: UUID?, roots: [String]?, workingDirectory: String) throws -> MCPProjectContext {
        let projects = try loadProjects()

        if let explicit {
            switch selector.select(explicit: explicit, projects: projects) {
            case .selected(let id):
                return try verified(id, source: .explicit, workspace: nil)
            case .noMatch, .ambiguous:
                return .unconfigured(.explicitProjectNotFound, workspace: nil)
            }
        }

        if let roots {
            var ids: [UUID] = []
            for path in roots.compactMap(Self.filePath) {
                switch selector.select(workspace: path, projects: projects) {
                case .selected(let id):
                    if !ids.contains(id) { ids.append(id) }
                case .ambiguous:
                    return .unconfigured(.ambiguousProjects, workspace: nil)
                case .noMatch:
                    break
                }
            }
            if ids.count > 1 {
                return .unconfigured(.ambiguousProjects, workspace: nil)
            }
            if let id = ids.first {
                return try verified(id, source: .roots, workspace: nil)
            }
        }

        switch selector.select(workspace: workingDirectory, projects: projects) {
        case .selected(let id):
            return try verified(id, source: .workingDirectory, workspace: workingDirectory)
        case .ambiguous:
            return .unconfigured(.ambiguousProjects, workspace: workingDirectory)
        case .noMatch:
            return .unconfigured(.noMatchingProject, workspace: workingDirectory)
        }
    }

    private func verified(_ id: UUID, source: MCPSelectionSource, workspace: String?) throws -> MCPProjectContext {
        guard let verified = try verify(id) else {
            return .unconfigured(.noMatchingProject, workspace: workspace)
        }
        guard verified.project.isEnabled else {
            return .unconfigured(.projectDisabled, workspace: workspace)
        }
        return .selected(verified, source: source)
    }

    /// The decoded path of a `file:` URI; nil for any other scheme or an
    /// unparseable string.
    private static func filePath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
