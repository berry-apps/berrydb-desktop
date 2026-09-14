import Foundation
import GRDB

/// A user-saved execution snapshot of one query, for comparing runs over time
/// e.g. "420ms yesterday, 63ms today,
/// what changed?" (plan-wise, not just wall-clock). Distinct from
/// `query_history` (which logs every run automatically): a replay
/// snapshot only exists when the user explicitly asks to keep one.
public struct QueryReplaySnapshotRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var profileID: UUID
    /// Groups snapshots of the same query across time — see `QueryReplayRecord.hash(of:)`.
    public var queryHash: String
    public var sql: String
    public var ts: Date
    public var durationMS: Double
    /// EXPLAIN ANALYZE plan tree as JSON (`PlanNode.jsonString(of:)` shape),
 /// Nil when the dialect has no EXPLAIN
    /// (`Capabilities.explain == false`), the run failed, or the plan shape
    /// wasn't recognized — a snapshot without a plan still records duration,
    /// same as before this field existed.
    public var planJSON: String?

    public static let databaseTableName = "query_replay"

    public init(
        id: UUID = UUID(), profileID: UUID, queryHash: String, sql: String, ts: Date,
        durationMS: Double, planJSON: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.queryHash = queryHash
        self.sql = sql
        self.ts = ts
        self.durationMS = durationMS
        self.planJSON = planJSON
    }
}

public enum QueryReplayRecord {
    /// Deterministic content hash so re-running the same query (modulo
    /// whitespace) groups under one `queryHash` — no crypto dependency, same
    /// FNV-1a approach as `GraphStore.digest` (keeps the module Linux-clean).
    public static func hash(of sql: String) -> String {
        let normalized = sql
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .joined(separator: " ")
            .lowercased()
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
