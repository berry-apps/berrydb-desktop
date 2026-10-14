import BerryCore
import BerryDriverKit
import BerryDriverPostgres
import BerryDriverTestKit
import BerryGraph
import BerryMCP
import Darwin
import Foundation
import GRDB
import Testing

@testable import BerryStore

// Scale benchmark for the stored schema graph: harvest passes over a
// synthetic catalog, the metadata reads an agent makes and the memory they
// keep, the store's size under churn, and the upgrade of a store written in
// the per-node graph format. Opt-in like the rest of this target: it runs
// only with BERRYDB_BENCH set (see `make bench`), so a plain `swift test`
// compiles it and skips it. Every measurement is printed as a BENCH line and
// checked against the budget it is held to at 20,000 tables.

private let benchEnabled = ProcessInfo.processInfo.environment["BERRYDB_BENCH"] != nil
private let tableCount = ProcessInfo.processInfo.environment["BERRYDB_BENCH_TABLES"].flatMap(Int.init) ?? 20_000
private let postgresTableCount = ProcessInfo.processInfo.environment["BENCH_PG_TABLES"].flatMap(Int.init) ?? 2_000

// Every BENCH line names the build it was measured in: the metadata reads
// below took up to twice as long in a debug build as in a release build.
#if DEBUG
private let buildMode = "debug"
#else
private let buildMode = "release"
#endif
private let scale = "schema graph n=\(tableCount) \(buildMode)"

private enum Budget {
    /// A synthetic catalog costs no network time, so this bounds the store
    /// and the coordinator alone.
    static let firstPass = Duration.seconds(60)
    static let oneTableChangedPass = Duration.seconds(1)
    /// A lookup by key: one connection's state, one table's definition.
    static let pointRead = Duration.milliseconds(10)
    /// A page of up to 200 objects, matches or change entries.
    static let pageRead = Duration.milliseconds(30)
    /// A graph query that reads and builds the table graph.
    static let graphBuild = Duration.milliseconds(100)
    /// A graph query answered from the cached table graph.
    static let cachedGraph = Duration.milliseconds(10)
    static let helperMemoryBytes: UInt64 = 60 << 20
    static let storeBytes: UInt64 = 60 << 20
    static let conversion = Duration.seconds(30)
}

private func report(_ line: String) {
    print("BENCH \(line)")
}

private func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let value = Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    return String(format: "%.1f ms", value)
}

private func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

private func measure<T>(_ body: () async throws -> T) async rethrows -> (value: T, elapsed: Duration) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    return (value, clock.now - start)
}

/// Timings of one operation. A budget is checked against the median: a single
/// timing swung past a 30 ms budget whenever another process loaded the
/// machine, and a median of five keeps one such sample from deciding the
/// gate while still failing an operation that is slow most of the time.
private struct Samples {
    static let count = 5

    /// Ascending.
    let durations: [Duration]

    var median: Duration { durations[durations.count / 2] }

    var summary: String {
        "\(milliseconds(median)) median of \(durations.count), \(milliseconds(durations[0])) to \(milliseconds(durations[durations.count - 1]))"
    }
}

/// Times `body` `Samples.count` times. `reset` runs before each sample,
/// outside the clock, so a gate on a first call starts every sample cold.
/// Returns the value of the last sample.
private func sample<T>(
    reset: () throws -> Void = {}, _ body: () async throws -> T
) async rethrows -> (value: T, samples: Samples) {
    try reset()
    var (value, elapsed) = try await measure(body)
    var durations = [elapsed]
    while durations.count < Samples.count {
        try reset()
        (value, elapsed) = try await measure(body)
        durations.append(elapsed)
    }
    return (value, Samples(durations: durations.sorted()))
}

/// The process's physical footprint, `phys_footprint` of `TASK_VM_INFO`, the
/// measure the memory budget is stated in. Nil when the kernel refuses the
/// query.
private func footprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

/// The files the store occupies on disk: the database, its WAL and the WAL's
/// shared-memory index.
private struct StoreSize {
    let database: UInt64
    let wal: UInt64
    let sharedMemory: UInt64

    var total: UInt64 { database + wal + sharedMemory }

    init(path: String) {
        func size(_ file: String) -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        database = size(path)
        wal = size(path + "-wal")
        sharedMemory = size(path + "-shm")
    }

    var summary: String {
        "\(megabytes(total)) (database \(megabytes(database)), wal \(megabytes(wal)), shm \(megabytes(sharedMemory)))"
    }
}

/// A temporary directory removed by `remove()`, so no run touches the app's
/// own store.
private struct ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var storePath: String { url.appendingPathComponent("store.sqlite").path }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Synthetic catalog

/// One schema of tables shaped like a mid-sized application's: 20 columns, a
/// primary key and one secondary index, and a foreign key from table `i` to
/// table `i / 2`, so every table but the first references another and the
/// graph fans in like a tree.
private struct SyntheticCatalog {
    struct Table {
        let id: Int
        var parent: Int?
        /// Each revision adds a column, as an `ALTER TABLE ... ADD COLUMN`
        /// does.
        var revision = 0
    }

