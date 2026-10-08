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
/// then the process working directory. Each of those workspaces is decided
/// on its own by its repository link file (`MCPRepositoryLink`) when it has
/// one, otherwise by the workspace roots registered in the app.
///
/// Selection is a convenience, not authorization: verification of the
/// selected project decides what is served. An unverifiable integrity tag
/// removes live reads but not selection: schema and graph metadata expose
/// nothing beyond what the store file already holds, so the resolved context
/// carries `projectTagValid` for the caller to report instead. A link file
/// comes from an untrusted repository and can name any project, which is why
/// it too only selects.
///
/// Roots that name different projects, through link files, registered roots
/// or a mix of both, are ambiguous and are never resolved by falling back to
/// the working directory. Roots with neither a link file nor a registered
/// match do fall back, since a host may open a folder BerryDB does not know
/// about.
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
    /// For `.invalidLinkFile`, `.unconfigured` carries the directory holding
    /// the bad file as `workspace`. Otherwise it carries the working
    /// directory only when the working directory was the input that failed;
    /// explicit and roots failures report nil.
    ///
    /// A workspace with a link file is decided by that file alone: the link
    /// is never skipped in favour of the workspace's registered roots, so
    /// what it says is what is served.
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

        if let roots,
           let decided = try decide(roots.compactMap(Self.filePath), projects: projects, workingDirectory: nil) {
            return decided
        }
        return try decide([workingDirectory], projects: projects, workingDirectory: workingDirectory)
            ?? .unconfigured(.noMatchingProject, workspace: workingDirectory)
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

    /// The outcome for the workspaces of one input, the host's roots or the
    /// working directory, or nil when none of them has a link file or a
    /// registered match, so the next input decides.
    ///
    /// Each workspace contributes on its own: through its nearest link file
    /// when it has one, otherwise through the registered roots that contain
    /// it. Problems in a single workspace are reported before conflicts
    /// between workspaces: an invalid link file, then a linked name no
    /// project has, then a tie between registered roots, a name several
    /// projects share, or workspaces naming different projects, all of which
    /// are ambiguous. The selection is attributed to the link file when any
    /// contributing workspace used one.
    ///
    /// - Parameter workingDirectory: Set when the input is the working
    ///   directory, nil for the roots. It is the workspace reported for the
    ///   input's failures and kept with a project its registered roots
    ///   select. A project a link chose is verified with no workspace: the
    ///   session re-verifies later requests with the workspace it keeps for a
    ///   link selection, which is nil, and a disabled or deleted project must
    ///   read the same on every request.
    private func decide(
        _ workspaces: [String], projects: [MCPProject], workingDirectory: String?
    ) throws -> MCPProjectContext? {
        var invalidLinkDirectory: String?
        var unknownLinkedName: String?
        var registeredTie = false
        var usedLink = false
        var ids: [UUID] = []
        for workspace in workspaces {
            var matched: [UUID] = []
            switch findLink(workspace) {
            case let .invalid(directory):
                invalidLinkDirectory = invalidLinkDirectory ?? directory
            case let .found(_, name):
                usedLink = true
                matched = projects
                    .filter { MCPRepositoryLink.matches(projectName: $0.name, linkedName: name) }
                    .map(\.id)
                if matched.isEmpty { unknownLinkedName = unknownLinkedName ?? name }
            case .none:
                switch selector.select(workspace: workspace, projects: projects) {
                case .selected(let id): matched = [id]
                case .ambiguous: registeredTie = true
                case .noMatch: break
                }
            }
            for id in matched where !ids.contains(id) {
                ids.append(id)
            }
        }
        // The directory holding a bad file is reported in place of the
        // workspace so the user knows which file to fix; it comes from the
        // walk up from the user's own workspace and names no project.
        if let invalidLinkDirectory {
            return .unconfigured(.invalidLinkFile, workspace: invalidLinkDirectory)
        }
        if let unknownLinkedName {
            return .unconfigured(.linkedProjectNotFound, workspace: workingDirectory, linkedProject: unknownLinkedName)
        }
        if registeredTie || ids.count > 1 {
            return .unconfigured(.ambiguousProjects, workspace: workingDirectory)
        }
        guard let id = ids.first else { return nil }
        if usedLink {
            return try verified(id: id, source: .linkedRepository, workspace: nil)
        }
        let source: MCPSelectionSource = workingDirectory == nil ? .roots : .workingDirectory
        return try verified(id: id, source: source, workspace: workingDirectory)
    }

    /// The decoded path of a `file:` URI; nil for any other scheme or an
    /// unparseable string.
    private static func filePath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
