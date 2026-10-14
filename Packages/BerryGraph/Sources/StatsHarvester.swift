import BerryCore
import BerryDriverKit
import BerryStore
import Foundation

/// Reads table and index statistics from the engine's own statistics views.
/// Metadata only: the queries read catalog and statistics views and never user
/// data. Best-effort: a missing view or a permissions error yields no rows for
/// that query, because statistics only enrich the schema.
public enum StatsHarvester {
    /// Runs the dialect's statistics queries over the metadata connection and
    /// returns one record per table in `scope`, keyed by schema and table name;
    /// empty for an engine without statistics views.
    ///
    /// Postgres reads `pg_stat_user_tables` and `pg_stat_user_indexes`
    /// (https://www.postgresql.org/docs/current/monitoring-stats.html), MySQL
    /// `information_schema.TABLES`
    /// (https://dev.mysql.com/doc/refman/8.4/en/information-schema-tables-table.html),
    /// whose row count is an estimate for InnoDB tables and which has no scan
    /// counters.
    public static func harvest(
        profileID: UUID, connection: any DriverConnection, driver: DriverID, scope: SchemaScope, now: Date
    ) async -> [SchemaStatsRecord] {
        switch driver {
        case .postgres:
            let tables = await rows(of: postgresTablesSQL(scope), connection)
            // Index counters fold only into tables that were read, and a
            // cancelled harvest is discarded by its caller, so in either case
            // the second query would be wasted.
            guard !Task.isCancelled, !tables.isEmpty else { return [] }
            let indexes = await rows(of: postgresIndexesSQL(scope), connection)
            return postgresRows(tables: tables, indexes: indexes, profileID: profileID, now: now)
        case .mysql:
            // Only the default scope depends on the connection's database. A
            // query that fails returns no row, while a connection without a
            // database returns one whose value is NULL
            // (https://dev.mysql.com/doc/refman/8.4/en/information-functions.html#function_database);
            // the first must not widen the read to every database on the server.
            var current: String?
            if scope == .allUserSchemas {
                guard let answer = await rows(of: "SELECT DATABASE() AS current_database", connection).first else { return [] }
                current = answer["current_database"]
            }
            let tables = await rows(of: mysqlTablesSQL(scope, currentDatabase: current), connection)
            return mysqlRows(tables: tables, profileID: profileID, now: now)
        default:
            return []
        }
    }

    // MARK: - Mapping query rows to records

