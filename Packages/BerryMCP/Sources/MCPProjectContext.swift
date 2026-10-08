import BerryStore
import Foundation

/// Which input decided the project a session serves. The raw values are
/// reported verbatim by the status tool.
public enum MCPSelectionSource: String, Codable, Sendable {
    case explicit
    case roots
    case workingDirectory = "working_directory"
    case linkedRepository = "linked_repository"
}

/// Why a session serves no project. The raw values are reported verbatim by
/// the status tool.
public enum MCPUnconfiguredReason: String, Codable, Sendable {
    case noMatchingProject = "no_matching_project"
    case ambiguousProjects = "ambiguous_projects"
    case explicitProjectNotFound = "explicit_project_not_found"
    case projectDisabled = "project_disabled"
    case integrityUnavailable = "integrity_unavailable"
    case linkedProjectNotFound = "linked_project_not_found"
    case invalidLinkFile = "invalid_link_file"
}

/// The project a session serves, or the reason it serves none.
public enum MCPProjectContext: Equatable, Sendable {
    case selected(MCPVerifiedProject, source: MCPSelectionSource)
    /// `linkedProject` is the name a link file gave when no project has it
    /// (`.linkedProjectNotFound`), so the status can show which project to
    /// create; nil for every other reason.
    case unconfigured(MCPUnconfiguredReason, workspace: String?, linkedProject: String? = nil)
}

/// Decides which project a host session serves, independent of any wire
/// protocol: an explicit project id wins, then the host's workspace roots,
/// then the process working directory. For the roots, and then for the
/// working directory, a repository link file (`MCPRepositoryLink`) decides
/// before the workspace roots registered in the app are matched.
///
/// Selection is a convenience, not authorization: verification of the
/// selected project decides what is served. An unverifiable integrity tag
/// removes live reads but not selection: schema and graph metadata expose
/// nothing beyond what the store file already holds, so the resolved context
/// carries `projectTagValid` for the caller to report instead. A link file
/// comes from an untrusted repository and can name any project, which is why
/// it too only selects.
///
/// Roots that name different projects are ambiguous and are never resolved
/// by falling back to the working directory. Roots that match no project do
/// fall back, since a host may open a folder BerryDB does not know about.
public struct MCPProjectContextResolver: Sendable {
    private let loadProjects: @Sendable () throws -> [MCPProject]
    private let verify: @Sendable (UUID) throws -> MCPVerifiedProject?
    private let selector: MCPProjectSelector
    private let findLink: @Sendable (String) -> MCPRepositoryLink.Lookup

    /// - Parameters:
    ///   - loadProjects: Reads the stored projects used for matching.
    ///   - verify: Returns the verified view of one project, or nil when it
    ///     no longer exists.
    ///   - selector: How workspaces are matched to projects.
    ///   - findLink: Looks up the link file for a workspace path; reads the
    ///     file system through `MCPRepositoryLink.find` unless replaced.
    public init(
        loadProjects: @escaping @Sendable () throws -> [MCPProject],
        verify: @escaping @Sendable (UUID) throws -> MCPVerifiedProject?,
        selector: MCPProjectSelector = MCPProjectSelector(),
        findLink: @escaping @Sendable (String) -> MCPRepositoryLink.Lookup = { MCPRepositoryLink.find(from: $0) }
    ) {
        self.loadProjects = loadProjects
        self.verify = verify
        self.selector = selector
        self.findLink = findLink
    }

    /// Resolves the project for one session. `roots` are file-URI strings
    /// from `roots/list`, nil when the host has no roots capability.
    /// `.unconfigured` carries the working directory as `workspace` only when
    /// the working directory, or the link file found from it, was the input
    /// that failed; explicit and roots failures report nil.
    ///
    /// When any root has a link file, the links alone decide and registered
    /// roots are not matched: a link is never skipped in favour of another
    /// input, so what it says is what is served.
    public func resolve(explicit: UUID?, roots: [String]?, workingDirectory: String) throws -> MCPProjectContext {
        let projects = try loadProjects()

        if let explicit {
            switch selector.select(explicit: explicit, projects: projects) {
            case .selected(let id):
                return try verified(id: id, source: .explicit, workspace: nil)
            case .noMatch, .ambiguous:
                return .unconfigured(.explicitProjectNotFound, workspace: nil)
            }
        }

        if let roots {
            let paths = roots.compactMap(Self.filePath)
            let links = paths.map(findLink).filter { $0 != .none }
            if !links.isEmpty {
                return try linked(links, projects: projects, workspace: nil)
            }
            var ids: [UUID] = []
            for path in paths {
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
                return try verified(id: id, source: .roots, workspace: nil)
            }
        }

        let workingDirectoryLink = findLink(workingDirectory)
        if workingDirectoryLink != .none {
            return try linked([workingDirectoryLink], projects: projects, workspace: workingDirectory)
        }
        switch selector.select(workspace: workingDirectory, projects: projects) {
        case .selected(let id):
            return try verified(id: id, source: .workingDirectory, workspace: workingDirectory)
        case .ambiguous:
            return .unconfigured(.ambiguousProjects, workspace: workingDirectory)
        case .noMatch:
            return .unconfigured(.noMatchingProject, workspace: workingDirectory)
        }
    }

    /// The current state of a project chosen earlier, without repeating the
    /// selection: verified and selected by `source`, or unconfigured because
    /// it no longer exists or is disabled. `workspace` is reported only in
    /// the unconfigured case. Throws when the store cannot be read.
    public func verified(id: UUID, source: MCPSelectionSource, workspace: String?) throws -> MCPProjectContext {
        guard let verified = try verify(id) else {
            return .unconfigured(.noMatchingProject, workspace: workspace)
        }
        guard verified.project.isEnabled else {
            return .unconfigured(.projectDisabled, workspace: workspace)
        }
        return .selected(verified, source: source)
    }

    /// The outcome decided by the link files found for one input, nearest
    /// file per workspace. Problems in a single file are reported before
    /// conflicts between files: any invalid file, then any name no project
    /// has, then a name shared by several projects or links naming different
    /// projects, both of which are ambiguous.
    ///
    /// A project chosen this way is verified with no workspace, even when the
    /// link was found from the working directory: the session re-verifies
    /// later requests with the workspace it keeps for a link selection, which
    /// is nil, and a disabled or deleted project must read the same on every
    /// request.
    private func linked(
        _ links: [MCPRepositoryLink.Lookup], projects: [MCPProject], workspace: String?
    ) throws -> MCPProjectContext {
        var names: [String] = []
        for link in links {
            guard case let .found(_, name) = link else {
                return .unconfigured(.invalidLinkFile, workspace: workspace)
            }
            names.append(name)
        }
        var ids: [UUID] = []
        for name in names {
            let matching = projects.filter { MCPRepositoryLink.matches(projectName: $0.name, linkedName: name) }
            guard !matching.isEmpty else {
                return .unconfigured(.linkedProjectNotFound, workspace: workspace, linkedProject: name)
            }
            for project in matching where !ids.contains(project.id) {
                ids.append(project.id)
            }
        }
        guard ids.count == 1 else { return .unconfigured(.ambiguousProjects, workspace: workspace) }
        return try verified(id: ids[0], source: .linkedRepository, workspace: nil)
    }

    /// The decoded path of a `file:` URI; nil for any other scheme or an
    /// unparseable string.
    private static func filePath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