    static let schema = "public"
    private static let nouns = ["orders", "customers", "invoices", "events", "users"]
    private static let columnNouns = ["created_at", "status", "amount", "user_id", "note"]
    private static let foreignKeyColumn = "col_3_user_id"

    private(set) var tables: [Table]
    private var nextID: Int

    init(tables count: Int) {
        tables = (0..<count).map { Table(id: $0, parent: $0 > 0 ? $0 / 2 : nil) }
        nextID = count
    }

    static func name(_ id: Int) -> String {
        "tbl_\(id)_" + nouns[id % nouns.count]
    }

    static func ref(_ id: Int) -> TableRef {
        TableRef(database: schema, name: name(id))
    }

    mutating func revise(_ id: Int) {
        guard let index = tables.firstIndex(where: { $0.id == id }) else { return }
        tables[index].revision += 1
    }

    /// Adds a column to every table, so every definition hash moves.
    mutating func reviseAll() {
        for index in tables.indices { tables[index].revision += 1 }
    }

    /// Drops the `count` oldest tables and creates `count` new ones. A table
    /// whose parent is dropped loses its foreign key, as
    /// `DROP TABLE ... CASCADE` removes the constraint that references it.
    mutating func churn(_ count: Int) {
        let dropped = Set(tables.prefix(count).map(\.id))
        tables.removeFirst(min(count, tables.count))
        for index in tables.indices where tables[index].parent.map(dropped.contains) == true {
            tables[index].parent = nil
        }
        let present = Set(tables.map(\.id))
        for id in nextID..<(nextID + count) {
            tables.append(Table(id: id, parent: present.contains(id / 2) ? id / 2 : nil))
        }
        nextID += count
    }

    /// Moves whenever the table's columns, indexes or foreign key do, like an
    /// engine's catalog fingerprint.
    static func summary(_ table: Table) -> SchemaObjectSummary {
        SchemaObjectSummary(ref: ref(table.id), kind: .table, fingerprint: "\(table.revision):\(table.parent ?? -1)")
    }

    static func detail(_ table: Table) -> TableDetail {
        let name = Self.name(table.id)
        var columns = [ColumnInfo(name: "id", declaredType: "bigint", isNullable: false, defaultValue: nil, isPrimaryKey: true)]
        for column in 1..<(20 + table.revision) {
            columns.append(ColumnInfo(
                name: "col_\(column)_" + columnNouns[column % columnNouns.count],
                declaredType: column % 3 == 0 ? "timestamp without time zone" : "character varying(255)",
                isNullable: column % 2 == 0, defaultValue: nil, isPrimaryKey: false
            ))
        }
        let indexes = [
            IndexInfo(name: "\(name)_pkey", isUnique: true, columns: ["id"]),
            IndexInfo(name: "\(name)_col_1_idx", isUnique: false, columns: ["col_1_status"]),
        ]
        let foreignKeys = table.parent.map {
            [ForeignKeyInfo(column: foreignKeyColumn, referencedSchema: schema, referencedTable: Self.name($0), referencedColumn: "id")]
        } ?? []
        return TableDetail(ref: ref(table.id), columns: columns, indexes: indexes, foreignKeys: foreignKeys)
    }

    static func relation(_ table: Table) -> ForeignKeyRelation? {
        table.parent.map {
            ForeignKeyRelation(
                source: ref(table.id), column: foreignKeyColumn, target: ref($0), referencedColumn: "id",
                constraintName: "\(name(table.id))_\(foreignKeyColumn)_fkey"
            )
        }
    }
}

/// Serves a `SyntheticCatalog` as a driver with bulk introspection does, and
/// records how many tables each detail read asked for, so a test can check
/// that a pass read only what changed.
private final class ScriptedIntrospector: Introspector, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var summaries: [SchemaObjectSummary] = []
    private var relations: [ForeignKeyRelation] = []
    private var details: [TableRef: TableDetail] = [:]
    private var detailReads: [Int] = []

    func serve(_ catalog: SyntheticCatalog, token: String) {
        let summaries = catalog.tables.map(SyntheticCatalog.summary)
        let relations = catalog.tables.compactMap(SyntheticCatalog.relation)
        let details = Dictionary(uniqueKeysWithValues: catalog.tables.map { (SyntheticCatalog.ref($0.id), SyntheticCatalog.detail($0)) })
        lock.withLock {
            self.token = token
            self.summaries = summaries
            self.relations = relations
            self.details = details
        }
    }

    /// The number of tables each detail read asked for, in call order.
    var detailReadSizes: [Int] { lock.withLock { detailReads } }

    func databases() async throws -> [DatabaseInfo] { [] }
    func objects(in database: String?) async throws -> [SchemaObject] { [] }
    func tableDetail(_ ref: TableRef) async throws -> TableDetail {
        guard let detail = lock.withLock({ details[ref] }) else {
            throw DriverError.queryFailed(message: "no table \(ref.name)", code: nil)
        }
        return detail
    }
    func tableStats(_ ref: TableRef) async throws -> TableStats {
        TableStats(estimatedRowCount: nil, sizeBytes: nil, engine: nil, comment: nil)
    }
    func ddl(of object: SchemaObject) async throws -> String { "" }
    func schemaVersionToken(scope: SchemaScope) async throws -> String? { lock.withLock { token } }
    func objectSummaries(scope: SchemaScope) async throws -> [SchemaObjectSummary] { lock.withLock { summaries } }
    func foreignKeys(scope: SchemaScope) async throws -> [ForeignKeyRelation] { lock.withLock { relations } }
    func tableDetails(_ refs: [TableRef]) async throws -> [TableDetail] {
        lock.withLock {
            detailReads.append(refs.count)
            return refs.compactMap { details[$0] }
        }
    }
    var bulkIntrospection: Bool { true }
}

