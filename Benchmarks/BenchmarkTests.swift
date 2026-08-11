import BerryCore
import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import Darwin
import Foundation
import Testing

// Performance harness for the measurable targets in docs/architecture/01 §2
// (streaming throughput, connect latency, memory under a large result). Opt-in:
// runs only with BERRYDB_BENCH=1 AND the Docker matrix env vars set, so a plain
// `swift test` never pays for it. Numbers are REPORTED (see `make bench`); the
// asserts are deliberately loose — they catch gross regressions, not jitter.

private let benchEnabled = ProcessInfo.processInfo.environment["BERRYDB_BENCH"] != nil
private let benchRows = ProcessInfo.processInfo.environment["BERRYDB_BENCH_ROWS"].flatMap(Int.init) ?? 200_000

private func report(_ line: String) {
    print("BENCH \(line)")
}

private func seconds(_ duration: Duration) -> Double {
    let c = duration.components
    return Double(c.seconds) + Double(c.attoseconds) * 1e-18
}

/// Resident memory of this process, via mach — for the N3 streaming check.
private func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { infoPtr in
        infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
}

private func openPostgres() async throws -> (ConnectionManager, Session) {
    DriverRegistry.register(PostgresDriver.self)
    let s = TestServer.postgres!
    let manager = ConnectionManager()
    let session = try await manager.open(ConnectionConfig(
        driver: .postgres, name: "bench", host: s.host, port: s.port,
        username: s.username, password: s.password, database: s.database
    ))
    return (manager, session)
}

private func openMySQL() async throws -> (ConnectionManager, Session) {
    DriverRegistry.register(MySQLDriver.self)
    let s = TestServer.mysql!
    let manager = ConnectionManager()
    let session = try await manager.open(ConnectionConfig(
        driver: .mysql, name: "bench", host: s.host, port: s.port,
        username: s.username, password: s.password, database: s.database
    ))
    return (manager, session)
}

/// Streams a statement through the single SQL path (N1) and counts rows without
/// retaining them — models the grid consuming a result lazily.
private func drainRowCount(_ sql: String, on session: Session) async throws -> Int {
    var rows = 0
    for try await event in QueryService.execute(sql, on: session, autoLimit: nil) {
        if case let .rows(batch) = event { rows += batch.count }
    }
    return rows
}

@Suite("Benchmarks (M7, docs/architecture/01 §2)", .enabled(if: benchEnabled))
struct Benchmarks {
    // MARK: - Streaming throughput (N3)

    @Test(.enabled(if: TestServer.postgres != nil))
    func postgresStreamingThroughput() async throws {
        let (manager, session) = try await openPostgres()
        defer { Task { await manager.close(session.id) } }

        let sql = "SELECT g, md5(g::text) FROM generate_series(1, \(benchRows)) g"
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await drainRowCount(sql, on: session)
        let elapsed = clock.now - start

        let rowsPerSec = Double(rows) / max(seconds(elapsed), 1e-9)
        report(String(format: "postgres throughput: %d rows in %.3fs = %.0f rows/s",
                      rows, seconds(elapsed), rowsPerSec))
        #expect(rows == benchRows)
        #expect(elapsed < .seconds(60)) // gross-regression guard only
    }

    @Test(.enabled(if: TestServer.mysql != nil))
    func mysqlStreamingThroughput() async throws {
        let (manager, session) = try await openMySQL()
        defer { Task { await manager.close(session.id) } }

        // Recursive CTE needs its depth ceiling raised for large N (MySQL 8).
        for try await _ in QueryService.execute(
            "SET SESSION cte_max_recursion_depth = \(benchRows + 16)", on: session, autoLimit: nil
        ) {}
        let sql = """
        WITH RECURSIVE seq(n) AS (
            SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < \(benchRows)
        )
        SELECT n, md5(n) FROM seq
        """
        let clock = ContinuousClock()
        let start = clock.now
        let rows = try await drainRowCount(sql, on: session)
        let elapsed = clock.now - start

        let rowsPerSec = Double(rows) / max(seconds(elapsed), 1e-9)
        report(String(format: "mysql throughput: %d rows in %.3fs = %.0f rows/s",
                      rows, seconds(elapsed), rowsPerSec))
        #expect(rows == benchRows)
        #expect(elapsed < .seconds(60))
    }

    // MARK: - Connect latency (cold-ish: connect + close)

    @Test(.enabled(if: TestServer.postgres != nil))
    func postgresConnectLatency() async throws {
        var best = Duration.seconds(1_000)
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let start = clock.now
            let (manager, session) = try await openPostgres()
            let elapsed = clock.now - start
            await manager.close(session.id)
            best = min(best, elapsed)
        }
        report(String(format: "postgres connect (best of 3): %.1f ms", seconds(best) * 1000))
        #expect(best < .seconds(10))
    }

    @Test(.enabled(if: TestServer.mysql != nil))
    func mysqlConnectLatency() async throws {
        var best = Duration.seconds(1_000)
        let clock = ContinuousClock()
        for _ in 0..<3 {
            let start = clock.now
            let (manager, session) = try await openMySQL()
            let elapsed = clock.now - start
            await manager.close(session.id)
            best = min(best, elapsed)
        }
        report(String(format: "mysql connect (best of 3): %.1f ms", seconds(best) * 1000))
        #expect(best < .seconds(10))
    }

    // MARK: - Memory under a large streamed result (N3: stream, don't buffer)

    @Test(.enabled(if: TestServer.postgres != nil))
    func streamingKeepsMemoryBounded() async throws {
        let (manager, session) = try await openPostgres()
        defer { Task { await manager.close(session.id) } }

        let baseline = residentBytes()
        var peak = baseline
        var rows = 0
        // Sample RSS as we drain; peak should stay near baseline if streaming.
        for try await event in QueryService.execute(
            "SELECT g, md5(g::text) FROM generate_series(1, \(benchRows)) g", on: session, autoLimit: nil
        ) {
            if case let .rows(batch) = event {
                rows += batch.count
                if rows % 20_000 < batch.count { peak = max(peak, residentBytes()) }
            }
        }
        peak = max(peak, residentBytes())
        let deltaMB = Double(peak &- baseline) / 1_048_576
        report(String(format: "postgres memory over %d rows: baseline %.0f MB, peak Δ %.1f MB",
                      rows, Double(baseline) / 1_048_576, deltaMB))
        #expect(rows == benchRows)
        // A full-buffer regression would scale with row count; streaming stays flat.
        #expect(deltaMB < 250)
    }
}
