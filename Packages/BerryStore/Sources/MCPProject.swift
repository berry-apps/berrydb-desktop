import Foundation
import GRDB

public enum MCPProjectCapability: String, Codable, CaseIterable, Sendable {
    case schema
    case graph
    case readQuery = "read_query"
    case sampleRows = "sample_rows"
}

public enum MCPProductionAccess: String, Codable, Sendable {
    /// Production profiles may not be opened by the MCP process.
    case disabled
    /// Persisted schema and graph snapshots may be shared, but live access is denied.
    case snapshotsOnly = "snapshots_only"
}

public enum MCPProjectError: Error, Equatable, Sendable {
    case workspaceRootMustBeAbsolute(String)
}

/// An explicit, persisted authorization boundary for one coding-agent project.
/// Workspace roots are descriptive configuration metadata; only `profileIDs`
/// and `enabledCapabilities` grant access.
public struct MCPProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var workspaceRoots: [String]
    public var profileIDs: [UUID]
    public var enabledCapabilities: Set<MCPProjectCapability>
    public var productionAccess: MCPProductionAccess
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        workspaceRoots: [String] = [],
        profileIDs: [UUID] = [],
        enabledCapabilities: Set<MCPProjectCapability> = [],
        productionAccess: MCPProductionAccess = .disabled,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workspaceRoots = workspaceRoots
        self.profileIDs = profileIDs
        self.enabledCapabilities = enabledCapabilities
        self.productionAccess = productionAccess
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct MCPProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_project"

    var id: UUID
    var name: String
    var workspaceRootsJSON: String
    var enabledCapabilitiesJSON: String
    var productionAccess: String
    var createdAt: Date
    var updatedAt: Date
}

struct MCPProjectProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_project_profile"

    var projectID: UUID
    var profileID: UUID
}

extension MCPProject {
    /// Normalizes roots for persisted display/configuration metadata only.
    /// These paths are never an authorization input.
    static func canonicalWorkspaceRoots(_ roots: [String]) throws -> [String] {
        var canonicalRoots = Set<String>()
        for root in roots {
            guard (root as NSString).isAbsolutePath else {
                throw MCPProjectError.workspaceRootMustBeAbsolute(root)
            }
            canonicalRoots.insert(URL(fileURLWithPath: root).standardizedFileURL.path)
        }
        return canonicalRoots.sorted()
    }
}
