import BerryStore
import Foundation

/// Reads the stored schema: one version row per table or view, the foreign
/// keys between them, their statistics, and the change history. Every read
/// asks the store for what it answers, rather than loading the whole graph
/// and filtering it, so a lookup by name or a page of objects costs what it
/// returns.
public struct GraphReader: Sendable {
    /// Most objects or change entries one page returns, whatever the caller
    /// asks for.
    public static let maximumPageSize = 200
    /// A schema last checked longer ago than this is reported as stale.
    public static let staleAfter: TimeInterval = 60

    let store: BerryStore

    public init(store: BerryStore) {
        self.store = store
    }

    /// One page of current objects ordered by namespace, name and kind.
    /// `nextOffset` is the offset of the next page, or nil when this page
    /// reaches the last matching object.
    public struct ObjectPage: Sendable {
        public let objects: [SchemaObjectRecord]
        /// The current foreign keys whose source is one of `objects`, ordered
        /// by source and target.
        public let relations: [SchemaRelationRecord]
        public let total: Int
        public let nextOffset: Int?
    }

    /// A table, view, column or index whose name contains a search needle.
    /// `table` names the object a column or index belongs to.
    public struct Match: Sendable, Equatable {
        public let name: String
        /// `"table"`, `"view"`, `"column"` or `"index"`.
        public let kind: String
        public let database: String?
        public let table: String?
    }

    /// How current the stored schema is, and why it may not be.
    public struct State: Sendable, Equatable {
        /// When a pass last confirmed the stored schema against the database.
        public let checkedAt: Date?
        /// When a pass last found the schema changed.
        public let changedAt: Date?
        /// Moves with every committed change of the stored objects,
        /// definitions or relations, including one written by a pass that
        /// then failed, which leaves `changedAt` as it was.
        public let revision: Int
        /// Whether the schema was never checked or last checked more than
        /// `staleAfter` ago.
        public let stale: Bool
        public let objectCount: Int
        public let detailedCount: Int
        /// The schemas the harvest is limited to, or nil for the driver's
        /// default scope (`SchemaScope.allUserSchemas`).
        public let selectedSchemas: [String]?
        /// `"selectSchemas"` when the catalog is too large to harvest whole.
        public let hint: String?
        public let lastErrorCode: String?
    }

    /// A page of current objects. `names` narrows it to objects whose name
    /// equals an entry, or whose namespace and name equal an entry split at
    /// its last `.`. Each entry is a point lookup on the stored name first;
    /// an entry that matches nothing that way is compared again ignoring case.
    ///
    /// `limit` is clamped to 1...`maximumPageSize`, so `nextOffset` always
    /// moves forward. The page also stops before an object whose estimated
    /// size (`estimatedSize(of:foreignKeys:)`) would take it past `maxBytes`,
    /// but it always holds at least one object when any remains: a definition
    /// larger than the whole budget still makes progress, one page at a time.
    ///
    /// With `includeRelations` false the foreign keys are neither read nor
    /// counted in the estimate, for a listing that shows none.
    public func objects(
        profileID: UUID, names: [String]?, offset: Int, limit: Int, maxBytes: Int, includeRelations: Bool = true
    ) throws -> ObjectPage {
        let start = max(0, offset)
        let page = try store.currentSchemaObjects(
            profileID: profileID, names: names, offset: start, limit: Self.clampedLimit(limit)
        )
        let relations = includeRelations ? try store.currentSchemaRelations(
            profileID: profileID, sources: page.rows.map { (database: $0.database, name: $0.name) }
        ) : []
        let bySource = Dictionary(grouping: relations) { ObjectKey(database: $0.srcDatabase, name: $0.srcName) }
        var objects: [SchemaObjectRecord] = []
        var bytes = 0
        for row in page.rows {
            let size = Self.estimatedSize(of: row, foreignKeys: bySource[ObjectKey(row)] ?? [])
            if !objects.isEmpty, bytes + size > maxBytes { break }
            objects.append(row)
            bytes += size
        }
        let kept = Set(objects.map(ObjectKey.init))
        let next = start + objects.count
        return ObjectPage(
            objects: objects,
            relations: relations.filter { kept.contains(ObjectKey(database: $0.srcDatabase, name: $0.srcName)) },
            total: page.total, nextOffset: next < page.total ? next : nil
        )
    }

