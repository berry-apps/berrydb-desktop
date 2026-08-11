import BerryDriverKit
import Foundation

/// Whole-database backup/restore (docs/feature/04) — Navicat's "Dump SQL File" /
/// "Execute SQL File" for SQL connections, built from existing primitives
/// (introspector DDL + `ExportEngine.sqlInsert` for dump, `StatementSplitter` +
/// `QueryService` for restore). Streams row data so RAM stays flat (principle N3).
public enum BackupService {
    public struct SQLBackupOptions: Sendable {
        public var includeStructure: Bool
        public var includeData: Bool
        public var batchSize: Int

        public init(includeStructure: Bool = true, includeData: Bool = true, batchSize: Int = 100) {
            self.includeStructure = includeStructure
            self.includeData = includeData
            self.batchSize = batchSize
        }
    }

    public struct RestoreFailure: Sendable {
        public let statement: String
        public let message: String
    }

    public struct RestoreResult: Sendable {
        public let executed: Int
        public let failures: [RestoreFailure]
    }

    /// Dump `objects` (or every object when nil) to a `.sql` file: each object's
    /// DDL, then each table's rows as batched INSERTs. Returns the object count.
    @discardableResult
    public static func backupSQL(
        session: Session,
        objects: [SchemaObject]? = nil,
        options: SQLBackupOptions = .init(),
        to url: URL,
        progress: (@Sendable (_ done: Int, _ total: Int, _ label: String) -> Void)? = nil
    ) async throws -> Int {
        let all: [SchemaObject]
        if let objects { all = objects } else { all = try await session.connection.introspector.objects(in: nil) }
        // Structure order: tables → views → routines → triggers, so a replayed
        // dump creates dependencies before things that reference them.
        let ordered = all.sorted { orderRank($0.kind) < orderRank($1.kind) }
        let total = ordered.count

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try write(handle, "-- BerryDB backup — \(session.displayName)\n")

        var dumped = 0
        for object in ordered {
            progress?(dumped, total, object.name)
            if options.includeStructure {
                let ddl = try await session.connection.introspector.ddl(of: object)
                try write(handle, "\n-- \(object.kind.rawValue.uppercased()): \(object.name)\n")
                try write(handle, terminated(ddl))
            }
            if options.includeData, object.kind == .table {
                let table = TableRef(database: object.database, name: object.name)
                let sql = "SELECT * FROM \(qualified(table, session.dialect))"
                let stream = QueryService.execute(sql, on: session, autoLimit: nil, recordHistory: false)
                try write(handle, "\n-- Data: \(object.name)\n")
                _ = try await ExportEngine.export(
                    stream: stream, to: handle,
                    format: .sqlInsert(table: table, dialect: session.dialect, batchSize: options.batchSize, ddlHeader: nil)
                )
                try write(handle, "\n")
            }
            dumped += 1
        }
        return dumped
    }

    /// Run a `.sql` file statement-by-statement. The danger gate is pre-confirmed
    /// — restoring is the user's explicit intent, so DROP/DELETE inside the dump
    /// must not each re-prompt. Failures are collected (not fatal unless
    /// `stopOnError`) so one bad statement doesn't abort the whole restore.
    @discardableResult
    public static func restoreSQL(
        session: Session,
        from url: URL,
        stopOnError: Bool = false,
        progress: (@Sendable (_ done: Int, _ total: Int, _ label: String) -> Void)? = nil
    ) async throws -> RestoreResult {
        // Split off a temporary read of the whole file, then drop it before the
        // execute loop so peak memory is just the statement list, not file+list.
        // (Fully streaming the parse would need an incremental SQL lexer;
        // StatementSplitter is whole-string by design — a later refinement.)
        let statements = StatementSplitter.split(try String(contentsOf: url, encoding: .utf8))
        let total = statements.count
        // Report at most ~100 times so a huge dump doesn't spam the UI thread.
        let step = max(1, total / 100)
        var executed = 0
        var failures: [RestoreFailure] = []
        for (index, statement) in statements.enumerated() {
            do {
                for try await _ in QueryService.execute(
                    statement.sql, on: session, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true
                ) {}
                executed += 1
            } catch {
                failures.append(RestoreFailure(statement: statement.sql, message: error.localizedDescription))
                if stopOnError { break }
            }
            if (index + 1) % step == 0 || index + 1 == total {
                progress?(index + 1, total, "")
            }
        }
        return RestoreResult(executed: executed, failures: failures)
    }

    // MARK: - Helpers

    private static func orderRank(_ kind: SchemaObjectKind) -> Int {
        switch kind {
        case .table: 0
        case .view: 1
        case .function, .procedure: 2
        case .trigger: 3
        case .index: 4
        }
    }

    /// The DDL as one statement ending in exactly one `;`.
    private static func terminated(_ ddl: String) -> String {
        let trimmed = ddl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix(";") ? trimmed + "\n" : trimmed + ";\n"
    }

    private static func qualified(_ table: TableRef, _ dialect: any SQLDialect) -> String {
        if let db = table.database, !db.isEmpty {
            return "\(dialect.quoteIdentifier(db)).\(dialect.quoteIdentifier(table.name))"
        }
        return dialect.quoteIdentifier(table.name)
    }

    private static func write(_ handle: FileHandle, _ text: String) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}
