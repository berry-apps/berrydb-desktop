import BerryDriverKit
import CryptoKit
import Foundation
import GRDB
import Synchronization

/// Local persistence:
/// `~/Library/Application Support/BerryDB/store.sqlite`.
/// Versioned migrations; backup logic added at the first schema change.
public final class BerryStore: Sendable {
    /// The app's connection, the only one that writes: the writer of a pool
    /// for a store file in WAL mode, else a queue. Nil in a store opened with
    /// `openReadOnly(path:)`.
    let writer: (any DatabaseWriter)?

    /// Serves every read. In the app, a store file in WAL mode is read
    /// through the reader connections of the writer's pool, so a read never
    /// waits for a write transaction such as a harvest pass's; an in-memory
    /// store, or one still in rollback mode, is read through the writer's
    /// queue. A read-only open gets a pool of reader connections on a WAL
    /// store and a single queue otherwise.
    let reader: any DatabaseReader

    /// How many times `releaseMemory()` ran; lets a test observe the memory
    /// manager without reaching into SQLite.
    private let releases = Mutex(0)

    /// Test access to the writer connection for raw SQL and explicit
    /// transactions. Nil in a read-only open; `dbQueue` is also nil when the
    /// writer is a pool's.
    var dbWriter: (any DatabaseWriter)? { writer }
    var dbQueue: DatabaseQueue? { writer as? DatabaseQueue }

    var releaseCount: Int { releases.withLock { $0 } }

    /// Whether reads run on a pool of reader connections rather than a single
    /// queue.
    var usesReaderPool: Bool { reader is DatabasePool }

    /// A write method was called on a store opened with
    /// `openReadOnly(path:)`. The helper never writes; reaching this is a
    /// programming error, reported as a thrown error so a caller cannot
    /// mistake the refusal for a successful save.
    public struct ReadOnlyWriteAttempt: Error, Equatable {}

    /// Every read goes through `reader`.
    func read<T>(_ body: (Database) throws -> T) throws -> T {
        try reader.read(body)
    }

    /// Every write goes through `writer`; a read-only open has none.
    func write<T>(_ body: (Database) throws -> T) throws -> T {
        guard let writer else { throw ReadOnlyWriteAttempt() }
        return try writer.write(body)
    }

    // The async pair keeps the methods on `AISession`'s main-actor path off
    // the main thread: GRDB runs the closure on the connection's own queue
    // instead of blocking the caller, which the sync pair above would do.

