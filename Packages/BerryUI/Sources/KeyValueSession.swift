import BerryKeyValueKit
import BerryTunnel
import Foundation

/// The key-value sibling of `Session` (BerryCore) / `DataSourceSession` — one
/// active `KeyValueDriver` connection per workspace, mutually exclusive with
/// both: connecting to one tears down the others.
/// No `kind` field like `DataSourceSession` — Redis has no document/vector
/// split, just one shape.
public struct KeyValueSession: Sendable, Identifiable {
    public let id: UUID
    /// Saved profile this session was opened from — mirrors `Session.profileID`.
    public let profileID: UUID?
 /// Production label — read from the profile at connect time.
    public let isProduction: Bool
    public let connection: any KeyValueConnection
    public let capabilities: KeyValueCapabilities
    public let driverDisplayName: String
    /// The connection's display name (profile name) — same reasoning as
    /// `DataSourceSession.displayName`.
    public let displayName: String
    /// The numbered database (Redis/Valkey: 0–15) selected at connect time
    /// via `ConnectionSheet` — `KeyValueBrowserView`'s live switcher
    /// initializes from this so it reflects the DB the connection actually opened on, not always 0.
    public let database: Int
 /// Non-nil when the connection runs through an SSH tunnel.
    public let tunnel: SSHTunnel?

    public init(
        id: UUID = UUID(),
        profileID: UUID?,
        isProduction: Bool,
        connection: any KeyValueConnection,
        capabilities: KeyValueCapabilities,
        driverDisplayName: String,
        displayName: String,
        database: Int = 0,
        tunnel: SSHTunnel? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.isProduction = isProduction
        self.connection = connection
        self.capabilities = capabilities
        self.driverDisplayName = driverDisplayName
        self.displayName = displayName
        self.database = database
        self.tunnel = tunnel
    }
}