    /// One record per table row, with the table's indexes folded into its own
    /// `indexStats`. Both are keyed by schema and table name, so two tables of
    /// one name in different schemas keep their own numbers, and an index of a
    /// table outside `tables` is dropped.
    static func postgresRows(
        tables: [[String: String]], indexes: [[String: String]], profileID: UUID, now: Date
    ) -> [SchemaStatsRecord] {
        var records: [SchemaStatsRecord] = []
        var position: [String: Int] = [:]
        for row in tables {
            guard let schema = row["schemaname"], let name = row["relname"] else { continue }
            position[key(schema: schema, name: name)] = records.count
            records.append(SchemaStatsRecord(
                profileID: profileID, database: schema, name: name,
                rows: integer(row["n_live_tup"]), sizeBytes: integer(row["size_bytes"]),
                seqScan: integer(row["seq_scan"]), idxScan: integer(row["idx_scan"]), updatedAt: now
            ))
        }
        var counters: [Int: [String: IndexCounters]] = [:]
        for row in indexes {
            guard let schema = row["schemaname"], let table = row["relname"], let index = row["indexrelname"],
                  let scans = integer(row["idx_scan"]), let at = position[key(schema: schema, name: table)]
            else { continue }
            counters[at, default: [:]][index] = IndexCounters(idxScan: scans)
        }
        // Sorted keys keep the stored text identical between passes that
        // report the same numbers.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (at, byIndex) in counters {
            records[at].indexStats = (try? encoder.encode(byIndex)).flatMap { String(data: $0, encoding: .utf8) }
        }
        return records
    }

    /// One record per base table: a row estimate and a size, no scan counters.
    static func mysqlRows(tables: [[String: String]], profileID: UUID, now: Date) -> [SchemaStatsRecord] {
        tables.compactMap { row in
            guard let schema = row["table_schema"], let name = row["table_name"] else { return nil }
            return SchemaStatsRecord(
                profileID: profileID, database: schema, name: name,
                rows: integer(row["n_rows"]), sizeBytes: integer(row["size_bytes"]), updatedAt: now
            )
        }
    }

    /// The shape `GraphReader.indexCounters(of:)` decodes.
    private struct IndexCounters: Encodable {
        let idxScan: Int64
    }

    /// Joined with a unit separator so that the pairs (a, bc) and (ab, c) give
    /// different keys.
    private static func key(schema: String, name: String) -> String {
        "\(schema)\u{1F}\(name)"
    }

    private static func integer(_ text: String?) -> Int64? {
        text.flatMap { Int64($0) }
    }

    // MARK: - Statistics queries

    private static func postgresTablesSQL(_ scope: SchemaScope) -> String {
        """
        SELECT schemaname, relname, n_live_tup, seq_scan, COALESCE(idx_scan, 0) AS idx_scan,
               pg_total_relation_size(relid) AS size_bytes
        FROM pg_stat_user_tables
        WHERE \(postgresScope(scope))
        """
    }

    private static func postgresIndexesSQL(_ scope: SchemaScope) -> String {
        """
        SELECT schemaname, relname, indexrelname, COALESCE(idx_scan, 0) AS idx_scan
        FROM pg_stat_user_indexes
        WHERE \(postgresScope(scope))
        """
    }

    /// The tables the catalog listing keeps: MariaDB reports a
    /// system-versioned table as `SYSTEM VERSIONED`
    /// (https://mariadb.com/kb/en/information-schema-tables-table/).
    private static func mysqlTablesSQL(_ scope: SchemaScope, currentDatabase: String?) -> String {
        """
        SELECT TABLE_SCHEMA AS table_schema, TABLE_NAME AS table_name, TABLE_ROWS AS n_rows,
               (DATA_LENGTH + INDEX_LENGTH) AS size_bytes
        FROM information_schema.TABLES
        WHERE TABLE_TYPE IN ('BASE TABLE', 'SYSTEM VERSIONED') AND \(mysqlScope(scope, currentDatabase: currentDatabase))
        """
    }

    /// SQL condition on the schema name of the Postgres statistics views for
    /// `scope`. Without a selection it excludes the same schemas the catalog
    /// listing does, system and per-session temporary ones, with the
    /// underscores of the temporary prefixes escaped so a schema such as
    /// `pgxtemp1` is not mistaken for one.
    static func postgresScope(_ scope: SchemaScope) -> String {
        switch scope {
        case .allUserSchemas:
            return """
                schemaname NOT IN ('pg_catalog', 'information_schema', 'pg_toast') \
                AND schemaname NOT LIKE 'pg!_temp!_%' ESCAPE '!' \
                AND schemaname NOT LIKE 'pg!_toast!_temp!_%' ESCAPE '!'
                """
        case .schemas(let names):
            guard !names.isEmpty else { return "FALSE" }
            return "schemaname IN (" + names.map { literal($0, backslashEscapes: false) }.joined(separator: ", ") + ")"
        }
    }

    /// SQL condition on `TABLE_SCHEMA` for `scope`, the scope the catalog
    /// listing reads: by default the connection's database, `currentDatabase`,
    /// and only when it has none every database but the server's own four.
    static func mysqlScope(_ scope: SchemaScope, currentDatabase: String?) -> String {
        switch scope {
        case .allUserSchemas:
            if let currentDatabase { return "TABLE_SCHEMA = \(literal(currentDatabase, backslashEscapes: true))" }
            return "TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')"
        case .schemas(let names):
            guard !names.isEmpty else { return "FALSE" }
            return "TABLE_SCHEMA IN (" + names.map { literal($0, backslashEscapes: true) }.joined(separator: ", ") + ")"
        }
    }

    /// A single-quoted string literal in which a quote is doubled. MySQL also
    /// reads a backslash as an escape character inside a string literal unless
    /// the `NO_BACKSLASH_ESCAPES` SQL mode is set
    /// (https://dev.mysql.com/doc/refman/8.4/en/string-literals.html), so there
    /// it is doubled too; a name ending in a backslash would otherwise swallow
    /// the closing quote. PostgreSQL reads a backslash literally while
    /// `standard_conforming_strings` is on, its default since 9.1
    /// (https://www.postgresql.org/docs/current/runtime-config-compatible.html#GUC-STANDARD-CONFORMING-STRINGS),
    /// so it is left alone. The drivers' catalog queries follow the same rule;
    /// this module does not depend on the driver modules, so it is repeated.
    private static func literal(_ value: String, backslashEscapes: Bool) -> String {
        var escaped = value
        if backslashEscapes { escaped = escaped.replacingOccurrences(of: "\\", with: "\\\\") }
        return "'" + escaped.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Helpers

    /// Runs a read-only statistics query on the connection and returns its rows
    /// as column-to-string maps. Best-effort: any error yields no rows.
    private static func rows(of sql: String, _ connection: any DriverConnection) async -> [[String: String]] {
        await collect(connection.execute(sql))
    }

    private static func collect(_ events: AsyncThrowingStream<ResultEvent, Error>) async -> [[String: String]] {
        do {
            var columns: [String] = []
            var result: [[String: String]] = []
            for try await event in events {
                switch event {
                case let .columns(metas):
                    columns = metas.map(\.name)
                case let .rows(batch):
                    for row in batch {
                        var map: [String: String] = [:]
                        for (index, value) in row.enumerated() where index < columns.count {
                            if let string = value.displayString { map[columns[index]] = string }
                        }
                        result.append(map)
                    }
                case .complete:
                    break
                }
            }
            return result
        } catch {
            return []
        }
    }
}
