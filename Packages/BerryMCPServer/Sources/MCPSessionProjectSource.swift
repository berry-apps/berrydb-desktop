import BerryMCP
import BerryStore
import Foundation
import Synchronization

/// The verified project of one server's session, for a resolver built
/// before that server exists.
///
/// The resolver behind a live read service is built before the server,
/// while each session is created by `BerryMCPServerFactory.makeServer`,
/// which binds this source to it. A live
/// read therefore resolves its profile against the project the session
/// verifies for that request, through the same selection the metadata tools
/// use. A source serves one server; binding it again replaces the session.
public final class MCPSessionProjectSource: Sendable {
    private let context = Mutex<(@Sendable () async -> MCPProjectContext)?>(nil)

    public init() {}

    func bind(_ context: @escaping @Sendable () async -> MCPProjectContext) {
        self.context.withLock { $0 = context }
    }

    /// The session's project verified afresh, or nil when the session
    /// serves none or no session is bound yet.
    public func project() async -> MCPVerifiedProject? {
        guard let context = context.withLock({ $0 }) else { return nil }
        guard case let .selected(project, _, _) = await context() else { return nil }
        return project
    }
}
