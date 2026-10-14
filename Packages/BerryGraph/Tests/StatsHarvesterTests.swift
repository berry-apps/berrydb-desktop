import BerryCore
import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

/// A connection that answers a statement with canned rows, chosen by a text
/// the statement contains, and records every statement it was given.
actor ScriptedConnection: DriverConnection, CatalogReadScoping {
    struct Answer: Sendable {
        let match: String
        let columns: [String]
        let rows: [[BerryValue]]
    }

    nonisolated let id = UUID()
    private let answers: [Answer]
    private let failing: Set<String>
    private let gate: Gate?
    private let gatedText: String?
    private var statements: [String] = []
    private let scopesReads: Bool
    private var opened: [CatalogReadScope] = []
    private(set) var ended: [Bool] = []
    private var readScopes: [CatalogReadScope?] = []

    /// `failing` names statement texts that fail, as a catalog view the user
    /// may not read does. `gate` holds a statement, only those containing
    /// `gatedText` when it is given, until the test opens it.
    init(
        answers: [Answer], failing: Set<String> = [], gate: Gate? = nil, gatedText: String? = nil, scopesReads: Bool = false
    ) {
        self.answers = answers
        self.failing = failing
        self.gate = gate
        self.gatedText = gatedText
        self.scopesReads = scopesReads
    }

    var openedScopes: [CatalogReadScope] { opened }
    /// The scope each statement was run in.
    var scopesRead: [CatalogReadScope?] { readScopes }

    func beginCatalogReads() async throws -> CatalogReadScope? {
        guard scopesReads else { return nil }
        let scope = CatalogReadScope()
        opened.append(scope)
        return scope
    }

    func endCatalogReads(_ scope: CatalogReadScope, commit: Bool) async {
        ended.append(commit)
    }

    var executed: [String] { statements }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                await self.record(sql, scope: CatalogReadScope.current)
                if let gate = self.gate, self.gatedText.map({ sql.contains($0) }) ?? true { await gate.wait() }
                if self.failing.contains(where: { sql.contains($0) }) {
                    continuation.finish(throwing: DriverError.queryFailed(message: "permission denied", code: nil))
                    return
                }
                if let answer = self.answers.first(where: { sql.contains($0.match) }) {
                    continuation.yield(.columns(answer.columns.map { ColumnMeta(name: $0, declaredType: "") }))
                    continuation.yield(.rows(answer.rows))
                }
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func record(_ sql: String, scope: CatalogReadScope?) {
        statements.append(sql)
        readScopes.append(scope)
    }

    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("statistics never introspect") }
    func ping() async -> Bool { true }
    func close() async {}
}

private func text(_ values: String...) -> [BerryValue] { values.map { .text($0) } }

private let postgresTables = ScriptedConnection.Answer(
    match: "pg_stat_user_tables",
    columns: ["schemaname", "relname", "n_live_tup", "seq_scan", "idx_scan", "size_bytes"],
    rows: [
        [.text("shop"), .text("orders"), .int(100), .int(7), .int(40), .int(16_384)],
        [.text("archive"), .text("orders"), .int(5), .int(1), .int(0), .int(8_192)],
    ]
)

private let postgresIndexes = ScriptedConnection.Answer(
    match: "pg_stat_user_indexes",
    columns: ["schemaname", "relname", "indexrelname", "idx_scan"],
    rows: [
        [.text("shop"), .text("orders"), .text("orders_pkey"), .int(40)],
        [.text("archive"), .text("orders"), .text("orders_pkey"), .int(0)],
    ]
)