/// A temporary store with one saved profile, harvested from a synthetic
/// catalog by a coordinator.
private struct HarvestBench {
    let scratch: ScratchDirectory
    let store: BerryStore
    let profile = ConnectionProfile(driverID: "postgres", name: "Scale", host: "127.0.0.1", username: "bench")
    let introspector = ScriptedIntrospector()
    let coordinator: HarvestCoordinator
    var catalog: SyntheticCatalog
    private var version = 0

    init(tables: Int) throws {
        scratch = try ScratchDirectory()
        store = try BerryStore(path: scratch.storePath)
        try store.save(profile)
        catalog = SyntheticCatalog(tables: tables)
        let introspector = introspector
        coordinator = HarvestCoordinator(store: store, introspector: { _ in introspector })
        publish()
    }

    var path: String { scratch.storePath }

    /// Serves the catalog as it is now under a new version token, so the
    /// next pass lists it again.
    mutating func publish() {
        version += 1
        introspector.serve(catalog, token: "v\(version)")
    }

    func pass() async -> HarvestOutcome {
        await coordinator.request(.userAction, for: profile.id)
    }

    func remove() {
        scratch.remove()
    }
}

@Suite("Schema graph scale", .serialized, .enabled(if: benchEnabled))
struct SchemaGraphScaleTests {
    // MARK: - Harvest passes

    @Test func harvestPassesStayWithinBudget() async throws {
        // Each first pass needs an empty store, so every sample but the last
        // harvests a store of its own and removes it; the last one is kept
        // for the size check and the passes that follow.
        var firstTimes: [Duration] = []
        for _ in 1..<Samples.count {
            let bench = try HarvestBench(tables: tableCount)
            defer { bench.remove() }
            let (first, firstTime) = await measure { await bench.pass() }
            guard case let .updated(_, added, _, _, completed) = first, added == tableCount, completed == tableCount else {
                Issue.record("first pass: \(first)")
                return
            }
            firstTimes.append(firstTime)
        }
        var bench = try HarvestBench(tables: tableCount)
        defer { bench.remove() }
        let (first, firstTime) = await measure { await bench.pass() }
        guard case let .updated(_, added, _, _, completed) = first, added == tableCount, completed == tableCount else {
            Issue.record("first pass: \(first)")
            return
        }
        let firstPasses = Samples(durations: (firstTimes + [firstTime]).sorted())
        let firstSize = StoreSize(path: bench.path)
        report("\(scale) first pass: \(firstPasses.summary), store \(firstSize.summary)")
        #expect(firstPasses.median < Budget.firstPass, "first pass took \(firstPasses.summary)")
        // Definitions are stored compressed: as text, a 20-column definition
        // of 2.0 KB filled a 4 KB page on its own, and 20,000 tables took
        // 89 MB.
        #expect(firstSize.total < Budget.storeBytes, "store after the first pass: \(firstSize.summary)")

        // Each sample changes another table, so every pass has exactly one
        // change to find.
        var revised = tableCount / 2
        var readsBefore = 0
        var outcomes: [HarvestOutcome] = []
        var reads: [[Int]] = []
        let (_, passes) = await sample(reset: {
            bench.catalog.revise(revised)
            bench.publish()
            revised += 1
            readsBefore = bench.introspector.detailReadSizes.count
        }) {
            outcomes.append(await bench.pass())
            reads.append(Array(bench.introspector.detailReadSizes.dropFirst(readsBefore)))
        }
        report("\(scale) pass with one table changed: \(passes.summary), detail reads \(reads)")
        for outcome in outcomes {
            guard case .updated(_, 0, 1, 0, 0) = outcome else {
                Issue.record("pass with one table changed: \(outcome)")
                return
            }
        }
        #expect(reads.allSatisfy { $0 == [1] }, "a pass after one change must read one definition")
        #expect(passes.median < Budget.oneTableChangedPass, "pass with one table changed took \(passes.summary)")
    }

