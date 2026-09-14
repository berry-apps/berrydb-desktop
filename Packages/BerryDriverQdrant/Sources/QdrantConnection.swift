import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// Cancellation state reachable from outside the actor (same reasoning as
/// `PostgresCancelBox` in BerryDriverPostgres):
/// `cancelCurrentQuery()` must work while the actor is busy awaiting the
/// in-flight HTTP request.
private final class QdrantCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return task }
        set { lock.lock(); defer { lock.unlock() }; task = newValue }
    }
}

public actor QdrantConnection: DataSourceConnection {
    public nonisolated let id = UUID()

    private let client: QdrantHTTPClient
    private nonisolated let cancelBox = QdrantCancelBox()
    private var isClosed = false

    /// Batch/page size for scroll and for chunking search results — N3
 /// "Qdrant search top-K is usually small, but
    /// scroll must batch/paginate."
    static let batchSize = 1000

    init(config: ConnectionConfig, session: URLSession = URLSession(configuration: .ephemeral)) throws {
        self.client = try QdrantHTTPClient(config: config, session: session)
    }

    public func listCollections() async throws -> [CollectionRef] {
        guard !isClosed else { throw DataSourceError.notConnected }
        return try await client.listCollections()
    }

    /// See `DataSourceConnection.createCollection` for the `options` shape
    /// this driver expects — validated here so a malformed/missing
    /// `vectorSize` never reaches `QdrantHTTPClient` as a broken request.
    public func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {
        guard !isClosed else { throw DataSourceError.notConnected }
        guard case .int(let size)? = options["vectorSize"], size > 0 else {
            throw DataSourceError.queryFailed("createCollection requires a positive integer \"vectorSize\" field")
        }
        var distance = "Cosine"
        if case .string(let d)? = options["distance"] { distance = d }
        try await client.createCollection(name: ref.name, vectorSize: Int(size), distance: distance)
    }

 // MARK: - Query

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
        _ request: DataSourceQuery,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        guard !isClosed else {
            continuation.finish(throwing: DataSourceError.notConnected)
            return
        }
        switch request {
        case .mongoFind, .mongoAggregate, .mongoListIndexes:
            continuation.finish(throwing: DataSourceError.unsupported(
                "QdrantConnection does not support Mongo-shaped queries"
            ))
        case .esSearch, .esScroll:
            continuation.finish(throwing: DataSourceError.unsupported(
                "QdrantConnection does not support Elasticsearch-shaped queries"
            ))
        case .qdrantSearch(let collection, let vector, let filter, let topK, let scoreThreshold):
            await runSearch(
                collection: collection, vector: vector, filter: filter,
                topK: topK, scoreThreshold: scoreThreshold, continuation: continuation
            )
        case .qdrantScroll(let collection, let filter, let pageToken):
            await runScroll(collection: collection, filter: filter, pageToken: pageToken, continuation: continuation)
        }
    }

    private func runSearch(
        collection: String, vector: [Float], filter: BerryDocument?, topK: Int, scoreThreshold: Double?,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let points = try await client.search(
                collection: collection, vector: vector, filter: filter, topK: topK, scoreThreshold: scoreThreshold
            )
            let docs = points.map(QdrantWire.document(fromPointJSON:))
            for chunk in docs.chunked(into: Self.batchSize) {
                continuation.yield(.items(chunk))
            }
            continuation.yield(.complete(
                DataSourceStats(itemsReturned: docs.count, duration: clock.now - started, nextPageToken: nil)
            ))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private func runScroll(
        collection: String, filter: BerryDocument?, pageToken: String?,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let page = try await client.scroll(
                collection: collection, filter: filter, pageToken: pageToken,
                limit: Self.batchSize, withVector: true
            )
            let docs = page.points.map(QdrantWire.document(fromPointJSON:))
            if !docs.isEmpty { continuation.yield(.items(docs)) }
            continuation.yield(.complete(
                DataSourceStats(itemsReturned: docs.count, duration: clock.now - started, nextPageToken: page.nextPageToken)
            ))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private static func mapError(_ error: Error) -> DataSourceError {
        if let dataSourceError = error as? DataSourceError { return dataSourceError }
        if error is CancellationError { return .cancelled }
        return .connectionFailed(error.localizedDescription)
    }

 // MARK: - Write

    public func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        guard !isClosed else { throw DataSourceError.notConnected }
        switch change {
        case .insert(let collection, let document):
            return try await insert(collection: collection, document: document)
        case .update(let collection, let id, let patch):
            return try await update(collection: collection, id: id, patch: patch)
        case .delete(let collection, let id):
            return try await delete(collection: collection, id: id)
        case .updateByFilter:
            throw DataSourceError.unsupported("Qdrant does not support filter-based bulk update — use the point's id.")
        case .deleteByFilter:
            throw DataSourceError.unsupported("Qdrant does not support filter-based bulk delete — use the point's id.")
        case .dropCollection:
            throw DataSourceError.unsupported("Qdrant does not support dropping a collection through the shell.")
        case .createIndex:
            throw DataSourceError.unsupported("Qdrant does not support index management through the shell.")
        case .dropIndex:
            throw DataSourceError.unsupported("Qdrant does not support index management through the shell.")
        case .renameCollection:
            throw DataSourceError.unsupported("Qdrant does not support renaming a collection through the shell.")
        }
    }

    /// Expects `document` shaped as `.object` with an optional `"id"` field,
    /// a required `"vector"` field, and an optional `"payload"` field — the
 /// point shape a caller builds for `.insert`.
    private func insert(collection: String, document: BerryDocument) async throws -> DataSourceWriteResult {
        guard let vectorDoc = document["vector"], let vector = QdrantWire.vectorArray(from: vectorDoc) else {
            throw DataSourceError.queryFailed("Insert requires a \"vector\" field")
        }
        let idDoc = document["id"] ?? .string(UUID().uuidString)
        let pointID = QdrantWire.pointID(from: idDoc)
        try await client.upsertPoint(
            collection: collection, id: pointID, vector: vector, payload: Self.payloadDict(from: document["payload"])
        )
        return DataSourceWriteResult(affectedCount: 1, insertedID: idDoc)
    }

    /// `patch` supplying `"vector"` does a full upsert (replaces the point);
    /// a payload-only patch uses the dedicated set-payload endpoint instead so
    /// it can never accidentally wipe the point's vector.
    private func update(collection: String, id: BerryDocument, patch: BerryDocument) async throws -> DataSourceWriteResult {
        let pointID = QdrantWire.pointID(from: id)
        if let vectorDoc = patch["vector"], let vector = QdrantWire.vectorArray(from: vectorDoc) {
            try await client.upsertPoint(
                collection: collection, id: pointID, vector: vector, payload: Self.payloadDict(from: patch["payload"])
            )
        } else if let payload = Self.payloadDict(from: patch["payload"]) {
            try await client.setPayload(collection: collection, id: pointID, payload: payload)
        } else {
            throw DataSourceError.queryFailed("Update patch must include \"vector\" and/or \"payload\"")
        }
        return DataSourceWriteResult(affectedCount: 1)
    }

 /// An empty/missing id is the "no filter" delete case
    /// `DataSourceDangerGuard`) — the caller already confirmed via the danger
 /// gate before this runs; here it just decides HOW to delete.
    private func delete(collection: String, id: BerryDocument) async throws -> DataSourceWriteResult {
        let classification = DataSourceDangerGuard.classify(.delete(collection: collection, id: id))
        if classification == .confirm(.deleteWithoutFilter) {
            let countBefore = try? await client.collectionInfo(name: collection).pointsCount
            try await client.deleteByFilter(collection: collection, filter: [:])
            return DataSourceWriteResult(affectedCount: countBefore ?? 0)
        }
        let pointID = QdrantWire.pointID(from: id)
        try await client.deleteByIDs(collection: collection, ids: [pointID])
        return DataSourceWriteResult(affectedCount: 1)
    }

    private static func payloadDict(from doc: BerryDocument?) -> [String: Any]? {
        guard let doc, case .object = doc else { return nil }
        return doc.jsonObject as? [String: Any]
    }

    // MARK: - Control

    public nonisolated func cancelCurrentQuery() {
        cancelBox.current?.cancel()
    }

    public nonisolated var introspector: any DataSourceIntrospector {
        QdrantIntrospector(client: client)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        return await client.ping()
    }

    public func close() async {
        isClosed = true
    }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
