import Foundation

/// A collection/table-like grouping inside a `DataSourceDriver` (Mongo
/// collection, Qdrant collection) — the sibling of `SchemaObject`
/// (BerryDriverKit), scoped down to what schema-less stores actually have.
public struct CollectionRef: Sendable, Hashable, Identifiable {
    public let database: String?
    public let name: String
    public var id: String { "\(database ?? "").\(name)" }

    public init(database: String? = nil, name: String) {
        self.database = database
        self.name = name
    }
}

/// Query shapes native to each `DataSourceDriver` — no shared SQL-like
/// surface exists across document/vector stores, so this stays a closed
/// per-driver enum rather than a generic string.
public enum DataSourceQuery: Sendable {
    case mongoFind(collection: String, filter: BerryDocument, projection: BerryDocument?, limit: Int?)
    case mongoAggregate(collection: String, pipeline: [BerryDocument])
    /// `getIndexes()` — lists every index on the collection (always includes
    /// at least the default `_id_` index).
    case mongoListIndexes(collection: String)
    case qdrantSearch(collection: String, vector: [Float], filter: BerryDocument?, topK: Int, scoreThreshold: Double?)
    case qdrantScroll(collection: String, filter: BerryDocument?, pageToken: String?)
    /// Query DSL search, bounded by `from`/`size` — the ES analogue of
 /// `.qdrantSearch`'s bounded top-K. `query`
    /// `.null` (or an empty object) means "match everything", same
    /// empty-means-match-all convention as `.mongoFind`'s `filter`.
    case esSearch(index: String, query: BerryDocument, from: Int, size: Int)
    /// Point-in-Time + `search_after` deep pagination — the ES analogue of
 /// `.qdrantScroll`'s offset-token paging: one
    /// page per call, `pageToken` opaquely carries the open PIT id plus the
    /// last hit's sort values forward.
    case esScroll(index: String, query: BerryDocument, pageToken: String?)
}

/// Result stream event — mirrors `ResultEvent` (BerryDriverKit): batched
/// 500–1000 items (principle N3), terminated by `.complete`.
public enum DataSourceEvent: Sendable {
    case items([BerryDocument])
    case complete(DataSourceStats)
}

public struct DataSourceStats: Sendable {
    public let itemsReturned: Int
    public let duration: Duration
    /// Opaque continuation for `.qdrantScroll`-style sequential paging —
    /// nil when the result set is exhausted.
    public let nextPageToken: String?

    public init(itemsReturned: Int, duration: Duration, nextPageToken: String? = nil) {
        self.itemsReturned = itemsReturned
        self.duration = duration
        self.nextPageToken = nextPageToken
    }
}

/// Write request — the document/vector-store analogue of `ChangeSet`
/// (BerryCore): always previewed in the native command shape before being
/// applied (principle).
public enum DataSourceChangeSet: Sendable {
    case insert(collection: String, document: BerryDocument)
    /// Grid-driven edit: the row's exact `_id`/point-id is already known.
    case update(collection: String, id: BerryDocument, patch: BerryDocument)
    /// Grid-driven delete: the row's exact `_id`/point-id is already known.
    case delete(collection: String, id: BerryDocument)
    /// Shell-script-driven: `updateOne`/`updateMany` target by an arbitrary
    /// filter rather than a known id. `update` carries the full update
    /// document as written (e.g. `{ $set: {...}, $push: {...} }`), not just
    /// a patch — unlike `.update`, which the caller wraps in `$set` itself.
    case updateByFilter(collection: String, filter: BerryDocument, update: BerryDocument, multi: Bool)
    /// Shell-script-driven: `deleteOne`/`deleteMany` target by an arbitrary
    /// filter rather than a known id.
    case deleteByFilter(collection: String, filter: BerryDocument, multi: Bool)
    /// `drop()` — removes the entire collection. Always requires typed
 /// confirmation (Group C) since there is no filter
    /// concept to scope the blast radius the way deleteMany has one.
    case dropCollection(collection: String)
    /// `createIndex(keys, options)` — non-destructive, always `.safe`.
    case createIndex(collection: String, keys: BerryDocument, options: BerryDocument?)
    /// `dropIndex(indexName)` — reversible (the index can be recreated), so
    /// a plain (non-typed) confirm is proportionate.
    case dropIndex(collection: String, indexName: String)
    /// `renameCollection(newName)` — always passes `dropTarget: false` at
    /// the driver layer, so a name collision fails loudly rather than
    /// silently destroying the pre-existing target; that's what keeps this
    /// classifiable as `.safe`.
    case renameCollection(collection: String, newName: String)

    /// Target collection name for this change set.
    public var collection: String {
        switch self {
        case .insert(let c, _),
             .update(let c, _, _),
             .delete(let c, _),
             .updateByFilter(let c, _, _, _),
             .deleteByFilter(let c, _, _),
             .dropCollection(let c),
             .createIndex(let c, _, _),
             .dropIndex(let c, _),
             .renameCollection(let c, _):
            return c
        }
    }
}

public struct DataSourceWriteResult: Sendable {
    public let affectedCount: Int
    public let insertedID: BerryDocument?

    public init(affectedCount: Int, insertedID: BerryDocument? = nil) {
        self.affectedCount = affectedCount
        self.insertedID = insertedID
    }
}
