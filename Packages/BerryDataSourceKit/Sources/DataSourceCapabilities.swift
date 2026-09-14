import Foundation

/// What kind of non-tabular data a `DataSourceDriver` holds — UI reads this to
/// pick a query surface (filter/pipeline builder vs. vector search form),
/// never if-else on `DriverID`.
public enum DataSourceKind: String, Sendable, Hashable {
    case document
    case vector
 /// Elasticsearch — Query DSL + Document APIs, a
    /// distinct shape from Mongo's shell syntax and Qdrant's vector search:
    /// its own tab/query surface, not a reuse of `.document`.
    case search
}

/// `DataSourceDriver` capabilities — sibling of `Capabilities` (BerryDriverKit),
/// same anti-bloat principle: UI shows/hides features by flag, not by name
///
public struct DataSourceCapabilities: Sendable {
 /// Insert/update/delete via `DataSourceChangeSet` (model).
    public let write: Bool
    /// Vector similarity search (`.qdrantSearch`-style queries).
    public let vectorSearch: Bool
    /// Best-effort schema inference from sample documents (Mongo) as opposed
    /// to a real `DescribeTable`-style catalog.
    public let inferredSchemaOnly: Bool
    /// Whether the Users tab shows a static, read-only note instead of real
 /// user management (Phase D) — for a data
    /// source with no in-DB user system, e.g. Qdrant (API-key auth). Mongo
    /// leaves this false: it gets real user/role management (Phase C), not a
    /// static note.
    public let userManagementInfo: Bool
    /// Whether this driver can list/create/drop users via
 /// `DataSourceConnection`'s Phase C methods
    /// — the `DataSourceDriver` sibling of `Capabilities.userManagement`.
    /// Mongo only; mutually exclusive in practice with `userManagementInfo`.
    public let userManagement: Bool

    public init(
        write: Bool = false, vectorSearch: Bool = false, inferredSchemaOnly: Bool = false,
        userManagementInfo: Bool = false, userManagement: Bool = false
    ) {
        self.write = write
        self.vectorSearch = vectorSearch
        self.inferredSchemaOnly = inferredSchemaOnly
        self.userManagementInfo = userManagementInfo
        self.userManagement = userManagement
    }
}