    // MARK: - Metadata reads

    /// Reads the store as the MCP helper does: a read-only open of the file
    /// the app writes, served by `MCPMetadataService(store:)`. Each call is
    /// timed `Samples.count` times. A call the helper can make first, before
    /// anything is cached, starts each sample cold: its reader connections
    /// closed and reopened by `releaseMemory()`, or its table graph dropped.
    @Test func metadataReadsStayWithinBudget() async throws {
        var bench = try HarvestBench(tables: tableCount)
        defer { bench.remove() }
        let first = await bench.pass()
        guard case .updated = first else {
            Issue.record("first pass: \(first)")
            return
        }
        bench.catalog.reviseAll()
        bench.publish()
        let everyTable = await bench.pass()
        guard case let .updated(everyTableChange?, 0, tableCount, 0, 0) = everyTable else {
            Issue.record("pass with every table changed: \(everyTable)")
            return
        }
        let revised = tableCount / 2
        bench.catalog.revise(revised)
        bench.publish()
        let second = await bench.pass()
        guard case let .updated(changeID?, _, 1, _, _) = second else {
            Issue.record("pass with one table changed: \(second)")
            return
        }

        // Statistics as a refresh on PostgreSQL leaves them: counters for
        // every table, whose primary key was scanned and whose secondary
        // index never was, so every table has one unused index.
        try bench.store.replaceSchemaStats(profileID: bench.profile.id, rows: bench.catalog.tables.map { table in
            let name = SyntheticCatalog.name(table.id)
            return SchemaStatsRecord(
                profileID: bench.profile.id, database: SyntheticCatalog.schema, name: name, rows: 1_000, sizeBytes: 65_536,
                seqScan: 3, idxScan: 40, indexStats: #"{"\#(name)_col_1_idx":{"idxScan":0},"\#(name)_pkey":{"idxScan":40}}"#,
                updatedAt: Date()
            )
        })

        // Hands back the memory the harvest freed, which the allocator keeps
        // cached and the footprint counts: `malloc_zone_pressure_relief`
        // unmaps it, as its declaration in <malloc/malloc.h> describes. The
        // baseline then holds only what is live, and the reads below cannot
        // reuse those pages without them counting.
        _ = malloc_zone_pressure_relief(nil, 0)
        let baseline = try #require(footprintBytes())

        let helperStore = try BerryStore.openReadOnly(path: bench.path)
        let service = MCPMetadataService(store: helperStore)
        let project = MCPVerifiedProject(
            project: MCPProject(name: "Scale", isEnabled: true, profiles: [MCPProfileAccess(profileID: bench.profile.id)]),
            liveReadProfileIDs: []
        )
        let connection = bench.profile.id
        let table = SyntheticCatalog.name(revised)
        let label = "\(scale) mcp"

        let (connections, listTimes) = try await sample(reset: helperStore.releaseMemory) {
            try service.listConnections(in: project)
        }
        report("\(label) listConnections: \(listTimes.summary)")
        #expect(connections.first?.detailCoverage.total == tableCount)
        #expect(listTimes.median < Budget.pointRead, "listConnections took \(listTimes.summary)")

        let (named, namedTimes) = try await sample {
            try service.schema(in: project, connectionID: connection, objectNames: [table], detail: .full)
        }
        report("\(label) schema by name: \(namedTimes.summary)")
        #expect(named.objects.map(\.name) == [table])
        #expect(namedTimes.median < Budget.pointRead, "schema by name took \(namedTimes.summary)")

        // A name that matches nothing, the common case when an agent guesses
        // one: the exact lookup misses, and the case-folded lookup after it
        // seeks the folded-name index rather than reading every current name.
        let (missed, missedTimes) = try await sample {
            try service.schema(in: project, connectionID: connection, objectNames: ["No_Such_Table"], detail: .full)
        }
        report("\(label) schema by a name that matches nothing: \(missedTimes.summary)")
        #expect(missed.objects.isEmpty)
        #expect(missedTimes.median < Budget.pointRead, "schema by a name that matches nothing took \(missedTimes.summary)")

        // The first page and the last: a page is read by offset, so the last
        // one is where skipping the rows before it costs the most. The first
        // page is what a helper reads first, so it starts cold.
        for offset in [0, max(0, tableCount - 200)] {
            let (page, pageTimes) = try await sample(reset: { if offset == 0 { helperStore.releaseMemory() } }) {
                try service.schema(in: project, connectionID: connection, objectNames: nil, detail: .full, offset: offset)
            }
            report("\(label) schema page at offset \(offset): \(page.objects.count) objects in \(pageTimes.summary)")
            #expect(!page.objects.isEmpty)
            #expect(pageTimes.median < Budget.pageRead, "schema page at offset \(offset) took \(pageTimes.summary)")
        }

        // A needle every table has a column for fills the limit early, from
        // the first definitions read; one that every index name holds and no
        // table or column name does, as `pkey` is on PostgreSQL, walks the
        // folded names and the column names of every current row before its
        // index matches fill the limit; one that matches nothing reads the
        // folded names of every current row from the search indexes.
        for needle in ["status", "pkey", "no_such_name"] {
            let (matches, searchTimes) = try await sample {
                try service.searchSchema(in: project, connectionID: connection, query: needle, limit: 200)
            }
            report("\(label) searchSchema '\(needle)': \(matches.value.count) matches in \(searchTimes.summary)")
            #expect(searchTimes.median < Budget.pageRead, "searchSchema '\(needle)' took \(searchTimes.summary)")
        }

        // From the beginning: the first page of the first pass's change, which
        // has an entry for each of the tables and foreign keys. A page is read
        // from the change indexes in its own order and stops at its size.
        let (history, historyTimes) = try await sample {
            try service.schemaChanges(in: project, connectionID: connection, since: nil, limit: 200)
        }
        report("\(label) schemaChanges from the start: \(history.changes.count) entries in \(historyTimes.summary)")
        #expect(history.changes.count == 200)
        #expect(historyTimes.median < Budget.pageRead, "schemaChanges from the start took \(historyTimes.summary)")

        // A pass that changed every table records one changed entry per
        // table, each with a diff, under one change, and closes a version of
        // every table that the listing must not read as a removal. The page
        // from the middle starts from a cursor that earlier pages returned.
        var middle: String? = "id:\(everyTableChange)"
        var skipped = 0
        while skipped < tableCount / 2, let cursor = middle {
            let page = try service.schemaChanges(in: project, connectionID: connection, since: cursor, limit: 200)
            skipped += page.changes.count
            middle = page.nextSince
        }
        for (place, since) in [("start", "id:\(everyTableChange)"), ("middle", middle)] {
            let (changed, changedTimes) = try await sample {
                try service.schemaChanges(in: project, connectionID: connection, since: since, limit: 200)
            }
            report("\(label) schemaChanges of a change to every table, from its \(place): \(changed.changes.count) entries in \(changedTimes.summary)")
            #expect(changed.changes.count == 200 && changed.changes.allSatisfy { $0.kind == .changed && $0.diff != nil })
            // The page decodes 400 definitions and diffs 200 pairs: 20 ms in a
            // release build. A debug build runs the diffs unspecialized and
            // misses the budget by 1 to 3 ms; once it stops missing, the
            // known issue fails the run so it can be removed.
            withKnownIssue(
                "a page of a change to every table: 31.0 to 33.0 ms in debug at 1,000 and 20,000 tables, 19.9 to 20.8 ms in release"
            ) {
                #expect(changedTimes.median < Budget.pageRead, "the change to every table from its \(place) took \(changedTimes.summary)")
            } when: {
                buildMode == "debug"
            }
        }

        let (latest, latestTimes) = try await sample {
            try service.schemaChanges(in: project, connectionID: connection, since: "id:\(changeID)", limit: 200)
        }
        report("\(label) schemaChanges since the last change: \(latest.changes.count) entries in \(latestTimes.summary)")
        #expect(latest.changes.map(\.name) == [table])
        #expect(latestTimes.median < Budget.pageRead, "schemaChanges since the last change took \(latestTimes.summary)")

        // The first call builds the table graph, so each of its samples drops
        // the cached one first; the second call, with the schema unchanged,
        // reuses the graph the last first call built. Table n/4 references
        // table n/8 and is referenced by n/2 and n/2 + 1.
        let hub = SyntheticCatalog.name(tableCount / 4)
        let (built, buildTimes) = try await sample(reset: service.dropCachedGraphs) {
            try service.graphQuery(in: project, connectionID: connection, operation: .neighbors(node: hub))
        }
        let (cached, cachedTimes) = try await sample {
            try service.graphQuery(in: project, connectionID: connection, operation: .neighbors(node: hub))
        }
        report("\(label) graphQuery neighbors: first \(buildTimes.summary); second \(cachedTimes.summary)")
        #expect(built == cached)
        if case let .neighbors(found) = built.value {
            #expect(found.dependsOn.count == 1 && found.dependedOnBy.count == 2)
        } else {
            Issue.record("neighbors answered \(built.value)")
        }
        // Building the table graph reads every current name and foreign-key
        // end and assembles a node and an edge for each: about 31 ms in a
        // release build at 20,000 tables, and 89 to 92 ms in a debug build,
        // which has no specialized generics, so this gate has the least
        // margin of any in a debug run.
        #expect(buildTimes.median < Budget.graphBuild, "first neighbors call took \(buildTimes.summary)")
        #expect(cachedTimes.median < Budget.cachedGraph, "second neighbors call took \(cachedTimes.summary)")

        // The statistics summary takes its tables from the table graph the
        // neighbors calls left cached, keeps the first 500 by name, and reads
        // and decodes the statistics of those alone.
        let (summary, summaryTimes) = try await sample {
            try service.graphStats(in: project, connectionID: connection, object: nil)
        }
        guard case let .summary(statistics) = summary.value else {
            Issue.record("graphStats answered \(summary.value)")
            return
        }
        report("\(label) graphStats summary: \(statistics.tables.count) tables in \(summaryTimes.summary)")
        #expect(statistics.tables.count == min(500, tableCount) && statistics.unusedIndexes.count == min(500, tableCount))
        #expect(summaryTimes.median < Budget.pageRead, "graphStats summary took \(summaryTimes.summary)")

        let after = try #require(footprintBytes())
        let grown = after > baseline ? after - baseline : 0
        report("\(label) memory: baseline \(megabytes(baseline)), after the calls \(megabytes(after)), grown \(megabytes(grown))")
        #expect(grown < Budget.helperMemoryBytes, "the metadata reads kept \(megabytes(grown))")
    }

