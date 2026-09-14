import Foundation
import GRDB

/// Per-connection AI preferences: AI on for this
/// connection, sending sample rows allowed, safe SELECTs
/// auto-run, and the metadata policy accepted. Keyed by profile — one row each;
/// profileless quick-open connections keep these in memory only. Stored
/// locally; never leaves the machine.
public struct AIConnectionSetting: Identifiable, Codable, Sendable {
    /// The profile this applies to — also the primary key.
    public var profileID: UUID
    public var aiEnabled: Bool
    public var allowSampleRows: Bool
    public var autoApproveSelects: Bool
    public var consentGiven: Bool
 /// Enabled/trusted MCP servers, stored as JSON arrays of ids.
    public var enabledMcpServers: String
    public var trustedMcpServers: String
    public var updatedAt: Date

    public var id: UUID { profileID }

    public init(
        profileID: UUID,
        aiEnabled: Bool,
        allowSampleRows: Bool,
        autoApproveSelects: Bool,
        consentGiven: Bool,
        enabledMcpServers: String = "[]",
        trustedMcpServers: String = "[]",
        updatedAt: Date = Date()
    ) {
        self.profileID = profileID
        self.aiEnabled = aiEnabled
        self.allowSampleRows = allowSampleRows
        self.autoApproveSelects = autoApproveSelects
        self.consentGiven = consentGiven
        self.enabledMcpServers = enabledMcpServers
        self.trustedMcpServers = trustedMcpServers
        self.updatedAt = updatedAt
    }
}

extension AIConnectionSetting: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ai_connection_setting"
}
