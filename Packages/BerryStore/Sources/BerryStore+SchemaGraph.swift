import Foundation
import GRDB

/// The scope a harvest pass started with: the stored `selectedSchemas` it
/// read, nil for the driver's default scope. A pass hands it to each of its
/// writes.
public struct PassScope: Sendable, Equatable {
    public let selectedSchemas: String?

    public init(selectedSchemas: String?) {
        self.selectedSchemas = selectedSchemas
    }
}

/// A pass's write was refused because the stored scope is no longer the one
/// the pass started with: what it read describes the catalog of the old
/// scope, and writing it would bring back objects the new scope left out.
public struct ScopeChanged: Error, Equatable {
    public init() {}
}

extension BerryStore {
    /// Brings the stored objects and relations in line with a complete catalog
    /// listing, in one transaction.
    ///
    /// An object the listing no longer has is closed here, not when its detail
    /// would have been read: a drop is recorded at the pass that sees it, even
    /// if the pass stops before the detail work. A newly listed object gets a
    /// pending row with no definition, so an interrupted pass still leaves the
    /// object known and the next pass knows its detail is missing.
    ///
    /// The listing must cover the profile's whole scope; every stored object it
    /// leaves out is closed, and so is every stored relation `relations` leaves
    /// out. With `relations` nil the stored relations are left as they are: an
    /// engine that reads foreign keys only with each table's detail supplies
    /// them later through `applySchemaRelations`.
    ///
    /// With `scope`, the write is refused with `ScopeChanged`, writing nothing,
    /// once the stored scope is not the one the pass started with.
    public func applySchemaListing(
        profileID: UUID, objects: [SchemaListedObject], relations: [SchemaListedRelation]?, now: Date,
        scope: PassScope? = nil
    ) throws -> SchemaListingOutcome {
        try write { db in
            try Self.requireScope(scope, profileID: profileID, db)
            var change = SchemaChangeStamp(profileID: profileID, now: now)

            var currentObjects: [String: CurrentObject] = [:]
            let objectRows = try Row.fetchCursor(db, sql: """
                SELECT id, database, name, kind, fingerprint, definition IS NULL AS pending
                FROM schema_object WHERE profileID = ? AND removedAt IS NULL
                """, arguments: [profileID])
            while let row = try objectRows.next() {
                currentObjects[Self.schemaKey(row["database"], row["name"], row["kind"])] = CurrentObject(
                    id: row["id"], name: row["name"], fingerprint: row["fingerprint"], pending: row["pending"]
                )
            }

            var listedKeys = Set<String>()
            var detailNeeded: [SchemaListedObject] = []
            var added = 0
            for object in objects {
                let key = Self.schemaKey(SchemaNamespace.stored(object.database), object.name, object.kind)
                guard listedKeys.insert(key).inserted else { continue }
                if let current = currentObjects[key] {
                    // A missing fingerprint on either side cannot prove the
                    // structure is unchanged.
                    if current.pending || current.fingerprint == nil || object.fingerprint == nil
                        || current.fingerprint != object.fingerprint {
                        detailNeeded.append(object)
                    }
                } else {
                    var pending = SchemaObjectRecord(
                        profileID: profileID, database: object.database, name: object.name, kind: object.kind,
                        firstSeen: now, changeID: try change.resolve(db), needsEmbedding: true
                    )
                    try pending.insert(db)
                    detailNeeded.append(object)
                    added += 1
                }
            }
            var removed = 0
            var removedNames = Set<String>()
            for (key, current) in currentObjects where !listedKeys.contains(key) {
                try Self.closeObject(id: current.id, now: now, changeID: try change.resolve(db), replaced: false, db)
                removedNames.insert(current.name)
                removed += 1
            }
            if !removedNames.isEmpty {
                // Once this write commits, the current objects are exactly the
                // listed ones, so a removed name is still current only when
                // the listing has it. Asking the store instead, once per
                // removal, read every current row of the profile each time.
                try Self.deleteEmbeddings(of: removedNames.subtracting(objects.map(\.name)), profileID: profileID, db)
            }

            var relationDiff = (added: 0, removed: 0)
            if let relations {
                relationDiff = try Self.applyRelationSet(relations, profileID: profileID, now: now, change: &change, db)
            }

            // Derived from the rows already read: a pending row is the only
            // kind without a definition, and removals are exactly the keys
            // that were not listed.
            let detailed = currentObjects.filter { listedKeys.contains($0.key) && !$0.value.pending }.count
            let changedGraph = added + removed + relationDiff.added + relationDiff.removed > 0
            try Self.upsertState(db, profileID: profileID) {
                $0.objectCount = listedKeys.count
                $0.detailedCount = detailed
                if changedGraph { $0.revision += 1 }
            }
            return SchemaListingOutcome(
                added: added, removed: removed,
                relationsAdded: relationDiff.added, relationsRemoved: relationDiff.removed,
                changeID: change.id, detailNeeded: detailNeeded
            )
        }
    }

