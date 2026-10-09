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
    /// `workspace` is the location that decided the selection: the host
    /// root or working directory that a registered folder matched; nil for
    /// an explicit project.
    case selected(MCPVerifiedProject, source: MCPSelectionSource, workspace: String?)
    case unconfigured(MCPUnconfiguredReason, workspace: String?)
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
    case unconfigured(MCPUnconfiguredReason, workspace: String?)
}

/// Decides which project a host session serves, independent of any wire
/// protocol: an explicit project, named by its ID or its name, wins, then
/// the host's workspace roots, then the process working directory. Roots
/// and the working directory are matched against the workspace folders
/// registered in the app.
///
/// Selection is a convenience, not authorization: verification of the
/// selected project decides what is served. An unverifiable integrity tag
/// removes live reads but not selection: schema and graph metadata expose
/// nothing beyond what the store file already holds, so the resolved context
/// carries `projectTagValid` for the caller to report instead.
///
/// Roots that match different projects, or a root that ties between
/// projects, are ambiguous and are never resolved by falling back to the
/// working directory. Roots without a registered match do fall back, since
/// a host may open a folder BerryDB does not know about.
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

    /// Selects and verifies the project for one session in a single step;
    /// see `select` for the inputs and `context(of:)` for verification.
    public func resolve(explicit: MCPProjectReference?, roots: [String]?, workingDirectory: String) throws -> MCPProjectContext {
        try context(of: select(explicit: explicit, roots: roots, workingDirectory: workingDirectory))
    }

    /// Selects the project for one session without verifying it. `roots`
    /// are file-URI strings from `roots/list`, nil when the host has no
    /// roots capability. A selected project carries the location that
    /// decided it as `workspace`. `.unconfigured` carries the working
    /// directory only when the working directory was the input that failed;
    /// explicit and roots failures report nil. An explicit project that
    /// cannot be selected never falls back to the other inputs: a name that
    /// no project has is `.explicitProjectNotFound`, and one that several
    /// projects share is `.ambiguousProjects`. Throws when the store cannot
    /// be read.
    public func select(explicit: MCPProjectReference?, roots: [String]?, workingDirectory: String) throws -> MCPSelectionOutcome {
        let projects = try loadProjects()

        if let explicit {
            switch selector.select(explicit: explicit, projects: projects) {
            case .selected(let id):
                return .project(id, source: .explicit, workspace: nil)
            case .noMatch:
                return .unconfigured(.explicitProjectNotFound, workspace: nil)
            case .ambiguous:
                return .unconfigured(.ambiguousProjects, workspace: nil)
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
        case let .unconfigured(reason, workspace):
            return .unconfigured(reason, workspace: workspace)
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
    /// working directory, or nil when none of them has a registered match,
    /// so the next input decides.
    ///
    /// Each workspace is matched on its own against the registered roots
    /// that contain it. A tie between registered roots, or workspaces that
    /// match different projects, is ambiguous. A selection keeps the first
    /// workspace that matched.
    ///
    /// - Parameter workingDirectory: Set when the input is the working
    ///   directory, nil for the roots. It tells the two sources of a
    ///   selection apart and is the workspace reported for an ambiguity,
    ///   which no single location decided.
    private func decide(
        _ workspaces: [String], projects: [MCPProject], workingDirectory: String?
    ) -> MCPSelectionOutcome? {
        var tie = false
        var matchedWorkspace: String?
        var ids: [UUID] = []
        for workspace in workspaces {
            switch selector.select(workspace: workspace, projects: projects) {
            case .selected(let id):
                if !ids.contains(id) { ids.append(id) }
                matchedWorkspace = matchedWorkspace ?? workspace
            case .ambiguous:
                tie = true
            case .noMatch:
                break
            }
        }
        if tie || ids.count > 1 {
            return .unconfigured(.ambiguousProjects, workspace: workingDirectory)
        }
        guard let id = ids.first else { return nil }
        let source: MCPSelectionSource = workingDirectory == nil ? .roots : .workingDirectory
        return .project(id, source: source, workspace: matchedWorkspace)
    }

    /// The decoded path of a `file:` URI; nil for any other scheme or an
    /// unparseable string.
    private static func filePath(_ uri: String) -> String? {
        guard let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }
}