    // MARK: - Store size under churn

    @Test func storeStaysSmallThroughTenRoundsOfChurn() async throws {
        var bench = try HarvestBench(tables: tableCount)
        defer { bench.remove() }
        let first = await bench.pass()
        guard case .updated = first else {
            Issue.record("first pass: \(first)")
            return
        }

        let step = max(1, tableCount / 100)
        var slowest = Duration.zero
        for round in 1...10 {
            bench.catalog.churn(step)
            bench.publish()
            let (outcome, elapsed) = await measure { await bench.pass() }
            guard case let .updated(_, added, _, removed, _) = outcome, added == step, removed == step else {
                Issue.record("churn round \(round): \(outcome)")
                return
            }
            slowest = max(slowest, elapsed)
        }
        let size = StoreSize(path: bench.path)
        report("\(scale) after 10 rounds of \(step) tables added and dropped: store \(size.summary), slowest pass \(milliseconds(slowest))")
        // Held to the one-table refresh budget as a guard against work that
        // grows with the removals times the tables kept: while each removal
        // looked its name up across every current row, a round at 20,000
        // tables took 5 to 14 seconds.
        #expect(slowest < Budget.oneTableChangedPass, "the slowest churn pass took \(milliseconds(slowest))")
        // The rows of the first pass plus the closed versions history keeps
        // of every dropped table.
        #expect(size.total < Budget.storeBytes, "store after churn: \(size.summary)")
    }

