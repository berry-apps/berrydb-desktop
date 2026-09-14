import BerryDataSourceKit
import BerryTunnel
import Foundation

/// The NoSQL/vector sibling of `Session` (BerryCore) — one active
/// `DataSourceDriver` connection per workspace, mutually exclusive with the
/// SQL `session` on `WorkspaceViewModel`:
/// connecting to one tears down the other.
public struct DataSourceSession: Sendable, Identifiable {
    public let id: UUID
    /// Saved profile this session was opened from — mirrors `Session.profileID`.
    public let profileID: UUID?
 /// Production label — read from the profile at connect time.
    public let isProduction: Bool
    public let connection: any DataSourceConnection
    public let kind: DataSourceKind
    public let capabilities: DataSourceCapabilities
    public let driverDisplayName: String
    /// The connection's display name (profile name). `Session.displayName`
    /// reads `config.name` from a stored `ConnectionConfig`; there is no
    /// equivalent config kept here, so this carries the same value directly.
    public let displayName: String
 /// Non-nil when the connection runs through an SSH tunnel
    /// closed together with the session, mirroring `Session.tunnel`.
    public let tunnel: SSHTunnel?

    public init(
        id: UUID = UUID(),
        profileID: UUID?,
        isProduction: Bool,
        connection: any DataSourceConnection,
        kind: DataSourceKind,
        capabilities: DataSourceCapabilities,
        driverDisplayName: String,
        displayName: String,
        tunnel: SSHTunnel? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.isProduction = isProduction
        self.connection = connection
        self.kind = kind
        self.capabilities = capabilities
        self.driverDisplayName = driverDisplayName
        self.displayName = displayName
        self.tunnel = tunnel
    }
}
