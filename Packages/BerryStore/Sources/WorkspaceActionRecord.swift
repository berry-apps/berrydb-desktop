import Foundation
import GRDB

/// One recent tab/pane action — bounded recall for the AI `get_ui_state` tool
/// separate from the in-memory-only UI graph itself
/// `description` is human-readable and never a
/// raw tab id: most `WorkspaceTab.id` values don't survive an app relaunch.
public struct WorkspaceActionRecord: Identifiable, Codable, Sendable {
    public var id: UUID
    public var profileID: UUID?
    /// "tab_opened" | "tab_closed" | "pane_split"
    public var kind: String
    public var description: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), profileID: UUID?, kind: String, description: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.kind = kind
        self.description = description
        self.createdAt = createdAt
    }
}

extension WorkspaceActionRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workspace_action"
}
