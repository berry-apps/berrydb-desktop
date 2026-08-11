import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// Cancellation state reachable from outside the actor (same reasoning as
/// `QdrantCancelBox`, docs/architecture/12 §5): `cancelCurrentQuery()` must
/// work while the actor is busy awaiting an in-flight `getMore`.
private final class MongoCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return task }
        set { lock.lock(); defer { lock.unlock() }; task = newValue }
    }
}

public actor MongoConnection: DataSourceConnection {
    public nonisolated let id = UUID()

    private nonisolated let client: MongoWireClient
    private nonisolated let cancelBox = MongoCancelBox()
    /// Working database for find/collections — Mongo convention: defaults to
    /// `"test"` when the connection profile doesn't specify one (deliberately
    /// different from `MongoWireClient.authDatabase`'s `"admin"` default —
    /// same distinction the mongo shell/drivers make).
    private nonisolated let database: String
    private var isClosed = false

    /// N3 (docs/architecture/12 §2): 500-1000 documents per batch — used both
    /// as the `batchSize` sent to `find`/`aggregate`/`getMore` (so mongod
    /// itself pages results, never a full-result buffer on our side) and as
    /// the size of each `.items` chunk yielded to callers.
    static let batchSize = 1000

    init(config: ConnectionConfig, transport: MongoTransport? = nil) throws {
        self.client = try MongoWireClient(config: config, transport: transport)
        self.database = (config.database?.isEmpty == false) ? config.database! : "test"
    }

    /// Performs the TCP connect + `hello` handshake + SCRAM auth — the
    /// "Test connection" (KN-06) fail-fast point `MongoDriver.connect` calls
    /// before returning.
    func open() async throws {
        try await client.connect()
    }

    public func listCollections() async throws -> [CollectionRef] {
        guard !isClosed else { throw DataSourceError.notConnected }
        let all = try await client.listCollections(database: database)
        return all.filter { !$0.name.hasPrefix("system.") }
    }

    /// `ref.database` is ignored — always creates on this connection's own
    /// working `database` (see `DataSourceConnection.createCollection`).
    /// `options` is ignored for v1.
    public func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {
        guard !isClosed else { throw DataSourceError.notConnected }
        try await client.createCollection(database: database, collection: ref.name)
    }

    // MARK: - Query (NS-01/02, docs/architecture/12 §3)

    public nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(request, continuation: continuation)
            }
            cancelBox.current = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        _ request: DataSourceQuery, continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        guard !isClosed else {
            continuation.finish(throwing: DataSourceError.notConnected)
            return
        }
        switch request {
        case .qdrantSearch, .qdrantScroll:
            continuation.finish(throwing: DataSourceError.unsupported(
                "MongoConnection does not support Qdrant-shaped queries"
            ))
        case .esSearch, .esScroll:
            continuation.finish(throwing: DataSourceError.unsupported(
                "MongoConnection does not support Elasticsearch-shaped queries"
            ))
        case .mongoFind(let collection, let filter, let projection, let limit):
            await runFind(collection: collection, filter: filter, projection: projection, limit: limit, continuation: continuation)
        case .mongoAggregate(let collection, let pipeline):
            await runAggregate(collection: collection, pipeline: pipeline, continuation: continuation)
        case .mongoListIndexes(let collection):
            await runListIndexes(collection: collection, continuation: continuation)
        }
    }

    private func runFind(
        collection: String, filter: BerryDocument, projection: BerryDocument?, limit: Int?,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let firstPage = try await client.find(
                database: database, collection: collection, filter: filter, projection: projection,
                limit: limit, batchSize: Self.batchSize
            )
            let total = try await streamCursor(firstPage, collection: collection, limit: limit, continuation: continuation)
            continuation.yield(.complete(DataSourceStats(itemsReturned: total, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private func runAggregate(
        collection: String, pipeline: [BerryDocument],
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let firstPage = try await client.aggregate(
                database: database, collection: collection, pipeline: pipeline, batchSize: Self.batchSize
            )
            let total = try await streamCursor(firstPage, collection: collection, limit: nil, continuation: continuation)
            continuation.yield(.complete(DataSourceStats(itemsReturned: total, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private func runListIndexes(
        collection: String, continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let firstPage = try await client.listIndexes(database: database, collection: collection, batchSize: Self.batchSize)
            let total = try await streamCursor(firstPage, collection: collection, limit: nil, continuation: continuation)
            continuation.yield(.complete(DataSourceStats(itemsReturned: total, duration: clock.now - started)))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Drains a Mongo cursor via `getMore` until it's exhausted
    /// (`cursorID == 0`) or `limit` is reached, yielding each page as one
    /// `.items` batch — server-side paging, never buffering the full result
    /// set (N3).
    private func streamCursor(
        _ firstPage: MongoWireClient.CursorPage, collection: String, limit: Int?,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async throws -> Int {
        var page = firstPage
        var total = 0
        while true {
            try Task.checkCancellation()
            if !page.documents.isEmpty {
                continuation.yield(.items(page.documents))
                total += page.documents.count
            }
            if let limit, total >= limit { break }
            guard page.cursorID != 0 else { break }
            page = try await client.getMore(
                database: database, collection: collection, cursorID: page.cursorID, batchSize: Self.batchSize
            )
        }
        return total
    }

    private static func mapError(_ error: Error) -> DataSourceError {
        if let dataSourceError = error as? DataSourceError { return dataSourceError }
        if error is CancellationError { return .cancelled }
        return .connectionFailed(error.localizedDescription)
    }

    // MARK: - Write (docs/architecture/12 §6)

    public func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        guard !isClosed else { throw DataSourceError.notConnected }
        switch change {
        case .insert(let collection, let document):
            return try await insert(collection: collection, document: document)
        case .update(let collection, let id, let patch):
            return try await update(collection: collection, id: id, patch: patch)
        case .delete(let collection, let id):
            return try await delete(collection: collection, id: id)
        case .updateByFilter(let collection, let filter, let update, let multi):
            return try await updateByFilter(collection: collection, filter: filter, update: update, multi: multi)
        case .deleteByFilter(let collection, let filter, let multi):
            return try await deleteByFilter(collection: collection, filter: filter, multi: multi)
        case .dropCollection(let collection):
            try await client.drop(database: database, collection: collection)
            return DataSourceWriteResult(affectedCount: 0)
        case .createIndex(let collection, let keys, let options):
            try await client.createIndex(database: database, collection: collection, keys: keys, options: options)
            return DataSourceWriteResult(affectedCount: 0)
        case .dropIndex(let collection, let indexName):
            try await client.dropIndex(database: database, collection: collection, indexName: indexName)
            return DataSourceWriteResult(affectedCount: 0)
        case .renameCollection(let collection, let newName):
            try await client.renameCollection(database: database, collection: collection, newName: newName)
            return DataSourceWriteResult(affectedCount: 0)
        }
    }

    private func insert(collection: String, document: BerryDocument) async throws -> DataSourceWriteResult {
        let (count, insertedID) = try await client.insert(database: database, collection: collection, document: document)
        return DataSourceWriteResult(affectedCount: count, insertedID: insertedID)
    }

    /// `id` becomes an equality filter on `_id`; `patch` is wrapped in
    /// `$set` — a partial-field update (leaves every field not in `patch`
    /// untouched), matching "patch" semantics rather than a full document
    /// replacement. A caller wanting whole-document replacement is out of
    /// this v1 scope (documented gap, docs/architecture/12 §3).
    private func update(collection: String, id: BerryDocument, patch: BerryDocument) async throws -> DataSourceWriteResult {
        let filter = BerryDocument.object([("_id", id)])
        let setDoc = BerryDocument.object([("$set", patch)])
        let count = try await client.update(database: database, collection: collection, filter: filter, update: setDoc, multi: false)
        return DataSourceWriteResult(affectedCount: count)
    }

    /// An empty/missing id is the "no filter" delete case (NS-08,
    /// `DataSourceDangerGuard`) — the caller already confirmed via the danger
    /// gate (DL-03/04) before this runs; here it just decides `{}`
    /// (deleteMany-everything) vs. an `_id` equality filter (deleteOne).
    private func delete(collection: String, id: BerryDocument) async throws -> DataSourceWriteResult {
        let classification = DataSourceDangerGuard.classify(.delete(collection: collection, id: id))
        let filter: BerryDocument = classification == .confirm(.deleteWithoutFilter) ? .object([]) : .object([("_id", id)])
        let multi = classification == .confirm(.deleteWithoutFilter)
        let count = try await client.delete(database: database, collection: collection, filter: filter, multi: multi)
        return DataSourceWriteResult(affectedCount: count)
    }

    /// Unlike `update(collection:id:patch:)`, this update document already carries its own operators (e.g. `$set`/`$push`) — do not wrap it in `$set` again.
    private func updateByFilter(
        collection: String, filter: BerryDocument, update: BerryDocument, multi: Bool
    ) async throws -> DataSourceWriteResult {
        let count = try await client.update(
            database: database, collection: collection, filter: filter, update: update, multi: multi
        )
        return DataSourceWriteResult(affectedCount: count)
    }

    /// Filter-based delete operation — only specified documents matching the filter are removed.
    private func deleteByFilter(
        collection: String, filter: BerryDocument, multi: Bool
    ) async throws -> DataSourceWriteResult {
        let count = try await client.delete(database: database, collection: collection, filter: filter, multi: multi)
        return DataSourceWriteResult(affectedCount: count)
    }

    // MARK: - User management (TI-03 Phase C, docs/architecture/14)

    public func listUsers() async throws -> [DataSourceUserInfo] {
        guard !isClosed else { throw DataSourceError.notConnected }
        return try await client.usersInfo(database: database)
    }

    public func createUser(username: String, password: String, roles: [String]) async throws {
        guard !isClosed else { throw DataSourceError.notConnected }
        try await client.createUser(database: database, username: username, password: password, roles: roles)
    }

    public func dropUser(username: String) async throws {
        guard !isClosed else { throw DataSourceError.notConnected }
        try await client.dropUser(database: database, username: username)
    }

    // MARK: - Control

    public nonisolated func cancelCurrentQuery() {
        cancelBox.current?.cancel()
    }

    public nonisolated var introspector: any DataSourceIntrospector {
        MongoIntrospector(client: client, database: database)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        return await client.ping()
    }

    public func close() async {
        isClosed = true
        await client.close()
    }
}
