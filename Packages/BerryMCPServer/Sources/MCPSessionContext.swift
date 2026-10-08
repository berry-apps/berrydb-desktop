import BerryMCP
import Foundation
import Synchronization

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
/// For the same reason a project that is disabled when it is selected stays
/// the selection, and enabling it in the app serves it from the next request.
///
/// A store that cannot be read yields `.integrityUnavailable` for that request
/// only, with one line on the diagnostics channel that carries neither a path
/// nor error text, and the next request tries again. Selection that failed
/// this way is not cached; a selection already made is kept and verified
/// again.
///
/// The roots request is bounded by `rootsTimeout`. The SDK waits for the
/// answer on a continuation with no timeout and no cancellation
/// (`sendAndAwait` in Server.swift of swift-sdk 0.12.1), so a host that
/// declares roots but never answers would otherwise stall every request of the
/// connection. The MCP lifecycle specification asks senders to set timeouts on
/// their requests: https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#timeouts
/// After a timeout, selection falls back to the working directory, and the
/// abandoned request stays pending in the SDK until the server stops.
public actor MCPSessionContext {
    /// The line written to the diagnostics channel when the store cannot be read.
    public static let storeUnavailableLine = "berrydb-mcp: store unavailable"

    /// Writes one line to standard error. Standard output is reserved for
    /// JSON-RPC messages, so diagnostics never go there.
    public static let standardError: @Sendable (String) -> Void = { line in
        // `write(contentsOf:)` reports a failed write as a Swift error,
        // dropped here; the older `write(_:)` raises an Objective-C exception
        // instead. Documented for both methods at
        // https://developer.apple.com/documentation/foundation/filehandle
        // A closed standard error is not survived either way: this process
        // keeps the default action of SIGPIPE, which ends it before the
        // write can fail with EPIPE (write(2), sigaction(2)).
        try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8))
    }

    private let resolver: MCPProjectContextResolver
    private let explicitProject: UUID?
    private let workingDirectory: String
    private let listRoots: @Sendable () async throws -> [String]?
    private let diagnostics: @Sendable (String) -> Void
    private let rootsTimeout: Duration
    private var roots: Task<[String]?, Never>?
    private var selection: MCPSelectionOutcome?

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
    ///   - rootsTimeout: How long the roots request may take before selection
    ///     proceeds without roots. A host answers from its own state, so five
    ///     seconds is generous, and the wait happens at most once per
    ///     connection.
    public init(
        resolver: MCPProjectContextResolver,
        explicitProject: UUID?,
        workingDirectory: String,
        listRoots: @escaping @Sendable () async throws -> [String]?,
        diagnostics: @escaping @Sendable (String) -> Void = MCPSessionContext.standardError,
        rootsTimeout: Duration = .seconds(5)
    ) {
        self.resolver = resolver
        self.explicitProject = explicitProject
        self.workingDirectory = workingDirectory
        self.listRoots = listRoots
        self.diagnostics = diagnostics
        self.rootsTimeout = rootsTimeout
    }

    /// The context for the current request: the selected project verified
    /// afresh, or the reason none is served.
    public func context() async -> MCPProjectContext {
        do {
            if let selection { return try resolver.context(of: selection) }
            let roots = explicitProject == nil ? await workspaceRoots() : nil
            // A concurrent request may have completed selection while this
            // one waited for the roots.
            if let selection { return try resolver.context(of: selection) }
            let made = try resolver.select(explicit: explicitProject, roots: roots, workingDirectory: workingDirectory)
            selection = made
            return try resolver.context(of: made)
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
        let timeout = rootsTimeout
        let request = Task { await Self.roots(from: listRoots, within: timeout) }
        roots = request
        return await request.value
    }

    /// The answer of `listRoots`, or nil once `timeout` has passed. The fetch
    /// and the timer run as separate unstructured tasks racing to resume one
    /// continuation: a task group would wait for the fetch child, which never
    /// returns while the host stays silent.
    private static func roots(
        from listRoots: @escaping @Sendable () async throws -> [String]?, within timeout: Duration
    ) async -> [String]? {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let timer = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                answer.resume(nil)
            }
            Task {
                answer.resume(try? await listRoots())
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation with the first answer only; later answers are dropped.
private final class FirstAnswer: Sendable {
    private let pending: Mutex<CheckedContinuation<[String]?, Never>?>

    init(_ continuation: CheckedContinuation<[String]?, Never>) {
        pending = Mutex(continuation)
    }

    func resume(_ roots: [String]?) {
        let continuation = pending.withLock { slot in
            let taken = slot
            slot = nil
            return taken
        }
        continuation?.resume(returning: roots)
    }
}
