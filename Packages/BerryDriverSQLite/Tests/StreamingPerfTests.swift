import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverSQLite

/// M1 spike: 1M rows must stream through the driver in batches fast enough
/// to feed a 60fps grid. Gated behind
/// BERRYDB_PERF so regular runs stay fast; the nightly perf job sets it.
@Suite("Streaming perf spike (1M rows)", .enabled(if: ProcessInfo.processInfo.environment["BERRYDB_PERF"] != nil))
struct StreamingPerfTests {
    @Test func streamsOneMillionRows() async throws {
        let path = NSTemporaryDirectory() + "berrydb-perf-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let conn = try SQLiteConnection(path: path)

        // Seed 1M rows (not part of the measured window).
        for try await _ in conn.execute(
            """
            CREATE TABLE big AS
            WITH RECURSIVE seq(x) AS (
                SELECT 1 UNION ALL SELECT x + 1 FROM seq WHERE x < 1000000
            )
            SELECT x AS id, 'row-' || x AS name, x * 1.5 AS score FROM seq
            """
        ) {}

        let clock = ContinuousClock()
        let started = clock.now
        var total = 0
        var batches = 0
        for try await event in conn.execute("SELECT id, name, score FROM big") {
            if case .rows(let batch) = event {
                total += batch.count
                batches += 1
            }
        }
        let elapsed = clock.now - started

        #expect(total == 1_000_000)
        #expect(batches >= 1_000_000 / SQLiteConnection.batchSize)
        // Budget: full pump of 1M rows in under 5s on a dev machine —
        // far above what the virtualized grid needs per frame.
        #expect(elapsed < .seconds(5), "1M rows took \(elapsed)")
        await conn.close()
    }
}