@Suite("Statistics mapping")
struct StatsHarvesterTests {
    let profile = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ records: [SchemaStatsRecord], _ database: String, _ name: String) -> SchemaStatsRecord? {
        records.first { $0.database == database && $0.name == name }
    }

    /// The same table name in two schemas is two tables; a merge by bare name
    /// would give both the numbers of whichever row came first.
    @Test func twoTablesOfOneNameInTwoSchemasKeepTheirOwnNumbers() {
        let records = StatsHarvester.postgresRows(
            tables: [
                ["schemaname": "shop", "relname": "orders", "n_live_tup": "100", "seq_scan": "7", "idx_scan": "40", "size_bytes": "16384"],
                ["schemaname": "archive", "relname": "orders", "n_live_tup": "5", "seq_scan": "1", "idx_scan": "0", "size_bytes": "8192"],
            ],
            indexes: [], profileID: profile, now: now
        )
        #expect(records.count == 2)
        let shop = record(records, "shop", "orders")
        let archive = record(records, "archive", "orders")
        #expect(shop?.rows == 100 && shop?.seqScan == 7 && shop?.idxScan == 40 && shop?.sizeBytes == 16_384)
        #expect(archive?.rows == 5 && archive?.seqScan == 1 && archive?.idxScan == 0 && archive?.sizeBytes == 8_192)
        #expect(records.allSatisfy { $0.profileID == profile && $0.updatedAt == now })
    }

    @Test func indexRowsFoldIntoTheirOwnTableOnly() {
        let records = StatsHarvester.postgresRows(
            tables: [
                ["schemaname": "shop", "relname": "orders", "n_live_tup": "1"],
                ["schemaname": "archive", "relname": "orders", "n_live_tup": "1"],
                ["schemaname": "shop", "relname": "customers", "n_live_tup": "1"],
            ],
            indexes: [
                ["schemaname": "shop", "relname": "orders", "indexrelname": "orders_pkey", "idx_scan": "5"],
                ["schemaname": "shop", "relname": "orders", "indexrelname": "orders_customer_idx", "idx_scan": "0"],
                ["schemaname": "archive", "relname": "orders", "indexrelname": "orders_pkey", "idx_scan": "9"],
                ["schemaname": "elsewhere", "relname": "orders", "indexrelname": "stray_idx", "idx_scan": "1"],
            ],
            profileID: profile, now: now
        )
        // Keys are sorted so the stored text does not change between passes
        // that report the same numbers.
        #expect(record(records, "shop", "orders")?.indexStats
            == #"{"orders_customer_idx":{"idxScan":0},"orders_pkey":{"idxScan":5}}"#)
        #expect(record(records, "archive", "orders")?.indexStats == #"{"orders_pkey":{"idxScan":9}}"#)
        #expect(record(records, "shop", "customers")?.indexStats == nil)
        #expect(records.count == 3)
    }

    @Test func aRowWithoutAnIdentityIsSkippedAndAnUnreadNumberStaysEmpty() {
        let records = StatsHarvester.postgresRows(
            tables: [
                ["relname": "no_schema", "n_live_tup": "1"],
                ["schemaname": "shop", "n_live_tup": "1"],
                ["schemaname": "shop", "relname": "orders", "n_live_tup": "many", "size_bytes": "4096"],
            ],
            indexes: [], profileID: profile, now: now
        )
        #expect(records.count == 1)
        #expect(records.first?.rows == nil && records.first?.sizeBytes == 4_096)
        #expect(records.first?.seqScan == nil && records.first?.idxScan == nil)
    }

    @Test func mysqlRowsAreKeyedBySchemaAndCarryOnlyRowsAndSize() {
        let records = StatsHarvester.mysqlRows(
            tables: [
                ["table_schema": "shop", "table_name": "orders", "n_rows": "100", "size_bytes": "49152"],
                ["table_schema": "archive", "table_name": "orders", "n_rows": "5", "size_bytes": "16384"],
                ["table_name": "orphan", "n_rows": "1"],
            ],
            profileID: profile, now: now
        )
        #expect(records.count == 2)
        let shop = record(records, "shop", "orders")
        let archive = record(records, "archive", "orders")
        #expect(shop?.rows == 100 && shop?.sizeBytes == 49_152)
        #expect(archive?.rows == 5 && archive?.sizeBytes == 16_384)
        #expect(records.allSatisfy { $0.seqScan == nil && $0.idxScan == nil && $0.indexStats == nil && $0.updatedAt == now })
    }

    @Test func postgresScopeFiltersOnTheSchemaName() {
        #expect(StatsHarvester.postgresScope(.allUserSchemas) == """
            schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
            AND schemaname NOT LIKE 'pg!_temp!_%' ESCAPE '!' \
            AND schemaname NOT LIKE 'pg!_toast!_temp!_%' ESCAPE '!'
            """)
        #expect(StatsHarvester.postgresScope(.schemas(["shop", "a'b"])) == "schemaname IN ('shop', 'a''b')")
        #expect(StatsHarvester.postgresScope(.schemas(["back\\slash"])) == #"schemaname IN ('back\slash')"#)
        #expect(StatsHarvester.postgresScope(.schemas([])) == "FALSE")
    }

    @Test func mysqlScopeFiltersOnTheSchemaNameAndEscapesBackslashes() {
        #expect(StatsHarvester.mysqlScope(.allUserSchemas, currentDatabase: nil)
            == "TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')")
        #expect(StatsHarvester.mysqlScope(.allUserSchemas, currentDatabase: "it's") == "TABLE_SCHEMA = 'it''s'")
        #expect(StatsHarvester.mysqlScope(.schemas(["shop", "a'b"]), currentDatabase: "shop") == "TABLE_SCHEMA IN ('shop', 'a''b')")
        #expect(StatsHarvester.mysqlScope(.schemas(["back\\slash"]), currentDatabase: nil) == #"TABLE_SCHEMA IN ('back\\slash')"#)
        #expect(StatsHarvester.mysqlScope(.schemas([]), currentDatabase: nil) == "FALSE")
    }
}

@Suite("Statistics harvest over a connection")
struct StatsHarvesterConnectionTests {
    let profile = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func postgresRunsBothViewsScopedAndMapsTheRows() async {
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let records = await StatsHarvester.harvest(
            profileID: profile, connection: connection, driver: .postgres, scope: .schemas(["shop", "archive"]), now: now
        )
        let statements = await connection.executed
        #expect(statements.count == 2)
        #expect(statements.allSatisfy { $0.contains("schemaname IN ('shop', 'archive')") })
        #expect(statements.first?.contains("pg_total_relation_size(relid) AS size_bytes") == true)
        #expect(records.count == 2)
        let shop = records.first { $0.database == "shop" }
        let archive = records.first { $0.database == "archive" }
        #expect(shop?.rows == 100 && shop?.indexStats == #"{"orders_pkey":{"idxScan":40}}"#)
        #expect(archive?.rows == 5 && archive?.indexStats == #"{"orders_pkey":{"idxScan":0}}"#)
    }

    @Test func mysqlScopesTheTablesViewToTheListedSchemas() async {
        let connection = ScriptedConnection(answers: [ScriptedConnection.Answer(
            match: "information_schema.TABLES",
            columns: ["table_schema", "table_name", "n_rows", "size_bytes"],
            rows: [[.text("shop"), .text("orders"), .int(12), .int(4_096)]]
        )])
        let records = await StatsHarvester.harvest(
            profileID: profile, connection: connection, driver: .mysql, scope: .schemas(["shop"]), now: now
        )
        let statements = await connection.executed
        #expect(statements.count == 1)
        #expect(statements.first?.contains("TABLE_SCHEMA IN ('shop')") == true)
        #expect(statements.first?.contains("DATABASE()") == false)
        #expect(records.map(\.name) == ["orders"] && records.first?.database == "shop" && records.first?.rows == 12)
    }

    /// The default scope on MySQL is the connection's database when it has
    /// one, as the catalog listing's is, and every user database otherwise.
    @Test func mysqlReadsTheDefaultScopeFromTheConnectionsDatabase() async {
        let tables = ScriptedConnection.Answer(
            match: "information_schema.TABLES",
            columns: ["table_schema", "table_name", "n_rows", "size_bytes"],
            rows: [[.text("shop"), .text("orders"), .int(12), .int(4_096)]]
        )
        let withDatabase = ScriptedConnection(answers: [
            ScriptedConnection.Answer(match: "SELECT DATABASE()", columns: ["current_database"], rows: [[.text("shop")]]), tables,
        ])
        _ = await StatsHarvester.harvest(
            profileID: profile, connection: withDatabase, driver: .mysql, scope: .allUserSchemas, now: now
        )
        #expect(await withDatabase.executed.last?.contains("TABLE_SCHEMA = 'shop'") == true)

        let withoutDatabase = ScriptedConnection(answers: [
            ScriptedConnection.Answer(match: "SELECT DATABASE()", columns: ["current_database"], rows: [[.null]]), tables,
        ])
        _ = await StatsHarvester.harvest(
            profileID: profile, connection: withoutDatabase, driver: .mysql, scope: .allUserSchemas, now: now
        )
        #expect(await withoutDatabase.executed.last?.contains("TABLE_SCHEMA NOT IN ('mysql'") == true)

        // Not knowing the database is not knowing the scope: nothing is read,
        // rather than the statistics of every database on the server.
        let unknown = ScriptedConnection(answers: [tables], failing: ["SELECT DATABASE()"])
        let records = await StatsHarvester.harvest(
            profileID: profile, connection: unknown, driver: .mysql, scope: .allUserSchemas, now: now
        )
        #expect(records.isEmpty)
        #expect(await unknown.executed.count == 1)
    }

    @Test func anEngineWithoutStatisticsViewsRunsNothing() async {
        let connection = ScriptedConnection(answers: [])
        let records = await StatsHarvester.harvest(
            profileID: profile, connection: connection, driver: .sqlite, scope: .allUserSchemas, now: now
        )
        #expect(records.isEmpty)
        #expect(await connection.executed.isEmpty)
    }

    /// A view the user may not read costs the numbers it holds, not the ones
    /// the other view still answers.
    @Test func aFailingQueryLeavesTheOtherQuerysRows() async {
        let noIndexes = ScriptedConnection(answers: [postgresTables], failing: ["pg_stat_user_indexes"])
        let records = await StatsHarvester.harvest(
            profileID: profile, connection: noIndexes, driver: .postgres, scope: .allUserSchemas, now: now
        )
        #expect(records.count == 2 && records.allSatisfy { $0.indexStats == nil && $0.rows != nil })
    }

    /// Index counters fold only into tables that were read, so when the tables
    /// query returns nothing the index view is not queried at all.
    @Test func noTableRowsMeanNoIndexQuery() async {
        let noTables = ScriptedConnection(answers: [postgresIndexes], failing: ["pg_stat_user_tables"])
        #expect(await StatsHarvester.harvest(
            profileID: profile, connection: noTables, driver: .postgres, scope: .allUserSchemas, now: now
        ).isEmpty)
        #expect(await noTables.executed.count == 1)
    }
}

@Suite("Statistics in the coordinator")
struct StatsHarvesterCoordinatorTests {
    let profile = UUID()

    private func make(
        clock: ManualClock = ManualClock(), maxConcurrent: Int = 2,
        provider: @escaping HarvestCoordinator.IntrospectorProvider = { _ in ScriptedIntrospector() }
    ) throws -> (BerryStore, HarvestCoordinator) {
        let store = try BerryStore(path: ":memory:")
        return (store, HarvestCoordinator(store: store, introspector: provider, maxConcurrent: maxConcurrent, now: { clock.now }))
    }

    /// `finished` records its marker once the call has returned, so a test can
    /// tell that a refresh came back without awaiting one that might not.
    private func refresh(
        _ coordinator: HarvestCoordinator, _ connection: ScriptedConnection, scope: SchemaScope = .allUserSchemas,
        finished: (log: ProviderLog, marker: UUID)? = nil
    ) -> Task<Void, Never> {
        let profile = profile
        return Task {
            await coordinator.requestStatistics(for: profile, connection: connection, driver: .postgres, scope: scope)
            finished?.log.append(finished?.marker ?? profile)
        }
    }

    @Test func writesTheHarvestedRowsForTheProfile() async throws {
        let clock = ManualClock()
        let (store, coordinator) = try make(clock: clock)
        let other = UUID()
        try store.replaceSchemaStats(profileID: other, rows: [
            SchemaStatsRecord(profileID: other, database: "shop", name: "orders", rows: 1, updatedAt: clock.now),
        ])
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        await refresh(coordinator, connection).value

        let rows = try store.schemaStats(profileID: profile)
        #expect(rows.map { "\($0.database ?? "").\($0.name)" } == ["archive.orders", "shop.orders"])
        #expect(rows.first { $0.database == "shop" }?.rows == 100)
        #expect(rows.allSatisfy { $0.updatedAt == clock.now })
        #expect(try store.schemaStats(profileID: other).map(\.rows) == [1])
    }

    @Test func aRefreshReplacesTheRowsOfAnEarlierOne() async throws {
        let (store, coordinator) = try make()
        await refresh(coordinator, ScriptedConnection(answers: [postgresTables, postgresIndexes])).value
        let shopOnly = ScriptedConnection.Answer(
            match: "pg_stat_user_tables", columns: postgresTables.columns,
            rows: [[.text("shop"), .text("orders"), .int(250), .int(9), .int(9), .int(32_768)]]
        )
        await refresh(coordinator, ScriptedConnection(answers: [shopOnly])).value

        let rows = try store.schemaStats(profileID: profile)
        #expect(rows.map(\.database) == ["shop"] && rows.first?.rows == 250)
    }

    /// Statistics are an enrichment: a refresh that read nothing must not
    /// erase the numbers an earlier one stored.
    @Test func aRefreshThatReadsNothingKeepsTheStoredRows() async throws {
        let (store, coordinator) = try make()
        await refresh(coordinator, ScriptedConnection(answers: [postgresTables, postgresIndexes])).value
        let denied = ScriptedConnection(answers: [], failing: ["pg_stat_user"])
        await refresh(coordinator, denied).value

        #expect(await denied.executed.count == 1)
        #expect(try store.schemaStats(profileID: profile).count == 2)
    }

    /// The caller drops a graph cached with the old numbers only when new ones
    /// were written, so an engine without statistics never costs a reload.
    @Test func aRefreshReportsWhetherItReplacedTheRows() async throws {
        let (_, coordinator) = try make()
        let profile = profile
        let wrote = await coordinator.requestStatistics(
            for: profile, connection: ScriptedConnection(answers: [postgresTables, postgresIndexes]),
            driver: .postgres, scope: .allUserSchemas
        )
        let denied = await coordinator.requestStatistics(
            for: profile, connection: ScriptedConnection(answers: [], failing: ["pg_stat_user"]),
            driver: .postgres, scope: .allUserSchemas
        )
        let unsupported = await coordinator.requestStatistics(
            for: profile, connection: ScriptedConnection(answers: []), driver: .sqlite, scope: .allUserSchemas
        )
        #expect(wrote)
        #expect(!denied)
        #expect(!unsupported)
    }

    @Test func aCancelledCallerWritesNothing() async throws {
        let (store, coordinator) = try make()
        try store.replaceSchemaStats(profileID: profile, rows: [
            SchemaStatsRecord(profileID: profile, database: "shop", name: "orders", rows: 1, updatedAt: Date()),
        ])
        let gate = Gate()
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes], gate: gate)
        let running = refresh(coordinator, connection)
        try await waitUntil { await connection.executed.count == 1 }
        running.cancel()
        await running.value
        await gate.open()

        #expect(await connection.executed.count == 1)
        #expect(try store.schemaStats(profileID: profile).map(\.rows) == [1])
        let next = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        await refresh(coordinator, next).value
        #expect(try store.schemaStats(profileID: profile).count == 2)
    }

    /// A cancel that lands after the tables were read leaves a harvest that
    /// holds rows but not the indexes; it must not be stored as if complete.
    @Test func aCancelWhileReadingTheIndexesWritesNothing() async throws {
        let (store, coordinator) = try make()
        let gate = Gate()
        let connection = ScriptedConnection(
            answers: [postgresTables, postgresIndexes], gate: gate, gatedText: "pg_stat_user_indexes"
        )
        let running = refresh(coordinator, connection)
        try await waitUntil { await connection.executed.count == 2 }
        running.cancel()
        await running.value
        await gate.open()

        #expect(try store.schemaStats(profileID: profile).isEmpty)
    }

    /// A refresh waits for a slot like a pass does: with two passes running it
    /// reads nothing until one finishes.
    @Test func aRefreshWaitsBehindTwoRunningPasses() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let gate = Gate()
        let log = ProviderLog()
        let (store, coordinator) = try make(provider: { profileID in
            log.append(profileID)
            await gate.wait()
            return fake
        })
        let passes = (0..<2).map { _ in UUID() }
        let running = passes.map { id in Task { await coordinator.request(.userAction, for: id) } }
        try await waitUntil { log.profiles.count == 2 }

        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let refreshing = refresh(coordinator, connection)
        try await waitUntil { await coordinator.waitingCount == 1 }
        #expect(await connection.executed.isEmpty)
        #expect(try store.schemaStats(profileID: profile).isEmpty)

        await gate.open()
        for pass in running { _ = await pass.value }
        await refreshing.value
        #expect(await connection.executed.count == 2)
        #expect(try store.schemaStats(profileID: profile).count == 2)
    }

    /// A running refresh holds one of the two slots, so of three requests the
    /// third waits, and starts once the refresh is done.
    @Test func aRunningRefreshTakesOneOfTheTwoSlots() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let passGate = Gate()
        let log = ProviderLog()
        let (_, coordinator) = try make(provider: { profileID in
            log.append(profileID)
            await passGate.wait()
            return fake
        })
        let statisticsGate = Gate()
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes], gate: statisticsGate)
        let refreshing = refresh(coordinator, connection)
        try await waitUntil { await connection.executed.count == 1 }

        let passes = (0..<2).map { _ in UUID() }
        let running = passes.map { id in Task { await coordinator.request(.userAction, for: id) } }
        try await waitUntil { log.profiles.count == 1 }
        try await waitUntil { await coordinator.waitingCount == 1 }
        #expect(log.profiles.count == 1)

        await statisticsGate.open()
        await refreshing.value
        try await waitUntil { log.profiles.count == 2 }
        await passGate.open()
        for pass in running { _ = await pass.value }
    }

    /// A refresh cancelled while it waits for a slot leaves the queue at once,
    /// instead of holding its caller until a slot frees, and never reads.
    @Test func aRefreshCancelledWhileWaitingReturnsAtOnceAndReadsNothing() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let gate = Gate()
        let log = ProviderLog()
        let (store, coordinator) = try make(provider: { profileID in
            log.append(profileID)
            await gate.wait()
            return fake
        })
        let holding = (0..<2).map { _ in Task { await coordinator.request(.userAction, for: UUID()) } }
        try await waitUntil { log.profiles.count == 2 }

        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let finished = ProviderLog()
        let marker = UUID()
        let refreshing = refresh(coordinator, connection, finished: (finished, marker))
        try await waitUntil { await coordinator.waitingCount == 1 }
        refreshing.cancel()
        try await waitUntil { finished.profiles == [marker] }

        #expect(await coordinator.waitingCount == 0)
        #expect(await connection.executed.isEmpty)
        await gate.open()
        for pass in holding { _ = await pass.value }
        #expect(await connection.executed.isEmpty)
        #expect(try store.schemaStats(profileID: profile).isEmpty)
    }

    /// With one slot, a leaked slot would stop every later pass and refresh, so
    /// a refresh cancelled while waiting and one cancelled while reading are
    /// followed by a pass and a refresh that both complete.
    @Test func cancelledRefreshesLeaveTheOnlySlotFree() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let holderGate = Gate()
        let log = ProviderLog()
        let holder = UUID()
        let (store, coordinator) = try make(maxConcurrent: 1, provider: { profileID in
            log.append(profileID)
            if profileID == holder { await holderGate.wait() }
            return fake
        })
        let holding = Task { await coordinator.request(.userAction, for: holder) }
        try await waitUntil { log.profiles == [holder] }

        let finished = ProviderLog()
        let waitingMarker = UUID()
        let waitingConnection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let waiting = refresh(coordinator, waitingConnection, finished: (finished, waitingMarker))
        try await waitUntil { await coordinator.waitingCount == 1 }
        waiting.cancel()
        try await waitUntil { finished.profiles == [waitingMarker] }
        #expect(await coordinator.waitingCount == 0)
        await holderGate.open()
        _ = await holding.value

        let readingGate = Gate()
        let readingConnection = ScriptedConnection(answers: [postgresTables, postgresIndexes], gate: readingGate)
        let reading = refresh(coordinator, readingConnection)
        try await waitUntil { await readingConnection.executed.count == 1 }
        reading.cancel()
        await reading.value
        await readingGate.open()

        let following = UUID()
        let passFinished = ProviderLog()
        _ = Task {
            _ = await coordinator.request(.userAction, for: following)
            passFinished.append(following)
        }
        try await waitUntil { passFinished.profiles == [following] }
        let lastConnection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let lastMarker = UUID()
        _ = refresh(coordinator, lastConnection, finished: (finished, lastMarker))
        try await waitUntil { finished.profiles.contains(lastMarker) }

        #expect(await waitingConnection.executed.isEmpty)
        #expect(try store.schemaStats(profileID: profile).count == 2)
    }

    /// A refresh whose caller is already cancelled is still granted the free
    /// slot before it can notice; it must hand that slot back unread.
    @Test func aRefreshCancelledBeforeItsGrantReleasesTheSlot() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let (store, coordinator) = try make(maxConcurrent: 1, provider: { _ in fake })
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let profile = profile
        let finished = ProviderLog()
        let marker = UUID()
        let refreshing = Task {
            while !Task.isCancelled { await Task.yield() }
            await coordinator.requestStatistics(for: profile, connection: connection, driver: .postgres, scope: .allUserSchemas)
            finished.append(marker)
        }
        refreshing.cancel()
        try await waitUntil { finished.profiles == [marker] }
        #expect(await connection.executed.isEmpty)

        let following = UUID()
        let passFinished = ProviderLog()
        _ = Task {
            _ = await coordinator.request(.userAction, for: following)
            passFinished.append(following)
        }
        try await waitUntil { passFinished.profiles == [following] }
        let last = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let lastMarker = UUID()
        _ = refresh(coordinator, last, finished: (finished, lastMarker))
        try await waitUntil { finished.profiles.contains(lastMarker) }
        #expect(try store.schemaStats(profileID: profile).count == 2)
    }

    /// A bounded Postgres connection reads a refresh's statistics in one
    /// transaction: both queries run in the scope the refresh opened, which
    /// is committed when the refresh ends.
    @Test func aRefreshReadsInOneScopeAndCommitsIt() async throws {
        let (_, coordinator) = try make(maxConcurrent: 1, provider: { _ in ScriptedIntrospector() })
        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes], scopesReads: true)

        await refresh(coordinator, connection).value

        let opened = await connection.openedScopes
        #expect(opened.count == 1)
        #expect(await connection.ended == [true])
        #expect(await connection.executed.count == 2)
        #expect(await connection.scopesRead.allSatisfy { $0 != nil && $0 == opened.first })
    }

    /// A refresh ranks as `.statistics`, below every reason a pass is asked
    /// for in the app, so a pass requested after it still starts first.
    @Test func aWaitingPassStartsBeforeAWaitingRefresh() async throws {
        let fake = ScriptedIntrospector(); fake.seed(tables: 1)
        let holderGate = Gate()
        let lateGate = Gate()
        let log = ProviderLog()
        let late = UUID()
        let (_, coordinator) = try make(maxConcurrent: 1, provider: { profileID in
            log.append(profileID)
            await (profileID == late ? lateGate : holderGate).wait()
            return fake
        })
        let holder = UUID()
        let holding = Task { await coordinator.request(.ownDDL, for: holder) }
        try await waitUntil { log.profiles == [holder] }

        let connection = ScriptedConnection(answers: [postgresTables, postgresIndexes])
        let refreshing = refresh(coordinator, connection)
        try await waitUntil { await coordinator.waitingCount == 1 }
        let latePass = Task { await coordinator.request(.ownDDL, for: late) }
        try await waitUntil { await coordinator.waitingCount == 2 }

        await holderGate.open()
        try await waitUntil { log.profiles == [holder, late] }
        #expect(await connection.executed.isEmpty)
        await lateGate.open()
        _ = await (holding.value, latePass.value)
        await refreshing.value
        #expect(await connection.executed.count == 2)
    }
}

@Suite("Statistics on Postgres", .enabled(if: TestServer.postgres != nil))
struct StatsHarvesterPostgresTests {
    private func connect() async throws -> PostgresDriverConnection {
        let server = TestServer.postgres!
        return try await PostgresDriverConnection(config: ConnectionConfig(
            driver: .postgres, name: "stats", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
    }

    private func exec(_ sql: String, on connection: PostgresDriverConnection) async throws {
        for try await _ in connection.execute(sql) {}
    }

    @Test func writesTableAndIndexStatsPerSchemaAndTable() async throws {
        let connection = try await connect()
        defer { Task { await connection.close() } }
        for schema in ["bd_stats_a", "bd_stats_b"] {
            try await exec("DROP SCHEMA IF EXISTS \(schema) CASCADE", on: connection)
            try await exec("CREATE SCHEMA \(schema)", on: connection)
            try await exec("CREATE TABLE \(schema).orders (id int PRIMARY KEY, v int)", on: connection)
            try await exec("CREATE INDEX bd_stats_idx ON \(schema).orders (v)", on: connection)
        }
        try await exec("INSERT INTO bd_stats_a.orders SELECT g, g FROM generate_series(1, 3) g", on: connection)
        try await exec("INSERT INTO bd_stats_b.orders SELECT g, g FROM generate_series(1, 5000) g", on: connection)
        try await exec("ANALYZE bd_stats_a.orders", on: connection)
        try await exec("ANALYZE bd_stats_b.orders", on: connection)

        let store = try BerryStore(path: ":memory:")
        let coordinator = HarvestCoordinator(store: store, introspector: { _ in ScriptedIntrospector() })
        let profile = UUID()
        await coordinator.requestStatistics(
            for: profile, connection: connection, driver: .postgres, scope: .schemas(["bd_stats_a", "bd_stats_b"])
        )

        let rows = try store.schemaStats(profileID: profile)
        #expect(rows.map { "\($0.database ?? "").\($0.name)" } == ["bd_stats_a.orders", "bd_stats_b.orders"])
        let small = try #require(rows.first { $0.database == "bd_stats_a" })
        let large = try #require(rows.first { $0.database == "bd_stats_b" })
        #expect((small.sizeBytes ?? 0) > 0)
        #expect((large.sizeBytes ?? 0) > (small.sizeBytes ?? 0))
        #expect(small.rows != nil && small.seqScan != nil && small.idxScan != nil)
        for row in rows {
            #expect(row.indexStats?.contains("\"bd_stats_idx\"") == true)
            #expect(row.indexStats?.contains("\"orders_pkey\"") == true)
        }

        try await exec("DROP SCHEMA IF EXISTS bd_stats_a CASCADE", on: connection)
        try await exec("DROP SCHEMA IF EXISTS bd_stats_b CASCADE", on: connection)
    }
}

@Suite("Statistics on MySQL", .enabled(if: TestServer.mysql != nil))
struct StatsHarvesterMySQLTests {
    @Test func writesTableSizeAndRowsPerSchema() async throws {
        let server = TestServer.mysql!
        let connection = try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql, name: "stats", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
        defer { Task { await connection.close() } }
        func exec(_ sql: String) async throws { for try await _ in connection.execute(sql) {} }
        try await exec("DROP TABLE IF EXISTS bd_stats_harvest_t")
        try await exec("CREATE TABLE bd_stats_harvest_t (id int PRIMARY KEY, v int) ENGINE=InnoDB")
        try await exec("INSERT INTO bd_stats_harvest_t (id, v) VALUES (1, 10), (2, 20)")
        try await exec("ANALYZE TABLE bd_stats_harvest_t")

        let schema = try #require(server.database)
        let records = await StatsHarvester.harvest(
            profileID: UUID(), connection: connection, driver: .mysql, scope: .schemas([schema]), now: Date()
        )
        let table = try #require(records.first { $0.name == "bd_stats_harvest_t" })
        #expect(table.database == schema)
        #expect((table.sizeBytes ?? 0) > 0)
        #expect(table.rows != nil)

        try await exec("DROP TABLE IF EXISTS bd_stats_harvest_t")
    }

    /// MariaDB reports a system-versioned table as `SYSTEM VERSIONED`
    /// (https://mariadb.com/kb/en/information-schema-tables-table/); the
    /// listing keeps it as a table, so its statistics are read too. MySQL has
    /// no such table, so there the test has nothing to do.
    @Test func mariaDBSystemVersionedTablesHaveStatistics() async throws {
        let server = TestServer.mysql!
        let connection = try await MySQLDriverConnection(config: ConnectionConfig(
            driver: .mysql, name: "stats", host: server.host, port: server.port,
            username: server.username, password: server.password, database: server.database
        ))
        defer { Task { await connection.close() } }
        var version = ""
        for try await event in connection.execute("SELECT VERSION()") {
            if case let .rows(rows) = event, case let .text(text)? = rows.first?.first { version = text }
        }
        guard version.contains("MariaDB") else { return }
        func exec(_ sql: String) async throws { for try await _ in connection.execute(sql) {} }
        try await exec("DROP TABLE IF EXISTS bd_stats_versioned")
        try await exec("CREATE TABLE bd_stats_versioned (id int PRIMARY KEY) WITH SYSTEM VERSIONING")

        let schema = try #require(server.database)
        let records = await StatsHarvester.harvest(
            profileID: UUID(), connection: connection, driver: .mysql, scope: .schemas([schema]), now: Date()
        )

        #expect(records.contains { $0.database == schema && $0.name == "bd_stats_versioned" })
        try await exec("DROP TABLE IF EXISTS bd_stats_versioned")
    }

    /// The default scope is the connection's database when it has one, and
    /// every database but the server's own four when it has none.
    @Test func theDefaultScopeFollowsTheConnectionsDatabase() async throws {
        let server = TestServer.mysql!
        func connect(database: String?) async throws -> MySQLDriverConnection {
            try await MySQLDriverConnection(config: ConnectionConfig(
                driver: .mysql, name: "stats", host: server.host, port: server.port,
                username: server.username, password: server.password, database: database
            ))
        }
        let schema = try #require(server.database)
        let withDatabase = try await connect(database: schema)
        let withoutDatabase = try await connect(database: nil)
        defer { Task { await withDatabase.close(); await withoutDatabase.close() } }
        func exec(_ sql: String) async throws { for try await _ in withDatabase.execute(sql) {} }
        try await exec("DROP DATABASE IF EXISTS bd_stats_other")
        try await exec("CREATE DATABASE bd_stats_other")
        try await exec("CREATE TABLE bd_stats_other.t (id int PRIMARY KEY) ENGINE=InnoDB")
        try await exec("DROP TABLE IF EXISTS bd_stats_mine")
        try await exec("CREATE TABLE bd_stats_mine (id int PRIMARY KEY) ENGINE=InnoDB")

        let mine = await StatsHarvester.harvest(
            profileID: UUID(), connection: withDatabase, driver: .mysql, scope: .allUserSchemas, now: Date()
        )
        #expect(mine.contains { $0.database == schema && $0.name == "bd_stats_mine" })
        #expect(mine.allSatisfy { $0.database == schema })

        let every = await StatsHarvester.harvest(
            profileID: UUID(), connection: withoutDatabase, driver: .mysql, scope: .allUserSchemas, now: Date()
        )
        #expect(every.contains { $0.database == schema && $0.name == "bd_stats_mine" })
        #expect(every.contains { $0.database == "bd_stats_other" && $0.name == "t" })
        let systemSchemas: Set<String> = ["mysql", "information_schema", "performance_schema", "sys"]
        #expect(!every.contains { systemSchemas.contains($0.database ?? "") })

        try await exec("DROP DATABASE IF EXISTS bd_stats_other")
        try await exec("DROP TABLE IF EXISTS bd_stats_mine")
    }
}
