import Foundation
import GRDB

/// A single instance-level health measurement at harvest time
///
public struct RuntimeMetricRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var profileID: UUID
    public var ts: Date
    public var metric: String
    public var value: Double

    public static let databaseTableName = "runtime_metric"

    public init(id: UUID = UUID(), profileID: UUID, ts: Date, metric: String, value: Double) {
        self.id = id
        self.profileID = profileID
        self.ts = ts
        self.metric = metric
        self.value = value
    }
}