    /// What one object adds to a full listing, estimated high: its definition
    /// as text, not the compressed form the store keeps, its name and
    /// namespace, 160 bytes for its kind, its pending flag and the keys and
    /// punctuation around them, and for each foreign key its four
    /// identifiers plus 90 bytes of keys and punctuation. The
    /// definition's JSON holds every column and index field the listing
    /// serialises and the column defaults besides, so the estimate does not
    /// fall below the compact JSON the MCP layer writes, even for a pending
    /// row that is little more than its names.
    static func estimatedSize(of row: SchemaObjectRecord, foreignKeys: [SchemaRelationRecord]) -> Int {
        var keys = 0
        for key in foreignKeys {
            let target: Int = key.dstDatabase?.utf8.count ?? 0
            keys += key.srcColumn.utf8.count + target + key.dstName.utf8.count + key.dstColumn.utf8.count + 90
        }
        let namespace: Int = row.database?.utf8.count ?? 0
        let definition: Int = row.definition?.utf8.count ?? 0
        return definition + row.name.utf8.count + namespace + 160 + keys
    }

    static func clampedLimit(_ limit: Int) -> Int {
        min(max(limit, 1), maximumPageSize)
    }

    /// Tables and views whose name contains `needle`, then columns, then
    /// indexes. Each kind is ordered by namespace, owning object and name; at
    /// most `limit` matches return.
    ///
    /// A name contains the needle when its UTF-8 bytes, case-folded with
    /// `SchemaSearchText.fold`, contain the needle's folded bytes: case
    /// folding that does not depend on the user's language, so "STRASSE"
    /// finds "straße" and "οδος" finds "ΟΔΟΣ", and a byte comparison, which
    /// is what SQLite's `instr` does on the stored folded text. A name is
    /// matched whole, even one that holds a line break.
    ///
    /// The store answers first whether any name holds the needle, so a needle
    /// that nothing holds costs one pass over its search indexes. Each kind
    /// is then matched in the store, which keeps the folded object, column
    /// and index names apart, and stops once the matches fill the limit:
    /// columns and indexes need definitions, and only those of the objects
    /// whose matches are kept are read. A needle that every index name holds,
    /// such as `pkey`, therefore reads at most `limit` definitions however
    /// large the catalog is.
    public func search(profileID: UUID, needle: String, limit: Int) throws -> [Match] {
        guard limit > 0, !needle.isEmpty, try store.schemaSearchTextContains(profileID: profileID, needle: needle) else {
            return []
        }
        let folded = SchemaSearchText.fold(needle)
        func contains(_ name: String) -> Bool { SchemaSearchText.fold(name).utf8.firstRange(of: folded.utf8) != nil }

        var matches = try store.searchSchemaObjectNames(profileID: profileID, needle: needle, limit: limit).map {
            Match(name: $0.name, kind: $0.kind, database: $0.database, table: nil)
        }
        func order(_ lhs: Match, _ rhs: Match) -> Bool {
            (lhs.database ?? "", lhs.table ?? "", lhs.name) < (rhs.database ?? "", rhs.table ?? "", rhs.name)
        }
        for field in [SchemaSearchField.columns, .indexes] where matches.count < limit {
            let found = try definitionMatches(profileID: profileID, needle: needle, in: field, needed: limit - matches.count) {
                definition, key in
                let names = field == .columns ? definition.columns.map(\.name) : definition.indexes.map(\.name)
                return names.filter(contains).map {
                    Match(name: $0, kind: field == .columns ? "column" : "index", database: key.database, table: key.name)
                }
            }
            matches += found.sorted(by: order)
        }
        return Array(matches.prefix(limit))
    }

