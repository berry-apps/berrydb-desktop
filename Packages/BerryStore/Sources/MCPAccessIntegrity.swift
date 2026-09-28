import CryptoKit
import Foundation

/// HMAC-SHA256 tags over MCP access settings.
///
/// The store file is writable by any process of the same user, including a
/// coding agent (spec §4). Tags keyed from Keychain let the helper tell
/// settings written by BerryDB from settings written by anything else. Each
/// row is tagged separately so a cascade delete of one profile leaves the
/// other rows verifiable. Payloads carry a domain string and the project ID
/// so a tag cannot be replayed onto another row kind or project, and a
/// profile-access payload also carries the profile's endpoint fingerprint so
/// the row stops verifying if the profile is pointed somewhere else.
enum MCPAccessIntegrity {
    private struct ProjectPayload: Encodable {
        let domain = "berrydb.mcp.project.v1"
        let projectID: String
        let isEnabled: Bool
        let workspaceRoots: [String]
    }

    private struct ProfilePayload: Encodable {
        let domain = "berrydb.mcp.profile-access.v2"
        let projectID: String
        let profileID: String
        let liveRead: Bool
        let redactedColumns: [String]
        let endpoint: EndpointFingerprint
    }

    /// The non-secret fields of a stored `ConnectionProfile` that decide
    /// where the helper sends the profile's Keychain credentials and whom it
    /// trusts on the way: `driverID`; `filePath` (SQLite); `host`, `port`,
    /// `username` and `database` (for DynamoDB these carry the endpoint
    /// override, the access key ID and the region); `tlsMode` and the three
    /// TLS certificate/key paths; `mongoAdditionalHosts` and
    /// `mongoReplicaSet`; `elasticsearchAPIKeyEnabled`, which picks the
    /// secret sent; and `sshEnabled`, `sshHost`, `sshPort`, `sshUsername`
    /// and `sshKeyPath` (key versus password authentication).
    ///
    /// A profile-access tag covers this fingerprint as it was when the app
    /// sealed the row, and verification recomputes it from the profile row
    /// as it is now. Any change to one of these fields therefore leaves the
    /// row unverifiable — fail closed — until the app re-seals it, so a
    /// process that can write the store file cannot redirect a live-read
    /// profile to a server it controls and receive those credentials.
    /// Display-only fields (`name`, `groupName`, `envColor`, `sortOrder`,
    /// `createdAt`, `historyEnabled`) are deliberately left out.
    private struct EndpointFingerprint: Encodable {
        let driverID: String
        let filePath: String?
        let host: String?
        let port: Int?
        let username: String?
        let database: String?
        let tlsMode: String
        let tlsCACertPath: String?
        let tlsClientCertPath: String?
        let tlsClientKeyPath: String?
        let mongoAdditionalHosts: String?
        let mongoReplicaSet: String?
        let elasticsearchAPIKeyEnabled: Bool
        let sshEnabled: Bool
        let sshHost: String?
        let sshPort: Int?
        let sshUsername: String?
        let sshKeyPath: String?

        init(_ profile: ConnectionProfile) {
            driverID = profile.driverID
            filePath = profile.filePath
            host = profile.host
            port = profile.port
            username = profile.username
            database = profile.database
            tlsMode = profile.tlsMode
            tlsCACertPath = profile.tlsCACertPath
            tlsClientCertPath = profile.tlsClientCertPath
            tlsClientKeyPath = profile.tlsClientKeyPath
            mongoAdditionalHosts = profile.mongoAdditionalHosts
            mongoReplicaSet = profile.mongoReplicaSet
            elasticsearchAPIKeyEnabled = profile.elasticsearchAPIKeyEnabled
            sshEnabled = profile.sshEnabled
            sshHost = profile.sshHost
            sshPort = profile.sshPort
            sshUsername = profile.sshUsername
            sshKeyPath = profile.sshKeyPath
        }
    }

    /// Canonical bytes of the project-level settings the helper trusts.
    static func projectPayload(id: UUID, isEnabled: Bool, workspaceRoots: [String]) throws -> Data {
        try canonical(ProjectPayload(
            projectID: id.uuidString.lowercased(),
            isEnabled: isEnabled,
            workspaceRoots: workspaceRoots
        ))
    }

    /// Canonical bytes of one profile's access row within one project,
    /// bound to the endpoint of `profile` — the stored connection profile
    /// the row refers to (see `EndpointFingerprint`).
    static func profilePayload(projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile) throws -> Data {
        try canonical(ProfilePayload(
            projectID: projectID.uuidString.lowercased(),
            profileID: access.profileID.uuidString.lowercased(),
            liveRead: access.liveRead,
            redactedColumns: MCPProfileAccess.normalizedColumns(access.redactedColumns),
            endpoint: EndpointFingerprint(profile)
        ))
    }

    static func tag(_ payload: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
    }

    /// Constant-time verification through CryptoKit; a missing tag is invalid.
    static func isValid(_ tag: Data?, payload: Data, key: SymmetricKey) -> Bool {
        guard let tag else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: payload, using: key)
    }

    private static func canonical<Payload: Encodable>(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}
