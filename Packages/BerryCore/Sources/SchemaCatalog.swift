import BerryDriverKit
import Foundation

/// Per-Session metadata cache (TR-05) — the source for the sidebar and
/// autocomplete; many readers, one writer, hence an actor (docs/architecture/04 §4).
public actor SchemaCatalog {
    private let session: Session
    private var cachedObjects: [SchemaObject]?
    /// Digital Twin seed (DI-08): every refresh feeds the snapshot sink.
    private let snapshotSink: (any SchemaSnapshotSink)?

    public init(session: Session, snapshotSink: (any SchemaSnapshotSink)? = nil) {
        self.session = session
        self.snapshotSink = snapshotSink
    }

    public func objects(forceRefresh: Bool = false) async throws -> [SchemaObject] {
        if !forceRefresh, let cachedObjects {
            return cachedObjects
        }
        let objects = try await session.connection.introspector.objects(in: nil)
        cachedObjects = objects
        snapshotSink?.recordSnapshot(profileID: session.profileID, objects: objects)
        return objects
    }

    public func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        try await session.connection.introspector.tableDetail(ref)
    }

    /// TR-04 quick-info panel — not cached (unlike `objects`/`tableDetail`
    /// via the catalog's normal flow): row count/size are meant to be
    /// refreshed on demand, not stale from the last schema load.
    public func tableStats(_ ref: TableRef) async throws -> TableStats {
        try await session.connection.introspector.tableStats(ref)
    }

    public func ddl(of object: SchemaObject) async throws -> String {
        try await session.connection.introspector.ddl(of: object)
    }

    public func invalidate() {
        cachedObjects = nil
    }
}
