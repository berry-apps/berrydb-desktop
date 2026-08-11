import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryUI

/// Pure batching/column-union logic (docs/architecture/12 §7, N3) — drives
/// the buffer with hand-built streams, no Docker.
@MainActor
@Suite("DataSourceResultBuffer")
struct DataSourceResultBufferTests {
    private func stream(_ build: @escaping (AsyncThrowingStream<DataSourceEvent, Error>.Continuation) -> Void) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in build(continuation) }
    }

    @Test func columnsComeOnlyFromTheFirstNonEmptyBatch() async {
        let buffer = DataSourceResultBuffer()
        buffer.consume(stream { continuation in
            continuation.yield(.items([.object([("a", .int(1))])]))
            // A later batch introducing a NEW key ("b") is the documented gap
            // — it must not retroactively widen `columns`.
            continuation.yield(.items([.object([("a", .int(2)), ("b", .int(3))])]))
            continuation.yield(.complete(DataSourceStats(itemsReturned: 2, duration: .zero)))
            continuation.finish()
        })
        await buffer.waitUntilFinished()

        #expect(buffer.columns == ["a"])
        #expect(buffer.itemCount == 2)
        #expect(buffer.state == .complete)
    }

    /// `cancel()`'s state transition is a synchronous, unconditional
    /// guarantee (`if state == .running { state = .cancelled }`) — it does
    /// NOT depend on the consuming `Task`'s `for await` loop ever actually
    /// observing cancellation (that timing is a genuine, pre-existing
    /// `AsyncThrowingStream`/`Task` subtlety shared with `ResultBuffer`,
    /// BerryCore, which has no test for that finer race either). Test the
    /// guaranteed part directly instead of racing the async Task.
    @Test func cancelSynchronouslyMarksStateCancelledWhileRunning() {
        let buffer = DataSourceResultBuffer()
        let openStream = AsyncThrowingStream<DataSourceEvent, Error> { _ in
            // Never yields/finishes — irrelevant, cancel() runs before
            // the consuming Task gets a chance to do anything.
        }
        buffer.consume(openStream)
        #expect(buffer.state == .running)
        buffer.cancel()
        #expect(buffer.state == .cancelled)
    }

    @Test func failedStreamSurfacesAsFailedState() async {
        let buffer = DataSourceResultBuffer()
        buffer.consume(stream { continuation in
            continuation.finish(throwing: DataSourceError.queryFailed("boom"))
        })
        await buffer.waitUntilFinished()

        guard case .failed(let message) = buffer.state else {
            Issue.record("Expected .failed, got \(buffer.state)")
            return
        }
        #expect(message.contains("boom"))
    }

    @Test func nonObjectItemsAreIgnoredForColumnUnionButStillCounted() async {
        let buffer = DataSourceResultBuffer()
        buffer.consume(stream { continuation in
            continuation.yield(.items([.string("not-an-object")]))
            continuation.yield(.complete(DataSourceStats(itemsReturned: 1, duration: .zero)))
            continuation.finish()
        })
        await buffer.waitUntilFinished()

        #expect(buffer.columns.isEmpty)
        #expect(buffer.itemCount == 1)
    }
}
