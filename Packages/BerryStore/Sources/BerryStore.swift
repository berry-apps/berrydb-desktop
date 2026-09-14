import Foundation
import GRDB

/// Local persistence:
/// `~/Library/Application Support/BerryDB/store.sqlite`.
/// Versioned migrations; backup logic added at the first schema change.
public final class BerryStore: Sendable {
    private let dbQueue: DatabaseQueue

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

    /// Store at an arbitrary path — used for tests (`:memory:`).
    public init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try SQLiteVecExtension.install(into: db)
        }
        dbQueue = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrator.migrate(dbQueue)
    }

    /// Test-only: wraps an already-prepared `DatabaseQueue` as-is, running no
    /// migration. Lets a migration test build a pre-v29 database, seed data,
    /// migrate it partway or fully with `BerryStore.migrator` directly, then
    /// exercise `BerryStore`'s own methods against the result.
    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
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
        return migrator
    }

 // MARK: - Connection profiles

    public func allProfiles() throws -> [ConnectionProfile] {
        try dbQueue.read { db in
            try ConnectionProfile
                .order(Column("sortOrder").asc, Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func save(_ profile: ConnectionProfile) throws {
        try dbQueue.write { db in
            try profile.save(db)
        }
    }

 /// Delete a profile — the caller MUST also delete the Keychain item.
    /// The key must be the UUID itself: GRDB stores UUID as a 16-byte blob,
    /// so a uuidString key would never match.
    public func deleteProfile(id: UUID) throws {
        _ = try dbQueue.write { db in
            try ConnectionProfile.deleteOne(db, key: id)
        }
    }

 // MARK: - Query history

 /// Cap per profile — rotation keeps the newest rows.
    public static let historyCapPerProfile = 10_000

    public func record(_ entry: QueryHistoryEntry) throws {
        try dbQueue.write { db in
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
        try dbQueue.read { db in
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
        _ = try dbQueue.write { db in
            try QueryHistoryEntry.deleteAll(db)
        }
    }

 // MARK: - Workspace action log

    /// Cap per profile — rotation keeps the newest rows, same pattern as
 /// query_history.
    public static let workspaceActionCapPerProfile = 50

    public func recordWorkspaceAction(_ entry: WorkspaceActionRecord) throws {
        try dbQueue.write { db in
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
        try dbQueue.read { db in
            try WorkspaceActionRecord
                .filter(Column("profileID") == profileID)
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

 // MARK: - Editor sessions

    public func saveEditorSession(_ record: EditorSessionRecord) throws {
        try dbQueue.write { db in
            try record.save(db)
        }
    }

    public func editorSessions(profileID: UUID?) throws -> [EditorSessionRecord] {
        try dbQueue.read { db in
            try EditorSessionRecord
                .filter(Column("profileID") == profileID)
                .order(Column("updatedAt").asc)
                .fetchAll(db)
        }
    }

    public func deleteEditorSession(id: UUID) throws {
        _ = try dbQueue.write { db in
            try EditorSessionRecord.deleteOne(db, key: id)
        }
    }

 // MARK: - Saved queries

    public func saveSavedQuery(_ query: SavedQuery) throws {
        try dbQueue.write { db in
            try query.save(db)
        }
    }

    /// Snippets visible from a connection: the profile's own plus all global
    /// (profileID IS NULL) ones, newest first. Pass nil for global-only.
    public func savedQueries(profileID: UUID?) throws -> [SavedQuery] {
        try dbQueue.read { db in
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
        _ = try dbQueue.write { db in
            try SavedQuery.deleteOne(db, key: id)
        }
    }

 // MARK: - Artifacts

    public func saveArtifact(_ artifact: Artifact) throws {
        try dbQueue.write { db in
            try artifact.save(db)
        }
    }

    public func artifact(id: UUID) throws -> Artifact? {
        try dbQueue.read { db in
            try Artifact.fetchOne(db, key: id)
        }
    }

    public func artifacts(profileID: UUID) throws -> [Artifact] {
        try dbQueue.read { db in
            try Artifact
                .filter(Column("profileID") == profileID)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    public func deleteArtifact(id: UUID) throws {
        _ = try dbQueue.write { db in
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
        try dbQueue.write { db in
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
        try dbQueue.read { db in
            try ArtifactVersion
                .filter(Column("artifactID") == artifactID)
                .order(Column("versionNumber").asc)
                .fetchAll(db)
        }
    }

    public func latestArtifactVersion(artifactID: UUID) throws -> ArtifactVersion? {
        try dbQueue.read { db in
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
        try dbQueue.read { db in
            try ArtifactVersion
                .filter(Column("artifactID") == artifactID && Column("versionNumber") == versionNumber)
                .fetchOne(db)
        }
    }

 // MARK: - Per-connection AI settings

    public func aiSetting(profileID: UUID) throws -> AIConnectionSetting? {
        try dbQueue.read { db in
            try AIConnectionSetting.fetchOne(db, key: profileID)
        }
    }

    public func saveAISetting(_ setting: AIConnectionSetting) throws {
        try dbQueue.write { db in
            try setting.save(db)
        }
    }

 // MARK: - Database Intelligence graph

    /// Upserts a profile's graph elements (preserving each element's `firstSeen`)
    /// and records a snapshot. Absent elements are NOT deleted — their stale
    /// `lastSeen` marks when they disappeared, which is how the Digital Twin
 /// reconstructs the graph as-of an earlier time.
    public func saveGraph(
        profileID: UUID,
        nodes: [GraphNodeRecord],
        edges: [GraphEdgeRecord],
        takenAt: Date,
        digest: String
    ) throws {
        try dbQueue.write { db in
            for node in nodes {
                try db.execute(sql: """
                    INSERT INTO graph_node (profileID, nodeID, kind, name, database, attrs, firstSeen, lastSeen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profileID, nodeID) DO UPDATE SET
                        kind = excluded.kind, name = excluded.name, database = excluded.database,
                        attrs = excluded.attrs, lastSeen = excluded.lastSeen
                    """, arguments: [node.profileID, node.nodeID, node.kind, node.name,
                                     node.database, node.attrs, node.firstSeen, node.lastSeen])
            }
            for edge in edges {
                try db.execute(sql: """
                    INSERT INTO graph_edge (profileID, src, dst, kind, weight, attrs, firstSeen, lastSeen)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profileID, src, dst, kind) DO UPDATE SET
                        weight = excluded.weight, attrs = excluded.attrs, lastSeen = excluded.lastSeen
                    """, arguments: [edge.profileID, edge.src, edge.dst, edge.kind,
                                     edge.weight, edge.attrs, edge.firstSeen, edge.lastSeen])
            }
            // Dedup by digest: only record a snapshot when the structure
            // changed, so frequent harvest-on-refresh doesn't bloat the Digital
 // Twin timeline. Node/edge lastSeen/attrs
            // were still upserted above, so stats stay fresh.
            let latestDigest = try GraphSnapshotRecord
                .filter(Column("profileID") == profileID)
                .order(Column("takenAt").desc)
                .fetchOne(db)?.digest
            if latestDigest != digest {
                try GraphSnapshotRecord(
                    profileID: profileID, takenAt: takenAt,
                    nodeCount: nodes.count, edgeCount: edges.count, digest: digest
                ).insert(db)
            }
        }
    }

    /// Graph elements present at `asOf` (firstSeen ≤ asOf ≤ lastSeen).
    public func graphNodes(profileID: UUID, asOf: Date) throws -> [GraphNodeRecord] {
        try dbQueue.read { db in
            try GraphNodeRecord
                .filter(Column("profileID") == profileID)
                .filter(Column("firstSeen") <= asOf && Column("lastSeen") >= asOf)
                .fetchAll(db)
        }
    }

    public func graphEdges(profileID: UUID, asOf: Date) throws -> [GraphEdgeRecord] {
        try dbQueue.read { db in
            try GraphEdgeRecord
                .filter(Column("profileID") == profileID)
                .filter(Column("firstSeen") <= asOf && Column("lastSeen") >= asOf)
                .fetchAll(db)
        }
    }

    public func latestGraphSnapshot(profileID: UUID) throws -> GraphSnapshotRecord? {
        try dbQueue.read { db in
            try GraphSnapshotRecord
                .filter(Column("profileID") == profileID)
                .order(Column("takenAt").desc)
                .fetchOne(db)
        }
    }

 /// Snapshot metadata for a profile, newest first (time-travel picker).
    public func graphSnapshots(profileID: UUID) throws -> [GraphSnapshotRecord] {
        try dbQueue.read { db in
            try GraphSnapshotRecord
                .filter(Column("profileID") == profileID)
                .order(Column("takenAt").desc)
                .fetchAll(db)
        }
    }

 // MARK: - Recommendation feedback

 /// Records the user's response to an insight.
    public func recordRecommendationFeedback(_ record: RecommendationFeedbackRecord) throws {
        try dbQueue.write { db in try record.insert(db) }
    }

    /// All feedback recorded for one insight on one profile, newest first.
    public func recommendationFeedback(profileID: UUID, insightID: String) throws -> [RecommendationFeedbackRecord] {
        try dbQueue.read { db in
            try RecommendationFeedbackRecord
                .filter(Column("profileID") == profileID && Column("insightID") == insightID)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

    /// Insight IDs the user has dismissed at least once on this profile — for down-ranking.
    public func dismissedInsightIDs(profileID: UUID) throws -> Set<String> {
        try dbQueue.read { db in
            let rows = try RecommendationFeedbackRecord
                .filter(Column("profileID") == profileID && Column("action") == RecommendationAction.dismissed.rawValue)
                .fetchAll(db)
            return Set(rows.map(\.insightID))
        }
    }

 // MARK: - Query replay

 /// Saves a user-requested execution snapshot.
    public func saveQueryReplaySnapshot(_ record: QueryReplaySnapshotRecord) throws {
        try dbQueue.write { db in try record.insert(db) }
    }

    /// Snapshots of the same query on this profile, newest first — the
    /// replay comparison's input (`QueryReplayComparator`, module BerryGraph).
    public func queryReplaySnapshots(profileID: UUID, queryHash: String) throws -> [QueryReplaySnapshotRecord] {
        try dbQueue.read { db in
            try QueryReplaySnapshotRecord
                .filter(Column("profileID") == profileID && Column("queryHash") == queryHash)
                .order(Column("ts").desc)
                .fetchAll(db)
        }
    }

 // MARK: - Daily review digest

 /// Saves a generated daily review digest.
    public func saveDailyReview(_ record: DailyReviewRecord) throws {
        try dbQueue.write { db in try record.insert(db) }
    }

    /// The most recent digest for this profile, or nil if none exists yet.
    public func latestDailyReview(profileID: UUID) throws -> DailyReviewRecord? {
        try dbQueue.read { db in
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
        try dbQueue.write { db in
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
        try dbQueue.read { db in
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
        try dbQueue.write { db in
            for record in records { try record.insert(db) }
        }
    }

    /// Recent values of one metric for this profile, newest first.
    public func runtimeMetrics(profileID: UUID, metric: String, limit: Int = 100) throws -> [RuntimeMetricRecord] {
        try dbQueue.read { db in
            try RuntimeMetricRecord
                .filter(Column("profileID") == profileID && Column("metric") == metric)
                .order(Column("ts").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

 // MARK: - AI chat history (Q17)

    public func saveAIThread(_ thread: AIThreadRecord) throws {
        try dbQueue.write { db in try thread.save(db) }
    }

    /// All local threads, most recently updated first. `connectionKey` scopes
 /// to one connection's history (v28) — always applied (nil matches
    /// only pre-v28/profileless threads, via SQL's `IS NULL`), so two
    /// connections sharing a dialect never see each other's threads.
    public func aiThreads(dialect: String? = nil, connectionKey: String? = nil) throws -> [AIThreadRecord] {
        try dbQueue.read { db in
            var request = AIThreadRecord.order(Column("updatedAt").desc)
                .filter(Column("connectionKey") == connectionKey)
            if let dialect { request = request.filter(Column("dialect") == dialect) }
            return try request.fetchAll(db)
        }
    }

    public func aiThread(id: UUID) throws -> AIThreadRecord? {
        try dbQueue.read { db in try AIThreadRecord.fetchOne(db, key: id) }
    }

    /// Deletes the thread and everything scoped to it — messages and their
    /// embeddings. No FK cascade (the embeddings live in a vec0 virtual
    /// table, which doesn't support foreign keys), so this deletes explicitly
    /// in dependency order, same as the old backend's delete_ai_thread.
    public func deleteAIThread(id: UUID) throws {
        try dbQueue.write { db in
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
        try dbQueue.write { db in try message.insert(db) }
    }

    /// A thread's messages in conversation order.
    public func aiMessages(threadID: UUID) throws -> [AIMessageRecord] {
        try dbQueue.read { db in
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
        try await dbQueue.write { db in try thread.save(db) }
    }

    public func aiThreadAsync(id: UUID) async throws -> AIThreadRecord? {
        try await dbQueue.read { db in try AIThreadRecord.fetchOne(db, key: id) }
    }

    public func appendAIMessageAsync(_ message: AIMessageRecord) async throws {
        try await dbQueue.write { db in try message.insert(db) }
    }

    public func aiMessagesAsync(threadID: UUID) async throws -> [AIMessageRecord] {
        try await dbQueue.read { db in
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
        try await dbQueue.read { db in
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
        try await dbQueue.read { db in
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
        try dbQueue.read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            return try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
        }
    }

    public func activeAIMessagesAsync(threadID: UUID) async throws -> [AIMessageRecord] {
        try await dbQueue.read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            return try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
        }
    }

    /// Branch-aware replacement for `aiRecentMessagesAsync` — the last
    /// `limit` non-interaction messages on the ACTIVE path, oldest first.
    public func activeAIRecentMessagesAsync(threadID: UUID, limit: Int) async throws -> [AIMessageRecord] {
        try await dbQueue.read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            let path = try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
            let nonInteraction = path.filter { $0.toolCalls != "local:interaction" }
            return Array(nonInteraction.suffix(limit))
        }
    }

    /// Branch-aware replacement for `aiMessagesAsync(threadID:sinceSeq:)` —
    /// non-interaction messages strictly after `sinceSeq`, ACTIVE path only.
    public func activeAIMessagesAsync(threadID: UUID, sinceSeq: Int) async throws -> [AIMessageRecord] {
        try await dbQueue.read { db in
            guard let thread = try AIThreadRecord.fetchOne(db, key: threadID) else { return [] }
            let path = try walkActivePath(db: db, threadID: threadID, leafID: thread.activeLeafMessageID)
            return path.filter { $0.seq > sinceSeq && $0.toolCalls != "local:interaction" }
        }
    }

    public func aiMessage(id: UUID) throws -> AIMessageRecord? {
        try dbQueue.read { db in try AIMessageRecord.fetchOne(db, key: id) }
    }

    /// Retargets a thread's active tip — used both when a normal turn
    /// finishes (advance to the newly-appended assistant reply) and when
    /// editing/switching versions (jump elsewhere in the tree).
    public func setActiveLeafMessage(threadID: UUID, messageID: UUID?) throws {
        try dbQueue.write { db in
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
        try dbQueue.read { db in
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
        try dbQueue.read { db in
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
        try dbQueue.write { db in try interaction.save(db) }
    }

    public func pendingAIInteraction(
        threadID: UUID
    ) throws -> AIPendingInteractionRecord? {
        try dbQueue.read { db in
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
        try dbQueue.write { db in
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
        try dbQueue.write { db in
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
        try dbQueue.write { db in
            try AIPendingInteractionRecord.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func deleteExpiredPendingAIInteractions(
        nowUnix: Int64
    ) throws -> Int {
        try dbQueue.write { db in
            try AIPendingInteractionRecord
                .filter(Column("expiresAtUnix") <= nowUnix)
                .deleteAll(db)
        }
    }

    // MARK: - Pending report draft (Task 4.1 pre-refinement consent gate)

    public func savePendingReportDraft(_ draft: AIPendingReportDraftRecord) throws {
        try dbQueue.write { db in try draft.save(db) }
    }

    public func pendingReportDraft(threadID: UUID) throws -> AIPendingReportDraftRecord? {
        try dbQueue.read { db in try AIPendingReportDraftRecord.fetchOne(db, key: threadID) }
    }

    @discardableResult
    public func deletePendingReportDraft(threadID: UUID) throws -> Bool {
        try dbQueue.write { db in try AIPendingReportDraftRecord.deleteOne(db, key: threadID) }
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
        try dbQueue.write { db in
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
        return try dbQueue.write { db in
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
        let embedded: Set<Int> = try dbQueue.read { db in
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
        return try dbQueue.read { db in
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

    /// Stores/replaces the embedding for one table/collection name, keyed by
    /// "profileID#name" in the vec0 virtual table (no composite-key support
    /// for declared vec0 primary keys, so the pair is encoded as one string).
    public func saveSchemaObjectEmbedding(profileID: UUID, name: String, vector: [Float]) throws {
        guard vector.count == Self.schemaObjectEmbeddingDimension else {
            throw DatabaseError(
                resultCode: .SQLITE_MISMATCH,
                message: "Schema object embedding must contain \(Self.schemaObjectEmbeddingDimension) values"
            )
        }
        let key = "\(profileID.uuidString)#\(name)"
        let blob = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_object_embedding(objectKey, embedding) VALUES (?, ?)",
                arguments: [key, blob]
            )
        }
    }

    /// Names among `candidateNames` that don't yet have a persisted vector
    /// for this profile.
    public func schemaObjectNamesMissingEmbeddings(
        profileID: UUID, candidateNames: [String]
    ) throws -> [String] {
        let prefix = "\(profileID.uuidString)#"
        let embedded: Set<String> = try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT objectKey FROM schema_object_embedding WHERE objectKey LIKE ?",
                arguments: ["\(prefix)%"]
            )
            return Set(rows.compactMap { row -> String? in
                let key: String = row["objectKey"]
                guard key.hasPrefix(prefix) else { return nil }
                return String(key.dropFirst(prefix.count))
            })
        }
        return candidateNames.filter { !embedded.contains($0) }
    }

    /// Cosine-nearest table/collection names in this profile to
 /// `queryVector` (search_schema), nearest first.
    /// vec0 has no per-profile partition index here, so this over-fetches a
    /// generous global top-K and filters/truncates to the profile
    /// client-side — the same tradeoff `nearestAIMessages` makes, correct at
    /// the object counts a single connection accumulates.
    public func nearestSchemaObjects(
        profileID: UUID, to queryVector: [Float], limit: Int = 8
    ) throws -> [(name: String, distance: Double)] {
        guard queryVector.count == Self.schemaObjectEmbeddingDimension else { return [] }
        let blob = queryVector.withUnsafeBufferPointer { Data(buffer: $0) }
        let prefix = "\(profileID.uuidString)#"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT objectKey, distance FROM schema_object_embedding WHERE embedding MATCH ? AND k = ? ORDER BY distance",
                arguments: [blob, 256]
            )
            return rows.compactMap { row -> (name: String, distance: Double)? in
                let key: String = row["objectKey"]
                guard key.hasPrefix(prefix) else { return nil }
                return (name: String(key.dropFirst(prefix.count)), distance: row["distance"])
            }
            .prefix(limit)
            .map { $0 }
        }
    }
}
