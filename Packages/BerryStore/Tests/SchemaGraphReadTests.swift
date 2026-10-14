import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("Schema graph reads, retention and cascade")
struct SchemaGraphReadTests {
    let profile = UUID()
    let other = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)

    func seeded(count: Int = 5) throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        let objects = (0..<count).map { SchemaListedObject(database: "shop", name: "t\($0)", kind: "table", fingerprint: "f") }
        let listing = try store.applySchemaListing(profileID: profile, objects: objects, relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "t1", srcColumn: "t0_id", dstDatabase: "shop", dstName: "t0", dstColumn: "id", constraintName: nil),
        ], now: t1)
        let details = objects.map {
            SchemaDetailWrite(database: "shop", name: $0.name, kind: "table", fingerprint: "f", definitionHash: "h-\($0.name)",
                              definition: #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"}],"indexes":[]}"#,
                              columnText: "id\ncustomer_email")
        }
        _ = try store.applySchemaDetails(profileID: profile, details: details, now: t1, changeID: listing.changeID)
        return store
    }

    /// Gives `other` an object, a relation, statistics, harvest state and a
    /// change row, so a delete that is not scoped to one profile shows up as
    /// missing rows.
    func seedOtherProfile(in store: BerryStore) throws {
        let listing = try store.applySchemaListing(profileID: other, objects: [
            SchemaListedObject(database: "shop", name: "keep", kind: "table", fingerprint: "f"),
        ], relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "keep", srcColumn: "parent_id", dstDatabase: "shop", dstName: "keep", dstColumn: "id", constraintName: nil),
        ], now: t1)
        _ = try store.applySchemaDetails(profileID: other, details: [
            SchemaDetailWrite(database: "shop", name: "keep", kind: "table", fingerprint: "f", definitionHash: "h-keep", definition: "{}"),
        ], now: t1, changeID: listing.changeID)
        try store.replaceSchemaStats(profileID: other, rows: [
            SchemaStatsRecord(profileID: other, database: "shop", name: "keep", rows: 1, updatedAt: t1),
        ])
    }

    func expectOtherProfileIntact(in store: BerryStore) throws {
        #expect(try store.currentSchemaObjects(profileID: other).map { "\($0.name):\($0.definition != nil)" } == ["keep:true"])
        #expect(try store.currentSchemaRelationEnds(profileID: other).count == 1)
        #expect(try store.schemaChangeMarks(profileID: other).count == 1)
        #expect(try store.schemaStats(profileID: other).count == 1)
        #expect(try store.schemaGraphState(profileID: other) != nil)
    }

    @Test func schemaCountsAreTheCurrentObjectsOfEachSchema() throws {
        let store = try seeded(count: 3)
        try seedOtherProfile(in: store)
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "t0", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "t1", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "archive", name: "old", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: nil, name: "events", kind: "view", fingerprint: nil),
        ], relations: nil, now: t2)

        let counts = try store.schemaObjectCountsBySchema(profileID: profile)

        #expect(counts.map(\.database) == [nil, "archive", "shop"])
        #expect(counts.map(\.count) == [1, 1, 2])
        #expect(try store.schemaObjectCountsBySchema(profileID: UUID()).isEmpty)
    }

    /// Grouping follows the current-row index, whose second column is the
    /// schema, so the count reads only current rows and needs no sort.
    @Test func schemaCountsReadTheCurrentRowIndexInOrder() throws {
        let store = try seeded()
        try store.read { db in
            let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + BerryStore.schemaCountsSQL, arguments: [profile])
                .map { $0[3] as String }.joined(separator: " | ")
            #expect(plan.contains("schema_object_current"), "schema counts: \(plan)")
            #expect(!plan.contains("TEMP B-TREE"), "schema counts: \(plan)")
        }
    }

    @Test func pagingIsOrderedAndReportsTotal() throws {
        let store = try seeded()
        let page = try store.currentSchemaObjects(profileID: profile, names: nil, offset: 2, limit: 2)
        #expect(page.rows.map(\.name) == ["t2", "t3"])
        #expect(page.total == 5)
    }

    @Test func namesMatchBareOrQualified() throws {
        let store = try seeded()
        let page = try store.currentSchemaObjects(profileID: profile, names: ["t4", "shop.t1", "nope"], offset: 0, limit: 50)
        #expect(Set(page.rows.map(\.name)) == ["t1", "t4"])
    }

    @Test func searchIsCaseInsensitiveSubstringAndEscapesWildcards() throws {
        let store = try seeded()
        #expect(try store.searchSchemaObjectKeys(profileID: profile, needle: "EMAIL", in: .columns, limit: 10).count == 5)
        #expect(try store.searchSchemaObjectKeys(profileID: profile, needle: "%", in: .columns, limit: 10).isEmpty)
        #expect(try store.searchSchemaObjectNames(profileID: profile, needle: "T3", limit: 10).map(\.name) == ["t3"])
        // The object name is not part of its column text.
        #expect(try store.searchSchemaObjectKeys(profileID: profile, needle: "t3", in: .columns, limit: 10).isEmpty)
    }

    @Test func objectsAndRelations() throws {
        let store = try seeded()
        let objects = try store.currentSchemaObjects(profileID: profile)
        #expect(objects.count == 5 && objects.allSatisfy { $0.kind == "table" && $0.definition != nil })
        #expect(try store.currentSchemaRelations(profileID: profile).map(\.dstName) == ["t0"])
    }

    @Test func asOfReturnsTheVersionCurrentAtThatTime() throws {
        let store = try seeded(count: 1)
        _ = try store.applySchemaDetails(profileID: profile, details: [
            SchemaDetailWrite(database: "shop", name: "t0", kind: "table", fingerprint: "f2", definitionHash: "h2", definition: "{}"),
        ], now: t2, changeID: nil)
        #expect(try store.schemaObjects(profileID: profile, asOf: t1).first?.definitionHash == "h-t0")
        #expect(try store.schemaObjects(profileID: profile, asOf: t2).first?.definitionHash == "h2")
        let marks = try store.schemaChangeMarks(profileID: profile)
        #expect(marks.map(\.at) == [t2, t1])
        // The version the change closed is the old side of its one entry,
        // not an entry of its own.
        let entries = try store.schemaObjectChangeEntries(profileID: profile, changeID: marks[0].id!, from: nil, limit: 10)
        try #require(entries.count == 1)
        let introduced = entries[0].position
        #expect(introduced.name == "t0" && introduced.database == "shop" && introduced.kind == "table" && introduced.introduced)
        let previous = try #require(entries[0].previousID)
        let definitions = try store.schemaObjectDefinitions(ids: [introduced.id, previous, previous + 1_000])
        #expect(definitions == [
            introduced.id: "{}",
            previous: #"{"columns":[{"name":"id","nullable":false,"primaryKey":true,"type":"int"}],"indexes":[]}"#,
        ])
        #expect(try store.schemaObjectDefinitions(ids: []).isEmpty)
    }

    /// Entries that share an object, or a relation's ends, are told apart by
    /// their row and by the side of the change they are on, so a page that
    /// ends between two of them loses neither.
    @Test func aPageResumesBetweenEntriesThatShareAKey() throws {
        let store = try seeded(count: 1)
        func version(_ hash: String) -> SchemaDetailWrite {
            SchemaDetailWrite(database: "shop", name: "t0", kind: "table", fingerprint: "f", definitionHash: hash,
                              definition: "{}")
        }
        let twice = try store.applySchemaDetails(profileID: profile, details: [version("h2")], now: t2, changeID: nil)
        let change = try #require(twice.changeID)
        _ = try store.applySchemaDetails(profileID: profile, details: [version("h3")], now: t2, changeID: change)
        let objects = try store.schemaObjectChangeEntries(profileID: profile, changeID: change, from: nil, limit: 10)
        #expect(objects.count == 2 && objects.allSatisfy { $0.position.introduced && $0.position.name == "t0" })
        // One entry a page, each page starting at the entry after the last,
        // as the change feed reads them.
        var pagedObjects: [SchemaObjectChangeEntry] = []
        var objectsFrom: SchemaObjectChangePosition?
        while true {
            let page = try store.schemaObjectChangeEntries(profileID: profile, changeID: change, from: objectsFrom, limit: 2)
            pagedObjects += page.prefix(1)
            guard page.count == 2 else { break }
            objectsFrom = page[1].position
        }
        #expect(pagedObjects == objects)

        let kept = SchemaListedRelation(srcDatabase: "shop", srcName: "t1", srcColumn: "t0_id",
                                        dstDatabase: "shop", dstName: "t0", dstColumn: "id", constraintName: nil)
        let passing = SchemaListedRelation(srcDatabase: "shop", srcName: "t0", srcColumn: "parent_id",
                                           dstDatabase: "shop", dstName: "t0", dstColumn: "id", constraintName: nil)
        let opened = try store.applySchemaRelations(profileID: profile, relations: [kept, passing], now: t2, changeID: nil)
        let relationChange = try #require(opened.changeID)
        _ = try store.applySchemaRelations(profileID: profile, relations: [kept], now: t2, changeID: relationChange)
        let relations = try store.schemaRelationChangeEntries(profileID: profile, changeID: relationChange, from: nil, limit: 10)
        #expect(relations.map(\.introduced) == [true, false])
        #expect(Set(relations.map(\.id)).count == 1)
        var pagedRelations: [SchemaRelationChangePosition] = []
        var relationsFrom: SchemaRelationChangePosition?
        while true {
            let page = try store.schemaRelationChangeEntries(profileID: profile, changeID: relationChange, from: relationsFrom, limit: 2)
            pagedRelations += page.prefix(1)
            guard page.count == 2 else { break }
            relationsFrom = page[1]
        }
        #expect(pagedRelations == relations)
    }

    @Test func retentionKeepsCurrentRowsAndEnforcesAgeThenCap() throws {
        let store = try seeded(count: 1)
        for round in 2...12 {
            _ = try store.applySchemaDetails(profileID: profile, details: [
                SchemaDetailWrite(database: "shop", name: "t0", kind: "table", fingerprint: "f", definitionHash: "h\(round)", definition: "{}"),
            ], now: Date(timeIntervalSince1970: Double(round) * 1_000), changeID: nil)
        }
        try store.pruneSchemaHistory(profileID: profile, olderThan: Date(timeIntervalSince1970: 5_000), keepingAtMost: 3)
        let rows = try store.read { try SchemaObjectRecord.filter(Column("profileID") == profile).order(Column("id")).fetchAll($0) }
        #expect(rows.filter { $0.removedAt == nil }.count == 1)
        let historical = rows.filter { $0.removedAt != nil }
        #expect(historical.count == 3)
        #expect(historical.allSatisfy { $0.removedAt! >= Date(timeIntervalSince1970: 5_000) })
    }

    /// A drain reads the queue for every batch and needs only each name and
    /// the version its vector goes to; reading whole rows decompressed a
    /// definition per queued name for nothing.
    @Test func theEmbeddingQueueReadsOnlyIdsAndNames() throws {
        let store = try seeded(count: 3)
        let log = SQLLog()
        let queue = try #require(store.dbQueue)
        queue.inDatabase { db in db.trace { if case let .statement(statement) = $0 { log.append(statement.sql) } } }
        defer { queue.inDatabase { $0.trace(options: .statement, nil) } }

        let queued = try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10)

        #expect(queued.map(\.name) == ["t0", "t1", "t2"])
        let reads = log.statements.filter { $0.contains("FROM schema_object") }
        #expect(reads.count == 1 && reads.allSatisfy { !$0.contains("SELECT *") && !$0.contains("definition") }, "\(reads)")
    }

    @Test func embeddingQueueIsBoundedByAttempts() throws {
        let store = try seeded(count: 2)
        let queued = try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10)
        #expect(queued.count == 2)
        for _ in 0..<5 { try store.recordSchemaEmbeddingFailure(id: queued[0].id) }
        _ = try store.storeSchemaEmbedding(
            id: queued[1].id, profileID: profile, name: queued[1].name,
            vector: Array(repeating: 0.1, count: BerryStore.schemaObjectEmbeddingDimension)
        )
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).isEmpty)
    }

    @Test func deletingAProfileRemovesItsGraphAndEmbeddings() throws {
        let store = try seeded()
        try seedOtherProfile(in: store)
        try store.embed("t0", profileID: profile, vector: Array(repeating: 0.1, count: BerryStore.schemaObjectEmbeddingDimension))
        try store.embed("keep", profileID: other, vector: Array(repeating: 0.1, count: BerryStore.schemaObjectEmbeddingDimension))
        try store.deleteProfile(id: profile)
        #expect(try store.currentSchemaObjectNames(profileID: profile).isEmpty)
        #expect(try store.currentSchemaRelationEnds(profileID: profile).isEmpty)
        #expect(try store.schemaGraphState(profileID: profile) == nil)
        let keys = try store.read { try String.fetchAll($0, sql: "SELECT objectKey FROM schema_object_embedding") }
        #expect(keys == ["\(other.uuidString)#keep"])
        try expectOtherProfileIntact(in: store)
    }

    @Test func narrowReadsUseTheirIndexes() throws {
        let store = try seeded()
        try store.read { db in
            let history = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT * FROM schema_object WHERE profileID = ? AND removedAt IS NOT NULL AND removedAt < ?", arguments: [profile, t2]).map { $0[3] as String }.joined()
            #expect(history.contains("schema_object_history"), "retention must use the history index: \(history)")

            func plan(_ sql: String, _ arguments: [(any DatabaseValueConvertible)?] = [profile, 1]) throws -> String {
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: StatementArguments(arguments)).map { $0[3] as String }.joined()
            }
            for names in [["t1"], ["shop.t1"]] {
                let filter = BerryStore.objectNameFilter(names)
                let count = try plan(BerryStore.namedObjectsCountSQL(filter.clause), [profile] + filter.arguments)
                #expect(count.contains("schema_object_current"), "name count \(names): \(count)")
                let page = try plan(BerryStore.namedObjectsPageSQL(filter.clause), [profile] + filter.arguments + [10, 0])
                #expect(page.contains("schema_object_current"), "name page \(names): \(page)")
            }
            for names in [["t1"], ["shop.t1"]] {
                let exists = try plan(BerryStore.namedObjectExistsSQL(BerryStore.objectNameFilter(names).clause),
                                      [profile] + BerryStore.objectNameFilter(names).arguments)
                #expect(exists.contains("schema_object_current"), "name probe \(names): \(exists)")
            }
            for count in [1, 3] {
                let statistics = try plan(
                    BerryStore.statsValuesSQL(count: count),
                    [profile] + Array(repeating: ["shop", "t1"], count: count).flatMap { $0 }
                )
                let byKey = "SEARCH schema_stats USING INDEX sqlite_autoindex_schema_stats_1 (profileID=? AND database=? AND name=?)"
                #expect(statistics.contains(byKey) && !statistics.contains("SCAN schema_stats"), "statistics by key: \(statistics)")
            }
            let folded = try plan(BerryStore.foldedNameLookupSQL, [profile, "t1"])
            #expect(folded.contains("schema_object_folded_name (profileID=? AND searchName=?)"), "folded name: \(folded)")
            let relationEnds = try plan(BerryStore.currentRelationEndsSQL, [profile])
            #expect(relationEnds.contains("schema_relation_current (profileID=?)")
                        && !relationEnds.contains("TEMP B-TREE"), "relation ends: \(relationEnds)")
            let currentNames = try plan(BerryStore.currentObjectNamesSQL, [profile])
            #expect(currentNames.contains("schema_object_current"), "current names: \(currentNames)")
            for count in [1, 3] {
                let relations = try plan(
                    BerryStore.relationsFromSourcesSQL(count: count),
                    [profile] + Array(repeating: ["shop", "t1"], count: count).flatMap { $0 }
                )
                #expect(relations.contains("schema_relation_current (profileID=? AND srcDatabase=? AND srcName=?)"),
                        "relations by source: \(relations)")
            }
            for field in [SchemaSearchField.columns, .indexes] {
                let firstBatch = try plan(BerryStore.searchKeysSQL(field, after: false), [profile, "t", 10])
                #expect(firstBatch.contains("schema_object_search (profileID=?)") && !firstBatch.contains("TEMP B-TREE"),
                        "search: \(firstBatch)")
                let nextBatch = try plan(BerryStore.searchKeysSQL(field, after: true), [profile, "t", "shop", "t1", "table", 10])
                #expect(nextBatch.contains("schema_object_search (profileID=? AND (database,name,kind)>(?,?,?))")
                            && !nextBatch.contains("TEMP B-TREE"), "search after a key: \(nextBatch)")
            }
            let probe = try plan(BerryStore.searchTextContainsSQL, [profile, "t"])
            #expect(probe.contains("schema_object_search (profileID=?)") && probe.contains("schema_object_folded_name (profileID=?)"),
                    "search probe: \(probe)")
            let names = try plan(BerryStore.searchNamesSQL, [profile, "t", 10])
            #expect(names.contains("schema_object_folded_name (profileID=?)"), "name search: \(names)")
            // A page of a change walks both change indexes in the page's
            // order and merges them: no temporary B-tree sorts the change.
            // The closed side walks only versions closed without a successor,
            // so it needs no correlated lookup per row: every row either side
            // reads is an entry of the page.
            for after in [nil, true, false] {
                let keyset = after == nil ? [] : ["shop", "t1", "table", 1] as [(any DatabaseValueConvertible)?]
                let objects = try plan(BerryStore.objectChangeEntriesSQL(from: after), [profile, 1] + keyset + [10, 0])
                #expect(objects.contains("schema_object_change (profileID=? AND changeID=?")
                            && objects.contains("schema_object_dropped_change (profileID=? AND removedByChangeID=?")
                            && !objects.contains("CORRELATED")
                            && !objects.contains("TEMP B-TREE"), "object entries after \(String(describing: after)): \(objects)")
                let ends = after == nil ? [] : ["shop", "t1", "t0_id", "shop", "t0", "id", 1] as [(any DatabaseValueConvertible)?]
                let relations = try plan(BerryStore.relationChangeEntriesSQL(from: after), [profile, 1] + ends + [10, 0])
                #expect(relations.contains("schema_relation_change (profileID=? AND changeID=?")
                            && relations.contains("schema_relation_removed_change (profileID=? AND removedByChangeID=?")
                            && !relations.contains("TEMP B-TREE"), "relation entries after \(String(describing: after)): \(relations)")
            }
        }
    }

    /// A name an agent passes in another case is folded as a search folds
    /// it, so `STRASSE` finds `Straße` here as `search_schema` finds it, with
    /// or without its schema.
    @Test func aNameInAnotherCaseIsFoldedAsSearchFoldsIt() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "Bücher", name: "Straße", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "orders", kind: "table", fingerprint: "f"),
        ], relations: [], now: t1)
        func names(_ entries: [String]) throws -> [String] {
            try store.currentSchemaObjects(profileID: profile, names: entries, offset: 0, limit: 10).rows.map(\.name)
        }
        #expect(try names(["STRASSE"]) == ["Straße"])
        #expect(try names(["BÜCHER.STRASSE"]) == ["Straße"])
        #expect(try names(["shop.STRASSE"]).isEmpty)
        #expect(try names(["no_such_table"]).isEmpty)
    }

    @Test func namesMatchObjectsWithoutANamespaceAndDottedNames() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: nil, name: "notes", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "logs", name: "system.profile", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "orders", kind: "table", fingerprint: "f"),
        ], relations: [], now: t1)
        let bare = try store.currentSchemaObjects(profileID: profile, names: ["notes"], offset: 0, limit: 10)
        #expect(bare.rows.map(\.name) == ["notes"])
        #expect(bare.rows.first?.database == nil)
        let dotted = try store.currentSchemaObjects(profileID: profile, names: ["system.profile"], offset: 0, limit: 10)
        #expect(dotted.rows.map(\.name) == ["system.profile"])
        let wrongCase = try store.currentSchemaObjects(profileID: profile, names: ["SHOP.orders", "Notes"], offset: 0, limit: 10)
        #expect(wrongCase.rows.map(\.name) == ["notes", "orders"])
        #expect(wrongCase.total == 2)
        let none = try store.currentSchemaObjects(profileID: profile, names: [], offset: 0, limit: 10)
        #expect(none.rows.isEmpty && none.total == 0)
    }

    /// Each entry is looked up exactly first; only an entry that matches
    /// nothing exactly is compared again ignoring case, so an exact name
    /// never also returns the objects that differ from it only in case.
    @Test func aNameWithoutAnExactMatchFallsBackToIgnoringCase() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: nil, name: "notes", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "Orders", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "orders", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "ops", name: "ORDERS", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "logs", name: "System.Profile", kind: "table", fingerprint: "f"),
        ], relations: [], now: t1)
        func names(_ entries: [String]) throws -> [String] {
            let page = try store.currentSchemaObjects(profileID: profile, names: entries, offset: 0, limit: 10)
            #expect(page.total == page.rows.count)
            return page.rows.map { "\($0.database ?? "").\($0.name)" }
        }
        #expect(try names(["orders"]) == ["shop.orders"])
        #expect(try names(["Orders"]) == ["shop.Orders"])
        #expect(try names(["oRdErS"]) == ["ops.ORDERS", "shop.Orders", "shop.orders"])
        #expect(try names(["OPS.orders"]) == ["ops.ORDERS"])
        #expect(try names(["system.profile"]) == ["logs.System.Profile"])
        #expect(try names(["orders", "NOTES"]) == [".notes", "shop.orders"])
        #expect(try names(["missing", "MISSING.orders"]).isEmpty)
        let page = try store.currentSchemaObjects(profileID: profile, names: ["orDers", "notes"], offset: 1, limit: 2)
        #expect(page.rows.map(\.name) == ["ORDERS", "Orders"])
        #expect(page.total == 4)
    }

    /// SQLite 3.51.0 plans the names read as `USING INDEX`, not `USING
    /// COVERING INDEX`, because the query names `removedAt`, which the index
    /// does not hold. It drops that term, which the partial index implies, so
    /// every column the program reads comes from the index and the table row,
    /// with the definition stored in it, is never read.
    @Test func currentNamesAreReadFromTheIndexAlone() throws {
        let store = try seeded()
        try store.read { db in
            let program = try Row.fetchAll(db, sql: "EXPLAIN " + BerryStore.currentObjectNamesSQL, arguments: [profile])
            let indexRoot = try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'schema_object_current'")
            var readsIndex: [Int: Bool] = [:]
            for op in program where (op["opcode"] as String) == "OpenRead" {
                readsIndex[op["p1"] as Int] = (op["p2"] as Int) == indexRoot
            }
            let columnReads = program.filter { ($0["opcode"] as String) == "Column" }.map { readsIndex[$0["p1"] as Int] }
            #expect(columnReads.count == 3)
            #expect(columnReads.allSatisfy { $0 == true }, "a column is read from the table: \(program)")
        }
    }

    /// The same holds for the ends of the current relations: the
    /// current-relation index holds every column the table graph reads.
    @Test func currentRelationEndsAreReadFromTheIndexAlone() throws {
        let store = try seeded()
        try store.read { db in
            let program = try Row.fetchAll(db, sql: "EXPLAIN " + BerryStore.currentRelationEndsSQL, arguments: [profile])
            let indexRoot = try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'schema_relation_current'")
            var readsIndex: [Int: Bool] = [:]
            for op in program where (op["opcode"] as String) == "OpenRead" {
                readsIndex[op["p1"] as Int] = (op["p2"] as Int) == indexRoot
            }
            let columnReads = program.filter { ($0["opcode"] as String) == "Column" }.map { readsIndex[$0["p1"] as Int] }
            #expect(columnReads.count == 6)
            #expect(columnReads.allSatisfy { $0 == true }, "a column is read from the table: \(program)")
        }
        #expect(try store.currentSchemaRelationEnds(profileID: profile) == [SchemaRelationEnds(
            srcDatabase: "shop", srcName: "t1", srcColumn: "t0_id", dstDatabase: "shop", dstName: "t0", dstColumn: "id"
        )])
    }

    /// Every search statement reads the search indexes alone: the probe, the
    /// name search and each batch of column or index keys read every column
    /// from an index cursor, so none reads a table row or decompresses a
    /// definition. SQLite still opens a cursor on the table, which none of
    /// them reads. A caller reads the definitions of the keys it keeps, by
    /// id.
    @Test func everySearchStatementReadsTheSearchIndexesAlone() throws {
        let store = try seeded()
        try store.read { db in
            let roots = Set(try Int.fetchAll(db, sql: """
                SELECT rootpage FROM sqlite_master WHERE name IN ('schema_object_search', 'schema_object_folded_name')
                """))
            var statements: [(String, StatementArguments)] = [
                (BerryStore.searchTextContainsSQL, [profile, "t"]),
                (BerryStore.searchNamesSQL, [profile, "t", 10]),
            ]
            for field in [SchemaSearchField.columns, .indexes] {
                statements.append((BerryStore.searchKeysSQL(field, after: false), [profile, "t", 10]))
                statements.append((BerryStore.searchKeysSQL(field, after: true), [profile, "t", "shop", "t1", "table", 10]))
            }
            for (sql, arguments) in statements {
                let program = try Row.fetchAll(db, sql: "EXPLAIN " + sql, arguments: arguments)
                var readsIndex: [Int: Bool] = [:]
                for op in program where (op["opcode"] as String) == "OpenRead" {
                    readsIndex[op["p1"] as Int] = roots.contains(op["p2"] as Int)
                }
                // The name search's sort reads its own cursor, which no
                // OpenRead opens and which holds no store page.
                let columnReads = program.filter { ($0["opcode"] as String) == "Column" }.compactMap { readsIndex[$0["p1"] as Int] }
                #expect(!columnReads.isEmpty && columnReads.allSatisfy { $0 }, "a column is read from the table: \(sql)")
            }
        }
    }

    @Test func currentNamesAreTheCurrentRowsInOrder() throws {
        let store = try seeded(count: 3)
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "t1", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: "shop", name: "t2", kind: "table", fingerprint: "f"),
            SchemaListedObject(database: nil, name: "v", kind: "view", fingerprint: nil),
        ], relations: [], now: t2)
        let names = try store.currentSchemaObjectNames(profileID: profile)
        #expect(names.map { "\($0.database ?? "-").\($0.name):\($0.kind)" } == ["-.v:view", "shop.t1:table", "shop.t2:table"])
        #expect(try store.currentSchemaObjectNames(profileID: other).isEmpty)
    }

    @Test func closedRowsAreNotCurrentAndSearchSkipsThem() throws {
        let store = try seeded(count: 2)
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "t0", kind: "table", fingerprint: "f"),
        ], relations: [], now: t2)
        #expect(try store.currentSchemaObjects(profileID: profile, names: nil, offset: 0, limit: 10).rows.map(\.name) == ["t0"])
        #expect(try store.searchSchemaObjectNames(profileID: profile, needle: "t1", limit: 10).isEmpty)
        #expect(try store.searchSchemaObjectKeys(profileID: profile, needle: "id", in: .columns, limit: 10).map(\.name) == ["t0"])
        #expect(try store.schemaObjectsNeedingEmbedding(profileID: profile, limit: 10).count == 1)
    }

    @Test func searchFoldsNonAsciiAndMatchesUnderscoreAndBackslashLiterally() throws {
        let store = try BerryStore(path: ":memory:")
        let texts = ["orders": "đơn_hàng", "plain": "xhàng", "files": "c:\\temp"]
        let listing = try store.applySchemaListing(
            profileID: profile,
            objects: texts.keys.map { SchemaListedObject(database: "shop", name: $0, kind: "table", fingerprint: "f") },
            relations: [], now: t1
        )
        _ = try store.applySchemaDetails(profileID: profile, details: texts.map {
            SchemaDetailWrite(database: "shop", name: $0.key, kind: "table", fingerprint: "f", definitionHash: "h", definition: "{}", columnText: $0.value)
        }, now: t1, changeID: listing.changeID)
        func columns(_ needle: String) throws -> [String] {
            try store.searchSchemaObjectKeys(profileID: profile, needle: needle, in: .columns, limit: 10).map(\.name)
        }
        // SQLite compares bytes, so a needle in capitals matches stored
        // folded text only once Swift has folded it.
        #expect(try columns("ĐƠN") == ["orders"])
        // A pattern-matching underscore would also match the "x" of "xhàng".
        #expect(try columns("_hàng") == ["orders"])
        #expect(try columns("xhàng") == ["plain"])
        // A pattern-matching backslash would escape the "t" that follows it.
        #expect(try columns("c:\\te") == ["files"])
    }

    @Test func changesResumeAfterAnIDAndFromADate() throws {
        let store = try seeded(count: 1)
        for (round, hash) in [(2, "h2"), (3, "h3")] {
            _ = try store.applySchemaDetails(profileID: profile, details: [
                SchemaDetailWrite(database: "shop", name: "t0", kind: "table", fingerprint: "f", definitionHash: hash, definition: "{}"),
            ], now: Date(timeIntervalSince1970: Double(round) * 1_000), changeID: nil)
        }
        let all = try store.schemaChanges(profileID: profile, afterID: nil, since: nil, limit: 10)
        #expect(all.map(\.at.timeIntervalSince1970) == [1_000, 2_000, 3_000])
        let firstID = try #require(all.first?.id)
        #expect(try store.schemaChanges(profileID: profile, afterID: firstID, since: nil, limit: 10).map(\.at) == [t2, Date(timeIntervalSince1970: 3_000)])
        #expect(try store.schemaChanges(profileID: profile, afterID: nil, since: t2, limit: 10).count == 2)
        #expect(try store.schemaChanges(profileID: profile, afterID: nil, since: nil, limit: 1).map(\.at) == [t1])
        #expect(try store.schemaChanges(profileID: other, afterID: nil, since: nil, limit: 10).isEmpty)
        #expect(try store.schemaChanges(profileID: profile, afterID: nil, since: nil, through: t2, limit: 10).map(\.at) == [t1, t2])
    }

    @Test func relationsAreVersionedByTime() throws {
        let store = try seeded(count: 2)
        let objects = (0..<2).map { SchemaListedObject(database: "shop", name: "t\($0)", kind: "table", fingerprint: "f") }
        let dropped = try store.applySchemaListing(profileID: profile, objects: objects, relations: [], now: t2)
        #expect(try store.schemaRelations(profileID: profile, asOf: t1).count == 1)
        #expect(try store.schemaRelations(profileID: profile, asOf: t2).isEmpty)
        #expect(try store.currentSchemaRelations(profileID: profile).isEmpty)
        let closed = try store.schemaRelationChangeEntries(profileID: profile, changeID: try #require(dropped.changeID), from: nil, limit: 10)
        #expect(closed.map(\.ends.srcName) == ["t1"] && closed.allSatisfy { !$0.introduced })
        let firstChange = try #require(try store.schemaChangeMarks(profileID: profile).last?.id)
        let added = try store.schemaRelationChangeEntries(profileID: profile, changeID: firstChange, from: nil, limit: 10)
        #expect(added.map(\.ends.srcName) == ["t1"] && added.allSatisfy(\.introduced))
    }

    @Test func relationsAreReadForTheirSourcesOnly() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: ["a", "b", "c"].map {
            SchemaListedObject(database: "shop", name: $0, kind: "table", fingerprint: "f")
        } + [SchemaListedObject(database: nil, name: "n", kind: "table", fingerprint: "f")], relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "a", srcColumn: "b_id", dstDatabase: "shop", dstName: "b", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: "shop", srcName: "a", srcColumn: "c_id", dstDatabase: "shop", dstName: "c", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: "shop", srcName: "b", srcColumn: "c_id", dstDatabase: "shop", dstName: "c", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: nil, srcName: "n", srcColumn: "a_id", dstDatabase: "shop", dstName: "a", dstColumn: "id", constraintName: nil),
        ], now: t1)
        func columns(_ sources: [(database: String?, name: String)]) throws -> [String] {
            try store.currentSchemaRelations(profileID: profile, sources: sources).map { "\($0.srcName).\($0.srcColumn)" }
        }
        #expect(try columns([("shop", "a")]) == ["a.b_id", "a.c_id"])
        #expect(try columns([(nil, "n"), ("shop", "b")]) == ["n.a_id", "b.c_id"])
        #expect(try columns([("shop", "c"), ("other", "a")]).isEmpty)
        #expect(try columns([]).isEmpty)
    }

    @Test func searchResumesAfterAKey() throws {
        let store = try seeded(count: 5)
        let first = try store.searchSchemaObjectKeys(profileID: profile, needle: "id", in: .columns, limit: 2)
        #expect(first.map(\.name) == ["t0", "t1"])
        let last = try #require(first.last)
        let next = try store.searchSchemaObjectKeys(
            profileID: profile, needle: "id", in: .columns, after: (last.database, last.name, last.kind), limit: 2
        )
        #expect(next.map(\.name) == ["t2", "t3"])
        let rest = try store.searchSchemaObjectKeys(
            profileID: profile, needle: "id", in: .columns, after: ("shop", "t3", "table"), limit: 10
        )
        #expect(rest.map(\.name) == ["t4"])
    }

    @Test func currentObjectsAreReadWhole() throws {
        let store = try seeded(count: 3)
        _ = try store.applySchemaListing(profileID: profile, objects: (0..<2).map {
            SchemaListedObject(database: "shop", name: "t\($0)", kind: "table", fingerprint: "f")
        }, relations: nil, now: t2)
        #expect(try store.currentSchemaObjects(profileID: profile).map(\.name) == ["t0", "t1"])
        #expect(try store.currentSchemaObjects(profileID: profile).allSatisfy { $0.definition != nil })
    }

    @Test func statsAreReplacedForOneProfileOnly() throws {
        let store = try BerryStore(path: ":memory:")
        func stat(_ owner: UUID, _ name: String, rows: Int64) -> SchemaStatsRecord {
            SchemaStatsRecord(profileID: owner, database: nil, name: name, rows: rows, updatedAt: t1)
        }
        try store.replaceSchemaStats(profileID: profile, rows: [stat(profile, "a", rows: 1), stat(profile, "b", rows: 2)])
        try store.replaceSchemaStats(profileID: other, rows: [stat(other, "x", rows: 9)])
        try store.replaceSchemaStats(profileID: profile, rows: [stat(profile, "b", rows: 3)])
        let mine = try store.schemaStats(profileID: profile)
        #expect(mine.map(\.name) == ["b"])
        #expect(mine.map(\.rows) == [3])
        #expect(mine.first?.database == nil)
        #expect(try store.schemaStats(profileID: other).map(\.name) == ["x"])
        #expect(try store.schemaStats(profileID: profile, database: nil, name: "b")?.rows == 3)
        #expect(try store.schemaStats(profileID: profile, database: nil, name: "a") == nil)
        #expect(try store.schemaStats(profileID: profile, database: "shop", name: "b") == nil)
    }

    @Test func retentionDropsOnlyOldChangeRowsNothingRefersTo() throws {
        let store = try seeded(count: 1)
        let ids = try store.write { db -> (old: Int64, recent: Int64) in
            var old = SchemaChangeRecord(profileID: profile, at: t1, added: 0, changed: 0, removed: 0, relationsAdded: 0, relationsRemoved: 0)
            try old.insert(db)
            var recent = SchemaChangeRecord(profileID: profile, at: Date(timeIntervalSince1970: 9_000), added: 0, changed: 0, removed: 0, relationsAdded: 0, relationsRemoved: 0)
            try recent.insert(db)
            return (old.id!, recent.id!)
        }
        try store.pruneSchemaHistory(profileID: profile, olderThan: Date(timeIntervalSince1970: 5_000), keepingAtMost: 10)
        let kept = try store.schemaChangeMarks(profileID: profile).compactMap(\.id)
        #expect(!kept.contains(ids.old))
        #expect(kept.contains(ids.recent))
        #expect(kept.count == 2, "the listing's change row is still referenced by the current rows")
    }

    @Test func retentionAlsoPrunesClosedRelations() throws {
        let store = try seeded(count: 2)
        let objects = (0..<2).map { SchemaListedObject(database: "shop", name: "t\($0)", kind: "table", fingerprint: "f") }
        _ = try store.applySchemaListing(profileID: profile, objects: objects, relations: [], now: t2)
        _ = try store.applySchemaListing(profileID: profile, objects: objects, relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "t1", srcColumn: "t0_id", dstDatabase: "shop", dstName: "t0", dstColumn: "id", constraintName: nil),
        ], now: Date(timeIntervalSince1970: 3_000))
        try store.pruneSchemaHistory(profileID: profile, olderThan: Date(timeIntervalSince1970: 2_500), keepingAtMost: 10)
        let rows = try store.read { try SchemaRelationRecord.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows.first?.removedAt == nil)
    }

    @Test func deleteProfileRemovesItsSchemaGraph() throws {
        let store = try seeded()
        try seedOtherProfile(in: store)
        var connection = ConnectionProfile(driverID: "sqlite", name: "Shop", filePath: "/tmp/shop.sqlite")
        connection.id = profile
        try store.save(connection)
        try store.deleteProfile(id: profile)
        #expect(try store.allProfiles().isEmpty)
        #expect(try store.currentSchemaObjectNames(profileID: profile).isEmpty)
        #expect(try store.currentSchemaRelationEnds(profileID: profile).isEmpty)
        #expect(try store.schemaGraphState(profileID: profile) == nil)
        #expect(try store.schemaChangeMarks(profileID: profile).isEmpty)
        try expectOtherProfileIntact(in: store)
    }
}
