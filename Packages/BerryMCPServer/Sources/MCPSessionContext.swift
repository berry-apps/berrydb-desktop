import BerryMCP
import Foundation

/// The project context of one host connection.
///
/// Selection runs lazily, on the first request that needs a context, because
/// a server may send `roots/list` only after the client has finished
/// initialization. `roots/list` is requested at most once per connection, and
/// the selection outcome (which project and by which input, or why none) is
/// kept for the connection's lifetime: a project created or re-mapped in the
/// app is picked up by the next host session, not mid-session.
///
/// Verification of the selected project is repeated on every request, which
/// re-reads the project row and the integrity key each time. A project deleted
/// or disabled in the app therefore stops being served on the next request,
/// and a store restored from an older copy cannot keep verifying under a key
/// that has since been rotated; caching the verified project would defeat both.
///
/// A store that cannot be read yields `.integrityUnavailable` for that request
/// only, with one line on the diagnostics channel that carries neither a path
/// nor error text, and the next request tries again. Selection that failed
/// this way is not cached.
public actor MCPSessionContext {
    /// The line written to the diagnostics channel when the store cannot be read.
    public static let storeUnavailableLine = "berrydb-mcp: store unavailable"

    /// Writes one line to standard error. Standard output is reserved for
    /// JSON-RPC messages, so diagnostics never go there.
    public static let standardError: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private enum Selection {
        case project(UUID, source: MCPSelectionSource, workspace: String?)
        case unconfigured(MCPUnconfiguredReason, workspace: String?)
    }

    private let resolver: MCPProjectContextResolver
    private let explicitProject: UUID?
    private let workingDirectory: String
    private let listRoots: @Sendable () async throws -> [String]?
    private let diagnostics: @Sendable (String) -> Void
    private var roots: Task<[String]?, Never>?
    private var selection: Selection?

    /// - Parameters:
    ///   - resolver: Selects and verifies projects against the store.
    ///   - explicitProject: A project named on the command line; when set,
    ///     roots are never requested.
    ///   - workingDirectory: The process working directory, the last input
    ///     to selection.
    ///   - listRoots: Asks the host for its workspace roots as file URIs; nil
    ///     when the host has no roots capability. A thrown error is treated
    ///     like nil, so selection falls back to the working directory.
    ///   - diagnostics: Receives the store-unavailable line; standard error
    ///     unless replaced.
    public init(
        resolver: MCPProjectContextResolver,
        explicitProject: UUID?,
        workingDirectory: String,
        listRoots: @escaping @Sendable () async throws -> [String]?,
        diagnostics: @escaping @Sendable (String) -> Void = MCPSessionContext.standardError
    ) {
        self.resolver = resolver
        self.explicitProject = explicitProject
        self.workingDirectory = workingDirectory
        self.listRoots = listRoots
        self.diagnostics = diagnostics
    }

    /// The context for the current request: the selected project verified
    /// afresh, or the reason none is served.
    public func context() async -> MCPProjectContext {
        do {
            if let selection { return try current(selection) }
            let roots = explicitProject == nil ? await workspaceRoots() : nil
            // A concurrent request may have completed selection while this
            // one waited for the roots.
            if let selection { return try current(selection) }
            let resolved = try resolver.resolve(explicit: explicitProject, roots: roots, workingDirectory: workingDirectory)
            selection = selectionOutcome(of: resolved)
            return resolved
        } catch {
            diagnostics(Self.storeUnavailableLine)
            return .unconfigured(.integrityUnavailable, workspace: nil)
        }
    }

    /// The host's roots, requested once; concurrent first requests share one
    /// `roots/list` round trip.
    private func workspaceRoots() async -> [String]? {
        if let roots { return await roots.value }
        let listRoots = self.listRoots
        let request = Task { try? await listRoots() }
        roots = request
        return await request.value
    }

    private func current(_ selection: Selection) throws -> MCPProjectContext {
        switch selection {
        case let .project(id, source, workspace):
            return try resolver.verified(id: id, source: source, workspace: workspace)
        case let .unconfigured(reason, workspace):
            return .unconfigured(reason, workspace: workspace)
        }
    }

    /// The workspace kept with a selected project is the one the resolver
    /// reports if that project later turns out disabled or deleted: the
    /// working directory when it decided the selection, nil otherwise.
    private func selectionOutcome(of context: MCPProjectContext) -> Selection {
        switch context {
        case let .selected(verified, source):
            let workspace = source == .workingDirectory ? workingDirectory : nil
            return .project(verified.project.id, source: source, workspace: workspace)
        case let .unconfigured(reason, workspace):
            return .unconfigured(reason, workspace: workspace)
        }
    }
}
