/// `KeyValueDriver` capabilities — sibling of `Capabilities` (BerryDriverKit)
/// and `DataSourceCapabilities` (BerryDataSourceKit), same anti-bloat
/// principle: UI shows/hides features by flag, never by driver name
///
public struct KeyValueCapabilities: Sendable {
    public let write: Bool
    public let ttl: Bool
    /// Numbered databases (Redis/Valkey: 0–15), not named ones like SQL's
    /// `multipleDatabases` — kept as its own flag rather than reusing that
    /// name, since the UI affordance (an index picker, not a name picker) differs.
    public let numberedDatabases: Bool

    public init(
        write: Bool = false,
        ttl: Bool = false,
        numberedDatabases: Bool = false
    ) {
        self.write = write
        self.ttl = ttl
        self.numberedDatabases = numberedDatabases
    }
}
