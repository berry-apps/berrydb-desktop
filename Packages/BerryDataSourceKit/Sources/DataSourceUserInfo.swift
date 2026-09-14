/// One user/role listing row (Phase C) — the
/// `DataSourceConnection` sibling of the SQL side's normalized
/// `listUsersSQL()` columns. `roles` are role names only (v1: curated
/// built-in roles scoped to the connection's own working database — no
/// custom-role definitions, no cross-database role assignment).
public struct DataSourceUserInfo: Sendable, Equatable {
    public let username: String
    public let roles: [String]

    public init(username: String, roles: [String]) {
        self.username = username
        self.roles = roles
    }
}
