import BerryMCP
import BerryStore
import Foundation
import Synchronization

/// The verified project of one server's session, for a resolver built
/// before that server exists.
///
/// The resolver behind a live read service is built before the server, while
/// each session is created by `BerryMCPServerFactory.makeServer`, which binds
/// this source to it. A live read therefore resolves its profile against the
/// project the session verifies for that request, through the same selection
/// the metadata tools use.
///
/// A source serves one server. Binding it a second time stops the process:
/// a later session would silently take over, and live reads begun for the
/// first session would resolve against the second session's project.
public final class MCPSessionProjectSource: Sendable {
    private let context = Mutex<(@Sendable () async -> MCPProjectContext)?>(nil)

    public init() {}

    func bind(_ context: @escaping @Sendable () async -> MCPProjectContext) {
        let first = self.context.withLock { slot in
            guard slot == nil else { return false }
            slot = context
            return true
        }
        precondition(first, "an MCPSessionProjectSource is bound to one server only")
    }

    /// The session's project verified afresh, or nil when the session
    /// serves none or no session is bound yet.
    public func project() async -> MCPVerifiedProject? {
        guard let context = context.withLock({ $0 }) else { return nil }
        guard case let .selected(project, _, _) = await context() else { return nil }
        return project
    }
}
