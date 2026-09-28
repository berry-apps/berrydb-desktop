import CryptoKit
import Foundation

/// HMAC-SHA256 tags over MCP access settings.
///
/// The store file is writable by any process of the same user, including a
/// coding agent (spec §4). Tags keyed from Keychain let the helper tell
/// settings written by BerryDB from settings written by anything else. Each
/// row is tagged separately so a cascade delete of one profile leaves the
/// other rows verifiable. Payloads carry a domain string and the project ID
/// so a tag cannot be replayed onto another row kind or project.
enum MCPAccessIntegrity {
    private struct ProjectPayload: Encodable {
        let domain = "berrydb.mcp.project.v1"
        let projectID: String
        let isEnabled: Bool
        let workspaceRoots: [String]
    }

    private struct ProfilePayload: Encodable {
        let domain = "berrydb.mcp.profile-access.v1"
        let projectID: String
        let profileID: String
        let liveRead: Bool
        let redactedColumns: [String]
    }

    /// Canonical bytes of the project-level settings the helper trusts.
    static func projectPayload(id: UUID, isEnabled: Bool, workspaceRoots: [String]) throws -> Data {
        try canonical(ProjectPayload(
            projectID: id.uuidString.lowercased(),
            isEnabled: isEnabled,
            workspaceRoots: workspaceRoots
        ))
    }

    /// Canonical bytes of one profile's access row within one project.
    static func profilePayload(projectID: UUID, access: MCPProfileAccess) throws -> Data {
        try canonical(ProfilePayload(
            projectID: projectID.uuidString.lowercased(),
            profileID: access.profileID.uuidString.lowercased(),
            liveRead: access.liveRead,
            redactedColumns: MCPProfileAccess.normalizedColumns(access.redactedColumns)
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
