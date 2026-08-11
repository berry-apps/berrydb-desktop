import BerryDataSourceKit
import Foundation
import Observation

/// Result buffer for `DocumentGridView` — the `DataSourceEvent` analogue of
/// `ResultBuffer` (BerryCore, docs/architecture/12 §7): drains the driver's
/// batched stream (500-1000 items, N3) one MainActor hop per batch.
@MainActor
@Observable
public final class DataSourceResultBuffer {
    public enum State: Equatable, Sendable {
        case running
        case complete
        case cancelled
        case failed(String)
    }

    /// Union of top-level `.object` keys seen in the FIRST non-empty batch
    /// only — a later batch introducing a new key outside that set is a
    /// known, documented gap (same shape as the DynamoDB driver's own
    /// column-union limitation, docs/architecture/12 §7/§4), not solved here.
    public private(set) var columns: [String] = []
    public private(set) var items: [BerryDocument] = []
    public private(set) var stats: DataSourceStats?
    public private(set) var state: State = .running

    private var task: Task<Void, Never>?

    public init() {}

    public var itemCount: Int { items.count }

    public func consume(_ stream: AsyncThrowingStream<DataSourceEvent, Error>) {
        task?.cancel()
        columns = []
        items = []
        stats = nil
        state = .running

        task = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .items(let batch):
                        if self.columns.isEmpty { self.columns = Self.unionKeys(batch) }
                        self.items.append(contentsOf: batch)
                    case .complete(let stats):
                        self.stats = stats
                    }
                }
                self?.state = .complete
            } catch let error as DataSourceError where isCancellation(error) {
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

    /// Awaits stream completion — tests drive `run()` deterministically
    /// instead of racing the MainActor hops (mirrors `ResultBuffer`).
    public func waitUntilFinished() async {
        await task?.value
    }

    private static func unionKeys(_ documents: [BerryDocument]) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for document in documents {
            guard case .object(let fields) = document else { continue }
            for (key, _) in fields where !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        return ordered
    }
}

private func isCancellation(_ error: DataSourceError) -> Bool {
    if case .cancelled = error { return true }
    return false
}