    // MARK: - Upgrade from the per-node graph

    /// Writes the per-node graph the store held before per-table versions,
    /// for the synthetic catalog, and times the migration that converts it.
    /// The graph is written once; each sample converts a copy of that file.
    @Test func perNodeGraphConvertsWithinBudget() async throws {
        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        // Opened the way `BerryStore(path:)` opens the file, because an
        // earlier migration creates a table of the vector extension.
        var configuration = Configuration()
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        do {
            let seeded = try DatabaseQueue(path: scratch.storePath, configuration: configuration)
            try BerryStore.migrator.migrate(seeded, upTo: "v30-mcp-project")
            try seedPerNodeGraph(seeded, profile: UUID(), catalog: SyntheticCatalog(tables: tableCount))
        }

        // A converted copy is closed and deleted before the next one is made,
        // so the samples never hold more than one converted store on disk.
        let copy = scratch.url.appendingPathComponent("converted.sqlite").path
        var queue: DatabaseQueue?
        let (_, conversions) = try await sample(reset: {
            queue = nil
            for file in [copy, copy + "-wal", copy + "-shm"] { try? FileManager.default.removeItem(atPath: file) }
            try FileManager.default.copyItem(atPath: scratch.storePath, toPath: copy)
            queue = try DatabaseQueue(path: copy, configuration: configuration)
            try queue?.inDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
        }) {
            try queue.map { try BerryStore.migrator.migrate($0, upTo: "v34-schema-object-versions") }
        }
        let converted = try #require(queue)
        let (_, remainingTime) = try await measure { try BerryStore.migrator.migrate(converted) }
        // Awaited and returning plain integers: in an async function the
        // Swift 6.1 toolchain picks GRDB's async `read`, whose result must be
        // `Sendable`.
        let counts: (objects: Int, detailed: Int, relations: Int)? = try await converted.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM schema_object WHERE removedAt IS NULL) AS objects,
                       (SELECT COUNT(definition) FROM schema_object WHERE removedAt IS NULL) AS detailed,
                       (SELECT COUNT(*) FROM schema_relation WHERE removedAt IS NULL) AS relations
                """) else { return nil }
            return (row["objects"], row["detailed"], row["relations"])
        }
        report("\(scale) per-node graph conversion: \(conversions.summary), later migrations \(milliseconds(remainingTime))")
        let (objects, detailed, relations) = try #require(counts)
        #expect(objects == tableCount && detailed == tableCount && relations == tableCount - 1)
        #expect(conversions.median < Budget.conversion, "conversion took \(conversions.summary)")
    }

    /// One table node with a node per column and index, joined by
    /// `hasColumn`, `hasIndex` and `references` edges, every one seen in all
    /// three harvests, as the per-node harvester recorded them.
    private func seedPerNodeGraph(_ queue: DatabaseQueue, profile: UUID, catalog: SyntheticCatalog) throws {
        let harvests = [1_000.0, 2_000.0, 3_000.0].map(Date.init(timeIntervalSince1970:))
        let firstSeen = harvests[0]
        let lastSeen = harvests[2]
        func json(_ attributes: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: attributes, options: .sortedKeys), as: UTF8.self)
        }
        try queue.write { db in
            // The upgrade copies only the graphs of saved profiles.
            try db.execute(
                sql: "INSERT INTO connection_profile (id, driverID, name, createdAt) VALUES (?, 'postgres', 'Scale', ?)",
                arguments: [profile, firstSeen]
            )
            let node = try db.cachedStatement(sql: """
                INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let edge = try db.cachedStatement(sql: """
                INSERT INTO graph_edge (profileID, src, dst, kind, weight, attrs, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                """)
            let schema = SyntheticCatalog.schema
            var nodes = 0
            var edges = 0
            for table in catalog.tables {
                let detail = SyntheticCatalog.detail(table)
                let name = detail.ref.name
                let tableID = "table:\(schema).\(name)"
                try node.execute(arguments: [profile, tableID, "table", name, schema, "{}", firstSeen, lastSeen])
                for column in detail.columns {
                    let columnID = "column:\(schema).\(name).\(column.name)"
                    let attributes = try json([
                        "type": column.declaredType, "nullable": String(column.isNullable), "primaryKey": String(column.isPrimaryKey),
                    ])
                    try node.execute(arguments: [profile, columnID, "column", column.name, schema, attributes, firstSeen, lastSeen])
                    try edge.execute(arguments: [profile, tableID, columnID, "hasColumn", "{}", firstSeen, lastSeen])
                }
                for index in detail.indexes {
                    let indexID = "index:\(schema).\(name).\(index.name)"
                    let attributes = try json(["unique": String(index.isUnique), "columns": index.columns.joined(separator: ",")])
                    try node.execute(arguments: [profile, indexID, "index", index.name, schema, attributes, firstSeen, lastSeen])
                    try edge.execute(arguments: [profile, tableID, indexID, "hasIndex", "{}", firstSeen, lastSeen])
                }
                for key in detail.foreignKeys {
                    let attributes = try json(["column": key.column, "referencedColumn": key.referencedColumn])
                    try edge.execute(arguments: [
                        profile, tableID, "table:\(schema).\(key.referencedTable)", "references", attributes, firstSeen, lastSeen,
                    ])
                }
                nodes += 1 + detail.columns.count + detail.indexes.count
                edges += detail.columns.count + detail.indexes.count + detail.foreignKeys.count
            }
            for (index, takenAt) in harvests.enumerated() {
                try db.execute(
                    sql: "INSERT INTO graph_snapshot (id, profileID, takenAt, nodeCount, edgeCount, digest) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [UUID(), profile, takenAt, nodes, edges, "digest-\(index)"]
                )
            }
        }
    }

    // MARK: - Real Postgres catalog

    /// Times each catalog read a pass makes, and a whole pass, against
    /// `BENCH_PG_TABLES` generated tables on the server `BERRYDB_TEST_POSTGRES`
    /// names. The tables live in their own schema, dropped before and after.
    @Test(.enabled(if: TestServer.postgres != nil))
    func postgresCatalogAtScale() async throws {
        DriverRegistry.register(PostgresDriver.self)
        let server = try #require(TestServer.postgres)
        let manager = ConnectionManager()
        let session = try await manager.open(ConnectionConfig(
            driver: .postgres, name: "bench-scale", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
        let connection = session.connection

        // Creating the tables runs inside the block whose cleanup drops them,
        // so a create that fails partway still drops what it made, and the
        // session closes only once the drop has finished.
        let measured: Result<Void, any Error>
        do {
            try await PostgresScaleSchema.drop(on: connection)
            let (_, createTime) = try await measure { try await PostgresScaleSchema.create(tables: postgresTableCount, on: connection) }
            report("postgres n=\(postgresTableCount) \(buildMode) generating the tables: \(milliseconds(createTime))")
            try await measurePostgresCatalog(connection.introspector)
            measured = .success(())
        } catch {
            measured = .failure(error)
        }
        let dropped: Result<Void, any Error>
        do {
            try await PostgresScaleSchema.drop(on: connection)
            dropped = .success(())
        } catch {
            dropped = .failure(error)
        }
        await manager.close(session.id)
        // A failed drop is recorded even when the measurement failed first,
        // since it leaves tables on the server.
        if case let .failure(error) = dropped {
            Issue.record(error, "dropping the generated schema")
        }
        try measured.get()
    }

    private func measurePostgresCatalog(_ introspector: any Introspector) async throws {
        let label = "postgres n=\(postgresTableCount) \(buildMode)"
        let scope = SchemaScope.schemas([PostgresScaleSchema.name])

        let (token, tokenTime) = try await measure { try await introspector.schemaVersionToken(scope: scope) }
        report("\(label) schemaVersionToken: \(milliseconds(tokenTime)) (\(token == nil ? "no token" : "token"))")

        let (summaries, listTime) = try await measure { try await introspector.objectSummaries(scope: scope) }
        report("\(label) objectSummaries: \(summaries.count) objects in \(milliseconds(listTime))")
        #expect(summaries.count == postgresTableCount)

        let (keys, keysTime) = try await measure { try await introspector.foreignKeys(scope: scope) }
        report("\(label) foreignKeys: \(keys.count) keys in \(milliseconds(keysTime))")
        #expect(keys.count == postgresTableCount - 1)

        // The coordinator reads definitions 500 tables at a time.
        let chunk = summaries.prefix(500).map(\.ref)
        let (details, detailTime) = try await measure { try await introspector.tableDetails(chunk) }
        report("\(label) tableDetails chunk: \(details.count) tables in \(milliseconds(detailTime))")
        #expect(details.count == chunk.count)

        let scratch = try ScratchDirectory()
        defer { scratch.remove() }
        let store = try BerryStore(path: scratch.storePath)
        let profileID = UUID()
        try store.updateSchemaGraphState(profileID: profileID) { $0.selectedSchemas = #"["\#(PostgresScaleSchema.name)"]"# }
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in introspector })
        let (outcome, passTime) = await measure { await coordinator.request(.userAction, for: profileID) }
        report("\(label) coordinator pass: \(milliseconds(passTime)), \(outcome)")
        guard case let .updated(_, added, _, _, completed) = outcome else {
            Issue.record("postgres pass: \(outcome)")
            return
        }
        #expect(added == postgresTableCount && completed == postgresTableCount)
    }
}

