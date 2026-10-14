import BerryDriverKit
import Foundation
import GRDB
import Testing

@testable import BerryGraph
@testable import BerryStore

/// The statements a store runs, recorded through SQLite's trace hook.
final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var statements: [String] { lock.withLock { recorded } }
    func append(_ sql: String) { lock.withLock { recorded.append(sql) } }

    /// Runs `body` with every statement `store` executes recorded. The store
    /// opened on a path has one connection, so the hook sees every read.
    static func recording<T>(_ store: BerryStore, _ body: () throws -> T) throws -> (result: T, statements: [String]) {
        let log = StatementLog()
        let queue = try #require(store.dbQueue)
        queue.inDatabase { db in
            db.trace { event in
                if case let .statement(statement) = event { log.append(statement.sql) }
            }
        }
        defer { queue.inDatabase { $0.trace(options: .statement, nil) } }
        return (try body(), log.statements)
    }
}

@Suite("GraphReader")
struct GraphReaderTests {
    let profile = UUID()
    let t1 = Date(timeIntervalSince1970: 1_000)
    let t2 = Date(timeIntervalSince1970: 2_000)
    let t3 = Date(timeIntervalSince1970: 3_000)

    static let customers = TableDetail(
        ref: TableRef(database: "shop", name: "customers"),
        columns: [
            ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
            ColumnInfo(name: "email", declaredType: "text", isNullable: true, defaultValue: nil, isPrimaryKey: false),
        ],
        indexes: [IndexInfo(name: "customers_email_key", isUnique: true, columns: ["email"])],
        foreignKeys: []
    )

    static let orders = TableDetail(
        ref: TableRef(database: "shop", name: "orders"),
        columns: [
            ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true),
            ColumnInfo(name: "customer_id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false),
            ColumnInfo(name: "placed_at", declaredType: "timestamp", isNullable: true, defaultValue: "now()", isPrimaryKey: false),
        ],
        indexes: [IndexInfo(name: "orders_customer_idx", isUnique: false, columns: ["customer_id", "placed_at"])],
        foreignKeys: [ForeignKeyInfo(column: "customer_id", referencedTable: "customers", referencedColumn: "id")]
    )

    /// `orders` with one more column, the second version of the table.
    static let ordersWithNote = TableDetail(
        ref: orders.ref,
        columns: orders.columns + [
            ColumnInfo(name: "note", declaredType: "text", isNullable: true, defaultValue: nil, isPrimaryKey: false),
        ],
        indexes: orders.indexes,
        foreignKeys: orders.foreignKeys
    )

