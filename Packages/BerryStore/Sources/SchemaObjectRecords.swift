import Foundation
import GRDB

/// One version of a table or view. It is valid from `firstSeen` until
/// `removedAt`; a row with no `removedAt` is the current version. A new row is
/// written only when `definitionHash` changes, and `previousID` links it to the
/// version it replaces.
///
/// `database` is nil for an engine with no namespace and is stored as `''`.
/// SQLite treats NULLs as distinct in a UNIQUE index
/// (https://www.sqlite.org/lang_createindex.html#unique_indexes), so a NULL
/// namespace would let the partial unique index admit a second current row.
/// Raw SQL must therefore filter `database = ''`, never `IS NULL`, for an
/// object without a namespace.
public struct SchemaObjectRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "schema_object"

    public var id: Int64?
    public var profileID: UUID
    public var database: String? {
        get { SchemaNamespace.read(storedDatabase) }
        set { storedDatabase = SchemaNamespace.stored(newValue) }
    }
    private var storedDatabase: String
    public var name: String
    /// `"table"` or `"view"`.
    public var kind: String
    public var fingerprint: String?
    public var definitionHash: String?
    /// The columns and indexes as canonical JSON. Nil while the object's
    /// detail has not been fetched yet. The store keeps it compressed; a
    /// fetched record holds the text, decompressed once when it is read.
    public var definition: String? {
        get { storedDefinition?.text }
        set { storedDefinition = newValue.map(StoredDefinition.init(text:)) }
    }
    private var storedDefinition: StoredDefinition?
    /// The column names, folded and newline-separated, which a column search
    /// matches against; empty while the definition is pending.
    public var columnText: String
    /// The index names, folded and newline-separated, which an index search
    /// matches against; empty while the definition is pending.
    public var indexText: String
    /// The name case-folded, which a name search compares whole, kept in step
    /// with `name` on every insert.
    private var searchName: String
    public var firstSeen: Date
    public var removedAt: Date?
    public var previousID: Int64?
    public var changeID: Int64?
    public var removedByChangeID: Int64?
    /// Whether this object's name has not been embedded yet. A row the listing
    /// inserts has it set; a new version of the object inherits it from the row
    /// it replaces, with `embeddingAttempts` back at 0; completing a pending
    /// row in place leaves it alone, because a detail does not change the name;
    /// and closing a row clears it, so only a current row is ever queued. Rows
    /// copied from the per-node graph start with it unset.
    public var needsEmbedding: Bool
    public var embeddingAttempts: Int

    public init(
        id: Int64? = nil, profileID: UUID, database: String?, name: String, kind: String,
        fingerprint: String? = nil, definitionHash: String? = nil, definition: String? = nil,
        columnText: String = "", indexText: String = "", firstSeen: Date, removedAt: Date? = nil, previousID: Int64? = nil,
        changeID: Int64? = nil, removedByChangeID: Int64? = nil,
        needsEmbedding: Bool = false, embeddingAttempts: Int = 0
    ) {
        self.id = id
        self.profileID = profileID
        self.storedDatabase = SchemaNamespace.stored(database)
        self.name = name
        self.kind = kind
        self.fingerprint = fingerprint
        self.definitionHash = definitionHash
        self.storedDefinition = definition.map(StoredDefinition.init(text:))
        self.columnText = columnText
        self.indexText = indexText
        self.searchName = SchemaSearchText.fold(name)
        self.firstSeen = firstSeen
        self.removedAt = removedAt
        self.previousID = previousID
        self.changeID = changeID
        self.removedByChangeID = removedByChangeID
        self.needsEmbedding = needsEmbedding
        self.embeddingAttempts = embeddingAttempts
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, storedDatabase = "database", name, kind, fingerprint, definitionHash
        case storedDefinition = "definition"
        case columnText, indexText, searchName, firstSeen, removedAt, previousID, changeID, removedByChangeID
        case needsEmbedding, embeddingAttempts
    }

    public mutating func willInsert(_ db: Database) throws {
        searchName = SchemaSearchText.fold(name)
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The form names are searched in: case-folded with Foundation's
/// `folding(options: .caseInsensitive, locale: nil)`, whose nil locale is
/// Foundation's system locale rather than the user's. The stored search
/// text and name and every search needle are folded alike, so a name
/// matches whatever case either is written in. Verified with Swift 6.3.3 on
/// macOS 26: it folds "ß" to "ss", both sigmas to one, "ﬁ" to "fi", the
/// micro sign and capital mu to mu and a long s to "s", which lower-casing
/// does not, leaves a line break as it is, and applies no Turkish rule to a
/// dotted capital I. The search tests pin those pairs in both directions.
public enum SchemaSearchText {
    public static func fold(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: nil)
    }

    /// `names` folded and newline-separated: the column or index text of
    /// one object.
    public static func joined(_ names: [String]) -> String {
        fold(names.joined(separator: "\n"))
    }
}

