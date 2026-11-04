import BerryDriverKit
import Foundation

/// A `PartitionQuerying` connection that returns scripted pages in order and
/// records what it was asked, so tests can assert on the exact queries sent.
actor ScriptedPartitionConnection: PartitionQuerying {
    nonisolated let id = UUID()
    private let schema: DynamoDBKeySchema
    private var pages: [Result<DynamoDBQueryPage, Error>]
    private let delay: Duration
    private let schemaError: Error?
    private let inFlight = InFlightSleep()
    private(set) var queries: [DynamoDBPartitionQuery] = []
    private(set) var closeCalls = 0
    /// True once a delayed query was cancelled before its delay ran out.
    private(set) var sawCancellation = false

    /// `schemaError`, when set, is what `keySchema(of:)` throws, as
    /// `DescribeTable` does for a table that does not exist.
    init(
        schema: DynamoDBKeySchema, pages: [Result<DynamoDBQueryPage, Error>], delay: Duration = .zero,
        schemaError: Error? = nil
    ) {
        self.schema = schema
        self.pages = pages
        self.delay = delay
        self.schemaError = schemaError
    }

    func keySchema(of table: String) async throws -> DynamoDBKeySchema {
        if let schemaError { throw schemaError }
        return schema
    }

    func queryPartition(_ query: DynamoDBPartitionQuery) async throws -> DynamoDBQueryPage {
        queries.append(query)
        if delay > .zero {
            let sleep = Task { try await Task.sleep(for: delay) }
            inFlight.set(sleep)
            do {
                try await withTaskCancellationHandler { try await sleep.value } onCancel: { sleep.cancel() }
            } catch is CancellationError {
                sawCancellation = true
                throw DriverError.cancelled
            }
        }
        guard !pages.isEmpty else { throw DriverError.queryFailed(message: "no scripted page", code: nil) }
        return try pages.removeFirst().get()
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() { inFlight.cancel() }
    func setDatabase(_ name: String) async throws { throw DriverError.unsupported("setDatabase") }
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async { closeCalls += 1 }
}

/// The sleep `cancelCurrentQuery` interrupts; held outside the actor because
/// the cancel must work while the actor is suspended in `queryPartition`.
private final class InFlightSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    func set(_ task: Task<Void, Error>) { lock.lock(); self.task = task; lock.unlock() }
    func cancel() { lock.lock(); let current = task; lock.unlock(); current?.cancel() }
}
