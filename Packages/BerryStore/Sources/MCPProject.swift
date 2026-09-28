import Foundation
import GRDB

public enum MCPProjectError: Error, Equatable, Sendable {
    case workspaceRootMustBeAbsolute(String)
}

/// Access one MCP project grants to one saved connection profile.
///
/// `liveRead` is the only switch that lets the MCP helper open a connection
/// for this profile; it defaults to off so adding a profile to a project
/// exposes schema and graph metadata only.
public struct MCPProfileAccess: Codable, Equatable, Sendable {
    public let profileID: UUID
    public var liveRead: Bool
    /// Column names redacted from live results; stored lowercased, deduped and sorted.
    public var redactedColumns: [String]

    public init(profileID: UUID, liveRead: Bool = false, redactedColumns: [String] = []) {
        self.profileID = profileID
        self.liveRead = liveRead
        self.redactedColumns = Self.normalizedColumns(redactedColumns)
    }

    static func normalizedColumns(_ columns: [String]) -> [String] {
        Set(columns.map { $0.lowercased() }).sorted()
    }
}

/// A coding-agent project: the workspace roots that select it and the
/// profiles it exposes. Selection by workspace is a convenience, not an
/// authorization boundary (spec §4); access is decided per profile.
public struct MCPProject: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var workspaceRoots: [String]
    public var profiles: [MCPProfileAccess]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = false,
        workspaceRoots: [String] = [],
        profiles: [MCPProfileAccess] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.workspaceRoots = workspaceRoots
        self.profiles = profiles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The helper's view of a project: settings as stored, plus which profiles'
/// live-read switch is proven — by a verified per-row HMAC tag — to have
/// been written by BerryDB. `berrydb.status` reports live access from this,
/// never from `MCPProject.profiles` directly.
public struct MCPVerifiedProject: Equatable, Sendable {
    public let project: MCPProject
    /// Profiles whose tag-verified row has liveRead on, in an enabled, verified project.
    public let liveReadProfileIDs: Set<UUID>
    /// False when the key is missing or the project row's tag does not verify.
    public let projectTagValid: Bool
    /// Profiles whose row claims liveRead but whose tag failed or whose ID is duplicated.
    public let rejectedLiveReadProfileIDs: Set<UUID>

    public init(
        project: MCPProject,
        liveReadProfileIDs: Set<UUID>,
        projectTagValid: Bool = true,
        rejectedLiveReadProfileIDs: Set<UUID> = []
    ) {
        self.project = project
        self.liveReadProfileIDs = liveReadProfileIDs
        self.projectTagValid = projectTagValid
        self.rejectedLiveReadProfileIDs = rejectedLiveReadProfileIDs
    }
}

struct MCPProjectRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_project"
    var id: UUID
    var name: String
    var isEnabled: Bool
    var workspaceRootsJSON: String
    var integrityTag: Data?
    var createdAt: Date
    var updatedAt: Date
}

struct MCPProjectProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mcp_project_profile"
    var projectID: UUID
    var profileID: UUID
    var liveRead: Bool
    var redactedColumnsJSON: String
    var integrityTag: Data?
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
