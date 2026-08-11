import BerryDriverKit
import Foundation
import Observation

/// Result buffer for the grid — receives batches from the stream, the UI reads
/// by row (docs/architecture/04 §3). M0: kept in RAM (by default the grid loads
/// at most auto-LIMIT rows); spilling to disk past a threshold comes in M1.
@MainActor
@Observable
public final class ResultBuffer {
    public enum State: Equatable, Sendable {
        case running
        case complete
        case cancelled
        case failed(String)
    }

    public private(set) var columns: [ColumnMeta] = []
    public private(set) var rows: [[BerryValue]] = []
    public private(set) var stats: QueryStats?
    public private(set) var state: State = .running

    private var task: Task<Void, Never>?

    public init() {}

    public var rowCount: Int { rows.count }

    /// Seed column metadata for a result that finished with ZERO rows — network
    /// drivers (Postgres/MySQL) only emit columns alongside the first row, so an
    /// empty table's SELECT arrives with no columns. The caller supplies them
    /// from the schema catalog so the grid still shows headers and can insert
    /// (docs/ui, empty-table editing). No-op unless the buffer completed empty.
    public func seedColumnsIfEmpty(_ metas: [ColumnMeta]) {
        guard state == .complete, columns.isEmpty, rows.isEmpty, !metas.isEmpty else { return }
        columns = metas
    }

    /// Consume the result stream. The driver already groups batches of 500–1000
    /// rows; one MainActor hop per batch — keeps 60fps (docs/architecture/04 §4).
    public func consume(_ stream: AsyncThrowingStream<ResultEvent, Error>) {
        task?.cancel()
        columns = []
        rows = []
        stats = nil
        state = .running

        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .columns(let metas):
                        // A statement/proc can return several differently-
                        // shaped result sets (e.g. SQL Server's multi-result
                        // batches) — each gets its own .columns event. Rows
                        // already buffered are from the PRIOR shape; keeping
                        // them left `rows` ragged against the new `columns`
                        // width, which crashed the grid (index out of range)
                        // the moment a row narrower than the latest column
                        // count got indexed. A same-shape .columns repeat
                        // (some drivers emit one per batch) is a no-op here,
                        // not a reset.
                        if !self.rows.isEmpty, self.columns != metas {
                            self.rows = []
                        }
                        self.columns = metas
                    case .rows(let batch):
                        self.rows.append(contentsOf: batch)
                    case .complete(let stats):
                        self.stats = stats
                    }
                }
                self?.state = .complete
            } catch let error as DriverError where isCancellation(error) {
                self?.state = .cancelled
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancel() {
        task?.cancel()
        if state == .running { state = .cancelled }
    }

    /// Awaits stream completion — the editor runs statements sequentially
    /// (ED-04/05) and needs to know when one finished before starting the next.
    public func waitUntilFinished() async {
        await task?.value
    }
}

private func isCancellation(_ error: DriverError) -> Bool {
    if case .cancelled = error { return true }
    return false
}
