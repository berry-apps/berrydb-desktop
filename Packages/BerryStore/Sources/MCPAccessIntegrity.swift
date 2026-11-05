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
/// profile-access payload also carries the profile's endpoint fingerprint,
/// so the row stops verifying if the profile is pointed somewhere else, and
/// whether the profile carried the production label when the row was sealed.
enum MCPAccessIntegrity {
    private struct ProjectPayload: Encodable {
        let domain = "berrydb.mcp.project.v1"
        let projectID: String
        let isEnabled: Bool
        let workspaceRoots: [String]
    }

    /// `production` seals the label that picks the stricter result limits.
    /// It is a field of its own rather than part of the fingerprint so that
    /// a label change never makes the row unverifiable: verification tries
    /// both values and learns the sealed one, and the helper applies the
    /// stricter of that and the profile's current label. `liveReadUntil`
    /// seals the end of the live-read grant in whole seconds since 1970, so
    /// a process that can write the store cannot extend or remove it; the
    /// key is absent from the bytes when the grant has no end.
    private struct ProfilePayload: Encodable {
        let domain = "berrydb.mcp.profile-access.v4"
        let projectID: String
        let profileID: String
        let liveRead: Bool
        let redactedColumns: [String]
        let endpoint: EndpointFingerprint
        let production: Bool
        let liveReadUntil: Int?
    }

    /// The payload of rows sealed after the label was covered and before
    /// the live-read expiry was. Such a row keeps verifying against these
    /// bytes as long as it carries no expiry.
    private struct LabelProfilePayload: Encodable {
        let domain = "berrydb.mcp.profile-access.v3"
        let projectID: String
        let profileID: String
        let liveRead: Bool
        let redactedColumns: [String]
        let endpoint: EndpointFingerprint
        let production: Bool
    }

    /// The payload of rows sealed before the label was covered. Such a row
    /// keeps verifying against these bytes, and counts as production until
    /// its project is saved again, since the label it was sealed under is
    /// unknown.
    private struct EarlierProfilePayload: Encodable {
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
    /// Display-only fields (`name`, `groupName`, `sortOrder`, `createdAt`,
    /// `historyEnabled`) are deliberately left out, as is `envColor`: the
    /// production label it carries is sealed as `ProfilePayload.production`
    /// instead.
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
    /// the row refers to (see `EndpointFingerprint`) — to `production`,
    /// whether the profile carries the production label, and to the row's
    /// live-read expiry.
    static func profilePayload(
        projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile, production: Bool
    ) throws -> Data {
        try canonical(ProfilePayload(
            projectID: projectID.uuidString.lowercased(),
            profileID: access.profileID.uuidString.lowercased(),
            liveRead: access.liveRead,
            redactedColumns: MCPProfileAccess.normalizedColumns(access.redactedColumns),
            endpoint: EndpointFingerprint(profile),
            production: production,
            liveReadUntil: access.liveReadUntil.map { Int(floor($0.timeIntervalSince1970)) }
        ))
    }

    /// Canonical bytes of the same row as sealed before the live-read
    /// expiry was covered (see `LabelProfilePayload`).
    static func labelProfilePayload(
        projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile, production: Bool
    ) throws -> Data {
        try canonical(LabelProfilePayload(
            projectID: projectID.uuidString.lowercased(),
            profileID: access.profileID.uuidString.lowercased(),
            liveRead: access.liveRead,
            redactedColumns: MCPProfileAccess.normalizedColumns(access.redactedColumns),
            endpoint: EndpointFingerprint(profile),
            production: production
        ))
    }

    /// Canonical bytes of the same row as sealed before the label was
    /// covered (see `EarlierProfilePayload`).
    static func earlierProfilePayload(
        projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile
    ) throws -> Data {
        try canonical(EarlierProfilePayload(
            projectID: projectID.uuidString.lowercased(),
            profileID: access.profileID.uuidString.lowercased(),
            liveRead: access.liveRead,
            redactedColumns: MCPProfileAccess.normalizedColumns(access.redactedColumns),
            endpoint: EndpointFingerprint(profile)
        ))
    }

    /// The bytes `tag` verifies against under `key`, and whether they mark
    /// the profile production: the row's payload with the label, then
    /// without it; then, for a row without an expiry only, the payload of a
    /// row sealed before the expiry was covered, with and without the
    /// label, and the payload of a row sealed before the label was covered,
    /// which counts as production. Nil when none verifies. The order does
    /// not matter for the answer, since one key never verifies two
    /// different payloads with one tag.
    ///
    /// The older payloads do not cover the expiry, so a row that carries
    /// one next to an older tag has an expiry BerryDB never sealed; it
    /// fails closed instead of verifying with the expiry ignored. A row
    /// without an expiry keeps verifying against the older payloads, since
    /// it grants exactly what it granted when it was sealed, and it moves
    /// to the current payload the next time its project is saved.
    static func verifiedProfilePayload(
        tag: Data?, projectID: UUID, access: MCPProfileAccess, profile: ConnectionProfile, key: SymmetricKey
    ) throws -> (payload: Data, production: Bool)? {
        guard let tag else { return nil }
        for production in [true, false] {
            let payload = try profilePayload(
                projectID: projectID, access: access, profile: profile, production: production
            )
            if isValid(tag, payload: payload, key: key) { return (payload, production) }
        }
        guard access.liveReadUntil == nil else { return nil }
        for production in [true, false] {
            let payload = try labelProfilePayload(
                projectID: projectID, access: access, profile: profile, production: production
            )
            if isValid(tag, payload: payload, key: key) { return (payload, production) }
        }
        let earlier = try earlierProfilePayload(projectID: projectID, access: access, profile: profile)
        return isValid(tag, payload: earlier, key: key) ? (earlier, true) : nil
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