    func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
        try await reader.read(body)
    }

    func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T {
        guard let writer else { throw ReadOnlyWriteAttempt() }
        return try await writer.write(body)
    }

    /// `~/Library/Application Support/BerryDB/store.sqlite` — exposed so
    /// callers that need the file itself (e.g. a "reset local data" action)
    /// don't have to duplicate this path logic.
    public static func defaultStoreURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("BerryDB", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("store.sqlite")
    }

    /// Default store in Application Support.
    public static func open() throws -> BerryStore {
        try BerryStore(path: defaultStoreURL().path)
    }

    /// How long a connection waits for another connection's lock on the
    /// store file before failing with "database is locked". The app and the
    /// MCP helper open the same file from separate processes. In WAL mode a
    /// reader and the writer no longer wait for each other
    /// (https://www.sqlite.org/wal.html), so the bound now covers what is
    /// left: switching the file to WAL at open, and a helper reading a store
    /// still in rollback mode, where an app commit and a helper read wait for
    /// each other. Both sides hold the lock for one short transaction (a
    /// settings save, a history insert, one verification read), far below
    /// this bound; 5 seconds absorbs a slow disk or a burst of writes without
    /// letting a stuck peer block the caller indefinitely, and is no longer
    /// than the request timeout for production-labeled profiles. The reader
    /// connections of a pool, the app's and the helper's, do not use it: GRDB
    /// gives pool readers its own default of 10 seconds and does not expose
    /// that setting (`readerConfiguration` in
    /// https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Core/DatabasePool.swift),
    /// so the bound applies to the writer and to the single-queue opens only.
    static let busyTimeout: TimeInterval = 5

    /// Store at an arbitrary path — used for tests (`:memory:`).
    public init(path: String) throws {
        var configuration = Configuration()
        configuration.busyMode = .timeout(Self.busyTimeout)
        // GRDB runs this on every connection it opens, the writer and each
        // reader of a pool alike (`Configuration.prepareDatabase` in GRDB
        // 7.11.1, https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Core/Configuration.swift);
        // a test queries the vector table from many pool readers at once.
        configuration.prepareDatabase { db in
            try SQLiteVecExtension.install(into: db)
        }
        let writer = try Self.openWriter(path: path, configuration: configuration)
        self.writer = writer
        reader = writer
        try Self.retireSupersededMigrations(in: writer)
        let migrator = Self.migrator
        do {
            try migrator.migrate(writer)
        } catch {
            throw Self.openError(afterFailedMigration: error, migrator: migrator, in: writer)
        }
    }

    /// A pool for a store file, which puts the file in WAL mode and reads
    /// through connections of its own, else a queue.
    ///
    /// WAL lets the MCP helper read while the app commits and the reverse,
    /// and lets the app's own reads go on while it writes. The mode persists
    /// in the file once set
    /// (https://www.sqlite.org/wal.html#persistence_of_wal_mode), so the
    /// switch only matters at the first open. GRDB's pool switches the file
    /// itself and refuses to open when it cannot
    /// (`Database.setUpWALMode` in GRDB 7.11.1). With a read open on a
    /// rollback-mode file the switch waited out the whole busy timeout
    /// (observed by opening a store while another connection held a read),
    /// and failing the open for that would leave the app without its store,
    /// so the store then opens as a queue in rollback mode, without trying
    /// the switch a second time, and the next launch retries. The pool also
    /// sets NORMAL synchronous on its writer, the level a WAL connection
    /// already had: the SQLite bundled with macOS (3.51.0) is built with
    /// `DEFAULT_WAL_SYNCHRONOUS=1` (`PRAGMA compile_options`). An in-memory
    /// store cannot use WAL and is always a queue.
    ///
    /// The pool keeps at most two reader connections, against GRDB's default
    /// of five. The app reads one main-actor read at a time beside a
    /// background read or two (a pass's state, a drain's queue, a chat
    /// thread), and every reader holds a page cache of its own, up to
    /// 2,000 KiB by default (https://www.sqlite.org/pragma.html#pragma_cache_size),
    /// in each of the two stores a window opens, its workspace's and its AI
    /// panel's. A third read at once waits for one of the two, as every read
    /// waited for the writer before. The helper keeps the default for its
    /// concurrent tool calls.
    ///
    /// `makePool` exists so a test can make the switch fail without racing a
    /// lock against the busy timeout.
    static func openWriter(
        path: String,
        configuration: Configuration,
        makePool: (String, Configuration) throws -> DatabasePool = { try DatabasePool(path: $0, configuration: $1) }
    ) throws -> any DatabaseWriter {
        var poolConfiguration = configuration
        poolConfiguration.maximumReaderCount = 2
        if path != ":memory:", !path.isEmpty, let pool = try? makePool(path, poolConfiguration) {
            return pool
        }
        return try DatabaseQueue(path: path, configuration: configuration)
    }

    /// Test-only: wraps an already-prepared `DatabaseQueue` as-is, running no
    /// migration. Lets a migration test build a pre-v29 database, seed data,
    /// migrate it partway or fully with `BerryStore.migrator` directly, then
    /// exercise `BerryStore`'s own methods against the result.
    init(dbQueue: DatabaseQueue) {
        writer = dbQueue
        reader = dbQueue
    }

    /// A store that only reads, as `openReadOnly(path:)` returns.
    private init(reader: any DatabaseReader) {
        writer = nil
        self.reader = reader
    }

    /// `init(path:)` failure modes of its own. Any other failure to open the
    /// file is thrown as the underlying error.
    public enum OpenError: Error, Equatable, LocalizedError {
        /// The migration `identifier` did not complete; `reason` is the
        /// underlying error's text, which may quote SQL. The step either threw
        /// and was rolled back or, in the rare cases listed on
        /// `openError(afterFailedMigration:migrator:in:)`, never started;
        /// either way it changed no data. Steps applied before it in the same
        /// open stay committed.
        case migrationFailed(identifier: String, reason: String)

        public var errorDescription: String? {
            "BerryDB could not upgrade its data store."
        }

        public var failureReason: String? {
            switch self {
            case let .migrationFailed(identifier, _):
                "Upgrade step \"\(identifier)\" did not complete and changed no data."
            }
        }
    }

    /// A migration a development build registered and a later build withdrew.
    private struct SupersededMigration {
        let identifier: String
        /// The registered migration that took its place. A store that applied
        /// both (legacy tables dropped by hand, then the replacement run) holds
        /// the replacement's schema and data under the same table names.
        let replacement: String
        /// Tables the withdrawn migration created, children before the parents
        /// they reference: with foreign keys enforced, DROP TABLE first runs an
        /// implicit DELETE, which a remaining child row would otherwise block
        /// (https://www.sqlite.org/lang_droptable.html). Indexes go with their
        /// table, per the same page.
        let tables: [String]
    }

    /// Withdrawn migrations whose identifier a store may still record. GRDB
    /// keeps only identifiers, so a store that ran the withdrawn definition
    /// has its tables while the migrator, which no longer knows that
    /// identifier, runs the replacement against them and fails on every open.
    ///
    /// `v30-mcp-project-grant` was never in a release. It created
    /// `mcp_project`, `mcp_project_profile` and `mcp_project_grant` for an
    /// access model replaced before any release had MCP projects: grants
    /// were removed, and per-project capability and production-access
    /// columns became per-profile access with integrity tags. Its rows have no
    /// meaning in that model, so they are dropped, deliberately, and
    /// `v30-mcp-project` then creates the current tables.
    ///
    /// `v31-schema-object-versions`, `v32-schema-embedding-partition` and
    /// `v33-drop-legacy-graph-tables` were never in a release either. Earlier
    /// definitions of all three were applied to a development machine's store
    /// by test runs that opened the default store, and the definitions changed
    /// afterwards; the current ones are registered as `v34`, `v35` and `v36`.
    /// A store that applied the earlier ones drops the schema version tables
    /// and the partitioned name vectors they created, and its schema history
    /// with them, deliberately. Where the earlier `v33` had already dropped
    /// the per-node graph they were copied from, `v34` copies nothing and the
    /// next harvest pass writes the schema again, queuing every name for
    /// embedding; where it had not, `v34` copies the graph again. `v33`
    /// created nothing. The vector table is a vec0 virtual table, which only
    /// a connection with sqlite-vec installed can drop; `init(path:)`
    /// installs it on every connection before this runs.
    private static let supersededMigrations = [
        SupersededMigration(
            identifier: "v30-mcp-project-grant",
            replacement: "v30-mcp-project",
            tables: ["mcp_project_grant", "mcp_project_profile", "mcp_project"]
        ),
        SupersededMigration(
            identifier: "v31-schema-object-versions",
            replacement: "v34-schema-object-versions",
            tables: ["schema_object", "schema_relation", "schema_stats", "schema_change", "schema_graph_state"]
        ),
        SupersededMigration(
            identifier: "v32-schema-embedding-partition",
            replacement: "v35-schema-embedding-partition",
            tables: ["schema_object_embedding"]
        ),
        SupersededMigration(
            identifier: "v33-drop-legacy-graph-tables",
            replacement: "v36-drop-per-node-graph-tables",
            tables: []
        ),
    ]

    /// Clears what withdrawn migrations left in the store, in one transaction,
    /// before the migrator runs. A store without `grdb_migrations` (a new
    /// file) or without a withdrawn identifier is left as it is. Only
    /// `init(path:)` calls this: `openReadOnly(path:)` never writes, and keeps
    /// refusing such a store through its applied-set check.
    private static func retireSupersededMigrations(in writer: any DatabaseWriter) throws {
        try writer.write { db in
            guard try db.tableExists("grdb_migrations") else { return }
            let applied = try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
            for superseded in supersededMigrations where applied.contains(superseded.identifier) {
                if !applied.contains(superseded.replacement) {
                    for table in superseded.tables {
                        try db.execute(sql: "DROP TABLE IF EXISTS \(table.quotedDatabaseIdentifier)")
                    }
                }
                try db.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: [superseded.identifier]
                )
            }
        }
    }

    /// Names the migration a failed `migrate` call was running. GRDB 7.11.1
    /// runs unapplied migrations in registration order and stops at the first
    /// that throws (`DatabaseMigrator.runMigrations`); each runs in its own
    /// transaction that inserts its identifier into `grdb_migrations` before
    /// committing (`Migration.updateAppliedIdentifier`), and a thrown error
    /// rolls that transaction back before it is rethrown
    /// (`Database.inTransaction`). When a migration threw, the first
    /// registered identifier missing from `grdb_migrations` is that migration.
    ///
    /// `migrate` can also throw outside any migration while one is pending:
    /// from its own reads of `grdb_migrations` before the first migration
    /// starts (`DatabaseMigrator.runMigrations`; e.g. SQLITE_BUSY once the
    /// busy timeout expires, or an I/O error), or from re-enabling foreign
    /// keys after a migration committed
    /// (`Migration.runWithDeferredForeignKeysChecks`). The error does not
    /// say which case it came from, so such a failure is reported against
    /// the first pending migration although that migration never ran. The
    /// reported reason is still the real error, and the named step still
    /// changed no data. When nothing is missing, or the table cannot be read
    /// (GRDB creates it before running any migration, so its absence means
    /// that step failed), the error is returned unchanged. Internal so a
    /// test can reach that case, which no store file produces on demand.
    static func openError(
        afterFailedMigration error: any Error,
        migrator: DatabaseMigrator,
        in database: any DatabaseReader
    ) -> any Error {
        let applied = try? database.read { db in
            try String.fetchSet(db, sql: "SELECT identifier FROM grdb_migrations")
        }
        guard let applied,
              let failed = migrator.migrations.first(where: { !applied.contains($0) })
        else { return error }
        return OpenError.migrationFailed(identifier: failed, reason: error.localizedDescription)
    }

    /// `openReadOnly(path:)` failure modes.
    public enum ReadOnlyOpenError: Error, Equatable {
        /// The file's applied migration set differs from this build's; the
        /// helper refuses to read a store it cannot be sure it understands,
        /// and never migrates it either way.
        case schemaMismatch(applied: [String], expected: [String])
    }

    /// Opens an existing store for the MCP helper: read-only, no migration.
    /// The helper and the app may run at the same time; only the app writes.
    /// SQLite's read-only open mode refuses to create a missing file, so a
    /// path the app has never written throws rather than starting an empty
    /// store; the file's applied migration set must also match this build's
    /// exactly, whether older or newer, or the open is refused the same way.
    /// A store in WAL mode is read through a pool of reader connections and
    /// one still in rollback mode through a single queue. Either way the
    /// returned store never writes: its write methods throw
    /// `ReadOnlyWriteAttempt`.
    public static func openReadOnly(path: String) throws -> BerryStore {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        configuration.prepareDatabase { db in try SQLiteVecExtension.install(into: db) }
        let probe = try DatabaseQueue(path: path, configuration: configuration)
        let expected = migrator.migrations
        // Read the table directly rather than asking the migrator: an identifier
        // unknown to this build is exactly what reveals a store from a newer app.
        let applied = try probe.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
        guard Set(applied) == Set(expected) else {
            throw ReadOnlyOpenError.schemaMismatch(applied: applied, expected: expected)
        }
        // A WAL store gets a pool of reader connections, so concurrent tool
        // calls read in parallel and never wait for the app's commits. A
        // read-only process can open a WAL database when it can create the
        // -shm file, which the same user in the same directory can
        // (https://www.sqlite.org/wal.html#readonly). A store still in
        // rollback mode, because the app could not switch it while a reader
        // held it, keeps the single queue.
        let mode = try probe.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        if mode == "wal" {
            return BerryStore(reader: try DatabasePool(path: path, configuration: configuration))
        }
        return BerryStore(reader: probe)
    }

    /// Moves as many committed pages as possible from the WAL into the store
    /// file without waiting for any reader or writer. Does nothing for a
    /// read-only open; on a store that is not in WAL mode the pragma is a
    /// no-op (https://www.sqlite.org/pragma.html#pragma_wal_checkpoint).
    public func checkpoint() {
        // PASSIVE never invokes the busy handler, so this cannot stall the
        // caller; pages it cannot move yet stay in the WAL for the next
        // checkpoint. A failure leaves the store as it was.
        try? writer?.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)") }
    }

    /// Gives SQLite's page and statement caches back to the system. GRDB does
    /// this on its own only on iOS, so a macOS process calls it when it goes
    /// idle or the system reports memory pressure
    /// (https://github.com/groue/GRDB.swift/blob/v7.11.1/README.md#memory-management).
    /// Blocks until in-flight reads finish.
    public func releaseMemory() {
        releases.withLock { $0 += 1 }
        // In the app the reader is the writer's pool or queue, so this releases
        // the writer and its readers; in a read-only open it releases the
        // helper's connections.
        switch reader {
        case let queue as DatabaseQueue: queue.releaseMemory()
        case let pool as DatabasePool: pool.releaseMemory()
        default: break
        }
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-connection-profile") { db in
            try db.create(table: "connection_profile") { t in
                t.primaryKey("id", .text)
                t.column("driverID", .text).notNull()
                t.column("name", .text).notNull()
                t.column("groupName", .text)
                t.column("envColor", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("filePath", .text)
                t.column("host", .text)
                t.column("port", .integer)
                t.column("username", .text)
                t.column("database", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-tls-ssh") { db in
            try db.alter(table: "connection_profile") { t in
                t.add(column: "tlsMode", .text).notNull().defaults(to: "prefer")
                t.add(column: "sshEnabled", .boolean).notNull().defaults(to: false)
                t.add(column: "sshHost", .text)
                t.add(column: "sshPort", .integer)
                t.add(column: "sshUsername", .text)
                t.add(column: "sshKeyPath", .text)
            }
        }
        migrator.registerMigration("v3-history-snapshot") { db in
            try db.create(table: "query_history") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).indexed()
                t.column("sql", .text).notNull()
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("durationMS", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("rowCount", .integer)
                t.column("errorMessage", .text)
            }
            try db.create(table: "schema_snapshot") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).indexed()
                t.column("takenAt", .datetime).notNull()
                t.column("digest", .text).notNull()
                t.column("payload", .text).notNull()
            }
        }
        migrator.registerMigration("v4-editor-session") { db in
            try db.create(table: "editor_session") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).indexed()
                t.column("title", .text).notNull()
                t.column("text", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v5-saved-query") { db in
            try db.create(table: "saved_query") { t in
                t.primaryKey("id", .blob)
                // NULL profileID → global snippet; indexed for the picker query.
                t.column("profileID", .blob).indexed()
                t.column("name", .text).notNull()
                t.column("sql", .text).notNull()
                t.column("folder", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v6-ai-connection-setting") { db in
            try db.create(table: "ai_connection_setting") { t in
 // One row per profile (+ consent).
                t.primaryKey("profileID", .blob)
                t.column("aiEnabled", .boolean).notNull().defaults(to: false)
                t.column("allowSampleRows", .boolean).notNull().defaults(to: false)
                t.column("autoApproveSelects", .boolean).notNull().defaults(to: true)
                t.column("consentGiven", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v7-database-intelligence-graph") { db in
 // Temporal DSG store — one accumulating
            // graph per profile with first/last-seen for time-travel.
            try db.create(table: "graph_node") { t in
                t.column("profileID", .blob).notNull()
                t.column("nodeID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("database", .text)
                t.column("attrs", .text).notNull().defaults(to: "{}")
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull().indexed()
                t.primaryKey(["profileID", "nodeID"])
            }
            try db.create(table: "graph_edge") { t in
                t.column("profileID", .blob).notNull()
                t.column("src", .text).notNull()
                t.column("dst", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1)
                t.column("attrs", .text).notNull().defaults(to: "{}")
                t.column("firstSeen", .datetime).notNull()
                t.column("lastSeen", .datetime).notNull().indexed()
                t.primaryKey(["profileID", "src", "dst", "kind"])
            }
            try db.create(table: "graph_snapshot") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("takenAt", .datetime).notNull()
                t.column("nodeCount", .integer).notNull()
                t.column("edgeCount", .integer).notNull()
                t.column("digest", .text).notNull()
            }
        }
        migrator.registerMigration("v8-history-toggle") { db in
 // Per-connection query-history switch. Existing profiles keep
            // history on.
            try db.alter(table: "connection_profile") { t in
                t.add(column: "historyEnabled", .boolean).notNull().defaults(to: true)
            }
        }
        migrator.registerMigration("v9-tls-ca-cert") { db in
 // Custom CA certificate path for TLS verification.
            try db.alter(table: "connection_profile") { t in
                t.add(column: "tlsCACertPath", .text)
            }
        }
        migrator.registerMigration("v10-tls-client-cert") { db in
 // Client certificate/key paths for mutual TLS.
            try db.alter(table: "connection_profile") { t in
                t.add(column: "tlsClientCertPath", .text)
                t.add(column: "tlsClientKeyPath", .text)
            }
        }
        migrator.registerMigration("v11-mcp-servers") { db in
 // Per-connection enabled/trusted MCP servers, JSON arrays of ids.
            try db.alter(table: "ai_connection_setting") { t in
                t.add(column: "enabledMcpServers", .text).notNull().defaults(to: "[]")
                t.add(column: "trustedMcpServers", .text).notNull().defaults(to: "[]")
            }
        }
        migrator.registerMigration("v12-mongo-replica-set") { db in
 // Mongo-only replica-set seeds/name, v1.
            try db.alter(table: "connection_profile") { t in
                t.add(column: "mongoAdditionalHosts", .text)
                t.add(column: "mongoReplicaSet", .text)
            }
        }
        migrator.registerMigration("v13-recommendation-feedback") { db in
 // User response to an AI insight — accept/dismiss/ignore.
            try db.create(table: "recommendation_feedback") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("insightID", .text).notNull()
                t.column("action", .text).notNull()
                t.column("ts", .datetime).notNull()
            }
        }
        migrator.registerMigration("v14-query-replay") { db in
 // User-saved execution snapshots for comparing runs over time.
            try db.create(table: "query_replay") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("queryHash", .text).notNull().indexed()
                t.column("sql", .text).notNull()
                t.column("ts", .datetime).notNull()
                t.column("durationMS", .double).notNull()
            }
        }
        migrator.registerMigration("v15-daily-review") { db in
 // A generated digest of Insight Panel findings, shown again on next launch.
            try db.create(table: "daily_review") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("generatedAt", .datetime).notNull()
                t.column("summaryJSON", .text).notNull()
            }
        }
        migrator.registerMigration("v16-runtime-metric") { db in
 // Instance-level health snapshot at harvest time.
            try db.create(table: "runtime_metric") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("ts", .datetime).notNull()
                t.column("metric", .text).notNull()
                t.column("value", .double).notNull()
            }
        }
        migrator.registerMigration("v17-ai-thread-message") { db in
 // Client-authoritative chat history (Q17,
 // — replaces the old backend-side berry_ai_threads/
 // berry_ai_messages. Schema matches exactly.
            try db.create(table: "ai_thread") { t in
                t.primaryKey("id", .blob)
                t.column("dialect", .text).notNull()
                t.column("title", .text)
                t.column("summary", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "ai_message") { t in
                t.primaryKey("id", .blob)
                t.column("threadID", .blob).notNull().indexed()
                t.column("seq", .integer).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("toolCalls", .text)
                t.column("toolCallID", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["threadID", "seq"])
            }
 // vec0 virtual table for RAG (search_conversation) — keyed by
            // "threadID#seq" since vec0's declared PK can't be a composite of
            // two columns. Dimension fixed at 1536 (OpenAI text-embedding-3-small,
            // the only embedding model currently wired server-side); revisit if
            // a different-dimension provider is ever configured.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ai_message_embedding USING vec0(
                    messageKey TEXT PRIMARY KEY,
                    embedding FLOAT[1536]
                )
                """)
        }
        migrator.registerMigration("v18-ai-thread-summary-cursor") { db in
 // Incremental client-side rolling summaries (Q17). Nil on
            // existing rows means their old summary coverage is unknown; the
            // client rebuilds it once, then advances this cursor atomically
            // with each successful fold.
            try db.alter(table: "ai_thread") { t in
                t.add(column: "summaryThroughSeq", .integer)
            }
        }
        migrator.registerMigration("v19-ai-pending-interaction") { db in
            // Suspended backend control state is intentionally isolated from
            // ai_message/ai_message_embedding so it cannot enter chat RAG,
            // rolling summaries, search results, or report attachments.
            try db.create(table: "ai_pending_interaction") { t in
                t.primaryKey("id", .text)
                t.column("threadID", .blob).notNull().unique(onConflict: .replace)
                t.column("kind", .text).notNull()
                t.column("argsJSON", .text).notNull()
                t.column("resumeToken", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("originThreadID", .text).notNull()
                t.column("originPath", .text).notNull()
                t.column("parentThreadID", .text).notNull()
                t.column("expiresAtUnix", .integer).notNull().indexed()
                t.column("registryVersion", .text).notNull()
                t.column("toolVersion", .text).notNull()
                t.column("schemaVersion", .text).notNull()
                t.column("allowedActionsJSON", .text).notNull()
                t.column("state", .text).notNull().defaults(to: "pending")
                t.column("selectedAction", .text)
                t.column("responseText", .text)
                t.column("clientRequestID", .text)
                t.column("requestDigest", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v20-ai-pending-report-draft") { db in
            // Task 4.1 pre-refinement consent gate: the rough /report text
            // stays local (outside ai_message/RAG) until the user explicitly
            // consents to send it for backend refinement. One draft per
            // thread — a fresh /report replaces any earlier undecided one.
            try db.create(table: "ai_pending_report_draft") { t in
                t.primaryKey("threadID", .blob)
                t.column("text", .text).notNull()
                t.column("attachContext", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v21-workspace-action") { db in
            // Bounded recent tab/pane action log for AI tab-awareness
 // NOT the UI graph itself (that stays
 // in-memory). Rotation caps rows per
 // profile the same way v3's query_history does. No
            // tabID column: most tab kinds' ids don't survive relaunch (see
            // WorkspaceTab.id), so this stores a human-readable description
            // instead of a raw id a later reader could be tempted to rely on.
            try db.create(table: "workspace_action") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).indexed()
                t.column("kind", .text).notNull()
                t.column("description", .text).notNull()
                t.column("createdAt", .datetime).notNull().indexed()
            }
        }
        migrator.registerMigration("v22-schema-object-embedding") { db in
 // Semantic Database Search: search
            // tables/collections by meaning ("payment" -> invoice/billing)
            // rather than literal name. Keyed by "profileID#name" (vec0's
            // declared PK can't be composite), mirroring v17's
            // ai_message_embedding. Dimension fixed at 1536, same
            // text-embedding-3-small contract.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE schema_object_embedding USING vec0(
                    objectKey TEXT PRIMARY KEY,
                    embedding FLOAT[1536]
                )
                """)
        }
        migrator.registerMigration("v23-query-replay-plan") { db in
 // "Save for Replay" now also
            // captures the EXPLAIN ANALYZE plan tree (JSON, PlanNode shape),
            // not just durationMS, so two snapshots of the same query can be
            // compared on more than wall-clock time. Nullable: dialects
            // without EXPLAIN, or a failed/declined run, still save duration.
            try db.alter(table: "query_replay") { t in
                t.add(column: "planJSON", .text)
            }
        }
        migrator.registerMigration("v24-artifact") { db in
 // a durable, linkable reference to
            // something the AI agent created or ran, so a chat bubble can
            // point back to it and it survives a history reload/app restart.
            // Unlike saved_query, profileID is required — an artifact always
            // belongs to one connection.
            try db.create(table: "artifact") { t in
                t.primaryKey("id", .blob)
                t.column("profileID", .blob).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("objectRef", .text)
                t.column("sourceThreadID", .blob)
                t.column("sourceMessageID", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // One row per run/edit of a query-shaped artifact — identity
            // (the artifact row above) stays stable across reruns, while this
            // keeps the full history traceable instead of overwriting it.
            try db.create(table: "artifact_version") { t in
                t.primaryKey("id", .blob)
                t.column("artifactID", .blob).notNull().indexed()
                t.column("versionNumber", .integer).notNull()
                t.column("payload", .text).notNull()
                t.column("resultSnapshotJSON", .text)
                t.column("createdAt", .datetime).notNull()
                t.uniqueKey(["artifactID", "versionNumber"])
            }
        }
        migrator.registerMigration("v25-editor-session-links") { db in
 // Fixes a pre-existing gap (found while building): a
            // restored editor tab lost its saved_query link because
            // editor_session never carried savedQueryID — so reopening a
            // saved query (or, now, an artifact) after an app restart created
            // a duplicate tab instead of focusing the restored one.
            try db.alter(table: "editor_session") { t in
                t.add(column: "savedQueryID", .blob)
                t.add(column: "artifactID", .blob)
            }
        }
        migrator.registerMigration("v26-ai-message-artifacts") { db in
 // which artifacts a turn's
            // tool calls touched, so the bubble's link survives a history
            // reload/app restart. A new nullable column, not a reuse of
            // `toolCalls` — that column is already an equality-checked
            // sentinel string ("local:interaction"), not JSON.
            try db.alter(table: "ai_message") { t in
                t.add(column: "artifactsJSON", .text)
            }
        }
        migrator.registerMigration("v27-elasticsearch-auth-mode") { db in
 // Elasticsearch Basic-vs-API-key auth mode
 // — a persisted flag, same reasoning as `historyEnabled`/
            // `sshEnabled`: existing profiles default to Basic (`false`).
            try db.alter(table: "connection_profile") { t in
                t.add(column: "elasticsearchAPIKeyEnabled", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v28-ai-thread-connection-key") { db in
 // Threads were scoped by dialect alone (Q17), so switching
            // between two connections sharing a dialect (e.g. two Postgres
            // servers) could surface one connection's chat history under the
            // other's. Nil on existing rows: pre-v28 threads have no known
 // connection and stay dialect-scoped only.
            try db.alter(table: "ai_thread") { t in
                t.add(column: "connectionKey", .text)
            }
        }
        migrator.registerMigration("v29-ai-message-tree") { db in
 // editing/versioning a
            // chat message. A parent-pointer tree over `ai_message` (nil
            // `parentID` = first message in the thread) — editing a message
            // inserts a sibling rather than deleting anything, so the old
            // reply stays reachable. `ai_thread.activeLeafMessageID` is the
            // current tip; walking `parentID` from there to nil is the
            // active transcript. `seq` stays a thread-wide counter that's
            // never reused across the tree, so `UNIQUE(threadID, seq)`
            // needs no change.
            try db.alter(table: "ai_message") { t in
                t.add(column: "parentID", .blob).indexed()
            }
            try db.alter(table: "ai_thread") { t in
                t.add(column: "activeLeafMessageID", .blob)
            }
            // Backfill: every pre-v29 thread is one straight line in seq
            // order (branching didn't exist yet) — chain each row to the
            // one immediately before it and point the thread at the last one.
            let threadIDs = try UUID.fetchAll(db, sql: "SELECT DISTINCT threadID FROM ai_message")
            for threadID in threadIDs {
                let ids = try UUID.fetchAll(
                    db, sql: "SELECT id FROM ai_message WHERE threadID = ? ORDER BY seq ASC",
                    arguments: [threadID]
                )
                var previous: UUID?
                for id in ids {
                    try db.execute(sql: "UPDATE ai_message SET parentID = ? WHERE id = ?", arguments: [previous, id])
                    previous = id
                }
                try db.execute(
                    sql: "UPDATE ai_thread SET activeLeafMessageID = ? WHERE id = ?",
                    arguments: [previous, threadID]
                )
            }
        }
        migrator.registerMigration("v30-mcp-project") { db in
            try db.create(table: "mcp_project") { t in
                t.primaryKey("id", .blob)
                t.column("name", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: false)
                t.column("workspaceRootsJSON", .text).notNull()
                t.column("integrityTag", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "mcp_project_profile") { t in
                t.column("projectID", .blob).notNull()
                    .references("mcp_project", onDelete: .cascade)
                t.column("profileID", .blob).notNull()
                    .references("connection_profile", onDelete: .cascade)
                t.column("liveRead", .boolean).notNull().defaults(to: false)
                t.column("redactedColumnsJSON", .text).notNull().defaults(to: "[]")
                t.column("integrityTag", .blob)
                t.primaryKey(["projectID", "profileID"])
            }
        }
        migrator.registerMigration("v34-schema-object-versions") { db in
            // One version row per table or view, valid from firstSeen until
            // removedAt (NULL = current). The per-node graph tables it replaces
            // cost ~15 KB per table at 20,000 tables; this holds a table's
            // columns and indexes in one JSON value and only ever writes a row
            // when the definition hash changes.
            //
            // Every namespace column (database, srcDatabase, dstDatabase) is
            // NOT NULL and holds '' for an engine with no namespace, such as
            // SQLite or DynamoDB. SQLite treats NULLs as distinct in a UNIQUE
            // index (https://www.sqlite.org/lang_createindex.html#unique_indexes)
            // and accepts NULL in a composite PRIMARY KEY
            // (https://www.sqlite.org/lang_createtable.html#the_primary_key),
            // so with NULL the indexes below would not stop a second current
            // row and schema_stats could not be overwritten in place.
            try db.create(table: "schema_object") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .blob).notNull()
                t.column("database", .text).notNull().defaults(to: "")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("fingerprint", .text)
                t.column("definitionHash", .text)
                // Compressed, as `StoredDefinition` writes it.
                t.column("definition", .blob)
                // The column names and the index names, each folded and
                // newline-separated, searched apart so a needle that matches
                // only index names never walks the column matches' rows.
                t.column("columnText", .text).notNull().defaults(to: "")
                t.column("indexText", .text).notNull().defaults(to: "")
                t.column("searchName", .text).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.column("removedAt", .datetime)
                t.column("previousID", .integer)
                t.column("changeID", .integer)
                t.column("removedByChangeID", .integer)
                t.column("needsEmbedding", .boolean).notNull().defaults(to: false)
                t.column("embeddingAttempts", .integer).notNull().defaults(to: 0)
                // Set on a version closed for a successor, which its change
                // records as one changed entry with the successor, never as a
                // removal of its own.
                t.column("replaced", .boolean).notNull().defaults(to: false)
            }
            // Partial unique index: at most one current row per object, enforced
            // by SQLite so two overlapping passes cannot both insert.
            try db.execute(sql: """
                CREATE UNIQUE INDEX schema_object_current
                    ON schema_object (profileID, database, name, kind) WHERE removedAt IS NULL
                """)
            // A column or index search reads the folded names of every
            // current row. In this index it reads about 0.4 KB per object in
            // the listing's order, where the table row also holds the
            // definition, and only the definitions of the rows a search keeps
            // are read from the table.
            try db.execute(sql: """
                CREATE INDEX schema_object_search
                    ON schema_object (profileID, database, name, kind, columnText, indexText) WHERE removedAt IS NULL
                """)
            // The folded name of every current row, for a search of object
            // names, which reads only this small index, and for a lookup of a
            // name in any case, which seeks it.
            try db.execute(sql: """
                CREATE INDEX schema_object_folded_name
                    ON schema_object (profileID, searchName, database, name, kind) WHERE removedAt IS NULL
                """)
            try db.execute(sql: "CREATE INDEX schema_object_history ON schema_object (profileID, removedAt, firstSeen)")
            try db.execute(sql: "CREATE INDEX schema_object_embedding_queue ON schema_object (profileID) WHERE needsEmbedding = 1")
            // A change listing reads the versions a change introduced and the
            // ones it closed without a successor; without an index on each
            // side the closed side would scan the profile's whole history.
            // Each index carries the listing's order after the change, so a
            // page of a first pass's change, which holds every object, walks
            // the index from where the previous page ended instead of sorting
            // the whole change. The closed side's index holds only versions
            // closed without a successor: a pass that changes every table
            // closes one version per table, and walking those to skip them
            // took 20 to 23 ms of SQL per page at 20,000 tables.
            try db.execute(sql: "CREATE INDEX schema_object_change ON schema_object (profileID, changeID, database, name, kind)")
            try db.execute(sql: """
                CREATE INDEX schema_object_dropped_change ON schema_object (profileID, removedByChangeID, database, name, kind)
                    WHERE removedByChangeID IS NOT NULL AND replaced = 0
                """)
            // Retention reads every change a closed version names through it:
            // EXPLAIN QUERY PLAN of its change-row delete on SQLite 3.51.0
            // shows `COVERING INDEX schema_object_removed_change
            // (profileID=? AND removedByChangeID>?)`.
            try db.execute(sql: "CREATE INDEX schema_object_removed_change ON schema_object (profileID, removedByChangeID)")

            try db.create(table: "schema_relation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .blob).notNull()
                t.column("srcDatabase", .text).notNull().defaults(to: "")
                t.column("srcName", .text).notNull()
                t.column("srcColumn", .text).notNull()
                t.column("dstDatabase", .text).notNull().defaults(to: "")
                t.column("dstName", .text).notNull()
                t.column("dstColumn", .text).notNull()
                t.column("constraintName", .text)
                t.column("firstSeen", .datetime).notNull()
                t.column("removedAt", .datetime)
                t.column("changeID", .integer)
                t.column("removedByChangeID", .integer)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX schema_relation_current
                    ON schema_relation (profileID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn)
                    WHERE removedAt IS NULL
                """)
            try db.execute(sql: "CREATE INDEX schema_relation_history ON schema_relation (profileID, removedAt)")
            // In the listing's order after the change, as for the objects.
            try db.execute(sql: """
                CREATE INDEX schema_relation_change ON schema_relation
                    (profileID, changeID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn)
                """)
            try db.execute(sql: """
                CREATE INDEX schema_relation_removed_change ON schema_relation
                    (profileID, removedByChangeID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn)
                """)

            // Statistics change on every pass; versioning them would make every
            // pass look like a schema change, so they are overwritten in place.
            try db.create(table: "schema_stats") { t in
                t.column("profileID", .blob).notNull()
                t.column("database", .text).notNull().defaults(to: "")
                t.column("name", .text).notNull()
                t.column("rows", .integer)
                t.column("sizeBytes", .integer)
                t.column("seqScan", .integer)
                t.column("idxScan", .integer)
                t.column("indexStats", .text)
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["profileID", "database", "name"])
            }
            try db.create(table: "schema_change") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .blob).notNull()
                t.column("at", .datetime).notNull()
                t.column("added", .integer).notNull().defaults(to: 0)
                t.column("changed", .integer).notNull().defaults(to: 0)
                t.column("removed", .integer).notNull().defaults(to: 0)
                t.column("relationsAdded", .integer).notNull().defaults(to: 0)
                t.column("relationsRemoved", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "CREATE INDEX schema_change_profile ON schema_change (profileID, at)")
            try db.create(table: "schema_graph_state") { t in
                t.primaryKey("profileID", .blob)
                t.column("versionToken", .text)
                t.column("lastCheckedAt", .datetime)
                t.column("lastChangedAt", .datetime)
                t.column("selectedSchemas", .text)
                t.column("objectCount", .integer).notNull().defaults(to: 0)
                t.column("detailedCount", .integer).notNull().defaults(to: 0)
                t.column("lastErrorCode", .text)
                t.column("lastErrorAt", .datetime)
                t.column("retryAfter", .datetime)
                t.column("hint", .text)
                // Moved by every committed write that changes the stored
                // objects, definitions or relations, including one of a pass
                // that fails afterwards, which leaves lastChangedAt as it was.
                t.column("revision", .integer).notNull().defaults(to: 0)
            }
            try Self.copyLegacyGraph(db)
        }
        migrator.registerMigration("v35-schema-embedding-partition") { db in
            // Name vectors gain the connection as a partition key, so a nearest
            // name query reads only that connection's vectors. Without one the
            // query took the nearest vectors across every connection first and
            // kept this connection's afterwards, which found nothing for a
            // small connection next to a large one.
            //
            // The partition key is part of the table definition, so the table
            // is rebuilt. Verified against sqlite-vec 0.1.9:
            // - ALTER TABLE ... RENAME is accepted but leaves the shadow tables
            //   under the old name, and the renamed table then fails every read
            //   because the module has no rename hook in this version
            //   (https://github.com/asg017/sqlite-vec/issues/43). The rows go
            //   through a scratch table so the final table keeps its name.
            // - Each partition allocates a whole chunk up front, and a chunk
            //   defaults to 1024 vectors, 6.3 MB for 1536 dimensions: ten
            //   connections with one vector each took 63.5 MB, against 4.4 MB
            //   with chunk_size=64. The documentation warns about the same
            //   over-sharding:
            //   https://alexgarcia.xyz/sqlite-vec/features/vec0.html#partition-keys
            func createEmbeddingTable(_ name: String) throws {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE \(name) USING vec0(
                        objectKey TEXT PRIMARY KEY,
                        profileID TEXT PARTITION KEY,
                        embedding FLOAT[1536],
                        chunk_size=64
                    )
                    """)
            }
            if try db.tableExists("schema_object_embedding") {
                // The key is "<profile uuid>#<name>" and a uuid is 36 characters.
                try createEmbeddingTable("schema_object_embedding_v2")
                try db.execute(sql: """
                    INSERT INTO schema_object_embedding_v2 (objectKey, profileID, embedding)
                    SELECT objectKey, substr(objectKey, 1, 36), embedding FROM schema_object_embedding
                    """)
                try db.execute(sql: "DROP TABLE schema_object_embedding")
                try createEmbeddingTable("schema_object_embedding")
                try db.execute(sql: """
                    INSERT INTO schema_object_embedding (objectKey, profileID, embedding)
                    SELECT objectKey, profileID, embedding FROM schema_object_embedding_v2
                    """)
                try db.execute(sql: "DROP TABLE schema_object_embedding_v2")
            } else {
                // A store that applied the withdrawn
                // `v32-schema-embedding-partition` had its vector table
                // dropped at open, so there are no vectors to copy.
                try createEmbeddingTable("schema_object_embedding")
            }

            // Objects copied from the earlier graph start with their queue flag
            // cleared, and a search embeds only a bounded number of the names
            // it lists, so a current object without a vector might never get
            // one.
            let profileUUID = """
                substr(hex(profileID), 1, 8) || '-' || substr(hex(profileID), 9, 4) || '-'
                || substr(hex(profileID), 13, 4) || '-' || substr(hex(profileID), 17, 4)
                || '-' || substr(hex(profileID), 21)
                """
            try db.execute(sql: """
                UPDATE schema_object SET needsEmbedding = 1
                WHERE removedAt IS NULL AND needsEmbedding = 0
                  AND (\(profileUUID)) || '#' || name NOT IN (SELECT objectKey FROM schema_object_embedding)
                """)
        }
        migrator.registerMigration("v36-drop-per-node-graph-tables") { db in
            // v34 copied these into the per-table tables; nothing reads them
            // once every consumer moved to the per-table store. Dropped in
            // their own migration so the copy and the drop are each final the
            // first time any build runs them.
            for table in ["graph_edge", "graph_node", "graph_snapshot"] {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
        }
        return migrator
    }

    /// Copies the per-node graph tables into the per-table version tables, one
    /// version per table or view. The graph tables stay in place.
    ///
    /// A graph snapshot is written only when the structure changed, so an
    /// object last seen before the latest snapshot was dropped by it, while an
    /// object last seen at or after it is current. A profile with no snapshot
    /// has only current objects. A dropped object is closed at the first
    /// snapshot after it was last seen: that is the first harvest that no
    /// longer had it, and closing at the last sighting instead would give an
    /// object seen in exactly one harvest an empty interval, invisible at the
    /// snapshot that recorded it.
    ///
    /// Only the graphs of saved profiles are copied. Deleting a profile left
    /// its graph rows behind before this version; copied, they would be rows
    /// that no profile deletion reaches, and the next migration would queue
    /// their names for embedding.
    ///
    /// A store that applied the withdrawn `v33-drop-legacy-graph-tables` has
    /// no graph tables left, and copies nothing: its first harvest pass
    /// writes the schema again.
    private static func copyLegacyGraph(_ db: Database) throws {
        for table in ["graph_node", "graph_edge", "graph_snapshot"] {
            guard try db.tableExists(table) else { return }
        }
        let profiles = try UUID.fetchAll(db, sql: """
            SELECT DISTINCT profileID FROM graph_node WHERE profileID IN (SELECT id FROM connection_profile)
            """)
        for profile in profiles {
            let snapshots = try Date.fetchAll(
                db, sql: "SELECT takenAt FROM graph_snapshot WHERE profileID = ? ORDER BY takenAt",
                arguments: [profile]
            )
            try copyLegacyObjects(db, profile: profile, snapshots: snapshots)
            try copyLegacyRelations(db, profile: profile, snapshots: snapshots)
            try copyLegacyChanges(db, profile: profile)
            let counts = try Row.fetchOne(
                db, sql: """
                    SELECT COUNT(*) AS objects, COUNT(definition) AS detailed
                    FROM schema_object WHERE profileID = ? AND removedAt IS NULL
                    """,
                arguments: [profile]
            )
            try db.execute(
                sql: "INSERT INTO schema_graph_state (profileID, lastChangedAt, objectCount, detailedCount) VALUES (?, ?, ?, ?)",
                arguments: [profile, snapshots.last, counts?["objects"] as Int? ?? 0, counts?["detailed"] as Int? ?? 0]
            )
        }
    }

    /// When something last seen at `lastSeen` was closed: the earliest
    /// snapshot after it, which is the first harvest that no longer had it. Nil
    /// when it was seen at or after the latest snapshot, so it is current. A
    /// closing snapshot always exists for a dropped object because it is
    /// dropped exactly when the latest snapshot is later than its last sighting.
    private static func removalDate(lastSeen: Date, snapshots: [Date]) -> Date? {
        guard let latest = snapshots.last, lastSeen < latest else { return nil }
        return snapshots.first { $0 > lastSeen }
    }

    /// Finds the columns or indexes of a table by edge, and keeps only those
    /// seen in the table's last pass: a column or index dropped earlier keeps
    /// its old lastSeen and must not reappear in the definition. rowid order is
    /// the order the harvest inserted them, the closest the old model has to
    /// the columns' ordinal order.
    ///
    /// The unary plus keeps the lastSeen term away from graph_node's lastSeen
    /// index. Without it SQLite drives the join from that index, and since most
    /// nodes share a lastSeen it walks nearly every node for every table: 2,000
    /// tables took 23 seconds and the time quadrupled with each doubling
    /// (EXPLAIN QUERY PLAN, SQLite as bundled with macOS). The unary plus is the
    /// documented way to keep a term away from an index, under "Disqualifying
    /// WHERE Clause Terms Using Unary +" at
    /// https://www.sqlite.org/optoverview.html#disqualifying_where_clause_terms_using_unary_
    /// in the SQLite query planner overview.
    static let legacyChildrenSQL = """
        SELECT child.name AS name, child.attrs AS attrs
        FROM graph_edge edge
        JOIN graph_node child ON child.profileID = edge.profileID AND child.nodeID = edge.dst
        WHERE edge.profileID = ? AND edge.src = ? AND edge.kind = ? AND +child.lastSeen = ?
        ORDER BY child.rowid
        """

    /// A table node and a pass in which a reference pointed at it.
    private struct LegacyReferenceTarget: Hashable {
        let nodeID: String
        let seen: Date
    }

    private static func copyLegacyObjects(_ db: Database, profile: UUID, snapshots: [Date]) throws {
        let children = try db.cachedStatement(sql: legacyChildrenSQL)
        // Read once per profile: the edge table's key starts with the source,
        // so looking a target up per table would scan the profile's edges.
        var referenced = Set<LegacyReferenceTarget>()
        let references = try Row.fetchCursor(db, sql: """
            SELECT dst, lastSeen FROM graph_edge WHERE profileID = ? AND kind = 'references'
            """, arguments: [profile])
        while let row = try references.next() {
            referenced.insert(LegacyReferenceTarget(nodeID: row["dst"], seen: row["lastSeen"]))
        }
        let insert = try db.cachedStatement(sql: """
            INSERT INTO schema_object
                (profileID, database, name, kind, definitionHash, definition, columnText, indexText, searchName, firstSeen,
                 removedAt, needsEmbedding)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """)
        let tables = try Row.fetchAll(db, sql: """
            SELECT nodeID, kind, name, COALESCE(database, '') AS database, firstSeen, lastSeen FROM graph_node
            WHERE profileID = ? AND kind IN ('table', 'view') ORDER BY rowid
            """, arguments: [profile])
        for table in tables {
            let nodeID: String = table["nodeID"]
            let name: String = table["name"]
            let lastSeen: Date = table["lastSeen"]
            let columns = try Row.fetchAll(children, arguments: [profile, nodeID, "hasColumn", lastSeen]).map { row -> [String: Any] in
                let attrs = decodeAttributes(row["attrs"])
                return [
                    "name": row["name"] as String,
                    "nullable": attrs["nullable"] == "true",
                    "primaryKey": attrs["primaryKey"] == "true",
                    "type": attrs["type"] ?? "",
                ]
            }
            let indexes = try Row.fetchAll(children, arguments: [profile, nodeID, "hasIndex", lastSeen])
                .map { row -> (name: String, unique: Bool, columns: [String]) in
                    let attrs = decodeAttributes(row["attrs"])
                    return (
                        row["name"] as String, attrs["unique"] == "true",
                        (attrs["columns"] ?? "").split(separator: ",").map(String.init)
                    )
                }
                .sorted { $0.name < $1.name }
            // The per-node graph builder added a bare table node for a foreign
            // key target missing from the listing, so the reference had an
            // end: no column and no index, only a reference into it in the
            // same pass. It is not a listed table; copied, the next pass would
            // record it as removed. The reference itself is still copied.
            if table["kind"] as String == "table", columns.isEmpty, indexes.isEmpty,
               referenced.contains(LegacyReferenceTarget(nodeID: nodeID, seen: lastSeen)) {
                continue
            }
            // A node with no column in its last pass never had its detail
            // harvested: a view, or a table whose detail fetch failed. It is
            // migrated as pending, with no definition, not as a table that has
            // no columns, and a name search can still find it.
            var definition: String?
            var columnNames: [String] = []
            var indexNames: [String] = []
            if !columns.isEmpty {
                definition = try canonicalDefinitionJSON(
                    columns: columns,
                    indexes: indexes.map { ["columns": $0.columns, "name": $0.name, "unique": $0.unique] as [String: Any] }
                )
                columnNames = columns.compactMap { $0["name"] as? String }
                indexNames = indexes.map(\.name)
            }
            try insert.execute(arguments: [
                profile, table["database"] as String, name, table["kind"] as String,
                definition.map(ContentHash.fnv1a64), definition.map(StoredDefinition.init(text:)),
                SchemaSearchText.joined(columnNames), SchemaSearchText.joined(indexNames), SchemaSearchText.fold(name),
                table["firstSeen"] as Date, removalDate(lastSeen: lastSeen, snapshots: snapshots),
            ])
        }
    }

    private static func copyLegacyRelations(_ db: Database, profile: UUID, snapshots: [Date]) throws {
        let edges = try Row.fetchAll(db, sql: """
            SELECT COALESCE(source.database, '') AS srcDatabase, source.name AS srcName,
                   COALESCE(target.database, '') AS dstDatabase, target.name AS dstName,
                   edge.attrs AS attrs, edge.firstSeen AS firstSeen, edge.lastSeen AS lastSeen
            FROM graph_edge edge
            JOIN graph_node source ON source.profileID = edge.profileID AND source.nodeID = edge.src
            JOIN graph_node target ON target.profileID = edge.profileID AND target.nodeID = edge.dst
            WHERE edge.profileID = ? AND edge.kind = 'references'
            ORDER BY edge.rowid
            """, arguments: [profile])
        for edge in edges {
            let attrs = decodeAttributes(edge["attrs"])
            try db.execute(sql: """
                INSERT INTO schema_relation
                    (profileID, srcDatabase, srcName, srcColumn, dstDatabase, dstName, dstColumn, firstSeen, removedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    profile, edge["srcDatabase"] as String, edge["srcName"] as String, attrs["column"] ?? "",
                    edge["dstDatabase"] as String, edge["dstName"] as String, attrs["referencedColumn"] ?? "",
                    edge["firstSeen"] as Date, removalDate(lastSeen: edge["lastSeen"], snapshots: snapshots),
                ])
        }
    }

    /// A snapshot records totals, so the delta against the previous snapshot is
    /// the best the old model can say about what a pass added or removed. The
    /// counts on these migrated rows are node and edge count deltas, not object
    /// counts: they include every column and index, and a changed table cannot
    /// be told from an unchanged one, so `changed` is always 0.
    private static func copyLegacyChanges(_ db: Database, profile: UUID) throws {
        let snapshots = try Row.fetchAll(db, sql: """
            SELECT takenAt, nodeCount, edgeCount FROM graph_snapshot
            WHERE profileID = ? ORDER BY takenAt, rowid
            """, arguments: [profile])
        var previousNodes = 0
        var previousEdges = 0
        for snapshot in snapshots {
            let nodes: Int = snapshot["nodeCount"]
            let edges: Int = snapshot["edgeCount"]
            try db.execute(sql: """
                INSERT INTO schema_change (profileID, at, added, changed, removed, relationsAdded, relationsRemoved)
                VALUES (?, ?, ?, 0, ?, ?, ?)
                """, arguments: [
                    profile, snapshot["takenAt"] as Date,
                    max(nodes - previousNodes, 0), max(previousNodes - nodes, 0),
                    max(edges - previousEdges, 0), max(previousEdges - edges, 0),
                ])
            previousNodes = nodes
            previousEdges = edges
        }
    }

    private static func decodeAttributes(_ json: String?) -> [String: String] {
        guard let json, let attributes = try? JSONDecoder().decode([String: String].self, from: Data(json.utf8)) else { return [:] }
        return attributes
    }

    /// The bytes `SchemaDefinition.json()` produces for the same content:
    /// sorted keys, no whitespace, slashes unescaped. The store cannot depend
    /// on BerryGraph, which owns that type, so a migrated row is written by this
    /// copy of the encoding, and the two must stay equal or the first harvest
    /// after the upgrade writes a new version of every table. The old model
    /// records no column default, so none is written.
    private static func canonicalDefinitionJSON(columns: [[String: Any]], indexes: [[String: Any]]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["columns": columns, "indexes": indexes],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

 // MARK: - Connection profiles

    public func allProfiles() throws -> [ConnectionProfile] {
        try read { db in
            try ConnectionProfile
                .order(Column("sortOrder").asc, Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func save(_ profile: ConnectionProfile) throws {
        try write { db in
            try profile.save(db)
        }
    }

 /// Delete a profile — the caller MUST also delete the Keychain item.
    /// The key must be the UUID itself: GRDB stores UUID as a 16-byte blob,
    /// so a uuidString key would never match.
    ///
    /// The profile's MCP access rows go with it by cascade, without an MCP
    /// key rotation. A copy of those rows restored into the file, together
    /// with the profile row, could verify again; that is acceptable because
    /// the profile's secrets are deleted from the Keychain with it, so the
    /// helper has no credential to use for it, and a connection that needs
    /// none is one the same-user process can open without BerryDB.
    ///
    /// The profile's schema graph, statistics and name embeddings are deleted
    /// in the same transaction; none of them is tied to the profile row by a
    /// foreign key, so they would otherwise stay behind as orphans.
    public func deleteProfile(id: UUID) throws {
        _ = try write { db in
            try Self.deleteSchemaGraphRows(db, profileID: id)
            try ConnectionProfile.deleteOne(db, key: id)
        }
    }

    // MARK: - MCP projects

    public func mcpProjects() throws -> [MCPProject] {
        try read { db in
            let records = try MCPProjectRecord
                .order(Column("name").collating(.nocase).asc, Column("id").asc)
                .fetchAll(db)
            return try records.map { try Self.makeMCPProject(record: $0, db: db) }
        }
    }

    public func mcpProject(id: UUID) throws -> MCPProject? {
        try read { db in
            guard let record = try MCPProjectRecord.fetchOne(db, key: id) else { return nil }
            return try Self.makeMCPProject(record: record, db: db)
        }
    }

    /// Test-only raw SQL, used to simulate a process editing the store file directly.
    func executeForTesting(_ sql: String, arguments: StatementArguments = []) throws {
        try write { try $0.execute(sql: sql, arguments: arguments) }
    }

    /// Test-only raw SQL read, used to snapshot exact stored bytes (e.g. a
    /// tag) before simulating a stale restore or other file-level tampering.
    func fetchForTesting(_ sql: String, arguments: StatementArguments = []) throws -> [Row] {
        try read { try Row.fetchAll($0, sql: sql, arguments: arguments) }
    }

    /// Saves `project` sealed under `sealingKey`, then re-seals every other
    /// stored project's rows for the same key rotation. `project` must come
    /// from `mcpProjectForEditing(id:key:)` (or be freshly constructed by the
    /// app), never from `mcpProject(id:)` or a value round-tripped through
    /// something else — `mcpProjectForEditing` is the only source that has
    /// already stripped any `liveRead` this call cannot prove BerryDB itself
    /// granted.
    ///
    /// Callers rotate the key in this order: (1)
    /// `previousKey = try MCPAccessKeyStore.keychain.loadForRotation()`,
    /// abort on throw; (2) generate `sealingKey = SymmetricKey(size:
    /// .bits256)`; (3) `try MCPAccessKeyStore.keychain.replace(with:
    /// sealingKey)`, abort on throw; (4) this call. The stored key is
    /// replaced *before* this call reseals anything: if this call fails or
    /// is interrupted after step 3 already ran, every row still sealed under
    /// `previousKey` is sealed under a key that is no longer stored, so live
    /// reads stop for every project. They do not come back on their own: the
    /// editing copy of such a project (`mcpProjectForEditing`) no longer
    /// verifies, so it is disabled with every `liveRead` off, and saving it
    /// seals exactly that. The user has to enable the project and turn live
    /// reads on again. A restored older copy of the store never verifies
    /// under the current key, by the same mechanism — expected, not a
    /// defect.
    ///
    /// A row belonging to another project is only carried forward — re-tagged
    /// under `sealingKey` — when it currently verifies under `previousKey`.
    /// Any row that does not (no previous key, a NULL tag, a tampered field,
    /// a duplicated profile ID, or a row whose stored fields cannot even be
    /// decoded) has its tag cleared instead of being re-signed from whatever
    /// is currently on disk, so a same-user process that edits another
    /// project's row between saves cannot have that edit signed off by a
    /// later, unrelated save.
    public func saveMCPProject(_ project: MCPProject, sealingKey: SymmetricKey, previousKey: SymmetricKey?) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roots = try MCPProject.canonicalWorkspaceRoots(project.workspaceRoots)
        var record = MCPProjectRecord(
            id: project.id,
            name: project.name,
            isEnabled: project.isEnabled,
            workspaceRootsJSON: String(decoding: try encoder.encode(roots), as: UTF8.self),
            integrityTag: nil,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
        record.integrityTag = MCPAccessIntegrity.tag(
            try MCPAccessIntegrity.projectPayload(id: project.id, isEnabled: project.isEnabled, workspaceRoots: roots),
            key: sealingKey
        )
        try write { db in
            try record.save(db)
            try MCPProjectProfileRecord.filter(Column("projectID") == project.id).deleteAll(db)
            var seen = Set<UUID>()
            for access in project.profiles where seen.insert(access.profileID).inserted {
                // The foreign key rejects unsaved profiles, so metadata such as
                // a group name or workspace path can never manufacture access.
                let normalizedAccess = MCPProfileAccess(
                    profileID: access.profileID,
                    liveRead: access.liveRead,
                    redactedColumns: access.redactedColumns
                )
                // The tag binds the row to the profile's endpoint as stored
                // right now; a missing profile yields no tag and the insert
                // below fails on the foreign key.
                let integrityTag = try ConnectionProfile.fetchOne(db, key: access.profileID).map { profile in
                    MCPAccessIntegrity.tag(
                        try MCPAccessIntegrity.profilePayload(
                            projectID: project.id, access: normalizedAccess, profile: profile
                        ),
                        key: sealingKey
                    )
                }
                try MCPProjectProfileRecord(
                    projectID: project.id,
                    profileID: access.profileID,
                    liveRead: access.liveRead,
                    redactedColumnsJSON: String(
                        decoding: try encoder.encode(normalizedAccess.redactedColumns),
                        as: UTF8.self
                    ),
                    integrityTag: integrityTag
                ).insert(db)
            }
            try Self.reseal(
                otherThan: project.id, sealingKey: sealingKey, previousKey: previousKey,
                db: db, encoder: encoder, decoder: decoder
            )
        }
    }

    /// Re-tags every stored project other than `excludedProjectID` for a key
    /// rotation from `previousKey` to `sealingKey`. A row is only carried
    /// forward — re-tagged under `sealingKey` — when it verifies under
    /// `previousKey` from its own current fields; anything else (no previous
    /// key, a bad or missing tag, a duplicated profile ID, or a row whose
    /// stored fields cannot even be decoded — a foreign process can write
    /// anything to the file) has its tag cleared rather than re-signed, so a
    /// same-user process that edits another project's row between saves
    /// cannot have that edit signed off by an unrelated save. A row this
    /// cannot decode never blocks the save in progress; it is simply left
    /// unverifiable, same as any other row that fails to verify.
    private static func reseal(
        otherThan excludedProjectID: UUID, sealingKey: SymmetricKey, previousKey: SymmetricKey?, db: Database,
        encoder: JSONEncoder, decoder: JSONDecoder
    ) throws {
        let otherProjects = try MCPProjectRecord.filter(Column("id") != excludedProjectID).fetchAll(db)
        for var other in otherProjects {
            other.integrityTag = Self.resealedProjectTag(
                other, sealingKey: sealingKey, previousKey: previousKey, decoder: decoder
            )
            try other.save(db)

            let rows = try MCPProjectProfileRecord.filter(Column("projectID") == other.id).fetchAll(db)
            var occurrences: [UUID: Int] = [:]
            for row in rows { occurrences[row.profileID, default: 0] += 1 }
            for var row in rows {
                row.integrityTag = Self.resealedProfileTag(
                    row, projectID: other.id, isDuplicated: occurrences[row.profileID] != 1,
                    sealingKey: sealingKey, previousKey: previousKey, decoder: decoder, db: db
                )
                try row.save(db)
            }
        }
    }

    /// The re-sealed tag for another project's row, or nil when it cannot be
    /// carried forward — no `previousKey`, a tag that does not verify, or
    /// stored fields (`workspaceRootsJSON`, a non-absolute root) that cannot
    /// even be decoded. Never throws: a decode failure here is data, not a
    /// programming error, and must not abort the save of an unrelated
    /// project.
    private static func resealedProjectTag(
        _ record: MCPProjectRecord, sealingKey: SymmetricKey, previousKey: SymmetricKey?, decoder: JSONDecoder
    ) -> Data? {
        guard let previousKey else { return nil }
        guard let roots = try? MCPProject.canonicalWorkspaceRoots(
            try decoder.decode([String].self, from: Data(record.workspaceRootsJSON.utf8))
        ) else { return nil }
        guard let payload = try? MCPAccessIntegrity.projectPayload(
            id: record.id, isEnabled: record.isEnabled, workspaceRoots: roots
        ) else { return nil }
        guard MCPAccessIntegrity.isValid(record.integrityTag, payload: payload, key: previousKey) else { return nil }
        return MCPAccessIntegrity.tag(payload, key: sealingKey)
    }

    /// The re-sealed tag for another project's profile row, or nil when it
    /// cannot be carried forward — no `previousKey`, a duplicated profile
    /// ID, a tag that does not verify (including because the profile's
    /// endpoint changed since the row was sealed), a profile row that is
    /// missing or cannot be decoded, or a `redactedColumnsJSON` that cannot
    /// even be decoded. Never throws, for the same reason as
    /// `resealedProjectTag`.
    private static func resealedProfileTag(
        _ row: MCPProjectProfileRecord, projectID: UUID, isDuplicated: Bool,
        sealingKey: SymmetricKey, previousKey: SymmetricKey?, decoder: JSONDecoder, db: Database
    ) -> Data? {
        guard !isDuplicated, let previousKey else { return nil }
        guard let redactedColumns = try? decoder.decode(
            [String].self, from: Data(row.redactedColumnsJSON.utf8)
        ) else { return nil }
        guard let profile = try? ConnectionProfile.fetchOne(db, key: row.profileID) else { return nil }
        let access = MCPProfileAccess(profileID: row.profileID, liveRead: row.liveRead, redactedColumns: redactedColumns)
        guard let payload = try? MCPAccessIntegrity.profilePayload(
            projectID: projectID, access: access, profile: profile
        ) else {
            return nil
        }
        guard MCPAccessIntegrity.isValid(row.integrityTag, payload: payload, key: previousKey) else { return nil }
        return MCPAccessIntegrity.tag(payload, key: sealingKey)
    }

    /// Deletes a project as a settings change: the project's rows go (its
    /// profile-access rows by cascade) and every other project's rows are
    /// re-sealed for the same key rotation `saveMCPProject` performs, with
    /// the same caller contract — read `previousKey` with
    /// `MCPAccessKeyStore.loadForRotation()`, store `sealingKey` with
    /// `replace(with:)`, then call this. Without the rotation, a copy of the
    /// deleted rows restored into the file would still carry tags that
    /// verify under the stored key and bring the project's live reads back.
    /// Rows of other projects that do not verify under `previousKey` are
    /// left untagged, exactly as in `saveMCPProject`.
    public func deleteMCPProject(id: UUID, sealingKey: SymmetricKey, previousKey: SymmetricKey?) throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        try write { db in
            _ = try MCPProjectRecord.deleteOne(db, key: id)
            try Self.reseal(
                otherThan: id, sealingKey: sealingKey, previousKey: previousKey,
                db: db, encoder: encoder, decoder: decoder
            )
        }
    }

    /// Loads a project and verifies its integrity tags. A missing key, a bad
    /// project tag, or a bad row tag never throws; it removes live reads,
    /// while schema/graph metadata (already readable from this file) stays
    /// available. Each profile row is verified from its own decoded fields,
    /// never from a same-profile-ID lookup elsewhere, so a duplicated or
    /// cross-wired row cannot borrow another row's payload: any profile ID
    /// that appears on more than one row is treated as tampered and rejected
    /// outright. A verified but disabled project always yields an empty
    /// `liveReadProfileIDs`.
    public func verifiedMCPProject(id: UUID, key: SymmetricKey?) throws -> MCPVerifiedProject? {
        try read { db in
            guard let record = try MCPProjectRecord.fetchOne(db, key: id) else { return nil }
            let project = try Self.makeMCPProject(record: record, db: db)

            guard let key else {
                return MCPVerifiedProject(project: project, liveReadProfileIDs: [], projectTagValid: false)
            }
            let projectPayload = try MCPAccessIntegrity.projectPayload(
                id: project.id, isEnabled: project.isEnabled, workspaceRoots: project.workspaceRoots
            )
            guard MCPAccessIntegrity.isValid(record.integrityTag, payload: projectPayload, key: key) else {
                return MCPVerifiedProject(project: project, liveReadProfileIDs: [], projectTagValid: false)
            }

            let rows = try MCPProjectProfileRecord.filter(Column("projectID") == id).fetchAll(db)
            let (verifiedLive, rejected) = try Self.verifiedProfileRows(projectID: id, rows: rows, key: key, db: db)
            let live = project.isEnabled ? verifiedLive : []
            return MCPVerifiedProject(project: project, liveReadProfileIDs: live, rejectedLiveReadProfileIDs: rejected)
        }
    }

    /// The only safe source for a `MCPProject` value passed back into
    /// `saveMCPProject`: `liveRead` is forced false on every profile that is
    /// not in `verifiedMCPProject(id:key:).liveReadProfileIDs`, and
    /// `isEnabled` is forced false when the project's own tag does not
    /// verify. One case is handled independently of `liveReadProfileIDs`:
    /// when the project tag verifies but the project is disabled,
    /// `verifiedMCPProject` reports an empty `liveReadProfileIDs` purely
    /// because it gates on `isEnabled` — using that set here would strip
    /// `liveRead` from every profile just because the project happened to be
    /// disabled at edit time. Instead, a disabled-but-verified project keeps
    /// each row's own tag-verified `liveRead`, so re-enabling and saving the
    /// editing copy restores exactly what was there before, no more and no
    /// less.
    ///
    /// `key` must be the currently stored key — the `previousKey` read with
    /// `MCPAccessKeyStore.loadForRotation()` before `replace(with:)` — never
    /// the new key about to be written: rows are sealed under the stored
    /// key, so any other key makes every row look unverified and the
    /// editing copy comes back disabled with every `liveRead` off.
    public func mcpProjectForEditing(id: UUID, key: SymmetricKey?) throws -> MCPProject? {
        try read { db in
            guard let record = try MCPProjectRecord.fetchOne(db, key: id) else { return nil }
            var project = try Self.makeMCPProject(record: record, db: db)

            let projectTagValid: Bool
            if let key {
                let projectPayload = try MCPAccessIntegrity.projectPayload(
                    id: project.id, isEnabled: project.isEnabled, workspaceRoots: project.workspaceRoots
                )
                projectTagValid = MCPAccessIntegrity.isValid(record.integrityTag, payload: projectPayload, key: key)
            } else {
                projectTagValid = false
            }

            guard projectTagValid, let key else {
                project.isEnabled = false
                for index in project.profiles.indices { project.profiles[index].liveRead = false }
                return project
            }

            let rows = try MCPProjectProfileRecord.filter(Column("projectID") == id).fetchAll(db)
            let (live, _) = try Self.verifiedProfileRows(projectID: id, rows: rows, key: key, db: db)
            for index in project.profiles.indices where !live.contains(project.profiles[index].profileID) {
                project.profiles[index].liveRead = false
            }
            return project
        }
    }

    /// Rows whose own decoded fields produce a tag that verifies under
    /// `key`, split into those with `liveRead` on (`live`) and those that
    /// claim `liveRead` but fail verification or share a duplicated profile
    /// ID (`rejected`). Deliberately does not apply the project's own
    /// `isEnabled` gate — `verifiedMCPProject` applies it afterward for its
    /// public `liveReadProfileIDs`, while `mcpProjectForEditing` needs the
    /// ungated result so editing a currently-disabled project does not
    /// discard a row's tag-verified `liveRead`. The payload is rebuilt with
    /// the endpoint of the profile row as it is now, so a row whose profile
    /// is missing, cannot be decoded, or was pointed at another endpoint
    /// since sealing is rejected.
    private static func verifiedProfileRows(
        projectID: UUID, rows: [MCPProjectProfileRecord], key: SymmetricKey, db: Database
    ) throws -> (live: Set<UUID>, rejected: Set<UUID>) {
        var occurrences: [UUID: Int] = [:]
        for row in rows { occurrences[row.profileID, default: 0] += 1 }

        let decoder = JSONDecoder()
        var live = Set<UUID>()
        var rejected = Set<UUID>()
        for row in rows where row.liveRead {
            guard occurrences[row.profileID] == 1 else {
                rejected.insert(row.profileID)
                continue
            }
            let redactedColumns = try decoder.decode([String].self, from: Data(row.redactedColumnsJSON.utf8))
            guard let profile = try? ConnectionProfile.fetchOne(db, key: row.profileID) else {
                rejected.insert(row.profileID)
                continue
            }
            let access = MCPProfileAccess(profileID: row.profileID, liveRead: row.liveRead, redactedColumns: redactedColumns)
            let payload = try MCPAccessIntegrity.profilePayload(projectID: projectID, access: access, profile: profile)
            guard MCPAccessIntegrity.isValid(row.integrityTag, payload: payload, key: key) else {
                rejected.insert(row.profileID)
                continue
            }
            live.insert(row.profileID)
        }
        return (live, rejected)
    }

    private static func makeMCPProject(record: MCPProjectRecord, db: Database) throws -> MCPProject {
        let decoder = JSONDecoder()
        let roots = try MCPProject.canonicalWorkspaceRoots(
            try decoder.decode([String].self, from: Data(record.workspaceRootsJSON.utf8))
        )
        let rows = try MCPProjectProfileRecord
            .filter(Column("projectID") == record.id)
            .fetchAll(db)
            .sorted { $0.profileID.uuidString.lowercased() < $1.profileID.uuidString.lowercased() }
        let profiles = try rows.map { row in
            MCPProfileAccess(
                profileID: row.profileID,
                liveRead: row.liveRead,
                redactedColumns: try decoder.decode([String].self, from: Data(row.redactedColumnsJSON.utf8))
            )
        }
        return MCPProject(
            id: record.id, name: record.name, isEnabled: record.isEnabled,
            workspaceRoots: roots, profiles: profiles,
            createdAt: record.createdAt, updatedAt: record.updatedAt
        )
    }

 // MARK: - Query history

 /// Cap per profile — rotation keeps the newest rows.
    public static let historyCapPerProfile = 10_000

    public func record(_ entry: QueryHistoryEntry) throws {
        try write { db in
            try entry.insert(db)
            // Rotate: delete oldest rows beyond the cap for this profile.
            try db.execute(
                sql: """
                DELETE FROM query_history WHERE id IN (
                    SELECT id FROM query_history
                    WHERE profileID IS ?
                    ORDER BY startedAt DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                arguments: [entry.profileID, Self.historyCapPerProfile]
            )
        }
    }

    /// Query history, newest first. DB-side search (`sql LIKE`) and keyset
    /// pagination on `(startedAt, id)` so the UI can page a large history and
 /// search the whole table, not just a client-side slice.
    public func history(
        profileID: UUID?,
        search: String? = nil,
        beforeStartedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 200
    ) throws -> [QueryHistoryEntry] {
        try read { db in
            var request = QueryHistoryEntry.all()
            if let profileID {
                request = request.filter(Column("profileID") == profileID)
            }
            if let search, !search.isEmpty {
                // Escape LIKE wildcards so a literal % / _ in the search matches itself.
                let escaped = search
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                request = request.filter(Column("sql").like("%\(escaped)%", escape: "\\"))
            }
            if let beforeStartedAt, let beforeID {
                request = request.filter(
                    Column("startedAt") < beforeStartedAt
                        || (Column("startedAt") == beforeStartedAt && Column("id") < beforeID)
                )
            }
            return try request
                .order(Column("startedAt").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func clearHistory() throws {
        _ = try write { db in
            try QueryHistoryEntry.deleteAll(db)
        }
    }

 // MARK: - Workspace action log

    /// Cap per profile — rotation keeps the newest rows, same pattern as
 /// query_history.
    public static let workspaceActionCapPerProfile = 50

    public func recordWorkspaceAction(_ entry: WorkspaceActionRecord) throws {
        try write { db in
            try entry.insert(db)
            try db.execute(
                sql: """
                DELETE FROM workspace_action WHERE id IN (
                    SELECT id FROM workspace_action
                    WHERE profileID IS ?
                    ORDER BY createdAt DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                arguments: [entry.profileID, Self.workspaceActionCapPerProfile]
            )
        }
    }

    /// Most recent actions for a profile, newest first.
    public func recentWorkspaceActions(profileID: UUID?, limit: Int = 50) throws -> [WorkspaceActionRecord] {
        try read { db in
            try WorkspaceActionRecord
                .filter(Column("profileID") == profileID)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

 // MARK: - Editor sessions

    public func saveEditorSession(_ record: EditorSessionRecord) throws {
        try write { db in
            try record.save(db)
        }
    }

    public func editorSessions(profileID: UUID?) throws -> [EditorSessionRecord] {
        try read { db in
            try EditorSessionRecord
                .filter(Column("profileID") == profileID)
                .order(Column("updatedAt").asc)
                .fetchAll(db)
        }
    }

    public func deleteEditorSession(id: UUID) throws {
        _ = try write { db in
            try EditorSessionRecord.deleteOne(db, key: id)
        }
    }

 // MARK: - Saved queries

    public func saveSavedQuery(_ query: SavedQuery) throws {
        try write { db in
            try query.save(db)
        }
    }

    /// Snippets visible from a connection: the profile's own plus all global
    /// (profileID IS NULL) ones, newest first. Pass nil for global-only.
    public func savedQueries(profileID: UUID?) throws -> [SavedQuery] {
        try read { db in
            if let profileID {
                return try SavedQuery
                    .filter(Column("profileID") == profileID || Column("profileID") == nil)
                    .order(Column("folder").asc, Column("updatedAt").desc)
                    .fetchAll(db)
            }
            return try SavedQuery
                .filter(Column("profileID") == nil)
                .order(Column("folder").asc, Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func deleteSavedQuery(id: UUID) throws {
        _ = try write { db in
            try SavedQuery.deleteOne(db, key: id)
        }
    }

 // MARK: - Artifacts

    public func saveArtifact(_ artifact: Artifact) throws {
        try write { db in
            try artifact.save(db)
        }
    }

    public func artifact(id: UUID) throws -> Artifact? {
        try read { db in
            try Artifact.fetchOne(db, key: id)
        }
    }

    public func artifacts(profileID: UUID) throws -> [Artifact] {
        try read { db in
            try Artifact
                .filter(Column("profileID") == profileID)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func deleteArtifact(id: UUID) throws {
        _ = try write { db in
            try ArtifactVersion.filter(Column("artifactID") == id).deleteAll(db)
            try Artifact.deleteOne(db, key: id)
        }
    }

    /// Appends the next version for `artifactID` (version numbers start at 1
    /// and increase monotonically) in one transaction, so concurrent runs on
    /// the same artifact can't race onto the same version number.
    @discardableResult
    public func appendArtifactVersion(
        artifactID: UUID, payload: String, resultSnapshotJSON: String? = nil
    ) throws -> ArtifactVersion {
        try write { db in
            let nextNumber = try (ArtifactVersion
                .filter(Column("artifactID") == artifactID)
                .select(max(Column("versionNumber")))
                .fetchOne(db) as Int?).map { $0 + 1 } ?? 1
            let version = ArtifactVersion(
                artifactID: artifactID, versionNumber: nextNumber,
                payload: payload, resultSnapshotJSON: resultSnapshotJSON
            )
            try version.save(db)
            return version
        }
    }

    public func artifactVersions(artifactID: UUID) throws -> [ArtifactVersion] {
        try read { db in
            try ArtifactVersion
                .filter(Column("artifactID") == artifactID)
                .order(Column("versionNumber").asc)
                .fetchAll(db)
        }
    }

    public func latestArtifactVersion(artifactID: UUID) throws -> ArtifactVersion? {
        try read { db in
            try ArtifactVersion
                .filter(Column("artifactID") == artifactID)
                .order(Column("versionNumber").desc)
                .fetchOne(db)
        }
    }

    /// A specific version by number, via the `(artifactID, versionNumber)`
    /// unique index — unlike `artifactVersions(artifactID:)`, doesn't pull
    /// every other version's `payload`/`resultSnapshotJSON` into memory just
    /// to discard them.
    public func artifactVersion(artifactID: UUID, versionNumber: Int) throws -> ArtifactVersion? {
        try read { db in
            try ArtifactVersion
                .filter(Column("artifactID") == artifactID && Column("versionNumber") == versionNumber)
                .fetchOne(db)
        }
    }

 // MARK: - Per-connection AI settings

    public func aiSetting(profileID: UUID) throws -> AIConnectionSetting? {
        try read { db in
            try AIConnectionSetting.fetchOne(db, key: profileID)
        }
    }

    public func saveAISetting(_ setting: AIConnectionSetting) throws {
        try write { db in
            try setting.save(db)
        }
    }

 // MARK: - Recommendation feedback

 /// Records the user's response to an insight.
    public func recordRecommendationFeedback(_ record: RecommendationFeedbackRecord) throws {
        try write { db in try record.insert(db) }
    }

    /// All feedback recorded for one insight on one profile, newest first.
    public func recommendationFeedback(profileID: UUID, insightID: String) throws -> [RecommendationFeedbackRecord] {
        try read { db in
            try RecommendationFeedbackRecord
                .filter(Column("profileID") == profileID && Column("insightID") == insightID)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

    /// Insight IDs the user has dismissed at least once on this profile — for down-ranking.
    public func dismissedInsightIDs(profileID: UUID) throws -> Set<String> {
        try read { db in
            let rows = try RecommendationFeedbackRecord
                .filter(Column("profileID") == profileID && Column("action") == RecommendationAction.dismissed.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.insightID))
        }
    }

 // MARK: - Query replay

 /// Saves a user-requested execution snapshot.
    public func saveQueryReplaySnapshot(_ record: QueryReplaySnapshotRecord) throws {
        try write { db in try record.insert(db) }
    }

    /// Snapshots of the same query on this profile, newest first — the
    /// replay comparison's input (`QueryReplayComparator`, module BerryGraph).
    public func queryReplaySnapshots(profileID: UUID, queryHash: String) throws -> [QueryReplaySnapshotRecord] {
        try read { db in
            try QueryReplaySnapshotRecord
                .filter(Column("profileID") == profileID && Column("queryHash") == queryHash)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

 // MARK: - Daily review digest

 /// Saves a generated daily review digest.
    public func saveDailyReview(_ record: DailyReviewRecord) throws {
        try write { db in try record.insert(db) }
    }

    /// The most recent digest for this profile, or nil if none exists yet.
    public func latestDailyReview(profileID: UUID) throws -> DailyReviewRecord? {
        try read { db in
            try DailyReviewRecord
                .filter(Column("profileID") == profileID)
                .order(Column("generatedAt").desc)
                .fetchOne(db)
        }
    }

 // MARK: - Schema snapshots (seed)

    /// Stores a snapshot unless the latest one for this profile already has
    /// the same digest (no schema change → no growth).
    public func recordSnapshotIfChanged(_ snapshot: SchemaSnapshotRecord) throws {
        try write { db in
            let latestDigest = try String.fetchOne(
                db,
                sql: """
                SELECT digest FROM schema_snapshot
                WHERE profileID IS ?
                ORDER BY takenAt DESC LIMIT 1
                """,
                arguments: [snapshot.profileID]
            )
            guard latestDigest != snapshot.digest else { return }
            try snapshot.insert(db)
        }
    }

    public func snapshots(profileID: UUID?, limit: Int = 100) throws -> [SchemaSnapshotRecord] {
        try read { db in
            try SchemaSnapshotRecord
                .filter(Column("profileID") == profileID)
                .order(Column("takenAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

 // MARK: - Runtime metrics

 /// Saves a batch of runtime metrics from one harvest pass.
    public func saveRuntimeMetrics(_ records: [RuntimeMetricRecord]) throws {
        try write { db in
            for record in records { try record.insert(db) }
        }
    }

    /// Recent values of one metric for this profile, newest first.
    public func runtimeMetrics(profileID: UUID, metric: String, limit: Int = 100) throws -> [RuntimeMetricRecord] {
        try read { db in
            try RuntimeMetricRecord
                .filter(Column("profileID") == profileID && Column("metric") == metric)
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

 // MARK: - AI chat history (Q17)

    public func saveAIThread(_ thread: AIThreadRecord) throws {
        try write { db in try thread.save(db) }
    }

    /// All local threads, most recently updated first. `connectionKey` scopes
 /// to one connection's history (v28) — always applied (nil matches
    /// only pre-v28/profileless threads, via SQL's `IS NULL`), so two
    /// connections sharing a dialect never see each other's threads.
    public func aiThreads(dialect: String? = nil, connectionKey: String? = nil) throws -> [AIThreadRecord] {
        try read { db in
            var request = AIThreadRecord.order(Column("updatedAt").desc)
                .filter(Column("connectionKey") == connectionKey)
            if let dialect { request = request.filter(Column("dialect") == dialect) }
            return try request.fetchAll(db)
        }
    }

    public func aiThread(id: UUID) throws -> AIThreadRecord? {
        try read { db in try AIThreadRecord.fetchOne(db, key: id) }
    }

    /// Deletes the thread and everything scoped to it — messages and their
    /// embeddings. No FK cascade (the embeddings live in a vec0 virtual
    /// table, which doesn't support foreign keys), so this deletes explicitly
    /// in dependency order, same as the old backend's delete_ai_thread.
    public func deleteAIThread(id: UUID) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM ai_pending_interaction WHERE threadID = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM ai_pending_report_draft WHERE threadID = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM ai_message_embedding WHERE messageKey LIKE ?", arguments: ["\(id.uuidString)#%"])
            try db.execute(sql: "DELETE FROM ai_message WHERE threadID = ?", arguments: [id])
            _ = try AIThreadRecord.deleteOne(db, key: id)
        }
    }

    public func appendAIMessage(_ message: AIMessageRecord) throws {
        try write { db in try message.insert(db) }
    }

    /// A thread's messages in conversation order.
    public func aiMessages(threadID: UUID) throws -> [AIMessageRecord] {
        try read { db in
            try AIMessageRecord
                .filter(Column("threadID") == threadID)
                .order(Column("seq").asc)
                .fetchAll(db)
        }
    }

    // Async counterparts of the four methods above, used on `AISession`'s
 // `@MainActor` send path (perf plan, item A2) so a turn's
    // SQLite reads/writes run off the main thread instead of blocking UI
    // during every send. New methods rather than overloads — GRDB's own
    // sync/async overload pair needed `@_disfavoredOverload` to disambiguate,
    // which isn't available to this module's simpler call sites.

    public func saveAIThreadAsync(_ thread: AIThreadRecord) async throws {
        try await write { db in try thread.save(db) }
    }

    public func aiThreadAsync(id: UUID) async throws -> AIThreadRecord? {
        try await read { db in try AIThreadRecord.fetchOne(db, key: id) }
    }

    public func appendAIMessageAsync(_ message: AIMessageRecord) async throws {
        try await write { db in try message.insert(db) }
    }

    public func aiMessagesAsync(threadID: UUID) async throws -> [AIMessageRecord] {
        try await read { db in
            try AIMessageRecord
                .filter(Column("threadID") == threadID)
                .order(Column("seq").asc)
                .fetchAll(db)
        }
    }

    /// The most recent `limit` non-interaction messages, oldest first — bounded
    /// at the SQL level so a long-lived thread's full history is never fetched
    /// just to read its tail (used by `AISession.buildContext`, which needs
    /// only a fixed-size recent window regardless of thread length). Not a
    /// general-purpose replacement for `aiMessagesAsync(threadID:)`: callers
    /// that need the true total count (e.g. seq assignment) or the full
    /// transcript (opening a thread) must keep using that method.
    public func aiRecentMessagesAsync(threadID: UUID, limit: Int) async throws -> [AIMessageRecord] {
        try await read { db in
            let rows = try AIMessageRecord
                .filter(Column("threadID") == threadID)
                .filter(Column("toolCalls") == nil || Column("toolCalls") != "local:interaction")
                .order(Column("seq").desc)
                .limit(limit)
                .fetchAll(db)
            return rows.reversed()
        }
    }

    /// Non-interaction messages strictly after `sinceSeq`, oldest first —
    /// bounded at the SQL level to just the unsummarized tail instead of the
    /// whole thread (used by `AISession.buildContext` once a rolling-summary
    /// cursor exists, so a long-lived thread's already-folded prefix is never
    /// re-fetched turn after turn).
    public func aiMessagesAsync(threadID: UUID, sinceSeq: Int) async throws -> [AIMessageRecord] {
        try await read { db in
            try AIMessageRecord
                .filter(Column("threadID") == threadID && Column("seq") > sinceSeq)
                .filter(Column("toolCalls") == nil || Column("toolCalls") != "local:interaction")
                .order(Column("seq").asc)
                .fetchAll(db)
        }
    }

 // MARK: -: active-path message tree (editing/versioning)
    //
    // `ai_message.parentID` (v29) forms a tree — editing a message inserts a
    // sibling rather than deleting anything, so the old reply stays
    // reachable. `ai_thread.activeLeafMessageID` is the current tip; walking
    // `parentID` from there back to nil is "the conversation as currently
    // shown". Every reader that needs that (opening a thread, search,
    // context-building) must use one of these instead of the flat
    // `aiMessages*` methods above, or an edited-away message can resurface.

    /// Walks `parentID` from `leafID` back to nil, root-first — ONE indexed
    /// `WHERE threadID = ?` fetch (same cost as the old flat `aiMessages`
    /// query) followed by an in-memory dictionary walk, not N sequential
    /// point-lookup queries: a first version did exactly that (simplest to
    /// write) and was measurably slow enough on a 200-message thread to
    /// blow through a test's fixed retry budget — every point-lookup is a
    /// full GRDB/SQLite round trip, and `buildContext` calls into this on
 /// every single turn (perf plan — the same "O(n) work
    /// that compounds" class of bug that plan already fixed once here).
    private func walkActivePath(db: Database, threadID: UUID, leafID: UUID?) throws -> [AIMessageRecord] {
        guard leafID != nil else { return [] }
        let all = try AIMessageRecord.filter(Column("threadID") == threadID).fetchAll(db)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var chain: [AIMessageRecord] = []
        var cursor = leafID
        while let id = cursor, let message = byID[id] {
            chain.append(message)
            cursor = message.parentID
        }
        return chain.reversed()
    }

    /// The active transcript for a thread, root to `activeLeafMessageID` —
    /// the branch-aware replacement for `aiMessages(threadID:)`.
    public func activeAIMessages(threadID: UUID) throws -> [AIMessageRecord] {
        try read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            return try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
        }
    }

    public func activeAIMessagesAsync(threadID: UUID) async throws -> [AIMessageRecord] {
        try await read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            return try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
        }
    }

    /// Branch-aware replacement for `aiRecentMessagesAsync` — the last
    /// `limit` non-interaction messages on the ACTIVE path, oldest first.
    public func activeAIRecentMessagesAsync(threadID: UUID, limit: Int) async throws -> [AIMessageRecord] {
        try await read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            let path = try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
            let nonInteraction = path.filter { $0.toolCalls != "local:interaction" }
            return Array(nonInteraction.suffix(limit))
        }
    }

    /// Branch-aware replacement for `aiMessagesAsync(threadID:sinceSeq:)` —
    /// non-interaction messages strictly after `sinceSeq`, ACTIVE path only.
    public func activeAIMessagesAsync(threadID: UUID, sinceSeq: Int) async throws -> [AIMessageRecord] {
        try await read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            let path = try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
            return path.filter { $0.seq > sinceSeq && $0.toolCalls != "local:interaction" }
        }
    }

    public func aiMessage(id: UUID) throws -> AIMessageRecord? {
        try read { db in try AIMessageRecord.fetchOne(db, key: id) }
    }

    /// Retargets a thread's active tip — used both when a normal turn
    /// finishes (advance to the newly-appended assistant reply) and when
    /// editing/switching versions (jump elsewhere in the tree).
    public func setActiveLeafMessage(threadID: UUID, messageID: UUID?) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE ai_thread SET activeLeafMessageID = ? WHERE id = ?",
                arguments: [messageID, threadID]
            )
        }
    }

    /// Follows the most-recently-created child repeatedly until a message
    /// with no children is reached — switching to a version always lands on
    /// that version's own latest content, not necessarily its first reply.
    public func resolveTip(threadID: UUID, from messageID: UUID) throws -> UUID {
        try read { db in
            var current = messageID
            while let child = try AIMessageRecord
                .filter(Column("threadID") == threadID && Column("parentID") == current)
                .order(Column("createdAt").desc)
                .fetchOne(db)
            {
                current = child.id
            }
            return current
        }
    }

    /// Every user-message fork point in a thread: parentID -> sibling
    /// message ids sharing it, oldest first (creation order = version 1, 2,
    /// 3, ...). `nil` is a valid key — versions of the thread's very first
    /// message all share a nil `parentID`. A caller checks its own message's
    /// `parentID` against this map and shows nav only when the group has
    /// more than one entry.
    public func siblingGroups(threadID: UUID) throws -> [UUID?: [UUID]] {
        try read { db in
            let rows = try AIMessageRecord
                .filter(Column("threadID") == threadID && Column("role") == "user")
                .order(Column("createdAt").asc)
                .fetchAll(db)
            var groups: [UUID?: [UUID]] = [:]
            for row in rows {
                groups[row.parentID, default: []].append(row.id)
            }
            return groups
        }
    }

    // MARK: - Pending AI control interactions

    public func savePendingAIInteraction(
        _ interaction: AIPendingInteractionRecord
    ) throws {
        try write { db in try interaction.save(db) }
    }

    public func pendingAIInteraction(
        threadID: UUID
    ) throws -> AIPendingInteractionRecord? {
        try read { db in
            try AIPendingInteractionRecord
                .filter(Column("threadID") == threadID)
                .fetchOne(db)
        }
    }

    @discardableResult
    public func markPendingAIInteractionResolving(
        id: String,
        action: String,
        responseText: String,
        clientRequestID: String,
        requestDigest: String
    ) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                UPDATE ai_pending_interaction
                SET state = 'resolving', selectedAction = ?,
                    responseText = ?, clientRequestID = ?, requestDigest = ?
                WHERE id = ?
                """,
                arguments: [
                    action, responseText, clientRequestID, requestDigest, id,
                ]
            )
            return db.changesCount == 1
        }
    }

    public func resetPendingAIInteraction(id: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE ai_pending_interaction
                SET state = 'pending'
                WHERE id = ?
                """,
                arguments: [id]
            )
        }
    }

    @discardableResult
    public func deletePendingAIInteraction(id: String) throws -> Bool {
        try write { db in
            try AIPendingInteractionRecord.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func deleteExpiredPendingAIInteractions(
        nowUnix: Int64
    ) throws -> Int {
        try write { db in
            try AIPendingInteractionRecord
                .filter(Column("expiresAtUnix") <= nowUnix)
                .deleteAll(db)
        }
    }

    // MARK: - Pending report draft (Task 4.1 pre-refinement consent gate)

    public func savePendingReportDraft(_ draft: AIPendingReportDraftRecord) throws {
        try write { db in try draft.save(db) }
    }

    public func pendingReportDraft(threadID: UUID) throws -> AIPendingReportDraftRecord? {
        try read { db in try AIPendingReportDraftRecord.fetchOne(db, key: threadID) }
    }

    @discardableResult
    public func deletePendingReportDraft(threadID: UUID) throws -> Bool {
        try write { db in try AIPendingReportDraftRecord.deleteOne(db, key: threadID) }
    }

    /// sqlite-vec dimension fixed by migration v17 and the configured
    /// text-embedding-3-small contract.
    public static let aiMessageEmbeddingDimension = 1536

    /// Stores/replaces the embedding for one message, keyed by
    /// "threadID#seq" in the vec0 virtual table (no composite-key support
    /// for declared vec0 primary keys, so the pair is encoded as one string).
    public func saveAIMessageEmbedding(threadID: UUID, seq: Int, vector: [Float]) throws {
        guard vector.count == Self.aiMessageEmbeddingDimension else {
            throw DatabaseError(
                resultCode: .SQLITE_MISMATCH,
                message: "AI message embedding must contain \(Self.aiMessageEmbeddingDimension) values"
            )
        }
        let key = "\(threadID.uuidString)#\(seq)"
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO ai_message_embedding(messageKey, embedding) VALUES (?, ?)",
                arguments: [key, blob]
            )
        }
    }

    /// Atomically saves an embedding only while its source message still
    /// exists. This closes the race between a best-effort background embed
    /// request and deleting the conversation before that request finishes.
    @discardableResult
    public func saveAIMessageEmbeddingIfMessageExists(
        threadID: UUID, seq: Int, vector: [Float]
    ) throws -> Bool {
        guard vector.count == Self.aiMessageEmbeddingDimension else { return false }
        let key = "\(threadID.uuidString)#\(seq)"
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        return try write { db in
            let exists = try AIMessageRecord
                .filter(Column("threadID") == threadID && Column("seq") == seq)
                .fetchCount(db) > 0
            guard exists else { return false }
            try db.execute(
                sql: "INSERT OR REPLACE INTO ai_message_embedding(messageKey, embedding) VALUES (?, ?)",
                arguments: [key, blob]
            )
            return true
        }
    }

    /// Messages without a persisted vector, optionally restricted to
    /// sequences before `beforeSeq` (the summarized-away portion of a thread).
    public func aiMessagesMissingEmbeddings(
        threadID: UUID, beforeSeq: Int? = nil
    ) throws -> [AIMessageRecord] {
 // active-path only — an edited-away message has nothing left
        // worth embedding, and would otherwise sit here forever re-offering
        // itself as "missing" every time the background backfill runs.
        let messages = try activeAIMessages(threadID: threadID)
        let prefix = "\(threadID.uuidString)#"
        let embedded: Set<Int> = try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT messageKey FROM ai_message_embedding WHERE messageKey LIKE ?",
                arguments: ["\(prefix)%"]
            )
            return Set(rows.compactMap { row in
                let key: String = row["messageKey"]
                guard key.hasPrefix(prefix) else { return nil }
                return Int(key.dropFirst(prefix.count))
            })
        }
        return messages.filter { message in
            !embedded.contains(message.seq) && beforeSeq.map { message.seq < $0 } ?? true
        }
    }

    /// Cosine-nearest messages in `threadID` to `queryVector` (search_conversation,
 /// nearest first. vec0 has no per-thread
    /// partition index here, so this over-fetches a generous global top-K and
    /// filters/truncates to the thread client-side — correct at the message
    /// volumes a single local user accumulates, not meant to scale beyond that.
    public func nearestAIMessages(
        threadID: UUID, to queryVector: [Float], limit: Int = 8,
        beforeSeq: Int? = nil
    ) throws -> [(seq: Int, distance: Double)] {
        guard queryVector.count == Self.aiMessageEmbeddingDimension else { return [] }
        let blob = queryVector.withUnsafeBufferPointer { Data(buffer: $0) }
        let prefix = "\(threadID.uuidString)#"
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT messageKey, distance FROM ai_message_embedding WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                arguments: [blob, 256]
            )
            return rows.compactMap { row -> (seq: Int, distance: Double)? in
                let key: String = row["messageKey"]
                guard key.hasPrefix(prefix), let seq = Int(key.dropFirst(prefix.count)) else { return nil }
                if let beforeSeq, seq >= beforeSeq { return nil }
                return (seq: seq, distance: row["distance"])
            }
            .prefix(limit)
            .map { $0 }
        }
    }

    /// sqlite-vec dimension fixed by migration v22, same
    /// text-embedding-3-small contract as `aiMessageEmbeddingDimension`.
    public static let schemaObjectEmbeddingDimension = 1536

    /// Stores the vector for the object `id` and clears its queue flag, in one
    /// transaction, unless that row has been closed in the meantime. A drain
    /// reads the queue, then waits on the provider, and the object can be
    /// removed during the wait; writing its vector afterwards would leave one
    /// that nothing deletes. Returns false, writing nothing, for a closed row.
    public func storeSchemaEmbedding(id: Int64, profileID: UUID, name: String, vector: [Float]) throws -> Bool {
        let blob = try Self.embeddingBlob(vector)
        return try write { db in
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM schema_object WHERE id = ? AND removedAt IS NULL)", arguments: [id]
            ) == true else { return false }
            try Self.replaceSchemaEmbedding(db, profileID: profileID, name: name, blob: blob)
            try db.execute(sql: "UPDATE schema_object SET needsEmbedding = 0 WHERE id = ?", arguments: [id])
            return true
        }
    }

    /// Of `names`, in their order and each once, at most `limit` that have no
    /// vector in the profile's partition; a vector is keyed by the name alone,
    /// so a name listed in two schemas has one. Nothing reads a vector:
    /// sqlite-vec 0.1.9 keeps a
    /// text primary key in the `<table>_rowids` shadow table under a UNIQUE
    /// constraint (`VEC0_SHADOW_ROWIDS_CREATE_PK_TEXT` in the vendored
    /// `sqlite-vec.c`), and each name is one lookup in that index. A lookup
    /// through the vec0 table itself also reads the 6 KB vector of every name
    /// it finds (`vec0Filter_point` there).
    public func schemaNamesWithoutEmbedding(profileID: UUID, among names: [String], limit: Int) throws -> [String] {
        guard !names.isEmpty, limit > 0 else { return [] }
        var seen = Set<String>()
        let distinct = names.filter { seen.insert($0).inserted }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: distinct), as: UTF8.self)
        return try read { db in
            try String.fetchAll(db, sql: """
                SELECT value FROM json_each(?)
                WHERE NOT EXISTS (SELECT 1 FROM schema_object_embedding_rowids WHERE id = ? || value)
                ORDER BY key LIMIT ?
                """, arguments: [json, "\(profileID.uuidString)#", limit])
        }
    }

    /// Stores the vector of a name that a search embedded itself, and takes
    /// the profile's current objects of that name off the embedding queue so
    /// the drain does not send the name again. The name need not be stored
    /// as an object: a search embeds the names the sidebar lists, which a
    /// harvest may never have listed. Such a vector is deleted with the
    /// profile; a search keeps only names it is given, so one left by a
    /// dropped table is never returned.
    public func storeSchemaNameEmbedding(profileID: UUID, name: String, vector: [Float]) throws {
        let blob = try Self.embeddingBlob(vector)
        try write { db in
            try Self.replaceSchemaEmbedding(db, profileID: profileID, name: name, blob: blob)
            // The queue's partial index holds only flagged rows; without it
            // SQLite walks the profile's whole history for every name.
            try db.execute(sql: """
                UPDATE schema_object INDEXED BY schema_object_embedding_queue SET needsEmbedding = 0
                WHERE profileID = ? AND needsEmbedding = 1 AND removedAt IS NULL AND name = ?
                """, arguments: [profileID, name])
        }
    }

    private static func embeddingBlob(_ vector: [Float]) throws -> Data {
        guard vector.count == schemaObjectEmbeddingDimension else {
            throw DatabaseError(
                resultCode: .SQLITE_MISMATCH,
                message: "Schema object embedding must contain \(schemaObjectEmbeddingDimension) values"
            )
        }
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The vector of one table or view name, keyed by "profileID#name" in the
    /// vec0 virtual table, which has no composite key for a declared primary
    /// key, and partitioned by the profile so a nearest-name query reads only
    /// that profile's vectors. A name that already has a vector is deleted
    /// first: vec0 rejects `INSERT OR REPLACE` on an existing key with a
    /// UNIQUE constraint error (verified against sqlite-vec 0.1.9), and a
    /// dropped and re-created table is embedded again under the same key.
    private static func replaceSchemaEmbedding(_ db: Database, profileID: UUID, name: String, blob: Data) throws {
        let key = "\(profileID.uuidString)#\(name)"
        try db.execute(sql: "DELETE FROM schema_object_embedding WHERE objectKey = ?", arguments: [key])
        try db.execute(
            sql: "INSERT INTO schema_object_embedding(objectKey, profileID, embedding) VALUES (?, ?, ?)",
            arguments: [key, profileID.uuidString, blob]
        )
    }

    /// The table/collection names in this profile nearest to `queryVector`
    /// (search_schema), nearest first. The KNN query is constrained to the
    /// profile's partition, so another connection's vectors cannot crowd this
    /// one's out of the first `limit` results.
    public func nearestSchemaObjects(
        profileID: UUID, to queryVector: [Float], limit: Int = 8
    ) throws -> [(name: String, distance: Double)] {
        guard queryVector.count == Self.schemaObjectEmbeddingDimension, limit > 0 else { return [] }
        let blob = queryVector.withUnsafeBufferPointer { Data(buffer: $0) }
        let prefix = "\(profileID.uuidString)#"
        // vec0 fails a query whose `k` exceeds 4096 (SQLITE_VEC_VEC0_K_MAX in the
        // vendored sqlite-vec 0.1.9); `k` itself is documented at
        // https://alexgarcia.xyz/sqlite-vec/features/knn.html.
        let k = min(limit, 4096)
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT objectKey, distance FROM schema_object_embedding WHERE embedding MATCH ? AND k = ? AND profileID = ? ORDER BY distance",
                arguments: [blob, k, profileID.uuidString]
            )
            return rows.map { row in
                let key: String = row["objectKey"]
                return (name: String(key.dropFirst(prefix.count)), distance: row["distance"])
            }
        }
    }
}