/// A name waiting for its embedding, with the id of the version its vector
/// is stored through.
public struct SchemaEmbeddingQueueEntry: Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

/// Which folded names of a definition a search matches against.
public enum SchemaSearchField: Sendable {
    case columns, indexes
}

/// A current object whose column or index names hold a search needle: its
/// version's id, for reading the definition, and its place in the listing's
/// order.
public struct SchemaSearchKey: Sendable, Equatable {
    public let id: Int64
    public let database: String?
    public let name: String
    /// `"table"` or `"view"`.
    public let kind: String

    public init(id: Int64, database: String?, name: String, kind: String) {
        self.id = id
        self.database = database
        self.name = name
        self.kind = kind
    }
}

/// A definition in the form the store keeps it: the canonical JSON
/// compressed with LZFSE in a BLOB. A 20-column definition of about 2 KB took
/// a 4 KB page to itself as text; compressed, several rows share a page.
/// LZFSE was chosen by measurement with Apple's Compression framework on
/// macOS 26, on a 2,017-byte definition: 433 bytes and 1.7 microseconds to
/// decompress, against 322 bytes and 13 microseconds for zlib and 518 bytes
/// for LZ4. A page of objects decompresses each of its rows, so the faster
/// read was worth the 111 bytes.
///
/// Text, which is written when compression fails, reads back as it is. A
/// blob that does not decompress reads back as text that is not a
/// definition. Every reader treats that as a definition not yet read, so
/// one damaged row fails no read of the connection and its object is listed
/// as pending. The store does not repair it: the row still counts as read,
/// so a listing does not ask for the object's detail again, and a detail
/// write with an unchanged hash refreshes only the fingerprint. The damage
/// stays until the object's definition changes and a new version replaces
/// the row. Checking each stored definition on every detail write would cost
/// a decompression per object per pass for an engine without fingerprints.
struct StoredDefinition: DatabaseValueConvertible, Codable, Sendable, Hashable {
    let text: String

    init(text: String) {
        self.text = text
    }

    // Codable lets a record that holds one synthesize its own conformance. A
    // record persists and fetches it through `DatabaseValueConvertible`:
    // GRDB 7.11.1's record coding prefers that conformance over Codable for
    // any property that has it, in GRDB/Record/EncodableRecord+Encodable.swift
    // and GRDB/Record/FetchableRecord+Decodable.swift
    // (https://github.com/groue/GRDB.swift/tree/v7.11.1/GRDB/Record), and a
    // store test reads the column back as a blob after a record insert.
    // Outside the store, Codable gives the text.

    init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    // NSData's compression methods return autoreleased objects, and no
    // autorelease pool drains on the threads the store reads and writes on:
    // without a pool around each call, every definition read or written
    // stayed alive, and paging a hundred pages of changes kept 117 MB in a
    // release build (measured with malloc_zone_statistics).

    /// The text when compression fails, which the reader accepts as well.
    var databaseValue: DatabaseValue {
        autoreleasepool {
            guard let compressed = try? (Data(text.utf8) as NSData).compressed(using: .lzfse) else {
                return text.databaseValue
            }
            return (compressed as Data).databaseValue
        }
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> StoredDefinition? {
        switch dbValue.storage {
        case let .blob(data):
            return autoreleasepool {
                guard let text = try? (data as NSData).decompressed(using: .lzfse) as Data else {
                    return StoredDefinition(text: String(decoding: data, as: UTF8.self))
                }
                return StoredDefinition(text: String(decoding: text, as: UTF8.self))
            }
        case let .string(text):
            return StoredDefinition(text: text)
        case .null, .int64, .double:
            return nil
        }
    }
}

/// Where an entry of a change's object side sits: the object, the version,
/// and whether the change introduced that version or closed it. Entries are
/// ordered by namespace, name, kind and version id, an introduced version
/// before a closed one of the same id.
public struct SchemaObjectChangePosition: Sendable, Hashable {
    public let database: String?
    public let name: String
    /// `"table"` or `"view"`.
    public let kind: String
    public let id: Int64
    public let introduced: Bool