    /// The column or index matches of the objects the store lists for
    /// `field`, walked in the listing's order until at least `needed` are
    /// found. An object whose column or index text holds the needle has at
    /// least one such name, so each batch asks for no more objects than
    /// matches are still needed. Their definitions are read by id and
    /// decoded in order, with one decoder, until the matches suffice, so an
    /// object with several matching columns leaves the rest of its batch
    /// undecoded. Rows of one namespace and name, a table and a view of one
    /// name, are finished together, because their matches interleave by
    /// name; a batch also takes the object after its last when the two share
    /// a name.
    private func definitionMatches(
        profileID: UUID, needle: String, in field: SchemaSearchField, needed: Int,
        _ extract: (SchemaDefinition, SchemaSearchKey) -> [Match]
    ) throws -> [Match] {
        let decoder = JSONDecoder()
        var found: [Match] = []
        var previous: SchemaSearchKey?
        var after: (database: String?, name: String, kind: String)?
        while found.count < needed {
            let wanted = min(needed - found.count, Self.maximumPageSize)
            let keys = try store.searchSchemaObjectKeys(
                profileID: profileID, needle: needle, in: field, after: after, limit: wanted + 1
            )
            var batch = Array(keys.prefix(wanted))
            if keys.count > wanted, let last = batch.last, keys[wanted].database == last.database, keys[wanted].name == last.name {
                batch.append(keys[wanted])
            }
            guard let last = batch.last else { break }
            let definitions = try store.schemaObjectDefinitions(ids: batch.map(\.id))
            for key in batch {
                if found.count >= needed, let previous, previous.database != key.database || previous.name != key.name {
                    return found
                }
                previous = key
                guard let json = definitions[key.id],
                      let definition = try? decoder.decode(SchemaDefinition.self, from: Data(json.utf8))
                else { continue }
                found += extract(definition, key)
            }
            guard keys.count > batch.count else { break }
            after = (last.database, last.name, last.kind)
        }
        return found
    }

    /// Whether a schema last checked at `checkedAt` is stale at `now`: never
    /// checked, or checked more than `staleAfter` ago.
    public static func isStale(checkedAt: Date?, now: Date) -> Bool {
        checkedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
    }

    public func state(profileID: UUID, now: Date = Date()) throws -> State {
        let record = try store.schemaGraphState(profileID: profileID)
        let checkedAt = record?.lastCheckedAt
        return State(
            checkedAt: checkedAt,
            changedAt: record?.lastChangedAt,
            revision: record?.revision ?? 0,
            stale: Self.isStale(checkedAt: checkedAt, now: now),
            objectCount: record?.objectCount ?? 0,
            detailedCount: record?.detailedCount ?? 0,
            // A selection that does not decode is treated by the harvest as
            // no selection, so it is reported as none here too.
            selectedSchemas: record?.selectedSchemas.flatMap {
                try? JSONDecoder().decode([String].self, from: Data($0.utf8))
            },
            hint: record?.hint,
            lastErrorCode: record?.lastErrorCode
        )
    }

    /// Current tables and views joined by the foreign keys between them: the
    /// graph that dependency queries traverse, without the column and index
    /// nodes they never visit, built from names alone.
    ///
    /// The nodes carry no statistics. A statistics refresh replaces the rows
    /// without changing the schema, so a graph kept between refreshes, as the
    /// MCP helper does, would hold counters that are out of date; callers read
    /// them from `stats(profileID:objects:)` instead.
    public func tableGraph(profileID: UUID) throws -> SchemaGraph {
        let objects = try store.currentSchemaObjectNames(profileID: profileID)
        let relations = try store.currentSchemaRelationEnds(profileID: profileID)
        var builder = GraphAssembly()
        builder.graph.reserveCapacity(nodes: objects.count, edges: relations.count)
        for object in objects {
            builder.addObject(database: object.database, name: object.name, kind: object.kind)
        }
        for relation in relations { builder.addRelation(relation) }
        return builder.graph
    }

