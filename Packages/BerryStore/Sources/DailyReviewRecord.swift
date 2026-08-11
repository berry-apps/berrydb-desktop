import Foundation
import GRDB

/// A generated digest of Insight Panel findings, shown again on next launch
/// (DI-23, docs/architecture/13 §5.3) — NOT sent anywhere, in-app only.
public struct DailyReviewRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var generatedAt: Date
    public var summaryJSON: String

    public static let databaseTableName = "daily_review"

    public init(id: UUID = UUID(), profileID: UUID, generatedAt: Date, summaryJSON: String) {
        self.id = id
        self.profileID = profileID
        self.generatedAt = generatedAt
        self.summaryJSON = summaryJSON
    }
}