    public init(database: String?, name: String, kind: String, id: Int64, introduced: Bool) {
        self.database = database
        self.name = name
        self.kind = kind
        self.id = id
        self.introduced = introduced
    }
}

/// One entry of a change's object side, without the version's definition:
/// a version the change introduced, or one it closed without introducing
/// the version that replaced it.
public struct SchemaObjectChangeEntry: Sendable, Equatable {
    public let position: SchemaObjectChangePosition
    /// The version this one replaced, or nil for an object first seen here.
    public let previousID: Int64?
}

/// Where an entry of a change's relation side sits: the relation's ends, its
/// row, and whether the change added or closed it. Entries are ordered by
/// source, target and row id, an added relation before a closed one of the
/// same id.
public struct SchemaRelationChangePosition: Sendable, Hashable {
    public let ends: SchemaRelationEnds
    public let id: Int64
    public let introduced: Bool

    public init(ends: SchemaRelationEnds, id: Int64, introduced: Bool) {
        self.ends = ends
        self.id = id
        self.introduced = introduced
    }
}

/// A foreign key from one column to another, valid from `firstSeen` until
/// `removedAt`.
///
/// `srcDatabase` and `dstDatabase` are nil for an engine with no namespace and
/// are stored as `''`. SQLite treats NULLs as distinct in a UNIQUE index
/// (https://www.sqlite.org/lang_createindex.html#unique_indexes), so a NULL
/// namespace would let the partial unique index admit a second current row.
/// Raw SQL must therefore filter `srcDatabase = ''` or `dstDatabase = ''`,
/// never `IS NULL`, for an endpoint without a namespace.
public struct SchemaRelationRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "schema_relation"

    public var id: Int64?
    public var profileID: UUID
    public var srcDatabase: String? {
        get { SchemaNamespace.read(storedSrcDatabase) }
        set { storedSrcDatabase = SchemaNamespace.stored(newValue) }
    }
    private var storedSrcDatabase: String
    public var srcName: String
    public var srcColumn: String
    public var dstDatabase: String? {
        get { SchemaNamespace.read(storedDstDatabase) }
        set { storedDstDatabase = SchemaNamespace.stored(newValue) }
    }
    private var storedDstDatabase: String
    public var dstName: String
    public var dstColumn: String
    public var constraintName: String?
    public var firstSeen: Date
    public var removedAt: Date?
    public var changeID: Int64?
    public var removedByChangeID: Int64?