    /// Writes the definitions of one chunk of objects, in one transaction.
    ///
    /// A pending row, with no definition yet, is completed in place: its first
    /// definition is not a change of anything, and a version for it would make
    /// every first harvest write two rows per table. A detail for an object the
    /// store has no current row for is dropped, because the listing that
    /// removed it is the newer fact and resurrecting it would contradict that.
    ///
    /// A row copied from the per-node graph is completed in place too when the
    /// new definition differs only in column order and column defaults. That
    /// store recorded each table's columns in dictionary order and never
    /// recorded a default, so neither is a change the first time such a table
    /// is read again: a `serial` key or a `DEFAULT now()` column would
    /// otherwise version nearly every table of a typical schema, and the
    /// change feed would report defaults that appeared out of nowhere. The
    /// row then keeps the new definition, defaults included. Any other
    /// difference closes the row and writes a new version.
    ///
    /// `changeID` attributes new versions to a change row an earlier call of
    /// the same pass created. With nil, the row is created when the first new
    /// version is written, and returned so the next chunk can pass it.
    ///
    /// With `scope`, the write is refused with `ScopeChanged`, writing nothing,
    /// once the stored scope is not the one the pass started with.
    public func applySchemaDetails(
        profileID: UUID, details: [SchemaDetailWrite], now: Date, changeID: Int64?, scope: PassScope? = nil
    ) throws -> SchemaDetailOutcome {
        try write { db in
            try Self.requireScope(scope, profileID: profileID, db)
            var change = SchemaChangeStamp(profileID: profileID, now: now, id: changeID)
            // The stored definition is read, and decompressed, only for a row
            // the upgrade wrote, the one case that compares it.
            let lookup = try db.cachedStatement(sql: """
                SELECT id, definition IS NULL AS pending, definitionHash, fingerprint, previousID, changeID, needsEmbedding
                FROM schema_object WHERE profileID = ? AND database = ? AND name = ? AND kind = ? AND removedAt IS NULL
                """)
            let storedDefinition = try db.cachedStatement(sql: "SELECT definition FROM schema_object WHERE id = ?")
            let complete = try db.cachedStatement(sql: """
                UPDATE schema_object SET definition = ?, definitionHash = ?, fingerprint = ?, columnText = ?, indexText = ?
                WHERE id = ?
                """)
            var changed = 0
            var unchanged = 0
            var completed = 0
            for detail in details {
                let arguments: StatementArguments = [profileID, SchemaNamespace.stored(detail.database), detail.name, detail.kind]
                guard let current = try Row.fetchOne(lookup, arguments: arguments) else { continue }
                let id: Int64 = current["id"]
                // Binding the definition compresses it, so only a write that
                // stores it binds it.
                func completeInPlace() throws {
                    try complete.execute(arguments: [
                        StoredDefinition(text: detail.definition), detail.definitionHash, detail.fingerprint,
                        detail.columnText, detail.indexText, id,
                    ])
                }
                if current["pending"] {
                    try completeInPlace()
                    completed += 1
                    continue
                }
                if (current["definitionHash"] as String?) == detail.definitionHash {
                    try db.execute(sql: "UPDATE schema_object SET fingerprint = ? WHERE id = ?", arguments: [detail.fingerprint, id])
                    unchanged += 1
                } else if Self.isUpgradedRow(current),
                          let stored = try StoredDefinition.fetchOne(storedDefinition, arguments: [id]),
                          Self.sameUpgradedDefinition(stored.text, detail.definition) {
                    try completeInPlace()
                    completed += 1
                } else {
                    let versionChange = try change.resolve(db)
                    // Closing clears the flag, so the new version takes over the
                    // closed row's place in the embedding queue.
                    let queued: Bool = current["needsEmbedding"]
                    try Self.closeObject(id: id, now: now, changeID: versionChange, replaced: true, db)
                    var next = SchemaObjectRecord(
                        profileID: profileID, database: detail.database, name: detail.name, kind: detail.kind,
                        fingerprint: detail.fingerprint, definitionHash: detail.definitionHash,
                        definition: detail.definition, columnText: detail.columnText, indexText: detail.indexText,
                        firstSeen: now,
                        previousID: id, changeID: versionChange, needsEmbedding: queued
                    )
                    try next.insert(db)
                    changed += 1
                }
            }
            // The detailed count moves only when a pending row gained its
            // definition; a new version replaces a row that already had one.
            if completed > 0 {
                let detailed = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM schema_object WHERE profileID = ? AND removedAt IS NULL AND definition IS NOT NULL
                    """, arguments: [profileID]) ?? 0
                try Self.upsertState(db, profileID: profileID) {
                    $0.detailedCount = detailed
                    $0.revision += 1
                }
            } else if changed > 0 {
                try Self.upsertState(db, profileID: profileID) { $0.revision += 1 }
            }
            return SchemaDetailOutcome(changed: changed, unchanged: unchanged, completed: completed, changeID: change.id)
        }
    }

    /// Brings the stored relations in line with `relations`, the complete
    /// foreign-key set of the profile's scope, in one transaction: the same
    /// diff a listing with relations performs, for an engine that reads
    /// foreign keys only with each table's detail.
    ///
    /// `changeID` attributes the added and closed relations to a change row an
    /// earlier call of the same pass created. With nil, the row is created
    /// when the first relation changes.
    ///
    /// With `scope`, the write is refused with `ScopeChanged`, writing nothing,
    /// once the stored scope is not the one the pass started with.
    public func applySchemaRelations(
        profileID: UUID, relations: [SchemaListedRelation], now: Date, changeID: Int64?, scope: PassScope? = nil
    ) throws -> SchemaRelationOutcome {
        try write { db in
            try Self.requireScope(scope, profileID: profileID, db)
            var change = SchemaChangeStamp(profileID: profileID, now: now, id: changeID)
            let diff = try Self.applyRelationSet(relations, profileID: profileID, now: now, change: &change, db)
            if diff.added + diff.removed > 0 {
                try Self.upsertState(db, profileID: profileID) { $0.revision += 1 }
            }
            return SchemaRelationOutcome(added: diff.added, removed: diff.removed, changeID: change.id)
        }
    }

    /// Overwrites the counts of a change row once the pass that wrote it knows
    /// them; the row is inserted with zero counts because a pass learns what
    /// changed only as it goes.
    public func finishSchemaChange(
        id: Int64, added: Int, changed: Int, removed: Int, relationsAdded: Int, relationsRemoved: Int
    ) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE schema_change
                SET added = ?, changed = ?, removed = ?, relationsAdded = ?, relationsRemoved = ?
                WHERE id = ?
                """, arguments: [added, changed, removed, relationsAdded, relationsRemoved, id])
        }
    }

    /// Sets the counts of change `id` from the rows that carry it, as the
    /// change listing reads its entries: versions it introduced without an
    /// earlier one are added, with one changed, and versions it closed
    /// without a successor removed. For a change some of whose rows were
    /// deleted after it was written, by a scope narrowed while its pass ran.
    public func recountSchemaChange(id: Int64, profileID: UUID) throws {
        try write { db in
            try db.execute(sql: """
                UPDATE schema_change SET
                    added = (SELECT COUNT(*) FROM schema_object
                             WHERE profileID = ?1 AND changeID = ?2 AND previousID IS NULL),
                    changed = (SELECT COUNT(*) FROM schema_object
                               WHERE profileID = ?1 AND changeID = ?2 AND previousID IS NOT NULL),
                    removed = (SELECT COUNT(*) FROM schema_object
                               WHERE profileID = ?1 AND removedByChangeID = ?2 AND replaced = 0),
                    relationsAdded = (SELECT COUNT(*) FROM schema_relation WHERE profileID = ?1 AND changeID = ?2),
                    relationsRemoved = (SELECT COUNT(*) FROM schema_relation WHERE profileID = ?1 AND removedByChangeID = ?2)
                WHERE id = ?2 AND profileID = ?1
                """, arguments: [profileID, id])
        }
    }

    public func schemaGraphState(profileID: UUID) throws -> SchemaGraphStateRecord? {
        try read { try SchemaGraphStateRecord.fetchOne($0, key: profileID) }
    }

    /// Applies `mutate` to the profile's state, creating the state first when
    /// the profile has none. A mutation that changes `selectedSchemas` also
    /// drops the version token.
    ///
    /// With `scope`, the write is refused with `ScopeChanged`, writing nothing,
    /// once the stored scope is not the one the pass started with.
    public func updateSchemaGraphState(
        profileID: UUID, scope: PassScope? = nil, _ mutate: (inout SchemaGraphStateRecord) -> Void
    ) throws {
        try write { db in
            try Self.requireScope(scope, profileID: profileID, db)
            try Self.upsertState(db, profileID: profileID, mutate)
        }
    }

