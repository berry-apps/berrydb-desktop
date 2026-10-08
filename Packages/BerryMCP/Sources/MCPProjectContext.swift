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
    /// `workspace` is the location that decided the selection: the directory
    /// holding the link file, or the host root or working directory that a
    /// registered folder matched; nil for an explicit project.
    case selected(MCPVerifiedProject, source: MCPSelectionSource, workspace: String?)
    /// `linkedProject` is the name a link file gave when no project has it
    /// (`.linkedProjectNotFound`), so the status can show which project to
    /// create; nil for every other reason.
    case unconfigured(MCPUnconfiguredReason, workspace: String?, linkedProject: String? = nil)
}

/// The outcome of selection before verification: the project chosen and by
/// which input, or why none was chosen. A session keeps it for its lifetime
/// and verifies the project on every request, so a project that is disabled
/// or missing when chosen stays the selection and is served as soon as it
/// verifies, the same as one disabled after it was chosen.
public enum MCPSelectionOutcome: Equatable, Sendable {
    /// `workspace` is the location that decided the selection, as
    /// `MCPProjectContext.selected` reports it; it is reported as well when
    /// verification finds the project disabled or missing.
    case project(UUID, source: MCPSelectionSource, workspace: String?)
    /// Carries the same values as `MCPProjectContext.unconfigured`.
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

    /// Selects and verifies the project for one session in a single step;
    /// see `select` for the inputs and `context(of:)` for verification.
    public func resolve(explicit: UUID?, roots: [String]?, workingDirectory: String) throws -> MCPProjectContext {
        try context(of: select(explicit: explicit, roots: roots, workingDirectory: workingDirectory))
    }

    /// Selects the project for one session without verifying it. `roots`
    /// are file-URI strings from `roots/list`, nil when the host has no
    /// roots capability. A selected project carries the location that
    /// decided it as `workspace`. For `.invalidLinkFile` and
    /// `.linkedProjectNotFound`, `.unconfigured` carries the directory
    /// holding the link file. Otherwise it carries the working directory only
    /// when the working directory was the input that failed; explicit and
    /// roots failures report nil. Throws when the store cannot be read.
    ///
    /// A workspace with a link file is decided by that file alone: the link
    /// is never skipped in favour of the workspace's registered roots, so
    /// what it says is what is served.
    public func select(explicit: UUID?, roots: [String]?, workingDirectory: String) throws -> MCPSelectionOutcome {
        let projects = try loadProjects()

        if let explicit {
            switch selector.select(explicit: explicit, projects: projects) {
            case .selected(let id):
                return .project(id, source: .explicit, workspace: nil)
            case .noMatch, .ambiguous:
                return .unconfigured(.explicitProjectNotFound, workspace: nil)
            }
        }

        if let roots, let decided = decide(roots.compactMap(Self.filePath), projects: projects, workingDirectory: nil) {
            return decided
        }
        return decide([workingDirectory], projects: projects, workingDirectory: workingDirectory)
            ?? .unconfigured(.noMatchingProject, workspace: workingDirectory)
    }

    /// The current state of a selection: its project verified afresh, or
    /// the reason no project was selected. Throws when the store cannot be
    /// read.
    public func context(of selection: MCPSelectionOutcome) throws -> MCPProjectContext {
        switch selection {
        case let .project(id, source, workspace):
            return try verified(id: id, source: source, workspace: workspace)
        case let .unconfigured(reason, workspace, linkedProject):
            return .unconfigured(reason, workspace: workspace, linkedProject: linkedProject)
        }
    }

    /// The current state of a project chosen earlier, without repeating the
    /// selection: verified and selected by `source`, or unconfigured because
    /// it no longer exists or is disabled. `workspace` is reported in every
    /// case, so a project reads the same location whether it verifies or
    /// not. Throws when the store cannot be read.
    public func verified(id: UUID, source: MCPSelectionSource, workspace: String?) throws -> MCPProjectContext {
        guard let verified = try verify(id) else {
            return .unconfigured(.noMatchingProject, workspace: workspace)
        }
        guard verified.project.isEnabled else {
            return .unconfigured(.projectDisabled, workspace: workspace)
        }
        return .selected(verified, source: source, workspace: workspace)
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
    /// contributing workspace used one, and keeps the directory of the first
    /// such file; otherwise it keeps the first workspace a registered root
    /// matched.
    ///
    /// - Parameter workingDirectory: Set when the input is the working
    ///   directory, nil for the roots. It tells the two sources of a
    ///   registered-root selection apart and is the workspace reported for
    ///   an ambiguity, which no single location decided.
    private func decide(
        _ workspaces: [String], projects: [MCPProject], workingDirectory: String?
    ) -> MCPSelectionOutcome? {
        var invalidLinkDirectory: String?
        var unknownLink: (name: String, directory: String)?
        var registeredTie = false
        var linkDirectory: String?
        var registeredWorkspace: String?
        var ids: [UUID] = []
        for workspace in workspaces {
            var matched: [UUID] = []
            switch findLink(workspace) {
            case let .invalid(directory):
                invalidLinkDirectory = invalidLinkDirectory ?? directory
            case let .found(directory, name):
                matched = projects
                    .filter { MCPRepositoryLink.matches(projectName: $0.name, linkedName: name) }
                    .map(\.id)
                if matched.isEmpty {
                    unknownLink = unknownLink ?? (name, directory)
                } else {
                    linkDirectory = linkDirectory ?? directory
                }
            case .none:
                switch selector.select(workspace: workspace, projects: projects) {
                case .selected(let id):
                    matched = [id]
                    registeredWorkspace = registeredWorkspace ?? workspace
                case .ambiguous: registeredTie = true
                case .noMatch: break
                }
            }
            for id in matched where !ids.contains(id) {
                ids.append(id)
            }
        }
        // The directory holding a link file is reported in place of the
        // workspace so the user knows which file decided, or which to fix;
        // it comes from the walk up from the user's own workspace and names
        // no project.
        if let invalidLinkDirectory {
            return .unconfigured(.invalidLinkFile, workspace: invalidLinkDirectory)
        }
        if let unknownLink {
            return .unconfigured(.linkedProjectNotFound, workspace: unknownLink.directory, linkedProject: unknownLink.name)
        }
        if registeredTie || ids.count > 1 {
            return .unconfigured(.ambiguousProjects, workspace: workingDirectory)
        }
        guard let id = ids.first else { return nil }
        if let linkDirectory {
            return .project(id, source: .linkedRepository, workspace: linkDirectory)
        }
        let source: MCPSelectionSource = workingDirectory == nil ? .roots : .workingDirectory
        return .project(id, source: source, workspace: registeredWorkspace)
    }

    /// The decoded path of a `file:` URI; nil for any other scheme or an
    /// unparseable string.
    private static func filePath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
