import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// Cancellation state reachable from outside the actor — same reasoning as
/// `QdrantCancelBox`: `cancelCurrentQuery()` must work while the actor is
/// busy awaiting an in-flight HTTP request.
private final class ElasticsearchCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? {
        get { lock.lock(); defer { lock.unlock() }; return task }
        set { lock.lock(); defer { lock.unlock() }; task = newValue }
    }
}

public actor ElasticsearchConnection: DataSourceConnection {
    public nonisolated let id = UUID()

    private let client: ElasticsearchHTTPClient
    private nonisolated let cancelBox = ElasticsearchCancelBox()
    private var isClosed = false

    /// Batch/page size for `.esScroll` and for chunking `.esSearch` results —
 /// N3's 500-1000 floor.
    static let batchSize = 500

    init(config: ConnectionConfig, session: URLSession = URLSession(configuration: .ephemeral)) throws {
        self.client = try ElasticsearchHTTPClient(config: config, session: session)
    }

    public func listCollections() async throws -> [CollectionRef] {
        guard !isClosed else { throw DataSourceError.notConnected }
        return try await client.listIndices()
    }

    public func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {
        guard !isClosed else { throw DataSourceError.notConnected }
        try await client.createIndex(name: ref.name)
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
                "ElasticsearchConnection does not support Mongo-shaped queries"
            ))
        case .qdrantSearch, .qdrantScroll:
            continuation.finish(throwing: DataSourceError.unsupported(
                "ElasticsearchConnection does not support Qdrant-shaped queries"
            ))
        case .esSearch(let index, let query, let from, let size):
            await runSearch(index: index, query: query, from: from, size: size, continuation: continuation)
        case .esScroll(let index, let query, let pageToken):
            await runScroll(index: index, query: query, pageToken: pageToken, continuation: continuation)
        }
    }

    private func runSearch(
        index: String, query: BerryDocument, from: Int, size: Int,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let hits = try await client.search(index: index, query: query, from: from, size: size)
            let docs = hits.map(ElasticsearchWire.document(fromHitJSON:))
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
        index: String, query: BerryDocument, pageToken: String?,
        continuation: AsyncThrowingStream<DataSourceEvent, Error>.Continuation
    ) async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let page = try await client.scroll(index: index, query: query, pageToken: pageToken, size: Self.batchSize)
            let docs = page.hits.map(ElasticsearchWire.document(fromHitJSON:))
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
        case .insert(let index, let document):
            return try await insert(index: index, document: document)
        case .update(let index, let id, let patch):
            return try await update(index: index, id: id, patch: patch)
        case .delete(let index, let id):
            return try await delete(index: index, id: id)
        case .deleteByFilter(let index, let filter, _):
            let deleted = try await client.deleteByQuery(index: index, query: filter)
            return DataSourceWriteResult(affectedCount: deleted)
        case .updateByFilter:
            throw DataSourceError.unsupported(
                "Elasticsearch does not support a filter-based bulk update with an arbitrary patch — "
                    + "that needs a Painless script, out of v1 scope. Update by the document's _id instead."
            )
        case .dropCollection(let index):
            try await client.dropIndex(name: index)
            return DataSourceWriteResult(affectedCount: 0)
        case .createIndex:
            throw DataSourceError.unsupported(
                "Elasticsearch indexes every field automatically — no secondary index management through the shell."
            )
        case .dropIndex:
            throw DataSourceError.unsupported(
                "Elasticsearch indexes every field automatically — no secondary index management through the shell."
            )
        case .renameCollection:
            throw DataSourceError.unsupported(
                "Elasticsearch does not support renaming an index through the shell — reindex + alias swap is out of v1 scope."
            )
        }
    }

    /// Expects `document` shaped as `.object`, with an optional `"_id"` field
    /// (used verbatim if present, matching Mongo's own "_id"-if-supplied
    /// convention) — the rest becomes the indexed `_source`.
    private func insert(index: String, document: BerryDocument) async throws -> DataSourceWriteResult {
        guard case .object(var fields) = document else {
            throw DataSourceError.queryFailed("Insert requires a document object")
        }
        let explicitID: String? = if case .string(let s)? = document["_id"] { s } else { nil }
        fields.removeAll { $0.0 == "_id" }
        let source = (BerryDocument.object(fields).jsonObject as? [String: Any]) ?? [:]
        let insertedID = try await client.indexDocument(index: index, id: explicitID, source: source)
        return DataSourceWriteResult(affectedCount: 1, insertedID: .string(insertedID))
    }

    private func update(index: String, id: BerryDocument, patch: BerryDocument) async throws -> DataSourceWriteResult {
        guard case .string(let docID) = id, !docID.isEmpty else {
            throw DataSourceError.queryFailed("Update requires a document _id")
        }
        guard let patchObject = patch.jsonObject as? [String: Any] else {
            throw DataSourceError.queryFailed("Update patch must be an object")
        }
        try await client.updateDocument(index: index, id: docID, patch: patchObject)
        return DataSourceWriteResult(affectedCount: 1)
    }

 /// An empty/missing id is the "no filter" delete case (-equivalent,
    /// `DataSourceDangerGuard`) — the caller already confirmed via the danger
 /// gate before this runs; here it just decides HOW to delete.
    private func delete(index: String, id: BerryDocument) async throws -> DataSourceWriteResult {
        let classification = DataSourceDangerGuard.classify(.delete(collection: index, id: id))
        if classification == .confirm(.deleteWithoutFilter) {
            let deleted = try await client.deleteByQuery(index: index, query: .null)
            return DataSourceWriteResult(affectedCount: deleted)
        }
        guard case .string(let docID) = id else {
            throw DataSourceError.queryFailed("Delete requires a document _id")
        }
        try await client.deleteDocument(index: index, id: docID)
        return DataSourceWriteResult(affectedCount: 1)
    }

    // MARK: - Control

    public nonisolated func cancelCurrentQuery() {
        cancelBox.current?.cancel()
    }

    public nonisolated var introspector: any DataSourceIntrospector {
        ElasticsearchIntrospector(client: client)
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
