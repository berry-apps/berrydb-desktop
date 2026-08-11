import Foundation
import GRDB

/// A named, reusable SQL snippet (ED-07) — docs/architecture/07 §3.
/// Scoped to a profile when `profileID` is set, otherwise global (available
/// from any connection). Stored locally only; never leaves the machine.
public struct SavedQuery: Identifiable, Codable, Sendable {
    public var id: UUID
    /// nil → global snippet, usable from any connection.
    public var profileID: UUID?
    public var name: String
    public var sql: String
    /// Optional free-text grouping shown as a section header in the picker.
    public var folder: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        profileID: UUID?,
        name: String,
        sql: String,
        folder: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.sql = sql
        self.folder = folder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension SavedQuery: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "saved_query"
}