    static let objects = [
        BerryDriverKit.SchemaObject(kind: .table, name: "customers", database: "shop"),
        BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "shop"),
        BerryDriverKit.SchemaObject(kind: .view, name: "recent_orders", database: "shop"),
    ]

    /// Two tables, one foreign key between them, and a view whose detail was
    /// never read, written the way a harvest pass writes them.
    func seeded() throws -> BerryStore {
        let store = try BerryStore(path: ":memory:")
        try Self.seed(store, profileID: profile, objects: Self.objects, details: [Self.customers, Self.orders], at: t1)
        return store
    }

    static func write(_ detail: TableDetail, kind: String = "table") throws -> SchemaDetailWrite {
        let definition = SchemaDefinition(detail: detail)
        return SchemaDetailWrite(
            database: detail.ref.database, name: detail.ref.name, kind: kind, fingerprint: nil,
            definitionHash: definition.hash, definition: try definition.json(),
            columnText: definition.columnText, indexText: definition.indexText
        )
    }

    static func seed(
        _ store: BerryStore, profileID: UUID, objects: [BerryDriverKit.SchemaObject], details: [TableDetail], at now: Date
    ) throws {
        let relations = details.flatMap { detail in
            detail.foreignKeys.map {
                SchemaListedRelation(
                    srcDatabase: detail.ref.database, srcName: detail.ref.name, srcColumn: $0.column,
                    dstDatabase: $0.referencedSchema ?? detail.ref.database, dstName: $0.referencedTable,
                    dstColumn: $0.referencedColumn, constraintName: nil
                )
            }
        }
        let listing = try store.applySchemaListing(
            profileID: profileID,
            objects: objects.map { SchemaListedObject(database: $0.database, name: $0.name, kind: $0.kind.rawValue, fingerprint: nil) },
            relations: relations, now: now
        )
        _ = try store.applySchemaDetails(
            profileID: profileID, details: try details.map { try write($0) }, now: now, changeID: listing.changeID
        )
    }

    func seedStats(_ store: BerryStore) throws {
        try store.replaceSchemaStats(profileID: profile, rows: [
            SchemaStatsRecord(
                profileID: profile, database: "shop", name: "customers", rows: 10, sizeBytes: 4096, seqScan: 3, idxScan: 7,
                indexStats: #"{"customers_email_key":{"idxScan":7}}"#, updatedAt: t1
            ),
            SchemaStatsRecord(
                profileID: profile, database: "shop", name: "orders", rows: 100,
                indexStats: #"{"orders_customer_idx":{"idxScan":0}}"#, updatedAt: t1
            ),
        ])
    }

    // MARK: - Objects

    @Test func pagingReportsTotalAndNextOffset() throws {
        let reader = GraphReader(store: try seeded())
        let first = try reader.objects(profileID: profile, names: nil, offset: 0, limit: 2, maxBytes: 512 * 1024)
        #expect(first.objects.map(\.name) == ["customers", "orders"])
        #expect(first.total == 3)
        #expect(first.nextOffset == 2)

        let last = try reader.objects(profileID: profile, names: nil, offset: 2, limit: 2, maxBytes: 512 * 1024)
        #expect(last.objects.map(\.name) == ["recent_orders"])
        #expect(last.objects.first?.definition == nil)
        #expect(last.total == 3)
        #expect(last.nextOffset == nil)
    }

    @Test func limitIsCappedAtTwoHundred() throws {
        let store = try BerryStore(path: ":memory:")
        let many = (0..<250).map { BerryDriverKit.SchemaObject(kind: .table, name: String(format: "t%03d", $0)) }
        try Self.seed(store, profileID: profile, objects: many, details: [], at: t1)
        let page = try GraphReader(store: store).objects(profileID: profile, names: nil, offset: 0, limit: 1_000, maxBytes: .max)
        #expect(page.objects.count == 200)
        #expect(page.total == 250)
        #expect(page.nextOffset == 200)
    }

    /// One definition larger than the whole budget still fills a page on its
    /// own, so a caller paging by `nextOffset` always makes progress, and the
    /// next object is left for the following page.
    @Test func byteCapCutsThePageButNeverBelowOneObject() throws {
        let store = try BerryStore(path: ":memory:")
        let wide = TableDetail(
            ref: TableRef(name: "a_wide"),
            columns: (0..<6_500).map {
                ColumnInfo(name: String(format: "column_with_a_long_name_%05d", $0), declaredType: "varchar(255)",
                           isNullable: true, defaultValue: nil, isPrimaryKey: false)
            },
            indexes: [], foreignKeys: []
        )
        let narrow = TableDetail(
            ref: TableRef(name: "b_narrow"),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [], foreignKeys: []
        )
        try Self.seed(
            store, profileID: profile,
            objects: [.init(kind: .table, name: "a_wide"), .init(kind: .table, name: "b_narrow")],
            details: [wide, narrow], at: t1
        )
        let reader = GraphReader(store: store)
        let wideBytes = try #require(try reader.objects(profileID: profile, names: ["a_wide"], offset: 0, limit: 1, maxBytes: .max)
            .objects.first?.definition?.utf8.count)
        #expect(wideBytes > 600_000)

        let page = try reader.objects(profileID: profile, names: nil, offset: 0, limit: 200, maxBytes: 512 * 1024)
        #expect(page.objects.map(\.name) == ["a_wide"])
        #expect(page.total == 2)
        #expect(page.nextOffset == 1)

        let rest = try reader.objects(profileID: profile, names: nil, offset: 1, limit: 200, maxBytes: 512 * 1024)
        #expect(rest.objects.map(\.name) == ["b_narrow"])
        #expect(rest.nextOffset == nil)
    }

    /// A bare name matches the object of that name in every namespace and
    /// `namespace.name` matches one; a name that matches nothing exactly is
    /// compared again ignoring case.
    @Test func namesSelectObjectsBareOrQualified() throws {
        let reader = GraphReader(store: try seeded())
        func names(_ entries: [String]) throws -> [String] {
            try reader.objects(profileID: profile, names: entries, offset: 0, limit: 200, maxBytes: .max).objects.map(\.name)
        }
        #expect(try names(["orders"]) == ["orders"])
        #expect(try names(["shop.orders", "customers"]) == ["customers", "orders"])
        #expect(try names(["ORDERS"]) == ["orders"])
        #expect(try names(["SHOP.Orders"]) == ["orders"])
        let none = try reader.objects(profileID: profile, names: ["nope"], offset: 0, limit: 200, maxBytes: .max)
        #expect(none.objects.isEmpty)
        #expect(none.total == 0)
        #expect(none.nextOffset == nil)
    }

    @Test func anExactNameWinsOverOneThatDiffersOnlyInCase() throws {
        let store = try BerryStore(path: ":memory:")
        try Self.seed(store, profileID: profile, objects: [
            .init(kind: .table, name: "Orders", database: "shop"), .init(kind: .table, name: "orders", database: "shop"),
        ], details: [], at: t1)
        let reader = GraphReader(store: store)
        func names(_ entry: String) throws -> [String] {
            try reader.objects(profileID: profile, names: [entry], offset: 0, limit: 200, maxBytes: .max).objects.map(\.name)
        }
        #expect(try names("orders") == ["orders"])
        #expect(try names("Orders") == ["Orders"])
        #expect(try names("ORDERS") == ["Orders", "orders"])
    }

    // MARK: - Search

    @Test func searchListsObjectsThenColumnsThenIndexes() throws {
        let reader = GraphReader(store: try seeded())
        #expect(try reader.search(profileID: profile, needle: "ORDER", limit: 50) == [
            .init(name: "orders", kind: "table", database: "shop", table: nil),
            .init(name: "recent_orders", kind: "view", database: "shop", table: nil),
            .init(name: "orders_customer_idx", kind: "index", database: "shop", table: "orders"),
        ])
        #expect(try reader.search(profileID: profile, needle: "id", limit: 50) == [
            .init(name: "id", kind: "column", database: "shop", table: "customers"),
            .init(name: "customer_id", kind: "column", database: "shop", table: "orders"),
            .init(name: "id", kind: "column", database: "shop", table: "orders"),
            .init(name: "orders_customer_idx", kind: "index", database: "shop", table: "orders"),
        ])
    }

    /// Names are matched in the store, over indexes of the current rows'
    /// folded names, so no search reads every current name into memory: at
    /// 20,000 tables that read and the case folding after it took about
    /// 40 ms of a 30 ms budget in a release build. Definitions are read by id
    /// only. A needle that nothing holds is answered by one statement.
    @Test func searchMatchesNamesInTheStore() throws {
        let store = try seeded()
        let reader = GraphReader(store: store)
        func objectReads(_ statements: [String]) -> [String] { statements.filter { $0.contains("FROM schema_object ") } }

        let some = try StatementLog.recording(store) { try reader.search(profileID: profile, needle: "ORDER", limit: 50) }
        #expect(some.result.map(\.name) == ["orders", "recent_orders", "orders_customer_idx"])
        #expect(objectReads(some.statements).allSatisfy {
            $0.contains("searchName") || $0.contains("columnText") || $0.contains("indexText") || $0.contains("WHERE id IN")
        }, "\(some.statements)")

        let none = try StatementLog.recording(store) { try reader.search(profileID: profile, needle: "no_such_name", limit: 50) }
        #expect(none.result.isEmpty)
        #expect(objectReads(none.statements).count == 1, "\(none.statements)")
    }

    /// Both sides are case-folded, so a name matches whatever case either is
    /// written in, including the folds that lower-casing alone misses: a
    /// sharp s and "ss", a final sigma, a ligature, the micro sign and a
    /// long s.
    @Test func searchFoldsCaseOnBothSides() throws {
        let pairs = [
            ("straße", "STRASSE"), ("STRASSE", "straße"), ("ΟΔΟΣ", "οδος"), ("οδος", "ΟΔΟΣ"), ("ﬁle", "FILE"),
            ("FILE", "ﬁle"), ("µ", "Μ"), ("Μ", "µ"), ("ſtatus", "status"), ("status", "ſtatus"),
        ]
        for (stored, needle) in pairs {
            let store = try BerryStore(path: ":memory:")
            let table = TableDetail(
                ref: TableRef(database: "shop", name: stored),
                columns: [ColumnInfo(name: "c_" + stored, declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
                indexes: [IndexInfo(name: "i_" + stored, isUnique: false, columns: ["c_" + stored])], foreignKeys: []
            )
            try Self.seed(store, profileID: profile, objects: [
                BerryDriverKit.SchemaObject(kind: .table, name: stored, database: "shop"),
            ], details: [table], at: t1)
            #expect(try GraphReader(store: store).search(profileID: profile, needle: needle, limit: 10) == [
                .init(name: stored, kind: "table", database: "shop", table: nil),
                .init(name: "c_" + stored, kind: "column", database: "shop", table: stored),
                .init(name: "i_" + stored, kind: "index", database: "shop", table: stored),
            ], "\(stored) searched as \(needle)")
        }
    }

    /// A name is matched whole, even one that holds a line break: a quoted
    /// PostgreSQL identifier can contain any character but the one with code
    /// zero (https://www.postgresql.org/docs/current/sql-syntax-lexical.html#SQL-SYNTAX-IDENTIFIERS).
    @Test func searchMatchesTheWholeOfANameWithALineBreak() throws {
        let store = try BerryStore(path: ":memory:")
        let name = "first\nSecond"
        let table = TableDetail(
            ref: TableRef(database: "shop", name: name),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [], foreignKeys: []
        )
        try Self.seed(store, profileID: profile, objects: [
            BerryDriverKit.SchemaObject(kind: .table, name: name, database: "shop"),
            BerryDriverKit.SchemaObject(kind: .view, name: "pending\nview", database: "shop"),
        ], details: [table], at: t1)
        let reader = GraphReader(store: store)
        #expect(try reader.search(profileID: profile, needle: "SECOND", limit: 10) == [
            .init(name: name, kind: "table", database: "shop", table: nil),
        ])
        #expect(try reader.search(profileID: profile, needle: "view", limit: 10) == [
            .init(name: "pending\nview", kind: "view", database: "shop", table: nil),
        ])
    }

    @Test func searchStopsAtTheLimit() throws {
        let reader = GraphReader(store: try seeded())
        #expect(try reader.search(profileID: profile, needle: "id", limit: 2) == [
            .init(name: "id", kind: "column", database: "shop", table: "customers"),
            .init(name: "customer_id", kind: "column", database: "shop", table: "orders"),
        ])
    }

    // MARK: - Counts and state

    @Test func stateIsStaleOnceTheLastCheckIsOlderThanSixtySeconds() throws {
        let store = try seeded()
        let reader = GraphReader(store: store)
        let never = try reader.state(profileID: profile, now: t1)
        #expect(never.checkedAt == nil)
        #expect(never.stale)
        #expect(never.objectCount == 3)
        #expect(never.detailedCount == 2)

        try store.updateSchemaGraphState(profileID: profile) {
            $0.lastCheckedAt = t1
            $0.lastChangedAt = t1
            $0.selectedSchemas = #"["shop"]"#
            $0.hint = "selectSchemas"
            $0.lastErrorCode = "timeout"
        }
        let fresh = try reader.state(profileID: profile, now: t1.addingTimeInterval(59))
        #expect(!fresh.stale)
        #expect(fresh.checkedAt == t1)
        #expect(fresh.changedAt == t1)
        #expect(fresh.selectedSchemas == ["shop"])
        #expect(fresh.hint == "selectSchemas")
        #expect(fresh.lastErrorCode == "timeout")
        #expect(try reader.state(profileID: profile, now: t1.addingTimeInterval(61)).stale)
    }

    @Test func stateOfAnUnknownProfileIsEmptyAndStale() throws {
        let state = try GraphReader(store: try seeded()).state(profileID: UUID(), now: t1)
        #expect(state == GraphReader.State(
            checkedAt: nil, changedAt: nil, revision: 0, stale: true, objectCount: 0, detailedCount: 0,
            selectedSchemas: nil, hint: nil, lastErrorCode: nil
        ))
    }

    // MARK: - Changes

    /// A first pass, a pass that adds a column, and a pass that drops the view.
    func storeWithHistory() throws -> BerryStore {
        let store = try seeded()
        _ = try store.applySchemaDetails(profileID: profile, details: [try Self.write(Self.ordersWithNote)], now: t2, changeID: nil)
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: Self.objects.prefix(2).map { SchemaListedObject(database: $0.database, name: $0.name, kind: $0.kind.rawValue, fingerprint: nil) },
            relations: [], now: t3
        )
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t3 }
        return store
    }

    @Test func changesListAddedThenChangedThenRemoved() throws {
        let reader = GraphReader(store: try storeWithHistory())
        let page = try reader.changes(profileID: profile, since: nil, limit: 50)
        #expect(page.nextSince == nil)
        #expect(page.entries.map(\.kind) == [
            .added, .added, .added, .relationAdded, .changed, .removed, .relationRemoved,
        ])
        #expect(page.entries.map(\.name) == [
            "customers", "orders", "recent_orders", "orders", "orders", "recent_orders", "orders",
        ])
        #expect(page.entries.map(\.at) == [t1, t1, t1, t1, t2, t3, t3])
        try #require(page.entries.count == 7)
        #expect(page.entries[2].objectKind == "view")
        #expect(page.entries[3].relation == "shop.orders.customer_id -> shop.customers.id")
        let diff = try #require(page.entries[4].diff)
        #expect(diff.columnsAdded == ["note"])
        #expect(diff.columnsRemoved.isEmpty)
        #expect(!diff.columnsReordered)
        #expect(page.entries.filter { $0.kind != .changed }.allSatisfy { $0.diff == nil })
    }

    /// A page stops at `limit` entries, inside a change when it must, and
    /// `nextSince` is where the next page starts.
    @Test func changesPageByEntriesAcrossAndWithinChanges() throws {
        let reader = GraphReader(store: try storeWithHistory())
        #expect(try reader.changeMarks(profileID: profile).map(\.at) == [t3, t2, t1])

        let first = try reader.changes(profileID: profile, since: nil, limit: 2)
        #expect(first.entries.map(\.name) == ["customers", "orders"])
        #expect(first.nextSince != nil)

        let second = try reader.changes(profileID: profile, since: first.nextSince, limit: 2)
        #expect(second.entries.map(\.kind) == [.added, .relationAdded])
        #expect(second.nextSince != nil)

        let third = try reader.changes(profileID: profile, since: second.nextSince, limit: 2)
        #expect(third.entries.map(\.kind) == [.changed, .removed])
        #expect(third.nextSince != nil)

        let last = try reader.changes(profileID: profile, since: third.nextSince, limit: 2)
        #expect(last.entries.map(\.kind) == [.relationRemoved])
        #expect(last.nextSince == nil)
    }

    /// A first pass records every object under one change; its entries come
    /// back a page at a time instead of in one response.
    @Test func aFirstHarvestIsPagedByEntries() throws {
        let store = try BerryStore(path: ":memory:")
        let many = (0..<450).map { BerryDriverKit.SchemaObject(kind: .table, name: String(format: "t%03d", $0)) }
        try Self.seed(store, profileID: profile, objects: many, details: [], at: t1)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t1 }
        let reader = GraphReader(store: store)

        let first = try reader.changes(profileID: profile, since: nil, limit: 200)
        #expect(first.entries.count == 200)
        #expect(first.entries.first?.name == "t000")
        #expect(first.nextSince != nil)

        let second = try reader.changes(profileID: profile, since: first.nextSince, limit: 200)
        #expect(second.entries.count == 200)
        #expect(second.entries.first?.name == "t200")
        #expect(second.nextSince != nil)

        let third = try reader.changes(profileID: profile, since: second.nextSince, limit: 200)
        #expect(third.entries.map(\.name) == (400..<450).map { String(format: "t%03d", $0) })
        #expect(third.nextSince == nil)
    }

    /// A first pass records every object and foreign key under one change.
    /// A page reads the change's entries in index order and stops at the
    /// page, so no statement reads a change's rows without a limit, except
    /// the lookup of the one row a cursor names, by its id: building
    /// the 40,000 entries of a first pass over 20,000 tables before cutting
    /// a page out of them took 163 to 249 ms in a release build.
    @Test func aPageOfAChangeReadsNoMoreThanThePage() throws {
        let store = try BerryStore(path: ":memory:")
        let many = (0..<450).map { BerryDriverKit.SchemaObject(kind: .table, name: String(format: "t%03d", $0), database: "shop") }
        let relations = (1..<450).map {
            SchemaListedRelation(srcDatabase: "shop", srcName: String(format: "t%03d", $0), srcColumn: "parent_id",
                                 dstDatabase: "shop", dstName: String(format: "t%03d", $0 / 2), dstColumn: "id", constraintName: nil)
        }
        _ = try store.applySchemaListing(
            profileID: profile,
            objects: many.map { SchemaListedObject(database: $0.database, name: $0.name, kind: "table", fingerprint: nil) },
            relations: relations, now: t1
        )
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t1 }
        let reader = GraphReader(store: store)

        for since in [nil, try reader.changes(profileID: profile, since: nil, limit: 200).nextSince] {
            let recorded = try StatementLog.recording(store) { try reader.changes(profileID: profile, since: since, limit: 200) }
            #expect(recorded.result.entries.count == 200)
            let changeReads = recorded.statements.filter {
                $0.lowercased().contains("changeid = ?") && !$0.contains("WHERE id = ?")
            }
            #expect(!changeReads.isEmpty)
            #expect(changeReads.allSatisfy { $0.contains("LIMIT") }, "\(changeReads)")
        }
    }

    /// A cursor names a place inside a change that no longer grows, so pages
    /// read across the completion of later passes join up to exactly what one
    /// read of the whole feed returns.
    @Test func aCursorKeepsItsPlaceWhileNewChangesArrive() throws {
        let store = try storeWithHistory()
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }
        let reader = GraphReader(store: store)
        var pages = [try reader.changes(profileID: profile, since: nil, limit: 3)]

        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t3 }
        let t4 = Date(timeIntervalSince1970: 4_000)
        _ = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "customers", kind: "table", fingerprint: nil),
            SchemaListedObject(database: "shop", name: "invoices", kind: "table", fingerprint: nil),
            SchemaListedObject(database: "shop", name: "orders", kind: "table", fingerprint: nil),
        ], relations: nil, now: t4)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t4 }
        while let next = pages.last?.nextSince {
            pages.append(try reader.changes(profileID: profile, since: next, limit: 3))
        }

        let whole = try reader.changes(profileID: profile, since: nil, limit: 200)
        #expect(whole.nextSince == nil)
        #expect(pages.flatMap(\.entries) == whole.entries)
        #expect(whole.entries.map(\.name).suffix(1) == ["invoices"])
    }

    /// The marks follow the change feed's gate: a change stamped after the
    /// last check belongs to a pass that has not completed, which can still
    /// add to it, and a profile never checked has no marks.
    @Test func changeMarksListOnlyChangesUpToTheLastCheck() throws {
        let store = try storeWithHistory()
        let reader = GraphReader(store: store)
        #expect(try reader.changeMarks(profileID: profile).map(\.at) == [t3, t2, t1])

        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }
        #expect(try reader.changeMarks(profileID: profile).map(\.at) == [t2, t1])

        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = nil }
        #expect(try reader.changeMarks(profileID: profile).isEmpty)
    }

    @Test func schemaCountsGroupTheCurrentObjectsBySchema() throws {
        let store = try storeWithHistory()
        let counts = try GraphReader(store: store).schemaCounts(profileID: profile)
        // The view was removed at t3, which leaves the two tables.
        #expect(counts.map(\.database) == ["shop"])
        #expect(counts.map(\.count) == [2])
    }

    @Test func changeCursorsAcceptAChangeIDOrADate() throws {
        let reader = GraphReader(store: try storeWithHistory())
        let second = try #require(try reader.changeMarks(profileID: profile).dropFirst().first?.id)
        let fromID = try reader.changes(profileID: profile, since: "id:\(second)", limit: 50)
        #expect(fromID.entries.map(\.kind) == [.changed, .removed, .relationRemoved])
        let fromDate = try reader.changes(profileID: profile, since: "1970-01-01T00:33:20Z", limit: 50)
        #expect(fromDate.entries.map(\.kind) == [.changed, .removed, .relationRemoved])
        // `id:<change>:<entry offset>` is the form an earlier build wrote.
        for text in ["yesterday", "id:", "id:x", "id:1:-1", "id:1:2:3", "id:1:2", "id:12:200"] {
            #expect(throws: GraphReader.InvalidChangeCursor(text: text)) {
                try reader.changes(profileID: profile, since: text, limit: 50)
            }
        }
    }

    /// The entries of one change are ordered by namespace and name whatever
    /// happened to each object, and its relations follow.
    @Test func entriesOfOneChangeAreOrderedByObject() throws {
        func table(_ name: String, _ columns: [String]) -> TableDetail {
            TableDetail(
                ref: TableRef(database: "shop", name: name),
                columns: columns.map { ColumnInfo(name: $0, declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false) },
                indexes: [], foreignKeys: []
            )
        }
        let store = try BerryStore(path: ":memory:")
        try Self.seed(store, profileID: profile, objects: ["a_old", "m_table", "z_table"].map {
            BerryDriverKit.SchemaObject(kind: .table, name: $0, database: "shop")
        }, details: [table("a_old", ["id"]), table("m_table", ["id"]), table("z_table", ["id", "m_id"])], at: t1)
        let listing = try store.applySchemaListing(profileID: profile, objects: ["b_new", "m_table", "z_table"].map {
            SchemaListedObject(database: "shop", name: $0, kind: "table", fingerprint: nil)
        }, relations: nil, now: t2)
        _ = try store.applySchemaDetails(
            profileID: profile, details: [try Self.write(table("m_table", ["id", "note"]))], now: t2, changeID: listing.changeID
        )
        _ = try store.applySchemaRelations(profileID: profile, relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "z_table", srcColumn: "m_id",
                                 dstDatabase: "shop", dstName: "m_table", dstColumn: "id", constraintName: nil),
        ], now: t2, changeID: listing.changeID)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }

        let page = try GraphReader(store: store).changes(profileID: profile, since: "1970-01-01T00:33:20Z", limit: 50)
        #expect(page.entries.map(\.kind) == [.removed, .added, .changed, .relationAdded])
        #expect(page.entries.map(\.name) == ["a_old", "b_new", "m_table", "z_table"])
    }

    /// Only the changes of completed passes are listed: a change written
    /// after the last check belongs to a pass that is still running or that
    /// stopped, and none is listed before the first check.
    @Test func theFeedListsOnlyChangesAtOrBeforeTheLastCheck() throws {
        let store = try storeWithHistory()
        let reader = GraphReader(store: store)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }
        let checked = try reader.changes(profileID: profile, since: nil, limit: 50)
        #expect(checked.entries.map(\.kind) == [.added, .added, .added, .relationAdded, .changed])
        #expect(checked.nextSince == nil)
        #expect(checked.checkedAt == t2)

        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = nil }
        let never = try reader.changes(profileID: profile, since: nil, limit: 50)
        #expect(never.entries.isEmpty && never.nextSince == nil && never.checkedAt == nil)
    }

    @Test func aChangeOfRelationsAloneIsListed() throws {
        let store = try seeded()
        let added = try store.applySchemaRelations(profileID: profile, relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "orders", srcColumn: "customer_id",
                                 dstDatabase: "shop", dstName: "customers", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: "shop", srcName: "customers", srcColumn: "referrer_id",
                                 dstDatabase: "shop", dstName: "customers", dstColumn: "id", constraintName: nil),
        ], now: t2, changeID: nil)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }
        let change = try #require(added.changeID)
        let page = try GraphReader(store: store).changes(profileID: profile, since: "id:\(change)", limit: 50)
        #expect(page.entries.map(\.kind) == [.relationAdded])
        #expect(page.entries.map(\.relation) == ["shop.customers.referrer_id -> shop.customers.id"])
        #expect(page.nextSince == nil)
    }

    @Test func aCursorOnTheLastEntryOfAChangeContinuesWithTheNextOne() throws {
        let reader = GraphReader(store: try storeWithHistory())
        let first = try reader.changes(profileID: profile, since: nil, limit: 4)
        #expect(first.entries.map(\.at) == [t1, t1, t1, t1])
        let page = try reader.changes(profileID: profile, since: first.nextSince, limit: 50)
        #expect(page.entries.map(\.kind) == [.changed, .removed, .relationRemoved])
    }

    /// Retention deleting a version before the cursor moves nothing: the
    /// next page starts at the entry the cursor names.
    @Test func aCursorOutlivesTheRetentionOfAnEarlierEntry() throws {
        let store = try storeWithHistory()
        let reader = GraphReader(store: store)
        let first = try reader.changes(profileID: profile, since: nil, limit: 2)
        #expect(first.entries.map(\.name) == ["customers", "orders"])
        // The first version of `orders` was closed at t2, so this deletes it.
        try store.pruneSchemaHistory(profileID: profile, olderThan: t3, keepingAtMost: 10)
        let page = try reader.changes(profileID: profile, since: first.nextSince, limit: 2)
        #expect(page.entries.map(\.name) == ["recent_orders", "orders"])
        #expect(page.entries.map(\.kind) == [.added, .relationAdded])
    }

    /// Retention deleting the very version the cursor names leaves the page
    /// to resume after as many entries of the change as came before it.
    @Test func aCursorOutlivesTheRetentionOfTheEntryItNames() throws {
        let store = try storeWithHistory()
        let reader = GraphReader(store: store)
        let first = try reader.changes(profileID: profile, since: nil, limit: 1)
        #expect(first.entries.map(\.name) == ["customers"])
        // The next entry is the first version of `orders`, closed at t2.
        try store.pruneSchemaHistory(profileID: profile, olderThan: t3, keepingAtMost: 10)
        let page = try reader.changes(profileID: profile, since: first.nextSince, limit: 2)
        #expect(page.entries.map(\.name) == ["recent_orders", "orders"])
        #expect(page.entries.map(\.kind) == [.added, .relationAdded])
    }

    /// A cursor's offset is counted up while a page is read, so one too large
    /// for any change must be refused as an invalid cursor rather than
    /// overflow; this one fits the 64 characters the MCP tool accepts.
    @Test func aCursorWithAnUnreachableOffsetIsInvalid() throws {
        let reader = GraphReader(store: try storeWithHistory())
        let change = try #require(try reader.changeMarks(profileID: profile).last?.id)
        let first = try reader.changes(profileID: profile, since: nil, limit: 1)
        #expect(first.entries.map(\.name) == ["customers"])
        let maximum = Int(Int32.max)
        for text in [
            "id:\(change):o1i\(Int.max)", "id:\(change):r1i\(Int.max)", "id:\(change):o1c\(Int.max)",
            "id:\(change):o1i\(maximum + 1)",
        ] {
            #expect(text.count <= 64)
            #expect(throws: GraphReader.InvalidChangeCursor(text: text)) {
                try reader.changes(profileID: profile, since: text, limit: 50)
            }
        }
        // The largest offset accepted is read without overflow, from a row
        // that exists and from one that does not.
        #expect(try reader.changes(profileID: profile, since: "id:\(change):o1i\(maximum)", limit: 50).entries.count == 7)
        #expect(try reader.changes(profileID: profile, since: "id:\(change):o999i\(maximum)", limit: 50).entries.map(\.kind)
                    == [.relationAdded, .changed, .removed, .relationRemoved])
    }

    /// The MCP tool takes a `since` of at most 64 characters, so a cursor must
    /// fit in them whatever names the entries have.
    @Test func everyCursorFitsInSixtyFourCharacters() throws {
        let store = try BerryStore(path: ":memory:")
        let schema = String(repeating: "s", count: 63)
        let names = ["a", "b", "c"].map { String(repeating: $0, count: 63) }
        _ = try store.applySchemaListing(profileID: profile, objects: names.map {
            SchemaListedObject(database: schema, name: $0, kind: "table", fingerprint: nil)
        }, relations: [
            SchemaListedRelation(srcDatabase: schema, srcName: names[1], srcColumn: String(repeating: "x", count: 63),
                                 dstDatabase: schema, dstName: names[0], dstColumn: String(repeating: "y", count: 63), constraintName: nil),
            SchemaListedRelation(srcDatabase: schema, srcName: names[2], srcColumn: String(repeating: "x", count: 63),
                                 dstDatabase: schema, dstName: names[0], dstColumn: String(repeating: "y", count: 63), constraintName: nil),
        ], now: t1)
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t1 }
        let reader = GraphReader(store: store)
        var cursors: [String] = []
        var page = try reader.changes(profileID: profile, since: nil, limit: 1)
        var entries = page.entries
        while let next = page.nextSince {
            cursors.append(next)
            page = try reader.changes(profileID: profile, since: next, limit: 1)
            entries += page.entries
        }
        #expect(entries.map(\.kind) == [.added, .added, .added, .relationAdded, .relationAdded])
        #expect(cursors.allSatisfy { $0.count <= 64 }, "\(cursors.map(\.count))")
    }

    @Test func limitsAreClampedSoPagingAlwaysAdvances() throws {
        let reader = GraphReader(store: try storeWithHistory())
        let objects = try reader.objects(profileID: profile, names: nil, offset: 0, limit: 0, maxBytes: .max)
        #expect(objects.objects.map(\.name) == ["customers"])
        #expect(objects.nextOffset == 1)
        let changes = try reader.changes(profileID: profile, since: nil, limit: 0)
        #expect(changes.entries.map(\.name) == ["customers"])
        #expect(changes.nextSince != nil)
    }

    /// Every one of 450 objects changes in one pass. A page of 200 reads the
    /// definitions of its own 200 version pairs, in one statement, and never
    /// the whole change.
    @Test func aPageReadsDefinitionsOnlyForItsOwnChangedEntries() throws {
        let store = try BerryStore(path: ":memory:")
        func table(_ index: Int, _ columns: [String]) -> TableDetail {
            TableDetail(
                ref: TableRef(database: "shop", name: String(format: "t%03d", index)),
                columns: columns.map { ColumnInfo(name: $0, declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false) },
                indexes: [], foreignKeys: []
            )
        }
        try Self.seed(store, profileID: profile, objects: (0..<450).map {
            BerryDriverKit.SchemaObject(kind: .table, name: String(format: "t%03d", $0), database: "shop")
        }, details: (0..<450).map { table($0, ["id"]) }, at: t1)
        let changed = try store.applySchemaDetails(
            profileID: profile, details: try (0..<450).map { try Self.write(table($0, ["id", "note"])) }, now: t2, changeID: nil
        )
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t2 }
        let change = try #require(changed.changeID)
        let reader = GraphReader(store: store)

        let recorded = try StatementLog.recording(store) {
            try reader.changes(profileID: profile, since: "id:\(change)", limit: 200)
        }
        let page = recorded.result
        #expect(page.entries.count == 200)
        #expect(page.entries.allSatisfy { $0.kind == .changed && $0.diff?.columnsAdded == ["note"] })
        #expect(page.nextSince != nil)
        let definitionReads = recorded.statements.filter { $0.hasPrefix("SELECT id, definition FROM schema_object WHERE id IN (") }
        #expect(definitionReads.count == 1)
        #expect(definitionReads.map { $0.filter { $0 == "?" }.count } == [400])
        #expect(!recorded.statements.contains { $0.contains("SELECT * FROM schema_object") && $0.contains("changeID = ?") })
    }

    @Test func searchStopsReadingOnceTheLimitIsFilled() throws {
        let store = try BerryStore(path: ":memory:")
        let tables = (0..<450).map { index in
            TableDetail(
                ref: TableRef(database: "shop", name: String(format: "t%03d", index)),
                columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
                indexes: [], foreignKeys: []
            )
        }
        try Self.seed(store, profileID: profile, objects: tables.map {
            BerryDriverKit.SchemaObject(kind: .table, name: $0.ref.name, database: "shop")
        }, details: tables, at: t1)
        let reader = GraphReader(store: store)
        // How many definitions the search read, all of them by id.
        func definitionsRead(_ statements: [String]) -> Int {
            statements.filter { $0.contains("WHERE id IN") }.map { $0.filter { $0 == "?" }.count }.reduce(0, +)
        }

        let few = try StatementLog.recording(store) { try reader.search(profileID: profile, needle: "id", limit: 10) }
        #expect(few.result.count == 10)
        #expect(few.result.first == .init(name: "id", kind: "column", database: "shop", table: "t000"))
        #expect(definitionsRead(few.statements) == 10)

        let all = try StatementLog.recording(store) { try reader.search(profileID: profile, needle: "id", limit: 1_000) }
        #expect(all.result.count == 450)
        #expect(all.result.last == .init(name: "id", kind: "column", database: "shop", table: "t449"))
        #expect(definitionsRead(all.statements) == 450)
    }

    /// Every table of a PostgreSQL schema has a `<table>_pkey` index, so a
    /// needle such as `pkey` matches every index name and no table or column
    /// name. Matching each phase in SQL reads the definitions of the matches
    /// it keeps and no others: at most `limit` of them, by id.
    @Test func anIndexOnlyNeedleReadsNoMoreDefinitionsThanTheLimit() throws {
        let store = try BerryStore(path: ":memory:")
        let tables = (0..<450).map { index in
            let name = String(format: "t%03d", index)
            return TableDetail(
                ref: TableRef(database: "shop", name: name),
                columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
                indexes: [IndexInfo(name: name + "_pkey", isUnique: true, columns: ["id"])], foreignKeys: []
            )
        }
        try Self.seed(store, profileID: profile, objects: tables.map {
            BerryDriverKit.SchemaObject(kind: .table, name: $0.ref.name, database: "shop")
        }, details: tables, at: t1)
        let reader = GraphReader(store: store)

        let found = try StatementLog.recording(store) { try reader.search(profileID: profile, needle: "PKEY", limit: 10) }
        #expect(found.result == (0..<10).map {
            .init(name: String(format: "t%03d_pkey", $0), kind: "index", database: "shop", table: String(format: "t%03d", $0))
        })
        let rowReads = found.statements.filter {
            $0.contains("FROM schema_object") && ($0.contains("SELECT *") || $0.contains("definition"))
        }
        #expect(rowReads.allSatisfy { $0.contains("WHERE id IN") }, "\(rowReads)")
        #expect(rowReads.map { $0.filter { $0 == "?" }.count }.reduce(0, +) <= 10, "\(rowReads)")
    }

    /// A table and a view of one name in one schema have their columns
    /// ordered together by name, so a search that stops at its limit still
    /// reads the second of them: here the view's column ranks first.
    @Test func aTableAndAViewOfOneNameAreReadTogether() throws {
        let store = try BerryStore(path: ":memory:")
        let table = TableDetail(
            ref: TableRef(database: "shop", name: "t"),
            columns: [ColumnInfo(name: "c_x", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [], foreignKeys: []
        )
        let view = TableDetail(
            ref: TableRef(database: "shop", name: "t"),
            columns: [ColumnInfo(name: "b_x", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [], foreignKeys: []
        )
        let listing = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "t", kind: "table", fingerprint: nil),
            SchemaListedObject(database: "shop", name: "t", kind: "view", fingerprint: nil),
        ], relations: [], now: t1)
        _ = try store.applySchemaDetails(
            profileID: profile, details: [try Self.write(table), try Self.write(view, kind: "view")], now: t1, changeID: listing.changeID
        )
        #expect(try GraphReader(store: store).search(profileID: profile, needle: "_x", limit: 1) == [
            .init(name: "b_x", kind: "column", database: "shop", table: "t"),
        ])
    }

    @Test func aPageReadsTheForeignKeysOfItsOwnObjectsOnly() throws {
        let store = try seeded()
        let reader = GraphReader(store: store)
        let recorded = try StatementLog.recording(store) {
            try reader.objects(profileID: profile, names: ["orders"], offset: 0, limit: 200, maxBytes: .max)
        }
        #expect(recorded.result.relations.map(\.srcColumn) == ["customer_id"])
        #expect(try reader.objects(profileID: profile, names: ["customers"], offset: 0, limit: 200, maxBytes: .max).relations.isEmpty)
        #expect(recorded.statements.contains { $0.contains("(srcDatabase, srcName) IN (VALUES") })
        #expect(!recorded.statements.contains { $0.contains("FROM schema_relation WHERE profileID = ? AND removedAt IS NULL") })
    }

    /// An overview serialises no foreign keys, so its page reads none.
    @Test func aPageWithoutRelationsReadsNoForeignKeys() throws {
        let store = try seeded()
        let reader = GraphReader(store: store)
        let recorded = try StatementLog.recording(store) {
            try reader.objects(
                profileID: profile, names: ["orders"], offset: 0, limit: 200, maxBytes: .max, includeRelations: false
            )
        }
        #expect(recorded.result.objects.map(\.name) == ["orders"])
        #expect(recorded.result.relations.isEmpty)
        #expect(!recorded.statements.contains { $0.contains("schema_relation") })
    }

    /// A pending row's listing entry is mostly its name and namespace, which
    /// the fixed overhead alone does not cover once they are long.
    @Test func theByteEstimateCoversTheListingEntryOfAPendingRowWithLongNames() throws {
        let store = try BerryStore(path: ":memory:")
        let name = String(repeating: "n", count: 128)
        let namespace = String(repeating: "s", count: 128)
        _ = try store.applySchemaListing(
            profileID: profile, objects: [SchemaListedObject(database: namespace, name: name, kind: "view", fingerprint: nil)],
            relations: [], now: t1
        )
        let row = try #require(try store.currentSchemaObjects(profileID: profile).first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let entry = try encoder.encode(
            BerryGraphQueryService.SchemaObject(name: name, database: namespace, kind: .view, detailPending: true)
        )
        #expect(GraphReader.estimatedSize(of: row, foreignKeys: []) >= entry.count)
    }

    /// Two objects without definitions fit a budget of 330 bytes on their
    /// own 165 each, the overhead plus their names; the foreign keys of the
    /// second take it past.
    /// The byte budget is spent on what a page returns, each definition as
    /// text, not on what the store keeps: a definition compresses to a
    /// fraction of its text, and counting the stored bytes would let a page
    /// run far past the budget.
    @Test func theByteBudgetCountsDefinitionsAsText() throws {
        let store = try BerryStore(path: ":memory:")
        let columns = (0..<2_000).map {
            ColumnInfo(name: "column_\($0)", declaredType: "int", isNullable: true, defaultValue: nil, isPrimaryKey: false)
        }
        let details = ["a", "b"].map { TableDetail(ref: TableRef(database: "shop", name: $0), columns: columns, indexes: [], foreignKeys: []) }
        try Self.seed(store, profileID: profile, objects: details.map {
            BerryDriverKit.SchemaObject(kind: .table, name: $0.ref.name, database: "shop")
        }, details: details, at: t1)
        let text = try Self.write(details[0]).definition.utf8.count
        let stored = try store.read { try Int.fetchOne($0, sql: "SELECT max(length(definition)) FROM schema_object") } ?? 0
        #expect(stored * 4 < text, "\(stored) bytes stored for \(text) bytes of text")

        let page = try GraphReader(store: store).objects(profileID: profile, names: nil, offset: 0, limit: 200, maxBytes: text + text / 2)
        #expect(page.objects.map(\.name) == ["a"])
        #expect(page.nextOffset == 1)
    }

    /// A stored definition that does not decompress fails no read: the
    /// object is listed as pending, searched by its name and graphed without
    /// columns. It stays so until the object's definition changes, since a
    /// detail write with the same hash only refreshes the fingerprint.
    @Test func aDamagedDefinitionFailsNoReadAndStaysUntilTheDefinitionChanges() throws {
        let store = try seeded()
        try store.write { try $0.execute(sql: "UPDATE schema_object SET definition = x'deadbeef' WHERE name = 'orders'") }
        try store.updateSchemaGraphState(profileID: profile) { $0.lastCheckedAt = t1 }
        let reader = GraphReader(store: store)
        func ordersDefinition() throws -> SchemaDefinition? {
            let row = try #require(try reader.objects(profileID: profile, names: ["orders"], offset: 0, limit: 10, maxBytes: .max).objects.first)
            return GraphReader.definition(of: row)
        }

        #expect(try ordersDefinition() == nil)
        #expect(try reader.search(profileID: profile, needle: "orders", limit: 10).map(\.name).contains("orders"))
        #expect(try reader.fullGraph(profileID: profile, asOf: nil).nodes["table:shop.orders"] != nil)
        #expect(try reader.changes(profileID: profile, since: nil, limit: 50).entries.contains { $0.name == "orders" })
        let graph = try reader.fullGraph(profileID: profile, asOf: nil)
        #expect(graph.nodes.values.filter { $0.kind == .column }.count == 2)
        #expect(graph.nodes.values.filter { $0.kind == .index }.count == 1)

        _ = try store.applySchemaDetails(profileID: profile, details: [try Self.write(Self.orders)], now: t2, changeID: nil)
        #expect(try ordersDefinition() == nil)
        _ = try store.applySchemaDetails(profileID: profile, details: [try Self.write(Self.ordersWithNote)], now: t2, changeID: nil)
        #expect(try ordersDefinition()?.columns.map(\.name).contains("note") == true)
    }

    @Test func theByteEstimateCountsForeignKeys() throws {
        let store = try BerryStore(path: ":memory:")
        _ = try store.applySchemaListing(profileID: profile, objects: ["a", "b"].map {
            SchemaListedObject(database: "shop", name: $0, kind: "table", fingerprint: nil)
        }, relations: [
            SchemaListedRelation(srcDatabase: "shop", srcName: "b", srcColumn: "a_id", dstDatabase: "shop", dstName: "a", dstColumn: "id", constraintName: nil),
        ], now: t1)
        let reader = GraphReader(store: store)
        let page = try reader.objects(profileID: profile, names: nil, offset: 0, limit: 200, maxBytes: 330)
        #expect(page.objects.map(\.name) == ["a"])
        #expect(page.nextOffset == 1)
        let row = try #require(try store.currentSchemaObjects(profileID: profile).last)
        let keys = try store.currentSchemaRelations(profileID: profile)
        #expect(GraphReader.estimatedSize(of: row, foreignKeys: keys)
            == 160 + "b".count + "shop".count + "a_id".count + "shop".count + "a".count + "id".count + 90)
    }

    @Test func theCurrentGraphReadsNoPageCount() throws {
        let store = try seeded()
        let reader = GraphReader(store: store)
        let graphed = try StatementLog.recording(store) { try reader.fullGraph(profileID: profile, asOf: nil) }
        #expect(graphed.result.nodeCount > 0)
        #expect(!graphed.statements.contains { $0.contains("COUNT(*) FROM schema_object") })
        #expect(!graphed.statements.contains { $0.contains("LIMIT ? OFFSET ?") })
    }

    // MARK: - Graphs

    /// A statistics refresh replaces the rows without changing the schema, so
    /// a graph kept between refreshes would carry counters that are out of
    /// date; counters are read from the rows, which `statistics` does.
    @Test func tableGraphHasObjectsAndReferencesButNoStatistics() throws {
        let store = try seeded()
        try seedStats(store)
        let graph = try GraphReader(store: store).tableGraph(profileID: profile)
        #expect(Set(graph.nodes.keys) == ["table:shop.customers", "table:shop.orders", "view:shop.recent_orders"])
        #expect(graph.edges == [GraphEdge(
            src: "table:shop.orders", dst: "table:shop.customers", kind: .references,
            attrs: ["column": "customer_id", "referencedColumn": "id"]
        )])
        #expect(graph.nodes.values.allSatisfy { $0.attrs.isEmpty })
        #expect(graph.nodes["view:shop.recent_orders"]?.kind == .view)
    }

    /// The table graph is the full graph's tables, views and foreign keys:
    /// the same nodes and the same edges, whatever namespace each end has
    /// and whether the listing holds the target.
    @Test func tableGraphIsTheTableLevelOfTheFullGraph() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "sales", name: "orders", kind: "table", fingerprint: nil),
            SchemaListedObject(database: "sales", name: "recent", kind: "view", fingerprint: nil),
            SchemaListedObject(database: nil, name: "notes", kind: "table", fingerprint: nil),
        ], relations: [
            SchemaListedRelation(srcDatabase: "sales", srcName: "orders", srcColumn: "customer_id",
                                 dstDatabase: "crm", dstName: "customers", dstColumn: "id", constraintName: "fk_customer"),
            SchemaListedRelation(srcDatabase: "sales", srcName: "orders", srcColumn: "product_id",
                                 dstDatabase: "sales", dstName: "products", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: nil, srcName: "notes", srcColumn: "order_id",
                                 dstDatabase: "sales", dstName: "orders", dstColumn: "id", constraintName: nil),
            SchemaListedRelation(srcDatabase: nil, srcName: "notes", srcColumn: "parent_id",
                                 dstDatabase: nil, dstName: "notes", dstColumn: "id", constraintName: nil),
        ], now: t1)
        let orders = TableDetail(
            ref: TableRef(database: "sales", name: "orders"),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [], foreignKeys: []
        )
        _ = try store.applySchemaDetails(profileID: profile, details: [try Self.write(orders)], now: t1, changeID: listing.changeID)
        let reader = GraphReader(store: store)

        let table = try reader.tableGraph(profileID: profile)
        let full = try reader.fullGraph(profileID: profile, asOf: nil)
        let tableLevel = full.nodes.values.filter { $0.kind == .table || $0.kind == .view }
        #expect(Set(table.nodes.values) == Set(tableLevel))
        #expect(table.edges == full.edges.filter { $0.kind == .references })
        #expect(table.edgeCount == 4)
        #expect(table.nodes["table:.notes"]?.database == nil)
    }

    /// Building the table graph needs each foreign key's two ends, not the
    /// whole record with its dates: decoding 20,000 records took 77 to 112 ms
    /// in a release build, against 6 to 16 ms for the ends alone.
    @Test func tableGraphReadsTheEndsOfEachForeignKeyOnly() throws {
        let store = try seeded()
        let recorded = try StatementLog.recording(store) { try GraphReader(store: store).tableGraph(profileID: profile) }
        #expect(recorded.result.edgeCount == 1)
        let relationReads = recorded.statements.filter { $0.contains("FROM schema_relation") }
        #expect(relationReads.count == 1)
        #expect(!relationReads.contains { $0.contains("SELECT *") }, "\(relationReads)")
    }

    @Test func fullGraphMatchesTheBuilderForTheSameSchema() throws {
        let built = SchemaGraphBuilder.build(
            objects: Self.objects,
            details: [Self.customers.ref: Self.customers, Self.orders.ref: Self.orders]
        )
        let read = try GraphReader(store: try seeded()).fullGraph(profileID: profile, asOf: nil)
        #expect(Set(read.nodes.values) == Set(built.nodes.values))
        #expect(Set(read.edges) == Set(built.edges))
        #expect(read.edgeCount == built.edgeCount)
    }

    /// A foreign key to a table outside the listing gets a stub table node,
    /// in the namespace the key names, as the builder gives it.
    @Test func fullGraphMatchesTheBuilderForUnlistedAndOtherNamespaceTargets() throws {
        let orders = TableDetail(
            ref: TableRef(database: "sales", name: "orders"),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: true)],
            indexes: [],
            foreignKeys: [
                ForeignKeyInfo(column: "customer_id", referencedSchema: "crm", referencedTable: "customers", referencedColumn: "id"),
                ForeignKeyInfo(column: "product_id", referencedTable: "products", referencedColumn: "id"),
            ]
        )
        let objects = [BerryDriverKit.SchemaObject(kind: .table, name: "orders", database: "sales")]
        let built = SchemaGraphBuilder.build(objects: objects, details: [orders.ref: orders])
        let store = try BerryStore(path: ":memory:")
        try Self.seed(store, profileID: profile, objects: objects, details: [orders], at: t1)
        let read = try GraphReader(store: store).fullGraph(profileID: profile, asOf: nil)
        #expect(Set(read.nodes.values) == Set(built.nodes.values))
        #expect(Set(read.edges) == Set(built.edges))
        #expect(read.nodes["table:crm.customers"]?.kind == .table)
        #expect(read.nodes["table:sales.products"]?.kind == .table)
    }

    /// The one place the reader departs from the builder: a view's columns
    /// hang off the view's own node, where the builder would add a table node
    /// of the same name for them.
    @Test func aViewWithADefinitionOwnsItsColumns() throws {
        let store = try BerryStore(path: ":memory:")
        let listing = try store.applySchemaListing(profileID: profile, objects: [
            SchemaListedObject(database: "shop", name: "recent", kind: "view", fingerprint: nil),
        ], relations: [], now: t1)
        let detail = TableDetail(
            ref: TableRef(database: "shop", name: "recent"),
            columns: [ColumnInfo(name: "id", declaredType: "int", isNullable: false, defaultValue: nil, isPrimaryKey: false)],
            indexes: [], foreignKeys: []
        )
        _ = try store.applySchemaDetails(
            profileID: profile, details: [try Self.write(detail, kind: "view")], now: t1, changeID: listing.changeID
        )
        let graph = try GraphReader(store: store).fullGraph(profileID: profile, asOf: nil)
        #expect(graph.neighbors(of: "view:shop.recent", direction: .outgoing, kinds: [.hasColumn]) == ["column:shop.recent.id"])
        #expect(graph.nodes["table:shop.recent"] == nil)
    }

    @Test func fullGraphCarriesTableAndIndexStatistics() throws {
        let store = try seeded()
        try seedStats(store)
        let graph = try GraphReader(store: store).fullGraph(profileID: profile, asOf: nil)
        #expect(graph.nodes["table:shop.customers"]?.attrs == [
            "rows": "10", "size_bytes": "4096", "seq_scan": "3", "idx_scan": "7",
        ])
        #expect(graph.nodes["table:shop.orders"]?.attrs == ["rows": "100"])
        #expect(graph.nodes["index:shop.orders.orders_customer_idx"]?.attrs == [
            "unique": "false", "columns": "customer_id,placed_at", "idx_scan": "0", "unused": "true",
        ])
        #expect(graph.nodes["index:shop.customers.customers_email_key"]?.attrs["unused"] == "false")
    }

    @Test func fullGraphAsOfReadsTheVersionsCurrentThen() throws {
        let reader = GraphReader(store: try storeWithHistory())
        func columns(_ graph: SchemaGraph) -> [String] {
            graph.neighbors(of: "table:shop.orders", direction: .outgoing, kinds: [.hasColumn])
                .compactMap { graph.nodes[$0]?.name }.sorted()
        }
        let before = try reader.fullGraph(profileID: profile, asOf: t1)
        #expect(columns(before) == ["customer_id", "id", "placed_at"])
        #expect(before.nodes["view:shop.recent_orders"] != nil)
        #expect(before.edges.contains { $0.kind == .references })

        let now = try reader.fullGraph(profileID: profile, asOf: nil)
        #expect(columns(now) == ["customer_id", "id", "note", "placed_at"])
        #expect(now.nodes["view:shop.recent_orders"] == nil)
        #expect(!now.edges.contains { $0.kind == .references })
    }

    @Test func statsAreTheStoredRows() throws {
        let store = try seeded()
        try seedStats(store)
        let rows = try GraphReader(store: store).stats(
            profileID: profile, objects: [(database: "shop", name: "customers"), (database: "shop", name: "orders")]
        )
        #expect(rows.map(\.name).sorted() == ["customers", "orders"])
    }
}
