import Foundation
import GRDB

public struct IssuedMCPGrant: Equatable, Sendable {
    public let id: UUID
    public let projectID: UUID
    /// The one-time clear token. BerryStore never persists this value.
    public let token: String
    public let createdAt: Date
    public let expiresAt: Date?
}

public struct ValidatedMCPGrant: Equatable, Sendable {
    public let grantID: UUID
    public let project: MCPProject
}

public enum MCPGrantValidation: Equatable, Sendable {
    case valid(ValidatedMCPGrant)
    case invalid
}

struct MCPProjectGrantRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_project_grant"

    var id: UUID
    var projectID: UUID
    var tokenHash: Data
    var createdAt: Date
    var expiresAt: Date?
    var revokedAt: Date?
    var lastUsedAt: Date?
}