/// The generated schema of the Postgres measurement. Tables are created and
/// dropped 200 per statement: PostgreSQL holds a lock on every relation a
/// transaction creates or drops until it commits, in a shared lock table
/// sized by `max_locks_per_transaction`
/// (https://www.postgresql.org/docs/current/runtime-config-locks.html).
/// Verified against postgres:16 with default settings: one statement
/// creating these tables failed with "out of shared memory" at the 2,146th,
/// and dropping a schema of 2,000 of them in one statement failed the same
/// way.
private enum PostgresScaleSchema {
    static let name = "bd_scale"
    private static let batch = 200

    /// `id`, a `parent_id` referencing table `i / 2`, and 18 more columns:
    /// 20 columns, the primary key and one secondary index, as the
    /// synthetic catalog has.
    static func create(tables count: Int, on connection: any DriverConnection) async throws {
        try await execute("CREATE SCHEMA \(name)", on: connection)
        let types = ["character varying(255)", "timestamp without time zone", "integer"]
        let columns = (1...18).map { "c\($0) \(types[$0 % types.count])" }.joined(separator: ", ")
        for start in stride(from: 0, to: count, by: batch) {
            let end = min(start + batch, count) - 1
            try await execute("""
                DO $$
                BEGIN
                    FOR i IN \(start)..\(end) LOOP
                        EXECUTE format(
                            'CREATE TABLE \(name).\(name)_%s (id bigint PRIMARY KEY, parent_id bigint%s, \(columns))',
                            i, CASE WHEN i > 0 THEN format(' REFERENCES \(name).\(name)_%s (id)', i / 2) ELSE '' END
                        );
                        EXECUTE format('CREATE INDEX \(name)_%s_c1_idx ON \(name).\(name)_%s (c1)', i, i);
                    END LOOP;
                END
                $$
                """, on: connection)
        }
    }

    /// Drops the newest tables first, so a batch rarely reaches a table that
    /// another batch still references.
    static func drop(on connection: any DriverConnection) async throws {
        while try await remainingTables(on: connection) > 0 {
            try await execute("""
                DO $$
                DECLARE t record;
                BEGIN
                    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = '\(name)'
                             ORDER BY length(tablename) DESC, tablename DESC LIMIT \(batch) LOOP
                        EXECUTE format('DROP TABLE \(name).%I CASCADE', t.tablename);
                    END LOOP;
                END
                $$
                """, on: connection)
        }
        try await execute("DROP SCHEMA IF EXISTS \(name) CASCADE", on: connection)
    }

    private static func remainingTables(on connection: any DriverConnection) async throws -> Int64 {
        var count: Int64 = 0
        for try await event in connection.execute("SELECT count(*) FROM pg_tables WHERE schemaname = '\(name)'") {
            if case let .rows(rows) = event, case let .int(value)? = rows.first?.first { count = value }
        }
        return count
    }

    private static func execute(_ sql: String, on connection: any DriverConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }
}
