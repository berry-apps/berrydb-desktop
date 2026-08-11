/// Driver identifier — adding a new DBMS = adding a case + a new driver package,
/// with no changes to core/UI (docs/architecture/05 §2).
///
/// Shared across both driver families (docs/architecture/12 §2): `.dynamodb` goes
/// through `DatabaseDriver`/`DriverRegistry` (PartiQL dialect); `.mongodb`/`.qdrant`
/// go through the sibling `DataSourceDriver`/`DataSourceRegistry` (BerryDataSourceKit)
/// — one enum keeps `ConnectionConfig`/KN-01 persistence/connection sheet unified
/// instead of duplicating that plumbing per family.
public enum DriverID: String, Sendable, Hashable, CaseIterable {
    case sqlite
    case postgres
    case mysql
    case redis
    case sqlserver
    case dynamodb
    case mongodb
    case qdrant
    case elasticsearch
}

/// Driver capabilities — the UI reads these to show/hide features; never
/// if-else on the DBMS name (docs/architecture/05 §4, 04 §6).
public struct Capabilities: Sendable {
    public let transactions: Bool
    public let cancelQuery: Bool
    public let multipleDatabases: Bool
    public let schemas: Bool
    public let explain: Bool
    public let processList: Bool
    public let serverSideCursor: Bool
    public let keyValueBrowser: Bool
    /// Whether this driver can list/create/edit database users (TI-03,
    /// docs/architecture/14). Gate is two-part, same shape as `processList`:
    /// `capabilities.userManagement && dialect.listUsersSQL() != nil`.
    public let userManagement: Bool

    public init(
        transactions: Bool = false,
        cancelQuery: Bool = false,
        multipleDatabases: Bool = false,
        schemas: Bool = false,
        explain: Bool = false,
        processList: Bool = false,
        serverSideCursor: Bool = false,
        keyValueBrowser: Bool = false,
        userManagement: Bool = false
    ) {
        self.transactions = transactions
        self.cancelQuery = cancelQuery
        self.multipleDatabases = multipleDatabases
        self.schemas = schemas
        self.explain = explain
        self.processList = processList
        self.serverSideCursor = serverSideCursor
        self.keyValueBrowser = keyValueBrowser
        self.userManagement = userManagement
    }
}
