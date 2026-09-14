import BerryCore
import BerryDriverKit
import BerryStore
import CryptoKit
import Foundation

/// Adapters that connect BerryCore's sink protocols to BerryStore.
/// They live in the UI/wiring layer on purpose: core and store stay
/// decoupled siblings.
struct StoreHistorySink: QueryHistorySink {
    let store: BerryStore

    func record(_ statement: ExecutedStatement) {
        let entry = QueryHistoryEntry(
            profileID: statement.profileID,
            sql: statement.sql,
            startedAt: statement.startedAt,
            durationMS: Int(statement.duration.components.seconds * 1000)
                + Int(statement.duration.components.attoseconds / 1_000_000_000_000_000),
            status: statement.status.rawValue,
            rowCount: statement.rowCount,
            errorMessage: statement.errorMessage
        )
        // History must never break the query path — persist failures are
        // logged by GRDB and dropped.
        try? store.record(entry)
    }
}

/// Digital Twin seed: normalizes the object list, hashes it and lets
/// the store dedupe by digest.
struct StoreSnapshotSink: SchemaSnapshotSink {
    let store: BerryStore

    func recordSnapshot(profileID: UUID?, objects: [SchemaObject]) {
        let normalized = objects
            .map { "\($0.kind.rawValue)|\($0.database ?? "")|\($0.name)" }
            .sorted()
        let payloadObjects = objects.map { object in
            ["kind": object.kind.rawValue, "name": object.name, "database": object.database ?? ""]
        }
        guard
            let payloadData = try? JSONSerialization.data(withJSONObject: payloadObjects, options: [.sortedKeys]),
            let payload = String(data: payloadData, encoding: .utf8)
        else { return }

        let digest = SHA256.hash(data: Data(normalized.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        try? store.recordSnapshotIfChanged(SchemaSnapshotRecord(
            profileID: profileID,
            takenAt: Date(),
            digest: digest,
            payload: payload
        ))
    }
}
