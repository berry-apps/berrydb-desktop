import BerryStore
import Foundation

/// Compares two saved Query Replay snapshots of the same query
/// — "420ms yesterday, 63ms today, −85%". Pure
/// the caller supplies the snapshots (`BerryStore.queryReplaySnapshots`).
public enum QueryReplayComparator {
    public struct Comparison: Sendable, Equatable {
        public let earlier: QueryReplaySnapshotRecord
        public let later: QueryReplaySnapshotRecord
        public let deltaMS: Double
        /// Positive = later run was slower; negative = faster. `nil` when
        /// `earlier` took 0ms (can't express a meaningful percentage).
        public let percentChange: Double?

        public var improved: Bool { deltaMS < 0 }
    }

    /// Compares the two most recent snapshots (already ordered newest-first,
    /// as `BerryStore.queryReplaySnapshots` returns them). `nil` when fewer
    /// than 2 snapshots exist — nothing to compare yet.
    public static func compareLatestTwo(_ snapshots: [QueryReplaySnapshotRecord]) -> Comparison? {
        guard snapshots.count >= 2 else { return nil }
        return compare(earlier: snapshots[1], later: snapshots[0])
    }

    public static func compare(earlier: QueryReplaySnapshotRecord, later: QueryReplaySnapshotRecord) -> Comparison {
        let delta = later.durationMS - earlier.durationMS
        let percent = earlier.durationMS == 0 ? nil : (delta / earlier.durationMS) * 100
        return Comparison(earlier: earlier, later: later, deltaMS: delta, percentChange: percent)
    }
}
