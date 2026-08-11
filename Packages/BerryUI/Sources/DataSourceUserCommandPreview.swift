/// Renders a create-user call as the literal mongosh-style command it maps
/// to — always shown to the user before Create runs (N1, mirrors
/// `KeyValueCommandPreview`/`DataSourceCommandPreview`). Illustrative text
/// only, not what's literally sent on the wire (that's a typed BSON
/// `createUser` admin command, built directly by `MongoConnection`) — same
/// relationship the other two preview renderers already have to their real
/// execution path.
enum DataSourceUserCommandPreview {
    static func render(username: String, password: String, roles: [String]) -> String {
        let rolesText = roles.map { "\"\($0)\"" }.joined(separator: ", ")
        return "db.createUser({user: \"\(username)\", pwd: \"\(password)\", roles: [\(rolesText)]})"
    }
}
