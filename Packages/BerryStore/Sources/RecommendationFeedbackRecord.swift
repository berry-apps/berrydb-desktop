import Foundation
import GRDB

/// The user's response to a single AI-generated Insight (DI-26, docs/architecture/13 §5.6).
public enum RecommendationAction: String, Sendable, Codable, CaseIterable {
    case applied, dismissed, ignored
}

public struct RecommendationFeedbackRecord: Codable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var insightID: String
    public var action: String
    public var ts: Date

    public static let databaseTableName = "recommendation_feedback"

    public init(id: UUID = UUID(), profileID: UUID, insightID: String, action: RecommendationAction, ts: Date) {
        self.id = id
        self.profileID = profileID
        self.insightID = insightID
        self.action = action.rawValue
        self.ts = ts
    }
}
