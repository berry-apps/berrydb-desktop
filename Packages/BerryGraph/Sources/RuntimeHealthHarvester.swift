import BerryCore
import BerryDriverKit
import Foundation

/// One instance-level health measurement at harvest time (DI-24,
/// docs/architecture/13 §5.5) — a snapshot, not a continuous stream (§1 "not
/// a 24/7 agent").
public struct RuntimeMetric: Sendable, Equatable {
    public let name: String
    public let value: Double

    public init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}

/// Harvests instance-level runtime health metrics at the same cadence as
/// StatsHarvester (connect/refresh) — no new polling mechanism, just a few
/// more queries in the harvest pass that already runs (DI-24,
/// docs/architecture/13 §5.5). Metadata only (Q6), best-effort: a missing
/// view or permissions error yields fewer metrics, never an error.
public enum RuntimeHealthHarvester {
    public static func harvest(session: Session) async -> [RuntimeMetric] {
        switch session.config.driver {
        case .postgres: return await harvestPostgres(session)
        case .mysql: return await harvestMySQL(session)
        default: return [] // SQLite/others: no instance-level stats concept.
        }
    }

    // MARK: - Postgres

    private static func harvestPostgres(_ session: Session) async -> [RuntimeMetric] {
        var metrics: [RuntimeMetric] = []

        if let row = await rows(of: "SELECT sum(blks_hit) AS hit, sum(blks_read) AS read FROM pg_stat_database", session).first,
           let hit = row["hit"].flatMap(Double.init), let read = row["read"].flatMap(Double.init), hit + read > 0 {
            metrics.append(RuntimeMetric(name: "cache_hit_ratio", value: hit / (hit + read)))
        }

        if let row = await rows(of: """
            SELECT (SELECT count(*) FROM pg_stat_activity) AS connections,
                   current_setting('max_connections')::int AS max_connections
            """, session).first {
            if let connections = row["connections"].flatMap(Double.init) {
                metrics.append(RuntimeMetric(name: "connection_count", value: connections))
            }
            if let maxConnections = row["max_connections"].flatMap(Double.init) {
                metrics.append(RuntimeMetric(name: "max_connections", value: maxConnections))
            }
        }

        if let row = await rows(of: "SELECT coalesce(sum(n_dead_tup), 0) AS dead FROM pg_stat_user_tables", session).first,
           let dead = row["dead"].flatMap(Double.init) {
            metrics.append(RuntimeMetric(name: "dead_tuple_count", value: dead))
        }

        return metrics
    }

    // MARK: - MySQL

    private static func harvestMySQL(_ session: Session) async -> [RuntimeMetric] {
        var metrics: [RuntimeMetric] = []
        let status = await statusVariables(session)

        if let connected = status["Threads_connected"].flatMap(Double.init) {
            metrics.append(RuntimeMetric(name: "connection_count", value: connected))
        }
        if let requests = status["Innodb_buffer_pool_read_requests"].flatMap(Double.init),
           let reads = status["Innodb_buffer_pool_reads"].flatMap(Double.init), requests > 0 {
            metrics.append(RuntimeMetric(name: "cache_hit_ratio", value: (requests - reads) / requests))
        }

        return metrics
    }

    private static func statusVariables(_ session: Session) async -> [String: String] {
        var result: [String: String] = [:]
        for row in await rows(of: """
            SHOW GLOBAL STATUS WHERE Variable_name IN
            ('Threads_connected', 'Innodb_buffer_pool_read_requests', 'Innodb_buffer_pool_reads')
            """, session) {
            if let name = row["Variable_name"], let value = row["Value"] { result[name] = value }
        }
        return result
    }

    // MARK: - Helpers (same shape as StatsHarvester.rows — do not deduplicate
    // across files, StatsHarvester's is private to that file)

    private static func rows(of sql: String, _ session: Session) async -> [[String: String]] {
        do {
            var columns: [String] = []
            var result: [[String: String]] = []
            for try await event in QueryService.execute(
                sql, on: session, autoLimit: nil, recordHistory: false
            ) {
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