    public init(
        id: Int64? = nil, profileID: UUID,
        srcDatabase: String?, srcName: String, srcColumn: String,
        dstDatabase: String?, dstName: String, dstColumn: String,
        constraintName: String? = nil, firstSeen: Date, removedAt: Date? = nil,
        changeID: Int64? = nil, removedByChangeID: Int64? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.storedSrcDatabase = SchemaNamespace.stored(srcDatabase)
        self.srcName = srcName
        self.srcColumn = srcColumn
        self.storedDstDatabase = SchemaNamespace.stored(dstDatabase)
        self.dstName = dstName
        self.dstColumn = dstColumn
        self.constraintName = constraintName
        self.firstSeen = firstSeen
        self.removedAt = removedAt
        self.changeID = changeID
        self.removedByChangeID = removedByChangeID
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileID, storedSrcDatabase = "srcDatabase", srcName, srcColumn
        case storedDstDatabase = "dstDatabase", dstName, dstColumn
        case constraintName, firstSeen, removedAt, changeID, removedByChangeID
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The two column ends of a foreign key, without its dates or ids: what a
/// graph of the tables needs from each relation.
public struct SchemaRelationEnds: Sendable, Hashable {
    public let srcDatabase: String?
    public let srcName: String
    public let srcColumn: String
    public let dstDatabase: String?
    public let dstName: String
    public let dstColumn: String

    public init(
        srcDatabase: String?, srcName: String, srcColumn: String, dstDatabase: String?, dstName: String, dstColumn: String
    ) {
        self.srcDatabase = srcDatabase
        self.srcName = srcName
        self.srcColumn = srcColumn
        self.dstDatabase = dstDatabase
        self.dstName = dstName
        self.dstColumn = dstColumn
    }
}

extension SchemaRelationRecord {
    public var ends: SchemaRelationEnds {
        SchemaRelationEnds(
            srcDatabase: srcDatabase, srcName: srcName, srcColumn: srcColumn,
            dstDatabase: dstDatabase, dstName: dstName, dstColumn: dstColumn
        )
    }
}

/// One object's statistics as plain values, without its update time: what a
/// summary of many tables reads, at a fraction of the cost of decoding each
/// row as a `SchemaStatsRecord`.
public struct SchemaStatsValues: Sendable, Equatable {
    public let database: String?
    public let name: String
    public let rows: Int64?
    public let sizeBytes: Int64?
    public let seqScan: Int64?
    public let idxScan: Int64?
    /// JSON object of per-index counters, as `SchemaStatsRecord.indexStats`.
    public let indexStats: String?

    public init(
        database: String?, name: String, rows: Int64?, sizeBytes: Int64?, seqScan: Int64?, idxScan: Int64?, indexStats: String?
    ) {
        self.database = database
        self.name = name
        self.rows = rows
        self.sizeBytes = sizeBytes
        self.seqScan = seqScan
        self.idxScan = idxScan
        self.indexStats = indexStats
    }
}

/// Live statistics for one object, overwritten in place on every pass.
///
/// `database` is nil for an engine with no namespace and is stored as `''`.
/// SQLite accepts NULL in a composite PRIMARY KEY
/// (https://www.sqlite.org/lang_createtable.html#the_primary_key) and never
/// matches it, so with a NULL namespace `save` would insert a second row
/// instead of overwriting the first. Raw SQL must filter `database = ''`,
/// never `IS NULL`, for an object without a namespace.
public struct SchemaStatsRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "schema_stats"

    public var profileID: UUID
    public var database: String? {
        get { SchemaNamespace.read(storedDatabase) }
        set { storedDatabase = SchemaNamespace.stored(newValue) }
    }
    private var storedDatabase: String
    public var name: String
    public var rows: Int64?
    public var sizeBytes: Int64?
    public var seqScan: Int64?
    public var idxScan: Int64?
    /// JSON object of per-index counters, `{"index_name": {"idxScan": n}}`.
    public var indexStats: String?
    public var updatedAt: Date

    public init(
        profileID: UUID, database: String?, name: String,
        rows: Int64? = nil, sizeBytes: Int64? = nil, seqScan: Int64? = nil, idxScan: Int64? = nil,
        indexStats: String? = nil, updatedAt: Date
    ) {
        self.profileID = profileID
        self.storedDatabase = SchemaNamespace.stored(database)
        self.name = name
        self.rows = rows
        self.sizeBytes = sizeBytes
        self.seqScan = seqScan
        self.idxScan = idxScan
        self.indexStats = indexStats
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case profileID, storedDatabase = "database", name, rows, sizeBytes, seqScan, idxScan, indexStats, updatedAt
    }
}

/// One pass that changed the schema, with how many objects and relations it
/// added, changed and removed.
public struct SchemaChangeRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "schema_change"

    public var id: Int64?
    public var profileID: UUID
    public var at: Date
    public var added: Int
    public var changed: Int
    public var removed: Int
    public var relationsAdded: Int
    public var relationsRemoved: Int