    /// Stores the profile's scope, the schemas a harvest is limited to or
    /// nil for the driver's default, and with a selection shrinks the stored
    /// graph to it, all in one transaction. A pass that started between two
    /// separate writes would list the new scope while the rows outside it
    /// still stood, record them as removed, and leave a change row whose
    /// counts outlived the deleted rows.
    ///
    /// Shrinking deletes every version of every object, current or closed,
    /// outside the selected schemas, the relations whose source table is
    /// outside them and the statistics of the objects outside them. Nothing
    /// is closed instead, because the objects still exist in the database:
    /// the next listing does not contain them, and a closed row or a stale
    /// relation would be recorded there as a drop that never happened. A
    /// relation from a kept table into a removed schema stays: a listing reads
    /// the foreign keys of the tables in its scope wherever they point, so the
    /// next one returns it again, and deleting it would record it there as
    /// added. It then points at an object the store does not hold, as a key
    /// into a schema never selected does.
    ///
    /// The name vector of a deleted object goes too, unless another current
    /// object of the profile still carries the name. `lastChangedAt` becomes
    /// `now` and the revision moves, so a cache keyed on either rebuilds. A change of scope drops the
    /// version token in any case, because it describes the catalog of the
    /// old scope and would stop the next pass before it lists the new one.
    ///
    /// Schemas compare as stored, so an object with no namespace has the
    /// empty string as its schema and is kept only when the selection
    /// contains `""`.
    public func saveSchemaScope(profileID: UUID, selectedSchemas: [String]?, now: Date) throws {
        let json = try selectedSchemas.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try write { db in
            try Self.upsertState(db, profileID: profileID) { $0.selectedSchemas = json }
            guard let keep = selectedSchemas else { return }
            let outside = SchemaObjectRecord
                .filter(Column("profileID") == profileID)
                .filter(!keep.contains(Column("database")))
            let removedNames = try String.fetchSet(
                db, outside.filter(Column("removedAt") == nil).select(Column("name"))
            )
            _ = try outside.deleteAll(db)
            _ = try SchemaRelationRecord
                .filter(Column("profileID") == profileID)
                .filter(!keep.contains(Column("srcDatabase")))
                .deleteAll(db)
            _ = try SchemaStatsRecord
                .filter(Column("profileID") == profileID)
                .filter(!keep.contains(Column("database")))
                .deleteAll(db)
            // Read once rather than per removed name, since a shrink can drop
            // thousands of objects at a time.
            let currentNames = try String.fetchSet(db, sql: """
                SELECT name FROM schema_object WHERE profileID = ? AND removedAt IS NULL
                """, arguments: [profileID])
            let deleteEmbedding = try db.cachedStatement(
                sql: "DELETE FROM schema_object_embedding WHERE profileID = ? AND objectKey = ?"
            )
            for name in removedNames.subtracting(currentNames) {
                try deleteEmbedding.execute(arguments: [profileID.uuidString, "\(profileID.uuidString)#\(name)"])
            }
            let counts = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS objects, COUNT(definition) AS detailed
                FROM schema_object WHERE profileID = ? AND removedAt IS NULL
                """, arguments: [profileID])
            try Self.upsertState(db, profileID: profileID) {
                $0.objectCount = counts?["objects"] ?? 0
                $0.detailedCount = counts?["detailed"] ?? 0
                $0.lastChangedAt = now
                $0.versionToken = nil
                $0.revision += 1
            }
        }
    }
}

extension BerryStore {
    /// A name queued for embedding is retried this many times before the queue
    /// stops offering it, so a name the provider keeps rejecting cannot sit at
    /// the head of the queue on every pass.
    private static let schemaEmbeddingAttemptLimit = 5

    /// One page of the profile's current objects ordered by namespace, name and
    /// kind, with the number of objects that match.
    ///
    /// `names` narrows the result to objects whose name equals an entry, or
    /// whose namespace and name equal an entry split at its last `.`, so that
    /// `shop.orders` finds `orders` in `shop`. An entry that contains a dot is
    /// also compared whole, because a name such as `system.profile` can itself
    /// contain one. An empty array matches nothing.
    ///
    /// Each entry is first looked up exactly. Only an entry that matches no
    /// object that way is compared again ignoring case, so an exact name never
    /// also selects the objects that differ from it only in case. All of it
    /// runs in one read, so the count and the page describe the same rows.
    public func currentSchemaObjects(
        profileID: UUID, names: [String]?, offset: Int, limit: Int
    ) throws -> (rows: [SchemaObjectRecord], total: Int) {
        guard let names else {
            return try read { db in
                let total = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM schema_object WHERE profileID = ? AND removedAt IS NULL", arguments: [profileID]
                ) ?? 0
                let rows = try SchemaObjectRecord.fetchAll(db, sql: """
                    SELECT * FROM schema_object WHERE profileID = ? AND removedAt IS NULL
                    ORDER BY database, name, kind LIMIT ? OFFSET ?
                    """, arguments: [profileID, limit, offset])
                return (rows, total)
            }
        }
        guard !names.isEmpty else { return ([], 0) }
        return try read { db in
            var exact: [String] = []
            var missed: [String] = []
            for name in names {
                let probe = Self.objectNameFilter([name])
                let found = try Bool.fetchOne(
                    db.cachedStatement(sql: Self.namedObjectExistsSQL(probe.clause)),
                    arguments: StatementArguments([profileID] + probe.arguments)
                ) ?? false
                if found { exact.append(name) } else { missed.append(name) }
            }
            var clauses: [String] = []
            var arguments: [(any DatabaseValueConvertible)?] = [profileID]
            if !exact.isEmpty {
                let filter = Self.objectNameFilter(exact)
                clauses.append(filter.clause)
                arguments += filter.arguments
            }
            if !missed.isEmpty {
                let folded = try Self.caseInsensitiveMatches(of: missed, profileID: profileID, db)
                for name in folded.names {
                    clauses.append("name = ?")
                    arguments.append(name)
                }
                for (database, name) in folded.pairs {
                    clauses.append("(database = ? AND name = ?)")
                    arguments += [database, name]
                }
            }
            guard !clauses.isEmpty else { return ([], 0) }
            let clause = clauses.joined(separator: " OR ")
            let total = try Int.fetchOne(db, sql: Self.namedObjectsCountSQL(clause), arguments: StatementArguments(arguments)) ?? 0
            let rows = try SchemaObjectRecord.fetchAll(
                db, sql: Self.namedObjectsPageSQL(clause), arguments: StatementArguments(arguments + [limit, offset])
            )
            return (rows, total)
        }
    }

    /// Every current object with its definition, ordered by namespace, name
    /// and kind: a whole graph's worth of rows, without the count a page needs.
    public func currentSchemaObjects(profileID: UUID) throws -> [SchemaObjectRecord] {
        try read { db in
            try SchemaObjectRecord.fetchAll(db, sql: """
                SELECT * FROM schema_object WHERE profileID = ? AND removedAt IS NULL ORDER BY database, name, kind
                """, arguments: [profileID])
        }
    }

    /// The stored names that equal `entries` once both are folded as a name
    /// search folds them (`SchemaSearchText.fold`), under the same two rules
    /// as an exact lookup: `names` match an entry whole in any namespace,
    /// `pairs` match its namespace and name split at the last `.`. Returned
    /// as exact values, so the page that follows is again a set of point
    /// lookups.
    ///
    /// Each entry seeks its folded name on the folded-name index, which the
    /// harvest keeps for every current row, so a name that matches nothing,
    /// the common case when an agent guesses one, reads no other row. SQLite's
    /// `NOCASE` would fold only the 26 ASCII letters
    /// (https://www.sqlite.org/datatype3.html#collating_sequences).
    private static func caseInsensitiveMatches(
        of entries: [String], profileID: UUID, _ db: Database
    ) throws -> (names: [String], pairs: [(String, String)]) {
        let lookup = try db.cachedStatement(sql: foldedNameLookupSQL)
        var names = Set<String>()
        var pairs: [String: (String, String)] = [:]
        for entry in entries {
            for row in try Row.fetchAll(lookup, arguments: [profileID, SchemaSearchText.fold(entry)]) {
                names.insert(row["name"])
            }
            guard let dot = entry.lastIndex(of: ".") else { continue }
            let database = SchemaSearchText.fold(String(entry[..<dot]))
            let name = SchemaSearchText.fold(String(entry[entry.index(after: dot)...]))
            for row in try Row.fetchAll(lookup, arguments: [profileID, name]) {
                let stored: (database: String, name: String) = (row["database"], row["name"])
                if SchemaSearchText.fold(stored.database) == database {
                    pairs[schemaKey(stored.database, stored.name)] = stored
                }
            }
        }
        return (names.sorted(), pairs.keys.sorted().compactMap { pairs[$0] })
    }

    static let foldedNameLookupSQL = """
        SELECT database, name FROM schema_object INDEXED BY schema_object_folded_name
        WHERE profileID = ? AND removedAt IS NULL AND searchName = ?
        """

    /// The namespace, name and kind of every current object, ordered by them,
    /// read from the current-row index alone without touching a definition.
    public func currentSchemaObjectNames(profileID: UUID) throws -> [(database: String?, name: String, kind: String)] {
        try read { db in
            var result: [(database: String?, name: String, kind: String)] = []
            let rows = try Row.fetchCursor(db, sql: Self.currentObjectNamesSQL, arguments: [profileID])
            while let row = try rows.next() {
                result.append((SchemaNamespace.read(row["database"]), row["name"], row["kind"]))
            }
            return result
        }
    }

    // The statements of a lookup by name are internal so a test can read the
    // query plan of exactly what the API runs. Each names the current-row
    // index: with the `removedAt IS NULL` term, SQLite 3.51.0 plans the count
    // over the history index and then reads every current row's table row to
    // compare its name, while the current-row index holds the namespace and
    // name and answers from the index alone. On 20,000 current rows with
    // 1.9 KB definitions in a file database, counting one name took 12 to
    // 13 ms that way and 0.95 ms with the index named.

    /// The condition that selects `names`, and the arguments it binds.
    static func objectNameFilter(_ names: [String]) -> (clause: String, arguments: [(any DatabaseValueConvertible)?]) {
        var clauses: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        for name in names {
            clauses.append("name = ?")
            arguments.append(name)
            if let dot = name.lastIndex(of: ".") {
                clauses.append("(database = ? AND name = ?)")
                arguments.append(String(name[..<dot]))
                arguments.append(String(name[name.index(after: dot)...]))
            }
        }
        return (clauses.joined(separator: " OR "), arguments)
    }

    static func namedObjectExistsSQL(_ clause: String) -> String {
        """
        SELECT EXISTS (SELECT 1 FROM schema_object INDEXED BY schema_object_current
                       WHERE profileID = ? AND removedAt IS NULL AND (\(clause)))
        """
    }

    static let currentObjectNamesSQL = """
        SELECT database, name, kind FROM schema_object INDEXED BY schema_object_current
        WHERE profileID = ? AND removedAt IS NULL ORDER BY database, name, kind
        """

    static func namedObjectsCountSQL(_ clause: String) -> String {
        "SELECT COUNT(*) FROM schema_object INDEXED BY schema_object_current WHERE profileID = ? AND removedAt IS NULL AND (\(clause))"
    }

    static func namedObjectsPageSQL(_ clause: String) -> String {
        """
        SELECT * FROM schema_object INDEXED BY schema_object_current
        WHERE profileID = ? AND removedAt IS NULL AND (\(clause))
        ORDER BY database, name, kind LIMIT ? OFFSET ?
        """
    }

    /// Whether the folded name, column names or index names of any current
    /// object of the profile contain `needle`, folded alike. A search asks
    /// this first, so a needle that nothing holds costs one pass over each
    /// search index.
    public func schemaSearchTextContains(profileID: UUID, needle: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(
                db.cachedStatement(sql: Self.searchTextContainsSQL), arguments: [profileID, SchemaSearchText.fold(needle)]
            ) ?? false
        }
    }

    /// The current tables and views whose whole name contains `needle`, at
    /// most `limit`: tables first, then views, each ordered by namespace, name
    /// and kind. Both are compared case-folded, the name as it is kept in the
    /// `searchName` column.
    public func searchSchemaObjectNames(
        profileID: UUID, needle: String, limit: Int
    ) throws -> [(database: String?, name: String, kind: String)] {
        try read { db in
            var result: [(database: String?, name: String, kind: String)] = []
            let rows = try Row.fetchCursor(
                db.cachedStatement(sql: Self.searchNamesSQL), arguments: [profileID, SchemaSearchText.fold(needle), limit]
            )
            while let row = try rows.next() {
                result.append((SchemaNamespace.read(row[0]), row[1], row[2]))
            }
            return result
        }
    }

    /// The current objects that have a column, or an index, whose name
    /// contains `needle`, ordered by namespace, name and kind, at most `limit`
    /// of them, starting after the object `after` names. Only keys are read,
    /// from the search index alone; a caller reads the definitions of the
    /// ones it keeps by id. Both sides are compared case-folded.
    public func searchSchemaObjectKeys(
        profileID: UUID, needle: String, in field: SchemaSearchField,
        after: (database: String?, name: String, kind: String)? = nil, limit: Int
    ) throws -> [SchemaSearchKey] {
        var arguments: [(any DatabaseValueConvertible)?] = [profileID, SchemaSearchText.fold(needle)]
        if let after { arguments += [SchemaNamespace.stored(after.database), after.name, after.kind] }
        arguments.append(limit)
        return try read { db in
            var keys: [SchemaSearchKey] = []
            let rows = try Row.fetchCursor(
                db.cachedStatement(sql: Self.searchKeysSQL(field, after: after != nil)), arguments: StatementArguments(arguments)
            )
            while let row = try rows.next() {
                keys.append(SchemaSearchKey(id: row[0], database: SchemaNamespace.read(row[1]), name: row[2], kind: row[3]))
            }
            return keys
        }
    }

    // The search statements read the search indexes: the folded names of the
    // current rows in one, their column and index names in the other, both
    // ahead of the definition the table row holds. `instr(X, Y)` finds the
    // first occurrence of Y in X and gives no character in Y a special
    // meaning (https://www.sqlite.org/lang_corefunc.html#instr), so the needle
    // needs no escaping.

    static let searchTextContainsSQL = """
        SELECT EXISTS (SELECT 1 FROM schema_object INDEXED BY schema_object_folded_name
                       WHERE profileID = ?1 AND removedAt IS NULL AND instr(searchName, ?2) > 0)
            OR EXISTS (SELECT 1 FROM schema_object INDEXED BY schema_object_search
                       WHERE profileID = ?1 AND removedAt IS NULL AND (instr(columnText, ?2) > 0 OR instr(indexText, ?2) > 0))
        """

    /// Ordering by whether the object is a view sorts the matches only. With
    /// the limit, SQLite keeps at most `limit` of them while it sorts: EXPLAIN
    /// on SQLite 3.51.0 shows each new match compared with the sorter's last
    /// row once the sorter holds `limit` rows, and that row deleted when the
    /// match sorts before it (`IfNotZero`, `Last`, `IdxLE`, `Delete`).
    static let searchNamesSQL = """
        SELECT database, name, kind FROM schema_object INDEXED BY schema_object_folded_name
        WHERE profileID = ? AND removedAt IS NULL AND instr(searchName, ?) > 0
        ORDER BY kind = 'view', database, name, kind LIMIT ?
        """

    /// Walks the search index in its own order, so a batch stops after
    /// `limit` matches instead of sorting every match first, and the keyset
    /// term starts the walk where the previous batch ended.
    static func searchKeysSQL(_ field: SchemaSearchField, after: Bool) -> String {
        let text = field == .columns ? "columnText" : "indexText"
        let keyset = after ? "AND (database, name, kind) > (?3, ?4, ?5)" : ""
        return """
            SELECT id, database, name, kind FROM schema_object INDEXED BY schema_object_search
            WHERE profileID = ?1 AND removedAt IS NULL AND instr(\(text), ?2) > 0 \(keyset)
            ORDER BY database, name, kind LIMIT ?\(after ? 6 : 3)
            """
    }

    /// The current relations whose source is one of `sources`, ordered by
    /// source and target: point lookups on the current-relation index, one
    /// per source, in one statement.
    public func currentSchemaRelations(
        profileID: UUID, sources: [(database: String?, name: String)]
    ) throws -> [SchemaRelationRecord] {
        guard !sources.isEmpty else { return [] }
        var arguments: [(any DatabaseValueConvertible)?] = [profileID]
        for source in sources { arguments += [SchemaNamespace.stored(source.database), source.name] }
        return try read { db in
            try SchemaRelationRecord.fetchAll(
                db, sql: Self.relationsFromSourcesSQL(count: sources.count), arguments: StatementArguments(arguments)
            )
        }
    }

    /// A row-value `IN` over a `VALUES` list: SQLite 3.51.0 plans it as one
    /// search of the current-relation index on profile, source namespace and
    /// source name per listed pair, where an `OR` of the same pairs scans every
    /// current relation of the profile (both checked with `EXPLAIN QUERY PLAN`).
    static func relationsFromSourcesSQL(count: Int) -> String {
        let pairs = Array(repeating: "(?, ?)", count: count).joined(separator: ", ")
        return """
            SELECT * FROM schema_relation INDEXED BY schema_relation_current
            WHERE profileID = ? AND removedAt IS NULL AND (srcDatabase, srcName) IN (VALUES \(pairs))
            ORDER BY srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
            """
    }

    /// The ends of every current relation, ordered by source and target, read
    /// as plain values from the current-relation index, which holds every
    /// column the statement names. Decoding the whole records instead put
    /// each date through Codable: for 20,000 relations that took 77 to 112 ms
    /// in a release build, against 6 to 16 ms for the ends alone.
    public func currentSchemaRelationEnds(profileID: UUID) throws -> [SchemaRelationEnds] {
        try read { db in
            var ends: [SchemaRelationEnds] = []
            let rows = try Row.fetchCursor(db.cachedStatement(sql: Self.currentRelationEndsSQL), arguments: [profileID])
            while let row = try rows.next() {
                ends.append(SchemaRelationEnds(
                    srcDatabase: SchemaNamespace.read(row[0]), srcName: row[1], srcColumn: row[2],
                    dstDatabase: SchemaNamespace.read(row[3]), dstName: row[4], dstColumn: row[5]
                ))
            }
            return ends
        }
    }

    static let currentRelationEndsSQL = """
        SELECT srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
        FROM schema_relation INDEXED BY schema_relation_current
        WHERE profileID = ? AND removedAt IS NULL
        ORDER BY srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
        """

    public func currentSchemaRelations(profileID: UUID) throws -> [SchemaRelationRecord] {
        try read { db in
            try SchemaRelationRecord.fetchAll(db, sql: """
                SELECT * FROM schema_relation WHERE profileID = ? AND removedAt IS NULL
                ORDER BY srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
                """, arguments: [profileID])
        }
    }

    /// Through the current-row index, whose second column is the schema,
    /// SQLite reads current rows only and in group order, with no temporary
    /// B-tree. SQLite 3.51.0 picks that index with or without it named
    /// (checked with `EXPLAIN QUERY PLAN` on both forms against these
    /// indexes); it is named so the plan stays there whatever indexes are
    /// added to the table later.
    static let schemaCountsSQL = """
        SELECT database, COUNT(*) AS count FROM schema_object INDEXED BY schema_object_current
        WHERE profileID = ? AND removedAt IS NULL GROUP BY database ORDER BY database
        """

    /// How many current tables and views each schema holds, ordered by schema;
    /// objects without a namespace come first, as a nil schema.
    public func schemaObjectCountsBySchema(profileID: UUID) throws -> [(database: String?, count: Int)] {
        try read { db in
            try Row.fetchAll(db, sql: Self.schemaCountsSQL, arguments: [profileID]).map {
                (database: SchemaNamespace.read($0["database"]), count: $0["count"])
            }
        }
    }

    /// The versions that were current at `asOf`: seen at or before it and not
    /// removed until after it. A version removed exactly at `asOf` is already
    /// gone, because the version that replaced it starts at that same instant.
    public func schemaObjects(profileID: UUID, asOf: Date) throws -> [SchemaObjectRecord] {
        try read { db in
            try SchemaObjectRecord.fetchAll(db, sql: """
                SELECT * FROM schema_object
                WHERE profileID = ? AND firstSeen <= ? AND (removedAt IS NULL OR removedAt > ?)
                ORDER BY database, name, kind
                """, arguments: [profileID, asOf, asOf])
        }
    }

    public func schemaRelations(profileID: UUID, asOf: Date) throws -> [SchemaRelationRecord] {
        try read { db in
            try SchemaRelationRecord.fetchAll(db, sql: """
                SELECT * FROM schema_relation
                WHERE profileID = ? AND firstSeen <= ? AND (removedAt IS NULL OR removedAt > ?)
                ORDER BY srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
                """, arguments: [profileID, asOf, asOf])
        }
    }

    /// Change rows in the order they were written. `afterID` keeps only later
    /// rows, so a caller can resume from the last row it saw; `since` keeps
    /// rows written at or after that instant, and `through` rows written at or
    /// before it.
    public func schemaChanges(
        profileID: UUID, afterID: Int64?, since: Date?, through: Date? = nil, limit: Int
    ) throws -> [SchemaChangeRecord] {
        try read { db in
            var request = SchemaChangeRecord.filter(Column("profileID") == profileID)
            if let afterID { request = request.filter(Column("id") > afterID) }
            if let since { request = request.filter(Column("at") >= since) }
            if let through { request = request.filter(Column("at") <= through) }
            return try request.order(Column("id")).limit(limit).fetchAll(db)
        }
    }

    /// Every change row of the profile, newest first.
    public func schemaChangeMarks(profileID: UUID) throws -> [SchemaChangeRecord] {
        try read { db in
            try SchemaChangeRecord.fetchAll(db, sql: """
                SELECT * FROM schema_change WHERE profileID = ? ORDER BY at DESC, id DESC
                """, arguments: [profileID])
        }
    }

    /// One page of a change's object entries, at most `limit`, starting at
    /// the entry `from` names, or at the change's start after skipping
    /// `skipping` entries when it is nil. The entries are the versions the
    /// change introduced merged with the ones it closed without a successor,
    /// in the order `SchemaObjectChangePosition` describes. Each half is read
    /// from its own index in that order, the closed half from one that holds
    /// only versions closed without a successor, so every row either half
    /// reads is an entry, and SQLite merges the halves and stops at the
    /// limit: a page reads what it returns however large the change is.
    /// Skipping is a walk over the skipped entries, for a cursor whose entry
    /// retention deleted.
    public func schemaObjectChangeEntries(
        profileID: UUID, changeID: Int64, from: SchemaObjectChangePosition?, skipping: Int = 0, limit: Int
    ) throws -> [SchemaObjectChangeEntry] {
        var arguments: [(any DatabaseValueConvertible)?] = [profileID, changeID]
        if let from { arguments += [SchemaNamespace.stored(from.database), from.name, from.kind, from.id] }
        arguments += [limit, skipping]
        return try read { db in
            try Row.fetchAll(
                db.cachedStatement(sql: Self.objectChangeEntriesSQL(from: from.map(\.introduced))),
                arguments: StatementArguments(arguments)
            ).map {
                SchemaObjectChangeEntry(
                    position: SchemaObjectChangePosition(
                        database: SchemaNamespace.read($0[2]), name: $0[3], kind: $0[4], id: $0[0], introduced: $0[5]
                    ),
                    previousID: $0[1]
                )
            }
        }
    }

    /// One page of a change's relation entries, at most `limit`, from the
    /// entry `from` names or after skipping `skipping` entries: the relations
    /// it added merged with the ones it closed, in the order
    /// `SchemaRelationChangePosition` describes, read like
    /// `schemaObjectChangeEntries`.
    public func schemaRelationChangeEntries(
        profileID: UUID, changeID: Int64, from: SchemaRelationChangePosition?, skipping: Int = 0, limit: Int
    ) throws -> [SchemaRelationChangePosition] {
        var arguments: [(any DatabaseValueConvertible)?] = [profileID, changeID]
        if let from {
            let ends = from.ends
            arguments += [
                SchemaNamespace.stored(ends.srcDatabase), ends.srcName, ends.srcColumn,
                SchemaNamespace.stored(ends.dstDatabase), ends.dstName, ends.dstColumn, from.id,
            ]
        }
        arguments += [limit, skipping]
        return try read { db in
            try Row.fetchAll(
                db.cachedStatement(sql: Self.relationChangeEntriesSQL(from: from.map(\.introduced))),
                arguments: StatementArguments(arguments)
            ).map(Self.relationChangePosition)
        }
    }

    /// The position of the entry of change `changeID` for object version
    /// `id` on the side `introduced` names, or nil when the change has no
    /// such entry, as when retention deleted the version.
    public func schemaObjectChangePosition(
        profileID: UUID, changeID: Int64, id: Int64, introduced: Bool
    ) throws -> SchemaObjectChangePosition? {
        let side = introduced ? "changeID = ?" : "removedByChangeID = ? AND replaced = 0"
        return try read { db in
            try Row.fetchOne(db, sql: """
                SELECT database, name, kind FROM schema_object WHERE id = ? AND profileID = ? AND \(side)
                """, arguments: [id, profileID, changeID]).map {
                SchemaObjectChangePosition(
                    database: SchemaNamespace.read($0[0]), name: $0[1], kind: $0[2], id: id, introduced: introduced
                )
            }
        }
    }

    /// The position of the entry of change `changeID` for relation row `id`
    /// on the side `introduced` names, or nil when the change has no such
    /// entry.
    public func schemaRelationChangePosition(
        profileID: UUID, changeID: Int64, id: Int64, introduced: Bool
    ) throws -> SchemaRelationChangePosition? {
        let side = introduced ? "changeID = ?" : "removedByChangeID = ?"
        return try read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn, \(introduced ? 1 : 0)
                FROM schema_relation WHERE id = ? AND profileID = ? AND \(side)
                """, arguments: [id, profileID, changeID]).map(Self.relationChangePosition)
        }
    }

    private static func relationChangePosition(_ row: Row) -> SchemaRelationChangePosition {
        SchemaRelationChangePosition(
            ends: SchemaRelationEnds(
                srcDatabase: SchemaNamespace.read(row[1]), srcName: row[2], srcColumn: row[3],
                dstDatabase: SchemaNamespace.read(row[4]), dstName: row[5], dstColumn: row[6]
            ),
            id: row[0], introduced: row[7]
        )
    }

    // The statements behind the change listing are internal so a test can
    // read the query plan of exactly what the API runs. `from` is nil for the
    // start of a change, else whether the entry a page starts at is an
    // introduced one. An introduced entry precedes a closed one of the same
    // row, so from an introduced entry both halves start at that row, and
    // from a closed one the introduced half starts past it; a row a change
    // both added and closed is then listed once on each side, whatever the
    // page size.

    static func objectChangeEntriesSQL(from introduced: Bool?) -> String {
        let keyset = changeKeyset(key: "(database, name, kind, id)", values: "(?3, ?4, ?5, ?6)", from: introduced)
        let page = introduced == nil ? "LIMIT ?3 OFFSET ?4" : "LIMIT ?7 OFFSET ?8"
        return """
            SELECT id, previousID, database, name, kind, 1 AS introduced
            FROM schema_object INDEXED BY schema_object_change
            WHERE profileID = ?1 AND changeID = ?2 \(keyset.introduced)
            UNION ALL
            SELECT id, previousID, database, name, kind, 0 AS introduced
            FROM schema_object INDEXED BY schema_object_dropped_change
            WHERE profileID = ?1 AND removedByChangeID = ?2 AND replaced = 0 \(keyset.closed)
            ORDER BY database, name, kind, id, introduced DESC
            \(page)
            """
    }

    static func relationChangeEntriesSQL(from introduced: Bool?) -> String {
        let key = "(srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn, id)"
        let keyset = changeKeyset(key: key, values: "(?3, ?4, ?5, ?6, ?7, ?8, ?9)", from: introduced)
        let page = introduced == nil ? "LIMIT ?3 OFFSET ?4" : "LIMIT ?10 OFFSET ?11"
        let columns = "id, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn"
        return """
            SELECT \(columns), 1 AS introduced
            FROM schema_relation INDEXED BY schema_relation_change
            WHERE profileID = ?1 AND changeID = ?2 \(keyset.introduced)
            UNION ALL
            SELECT \(columns), 0 AS introduced
            FROM schema_relation INDEXED BY schema_relation_removed_change
            WHERE profileID = ?1 AND removedByChangeID = ?2 \(keyset.closed)
            ORDER BY srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn, id, introduced DESC
            \(page)
            """
    }

    private static func changeKeyset(key: String, values: String, from introduced: Bool?) -> (introduced: String, closed: String) {
        guard let introduced else { return ("", "") }
        return ("AND \(key) \(introduced ? ">=" : ">") \(values)", "AND \(key) >= \(values)")
    }

    /// The definitions of the versions with these ids, by id. A version
    /// still pending has none, and an id whose row retention deleted is
    /// missing. Only the id and the definition are read: a change page diffs
    /// up to 400 versions, and decoding each as a whole record took a sixth
    /// of such a page in a release build.
    public func schemaObjectDefinitions(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try read { db in
            var definitions: [Int64: String] = [:]
            let rows = try Row.fetchCursor(
                db, sql: "SELECT id, definition FROM schema_object WHERE id IN (\(placeholders)) AND definition IS NOT NULL",
                arguments: StatementArguments(ids)
            )
            while let row = try rows.next() {
                if let definition = StoredDefinition.fromDatabaseValue(row[1]) { definitions[row[0]] = definition.text }
            }
            return definitions
        }
    }

    public func schemaStats(profileID: UUID) throws -> [SchemaStatsRecord] {
        try read { db in
            try SchemaStatsRecord.fetchAll(db, sql: """
                SELECT * FROM schema_stats WHERE profileID = ? ORDER BY database, name
                """, arguments: [profileID])
        }
    }

    /// The statistics of those of `objects` that have a row, as plain values,
    /// in no particular order. Each object is a lookup by the table's primary
    /// key, at most 500 to a statement, so a caller that keeps a few hundred
    /// tables of a large schema reads their rows alone. A whole profile's
    /// rows decoded as records, with a date each, took 77 to 112 ms in a
    /// release build at 20,000 rows.
    public func schemaStatsValues(profileID: UUID, objects: [(database: String?, name: String)]) throws -> [SchemaStatsValues] {
        guard !objects.isEmpty else { return [] }
        return try read { db in
            var values: [SchemaStatsValues] = []
            for start in stride(from: 0, to: objects.count, by: Self.statsLookupsPerStatement) {
                let chunk = objects[start..<min(start + Self.statsLookupsPerStatement, objects.count)]
                var arguments: [(any DatabaseValueConvertible)?] = [profileID]
                for object in chunk { arguments += [SchemaNamespace.stored(object.database), object.name] }
                let rows = try Row.fetchCursor(
                    db, sql: Self.statsValuesSQL(count: chunk.count), arguments: StatementArguments(arguments)
                )
                while let row = try rows.next() {
                    values.append(SchemaStatsValues(
                        database: SchemaNamespace.read(row[0]), name: row[1], rows: row[2], sizeBytes: row[3],
                        seqScan: row[4], idxScan: row[5], indexStats: row[6]
                    ))
                }
            }
            return values
        }
    }

    /// Two bound values each, well under SQLite's default limit of 32,766
    /// variables per statement (https://www.sqlite.org/limits.html#max_variable_number).
    static let statsLookupsPerStatement = 500

    /// A row-value `IN` over a `VALUES` list, which SQLite plans as one search
    /// of the primary key per listed pair, as `relationsFromSourcesSQL` is.
    static func statsValuesSQL(count: Int) -> String {
        let pairs = Array(repeating: "(?, ?)", count: count).joined(separator: ", ")
        return """
            SELECT database, name, rows, sizeBytes, seqScan, idxScan, indexStats FROM schema_stats
            WHERE profileID = ? AND (database, name) IN (VALUES \(pairs))
            """
    }

    /// The statistics of one object, read by the table's primary key.
    public func schemaStats(profileID: UUID, database: String?, name: String) throws -> SchemaStatsRecord? {
        try read { db in
            try SchemaStatsRecord.fetchOne(db, sql: """
                SELECT * FROM schema_stats WHERE profileID = ? AND database = ? AND name = ?
                """, arguments: [profileID, SchemaNamespace.stored(database), name])
        }
    }

    /// Replaces the profile's statistics with `rows`, which must carry the same
    /// profile ID, in one transaction. A pass that no longer reports an object
    /// therefore drops its row instead of leaving stale counters behind.
    public func replaceSchemaStats(profileID: UUID, rows: [SchemaStatsRecord]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM schema_stats WHERE profileID = ?", arguments: [profileID])
            for row in rows { try row.insert(db) }
        }
    }

    /// The current objects whose name still needs an embedding, oldest first.
    /// A closed row is excluded here as well as by the flag it no longer
    /// carries, so the queue stays correct for any row written some other way.
    ///
    /// The index is named because the `removedAt IS NULL` term otherwise makes
    /// SQLite 3.51.0 scan the profile's whole history index and test the flag
    /// row by row, instead of reading the few flagged rows the partial index
    /// holds (checked with `EXPLAIN QUERY PLAN` on both forms).
    ///
    /// Only the id and the name are read: a drain reads the queue for every
    /// batch, and a whole row would also decompress a definition it never
    /// uses.
    public func schemaObjectsNeedingEmbedding(profileID: UUID, limit: Int) throws -> [SchemaEmbeddingQueueEntry] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name FROM schema_object INDEXED BY schema_object_embedding_queue
                WHERE profileID = ? AND needsEmbedding = 1 AND embeddingAttempts < ? AND removedAt IS NULL
                ORDER BY firstSeen, id LIMIT ?
                """, arguments: [profileID, Self.schemaEmbeddingAttemptLimit, limit]
            ).map { SchemaEmbeddingQueueEntry(id: $0[0], name: $0[1]) }
        }
    }

    public func recordSchemaEmbeddingFailure(id: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE schema_object SET embeddingAttempts = embeddingAttempts + 1 WHERE id = ?", arguments: [id]
            )
        }
    }

    /// Deletes closed versions and relations that were removed before
    /// `olderThan`, then the oldest closed ones beyond `cap` of each kind, so a
    /// connection that changes constantly cannot grow its history without
    /// bound. Current rows are never deleted. A change row older than
    /// `olderThan` goes once no version or relation refers to it.
    ///
    /// A surviving version's `previousID` can point at a deleted row, so a
    /// reader that follows it must expect the link to end.
    public func pruneSchemaHistory(profileID: UUID, olderThan: Date, keepingAtMost cap: Int) throws {
        try write { db in
            try Self.pruneClosedRows(db, table: "schema_object", profileID: profileID, olderThan: olderThan, cap: cap)
            try Self.pruneClosedRows(db, table: "schema_relation", profileID: profileID, olderThan: olderThan, cap: cap)
            try db.execute(sql: """
                DELETE FROM schema_change
                WHERE profileID = ? AND at < ? AND id NOT IN (
                    SELECT changeID FROM schema_object WHERE profileID = ? AND changeID IS NOT NULL
                    UNION SELECT removedByChangeID FROM schema_object WHERE profileID = ? AND removedByChangeID IS NOT NULL
                    UNION SELECT changeID FROM schema_relation WHERE profileID = ? AND changeID IS NOT NULL
                    UNION SELECT removedByChangeID FROM schema_relation WHERE profileID = ? AND removedByChangeID IS NOT NULL
                )
                """, arguments: [profileID, olderThan, profileID, profileID, profileID, profileID])
        }
    }

    /// Removes everything the store holds about a profile's schema: versions,
    /// relations, statistics, change rows, harvest state and name embeddings.
    /// `deleteProfile` runs it in the same transaction as the profile row.
    static func deleteSchemaGraphRows(_ db: Database, profileID: UUID) throws {
        for table in ["schema_object", "schema_relation", "schema_stats", "schema_change", "schema_graph_state"] {
            try db.execute(sql: "DELETE FROM \(table) WHERE profileID = ?", arguments: [profileID])
        }
        try db.execute(sql: "DELETE FROM schema_object_embedding WHERE profileID = ?", arguments: [profileID.uuidString])
    }

    /// Both history tables have an `id` and a `removedAt`, and each has an index
    /// that starts with the profile and `removedAt`, so the age step is a range
    /// scan and the cap step reads the oldest rows in index order. The cap step
    /// deletes through a bounded subquery instead of loading the rows.
    private static func pruneClosedRows(
        _ db: Database, table: String, profileID: UUID, olderThan: Date, cap: Int
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(table) WHERE profileID = ? AND removedAt IS NOT NULL AND removedAt < ?",
            arguments: [profileID, olderThan]
        )
        let closed = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM \(table) WHERE profileID = ? AND removedAt IS NOT NULL", arguments: [profileID]
        ) ?? 0
        guard closed > cap else { return }
        try db.execute(sql: """
            DELETE FROM \(table) WHERE id IN (
                SELECT id FROM \(table) WHERE profileID = ? AND removedAt IS NOT NULL ORDER BY removedAt ASC LIMIT ?
            )
            """, arguments: [profileID, closed - cap])
    }
}

/// The row of one pass in `schema_change`. It is written the first time the
/// pass changes something, so a pass that finds nothing new leaves no row.
private struct SchemaChangeStamp {
    let profileID: UUID
    let now: Date
    var id: Int64?

    mutating func resolve(_ db: Database) throws -> Int64 {
        if let id { return id }
        var record = SchemaChangeRecord(
            profileID: profileID, at: now, added: 0, changed: 0, removed: 0, relationsAdded: 0, relationsRemoved: 0
        )
        try record.insert(db)
        let inserted = db.lastInsertedRowID
        id = inserted
        return inserted
    }
}

/// The fields of a current object row a listing compares against.
private struct CurrentObject {
    let id: Int64
    let name: String
    let fingerprint: String?
    let pending: Bool
}

extension BerryStore {
    /// Joined with the unit separator so that, for example, `("a", "bc")` and
    /// `("ab", "c")` stay different keys.
    private static func schemaKey(_ parts: String...) -> String {
        parts.joined(separator: "\u{1F}")
    }

    /// Inserts the relations of `relations` that are not current and closes the
    /// current ones it leaves out. A relation is identified by its two column
    /// ends; the constraint name is not part of the key.
    private static func applyRelationSet(
        _ relations: [SchemaListedRelation], profileID: UUID, now: Date, change: inout SchemaChangeStamp, _ db: Database
    ) throws -> (added: Int, removed: Int) {
        var current: [String: Int64] = [:]
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn
            FROM schema_relation WHERE profileID = ? AND removedAt IS NULL
            """, arguments: [profileID])
        while let row = try rows.next() {
            current[relationKey(row)] = row["id"]
        }
        var listedKeys = Set<String>()
        var added = 0
        for relation in relations {
            let key = schemaKey(
                SchemaNamespace.stored(relation.srcDatabase), relation.srcName, relation.srcColumn,
                SchemaNamespace.stored(relation.dstDatabase), relation.dstName, relation.dstColumn
            )
            guard listedKeys.insert(key).inserted, current[key] == nil else { continue }
            var record = SchemaRelationRecord(
                profileID: profileID,
                srcDatabase: relation.srcDatabase, srcName: relation.srcName, srcColumn: relation.srcColumn,
                dstDatabase: relation.dstDatabase, dstName: relation.dstName, dstColumn: relation.dstColumn,
                constraintName: relation.constraintName, firstSeen: now, changeID: try change.resolve(db)
            )
            try record.insert(db)
            added += 1
        }
        var removed = 0
        for (key, id) in current where !listedKeys.contains(key) {
            try closeRelation(id: id, now: now, changeID: try change.resolve(db), db)
            removed += 1
        }
        return (added, removed)
    }

    private static func relationKey(_ row: Row) -> String {
        schemaKey(row["srcDatabase"], row["srcName"], row["srcColumn"], row["dstDatabase"], row["dstName"], row["dstColumn"])
    }

    /// Clears the embedding flag and its attempts along with the close, so a
    /// closed row is never queued and no reader of the queue has to filter on
    /// `removedAt`. `replaced` marks a version closed for a successor written
    /// in the same change, which the change listing reads as the old side of
    /// a changed entry and leaves out of its removals.
    private static func closeObject(id: Int64, now: Date, changeID: Int64, replaced: Bool, _ db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE schema_object
            SET removedAt = ?, removedByChangeID = ?, replaced = ?, needsEmbedding = 0, embeddingAttempts = 0 WHERE id = ?
            """).execute(arguments: [now, changeID, replaced, id])
    }

    /// Deletes the vectors of `names`, which no current object of the profile
    /// carries any more. A name's vector belongs to the name, not to one
    /// object, and the same name can be current in two namespaces, so it goes
    /// only with the last current object that carries it. Only a removal
    /// calls this: a new version of an object closes its old row but leaves
    /// the name current.
    private static func deleteEmbeddings(of names: Set<String>, profileID: UUID, _ db: Database) throws {
        let delete = try db.cachedStatement(sql: "DELETE FROM schema_object_embedding WHERE profileID = ? AND objectKey = ?")
        for name in names {
            try delete.execute(arguments: [profileID.uuidString, "\(profileID.uuidString)#\(name)"])
        }
    }

    private static func closeRelation(id: Int64, now: Date, changeID: Int64, _ db: Database) throws {
        try db.cachedStatement(sql: "UPDATE schema_relation SET removedAt = ?, removedByChangeID = ? WHERE id = ?")
            .execute(arguments: [now, changeID, id])
    }

    /// Throws `ScopeChanged` when `scope` is given and the stored scope is
    /// another, inside the caller's transaction, so the comparison and the
    /// write cannot be separated by a scope change.
    private static func requireScope(_ scope: PassScope?, profileID: UUID, _ db: Database) throws {
        guard let scope else { return }
        let row = try Row.fetchOne(
            db, sql: "SELECT selectedSchemas FROM schema_graph_state WHERE profileID = ?", arguments: [profileID]
        )
        let stored: String? = row?["selectedSchemas"]
        guard stored == scope.selectedSchemas else { throw ScopeChanged() }
    }

    private static func upsertState(
        _ db: Database, profileID: UUID, _ update: (inout SchemaGraphStateRecord) -> Void
    ) throws {
        var state = try SchemaGraphStateRecord.fetchOne(db, key: profileID) ?? SchemaGraphStateRecord(profileID: profileID)
        let selected = state.selectedSchemas
        update(&state)
        // A token describes the catalog of one scope. Kept across a change of
        // scope, it would stop the next pass before it lists the new one.
        if state.selectedSchemas != selected { state.versionToken = nil }
        try state.save(db)
    }

    /// Whether a current row is one the upgrade from the per-node graph wrote:
    /// it has a definition but no fingerprint, no earlier version and no change
    /// row. A row this code writes always carries a change row, so a pass over
    /// an engine that reports no fingerprints cannot mistake its own first
    /// version for an upgraded one.
    private static func isUpgradedRow(_ row: Row) -> Bool {
        (row["fingerprint"] as String?) == nil && (row["previousID"] as Int64?) == nil && (row["changeID"] as Int64?) == nil
    }

    /// Whether the definition an upgrade copied, `stored`, equals `new` once
    /// the columns of each are sorted by name and the new columns' defaults,
    /// which the copy could not record, are left out. Indexes are compared as
    /// stored: both sides keep them sorted by name.
    private static func sameUpgradedDefinition(_ stored: String, _ new: String) -> Bool {
        guard let stored = comparableColumns(of: stored, droppingDefaults: false),
              let new = comparableColumns(of: new, droppingDefaults: true)
        else { return false }
        return stored == new
    }

    private static func comparableColumns(of definition: String, droppingDefaults: Bool) -> String? {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(definition.utf8))) as? [String: Any],
              var columns = object["columns"] as? [[String: Any]]
        else { return nil }
        if droppingDefaults {
            columns = columns.map { $0.filter { $0.key != "defaultValue" } }
        }
        object["columns"] = columns.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
