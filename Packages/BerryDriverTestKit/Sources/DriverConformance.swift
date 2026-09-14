import BerryDriverKit
import Foundation

/// Conformance failure — the message carries enough context to read straight from the test log.
public struct ConformanceFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Shared contract checks for EVERY driver.
/// Each driver supplies SQL in its own dialect; the behavioral assertions
/// (streaming, cancel, error classification, round-trip) are shared and mandatory.
public struct DriverConformance: Sendable {
    public let makeConnection: @Sendable () async throws -> any DriverConnection

    public init(makeConnection: @escaping @Sendable () async throws -> any DriverConnection) {
        self.makeConnection = makeConnection
    }

    // MARK: Helpers

    @discardableResult
    public func drain(
        _ stream: AsyncThrowingStream<ResultEvent, Error>
    ) async throws -> (columns: [ColumnMeta], rows: [[BerryValue]], stats: QueryStats?) {
        var columns: [ColumnMeta] = []
        var rows: [[BerryValue]] = []
        var stats: QueryStats?
        for try await event in stream {
            switch event {
            case .columns(let c): columns = c
            case .rows(let batch): rows.append(contentsOf: batch)
            case .complete(let s): stats = s
            }
        }
        return (columns, rows, stats)
    }

    public func exec(_ connection: any DriverConnection, _ statements: [String]) async throws {
        for sql in statements {
            _ = try await drain(connection.execute(sql))
        }
    }

    // MARK: Checks

    /// Data type round-trip: run setup, SELECT one row, compare with expectations.
    /// `expected` is a closure so drivers can verify flexibly (a value may be
    /// valid in several representations, e.g. DECIMAL).
    public func checkRoundTrip(
        setup: [String],
        select: String,
        expectedColumnCount: Int,
        verify: ([BerryValue]) throws -> Void
    ) async throws {
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        try await exec(conn, setup)
        let result = try await drain(conn.execute(select))
        guard result.rows.count == 1 else {
            throw ConformanceFailure("Expected 1 row, got \(result.rows.count)")
        }
        guard result.rows[0].count == expectedColumnCount else {
            throw ConformanceFailure("Expected \(expectedColumnCount) columns, got \(result.rows[0].count)")
        }
        try verify(result.rows[0])
    }

    /// Streaming: receive all `expectedRows` rows, in multiple batches, each ≤ maxBatch.
    public func checkStreaming(
        setup: [String],
        select: String,
        expectedRows: Int,
        maxBatch: Int = 1000
    ) async throws {
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        try await exec(conn, setup)

        var total = 0
        var batches = 0
        var sawComplete = false
        for try await event in conn.execute(select) {
            switch event {
            case .columns: break
            case .rows(let batch):
                if batch.count > maxBatch {
                    throw ConformanceFailure("Batch of \(batch.count) rows exceeds cap of \(maxBatch)")
                }
                total += batch.count
                batches += 1
            case .complete:
                sawComplete = true
            }
        }
        guard sawComplete else { throw ConformanceFailure("Missing .complete event") }
        guard total == expectedRows else {
            throw ConformanceFailure("Expected \(expectedRows) rows, got \(total)")
        }
        guard batches >= expectedRows / maxBatch else {
            throw ConformanceFailure("Large results must be split into multiple batches (got \(batches) batches)")
        }
    }

    /// Mid-flight cancel: the stream must finish with an error within `deadline`
    /// seconds and the connection (or a new one) must remain usable afterwards.
    public func checkCancel(
        heavyQuery: String,
        probeQuery: String,
        deadline: Duration = .seconds(3)
    ) async throws {
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }

        let started = ContinuousClock.now
        let stream = conn.execute(heavyQuery)
        Task {
            // nanoseconds, not Task.sleep(for:) — the latter is a confirmed
            // Swift runtime crash risk in release builds when multiple
            // modules generate different Clock-generic specializations
 // (swiftlang/swift#86204, #84793).
            try? await Task.sleep(nanoseconds: 150_000_000)
            conn.cancelCurrentQuery()
        }

        var failed = false
        do {
            _ = try await drain(stream)
        } catch {
            failed = true
        }
        let elapsed = ContinuousClock.now - started
        guard failed else { throw ConformanceFailure("Cancelled, but the stream finished successfully") }
        guard elapsed < deadline else {
            throw ConformanceFailure("Cancel took \(elapsed) — past the \(deadline) deadline")
        }

        let probe = try await drain(conn.execute(probeQuery))
        guard !probe.rows.isEmpty else {
            throw ConformanceFailure("Connection unusable after cancel")
        }
    }

    /// SQL errors must be classifiable DriverErrors, and the connection must survive.
    public func checkErrorClassification(badQuery: String, probeQuery: String) async throws {
        let conn = try await makeConnection()
        defer { Task { await conn.close() } }
        do {
            _ = try await drain(conn.execute(badQuery))
            throw ConformanceFailure("Bad query did not throw")
        } catch is DriverError {
            // as expected
        } catch let failure as ConformanceFailure {
            throw failure
        } catch {
            throw ConformanceFailure("Error is not a DriverError: \(type(of: error))")
        }
        let probe = try await drain(conn.execute(probeQuery))
        guard !probe.rows.isEmpty else {
            throw ConformanceFailure("Connection unusable after SQL error")
        }
    }
}