    /// Tables and views with their columns, indexes and foreign keys as they
    /// were at `asOf`, or now when it is nil: the shape `SchemaGraphBuilder`
    /// produces from a live catalog, so the analyzers read either alike.
    /// The store keeps only the latest statistics, so a graph of the past
    /// carries today's counters.
    public func fullGraph(profileID: UUID, asOf: Date?) throws -> SchemaGraph {
        let objects: [SchemaObjectRecord]
        let relations: [SchemaRelationRecord]
        if let asOf {
            objects = try store.schemaObjects(profileID: profileID, asOf: asOf)
            relations = try store.schemaRelations(profileID: profileID, asOf: asOf)
        } else {
            objects = try store.currentSchemaObjects(profileID: profileID)
            relations = try store.currentSchemaRelations(profileID: profileID)
        }
        var builder = GraphAssembly()
        for object in objects {
            builder.addObject(database: object.database, name: object.name, kind: object.kind)
            if let definition = Self.definition(of: object) { builder.addDefinition(definition, of: object) }
        }
        for relation in relations { builder.addRelation(relation.ends) }
        builder.addStatistics(try store.schemaStats(profileID: profileID))
        return builder.graph
    }

    /// How many current tables and views each schema holds, ordered by schema,
    /// with nil for the objects of an engine without namespaces: what a scope
    /// picker lists.
    public func schemaCounts(profileID: UUID) throws -> [(database: String?, count: Int)] {
        try store.schemaObjectCountsBySchema(profileID: profileID)
    }

    /// The statistics of those of `objects` that have a row, read by key and
    /// as plain values.
    public func stats(profileID: UUID, objects: [(database: String?, name: String)]) throws -> [SchemaStatsValues] {
        try store.schemaStatsValues(profileID: profileID, objects: objects)
    }

    /// The statistics of one table or view, read by key.
    public func stats(profileID: UUID, database: String?, name: String) throws -> SchemaStatsRecord? {
        try store.schemaStats(profileID: profileID, database: database, name: name)
    }

    /// The definition of a row, or nil while its detail is pending. A
    /// definition that does not decode is treated as pending too, so one
    /// malformed row cannot fail every read of the connection.
    static func definition(of row: SchemaObjectRecord) -> SchemaDefinition? {
        guard let json = row.definition else { return nil }
        return try? SchemaDefinition.decode(json)
    }

    /// The table counters of a statistics row that are known, as node
    /// attributes.
    static func counterAttributes(of stats: SchemaStatsRecord) -> [String: String] {
        counterAttributes([
            ("rows", stats.rows), ("size_bytes", stats.sizeBytes), ("seq_scan", stats.seqScan), ("idx_scan", stats.idxScan),
        ])
    }

    static func counterAttributes(of stats: SchemaStatsValues) -> [String: String] {
        counterAttributes([
            ("rows", stats.rows), ("size_bytes", stats.sizeBytes), ("seq_scan", stats.seqScan), ("idx_scan", stats.idxScan),
        ])
    }

    private static func counterAttributes(_ counters: [(String, Int64?)]) -> [String: String] {
        var attributes: [String: String] = [:]
        for case let (key, value?) in counters { attributes[key] = String(value) }
        return attributes
    }

    /// Per-index counters of a statistics row, keyed by index name.
    static func indexCounters(of stats: SchemaStatsRecord) -> [String: Int64?] {
        indexCounters(of: stats.indexStats, decoder: JSONDecoder())
    }

    /// Per-index counters of a row's `indexStats` text. A caller reading many
    /// rows passes one decoder for all of them.
    static func indexCounters(of json: String?, decoder: JSONDecoder) -> [String: Int64?] {
        struct Counters: Decodable { let idxScan: Int64? }
        guard let json, let decoded = try? decoder.decode([String: Counters].self, from: Data(json.utf8)) else { return [:] }
        return decoded.mapValues(\.idxScan)
    }

    /// The statistic attributes of an index: its scan count, and whether it
    /// was never scanned.
    static func indexAttributes(scans: Int64?) -> [String: String] {
        guard let scans else { return [:] }
        return ["idx_scan": String(scans), "unused": scans == 0 ? "true" : "false"]
    }
}

/// An object's namespace and name: what a foreign key names its ends by, and
/// what statistics are keyed on.
struct ObjectKey: Hashable {
    let database: String?
    let name: String

    init(database: String?, name: String) {
        self.database = database
        self.name = name
    }

    init(_ row: SchemaObjectRecord) {
        self.init(database: row.database, name: row.name)
    }
}