    public init(
        id: Int64? = nil, profileID: UUID, at: Date,
        added: Int, changed: Int, removed: Int, relationsAdded: Int, relationsRemoved: Int
    ) {
        self.id = id
        self.profileID = profileID
        self.at = at
        self.added = added
        self.changed = changed
        self.removed = removed
        self.relationsAdded = relationsAdded
        self.relationsRemoved = relationsRemoved
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Per-profile harvest state: what the last pass saw, and why the next one is
/// delayed or needs the user's attention.
public struct SchemaGraphStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "schema_graph_state"

    public var profileID: UUID
    public var versionToken: String?
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
    /// JSON array of schema names, or nil for the driver's default scope.
    public var selectedSchemas: String?
    public var objectCount: Int
    public var detailedCount: Int
    public var lastErrorCode: String?
    public var lastErrorAt: Date?
    public var retryAfter: Date?
    /// `"selectSchemas"` when the catalog is too large to harvest whole, else nil.
    public var hint: String?
    /// Moves with every committed write that changes the stored objects,
    /// definitions or relations, whether or not the pass that wrote it
    /// completed, so a cache of the stored graph can key on it.
    public var revision: Int

    public init(profileID: UUID) {
        self.profileID = profileID
        objectCount = 0
        detailedCount = 0
        revision = 0
    }
}

/// One object as a catalog listing reports it, before its columns are read.
public struct SchemaListedObject: Sendable, Hashable {
    public let database: String?
    public let name: String
    /// `"table"` or `"view"`.
    public let kind: String
    /// A cheap token that changes whenever the object's structure may have
    /// changed, or nil when the engine has none.
    public let fingerprint: String?

    public init(database: String?, name: String, kind: String, fingerprint: String?) {
        self.database = database
        self.name = name
        self.kind = kind
        self.fingerprint = fingerprint
    }
}

/// One foreign-key column pair as a catalog listing reports it. The
/// constraint name is not part of the relation's identity: the store keeps at
/// most one current relation per source and destination column pair.
public struct SchemaListedRelation: Sendable, Hashable {
    public let srcDatabase: String?
    public let srcName: String
    public let srcColumn: String
    public let dstDatabase: String?
    public let dstName: String
    public let dstColumn: String
    public let constraintName: String?

    public init(
        srcDatabase: String?, srcName: String, srcColumn: String,
        dstDatabase: String?, dstName: String, dstColumn: String, constraintName: String?
    ) {
        self.srcDatabase = srcDatabase
        self.srcName = srcName
        self.srcColumn = srcColumn
        self.dstDatabase = dstDatabase
        self.dstName = dstName
        self.dstColumn = dstColumn
        self.constraintName = constraintName
    }
}

public struct SchemaListingOutcome: Sendable, Equatable {
    public let added: Int
    public let removed: Int
    public let relationsAdded: Int
    public let relationsRemoved: Int
    /// The change row the listing wrote, or nil when nothing changed.
    public let changeID: Int64?
    /// The listed objects whose columns must be read: new ones, ones still
    /// without a definition, and ones whose fingerprint moved or is unknown.
    public let detailNeeded: [SchemaListedObject]
}

public struct SchemaRelationOutcome: Sendable, Equatable {
    public let added: Int
    public let removed: Int
    /// The change row the added and closed relations are attributed to, or nil
    /// when none was passed in and no relation changed.
    public let changeID: Int64?
}

/// An object's columns and indexes as read from the catalog.
public struct SchemaDetailWrite: Sendable, Hashable {
    public let database: String?
    public let name: String
    public let kind: String
    public let fingerprint: String?
    public let definitionHash: String
    /// Canonical JSON of the columns and indexes.
    public let definition: String
    /// The column names and the index names a search looks through, as
    /// `SchemaSearchText.joined` writes them. They must already be folded: a
    /// search folds only its needle, so text kept in another case would never
    /// match.
    public let columnText: String
    public let indexText: String

    public init(
        database: String?, name: String, kind: String, fingerprint: String?,
        definitionHash: String, definition: String, columnText: String = "", indexText: String = ""
    ) {
        self.database = database
        self.name = name
        self.kind = kind
        self.fingerprint = fingerprint
        self.definitionHash = definitionHash
        self.definition = definition
        self.columnText = columnText
        self.indexText = indexText
    }
}

public struct SchemaDetailOutcome: Sendable, Equatable {
    /// Objects whose definition changed, each written as a new version.
    public let changed: Int
    /// Objects whose definition hash was equal, so only the fingerprint was refreshed.
    public let unchanged: Int
    /// Objects whose first definition was written into their existing row.
    public let completed: Int
    /// The change row the new versions are attributed to, or nil when none was
    /// passed in and no version was written.
    public let changeID: Int64?
}

/// The mapping between a namespace in the Swift API (nil: the engine has none)
/// and its stored form (`''`).
enum SchemaNamespace {
    static func stored(_ namespace: String?) -> String { namespace ?? "" }

    static func read(_ stored: String) -> String? { stored.isEmpty ? nil : stored }
}
