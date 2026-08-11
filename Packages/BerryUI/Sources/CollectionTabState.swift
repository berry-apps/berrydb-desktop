import BerryCore
import BerryDataSourceKit
import Foundation
import Observation

/// State of one collection/point-collection tab (docs/architecture/12 §7) —
/// the `DataSourceQuery` sibling of `TableTabState`. Unlike `TableTabState`,
/// writes are NOT staged locally: insert/update/delete are single-shot,
/// funneled through `WorkspaceViewModel.applyDataSourceWrite` (native-command
/// preview + confirm, docs/architecture/12 §6), then the tab just reloads.
///
/// Qdrant-only (`.vector`) since Task 8 routed `.document` collections to
/// `MongoShellTabState`/`MongoShellTabView` instead.
@MainActor
@Observable
public final class CollectionTabState: @MainActor Identifiable {
    public let ref: CollectionRef
    public let kind: DataSourceKind
    public let buffer = DataSourceResultBuffer()

    /// Qdrant: raw JSON vector array for `.qdrantSearch` — empty runs
    /// `.qdrantScroll` (browse all points) instead.
    public var vectorText: String = ""
    public var topK: Int = 10
    /// Qdrant: optional minimum similarity score for `.qdrantSearch` — blank
    /// text means "no threshold" (`nil`).
    public var scoreThresholdText: String = ""
    /// Qdrant: optional JSON payload filter, applies to both `.qdrantSearch`
    /// and `.qdrantScroll` — blank text means "no filter" (`nil`).
    public var payloadFilterText: String = ""

    private let connection: any DataSourceConnection

    public var id: String { ref.id }

    public init(ref: CollectionRef, kind: DataSourceKind, connection: any DataSourceConnection) {
        self.ref = ref
        self.kind = kind
        self.connection = connection
    }

    public func run() {
        let query = currentQuery()
        let startedAt = Date()
        let clock = ContinuousClock()
        let began = clock.now
        buffer.consume(connection.query(query))
        Task { [weak self] in
            guard let self else { return }
            await self.buffer.waitUntilFinished()
            Self.recordHistory(query: query, startedAt: startedAt, duration: clock.now - began, buffer: self.buffer)
        }
    }

    public func cancel() {
        buffer.cancel()
    }

    private func currentQuery() -> DataSourceQuery {
        let filter = Self.parseOptionalFilter(payloadFilterText)
        switch kind {
        case .document:
            return .mongoFind(collection: ref.name, filter: filter ?? .object([]), projection: nil, limit: 50)
        case .vector:
            if let vector = Self.parseVector(vectorText), !vector.isEmpty {
                return .qdrantSearch(
                    collection: ref.name, vector: vector, filter: filter,
                    topK: topK, scoreThreshold: Self.parseScoreThreshold(scoreThresholdText)
                )
            }
            return .qdrantScroll(collection: ref.name, filter: filter, pageToken: nil)
        case .search:
            // `payloadFilterText` doubles as the ES Query DSL filter — no
            // vector concept for Elasticsearch in v1, so vectorText/topK/
            // scoreThresholdText (Qdrant-only fields) stay unused here.
            return .esScroll(index: ref.name, query: filter ?? .null, pageToken: nil)
        }
    }

    private static func recordHistory(
        query: DataSourceQuery, startedAt: Date, duration: Duration, buffer: DataSourceResultBuffer
    ) {
        let status: ExecutedStatement.Status
        var errorMessage: String?
        switch buffer.state {
        case .complete: status = .success
        case .cancelled: status = .cancelled
        case .failed(let message): status = .failed; errorMessage = message
        case .running: return
        }
        QueryService.historySink?.record(ExecutedStatement(
            profileID: nil, sql: Self.describe(query), startedAt: startedAt,
            duration: duration, status: status, rowCount: buffer.itemCount, errorMessage: errorMessage
        ))
    }

    /// The canonical Qdrant query JSON (docs/feature/03) so the history entry is
    /// runnable — replaying it opens a Qdrant query tab with the exact query,
    /// unlike the old readable-description form which could not re-run.
    private static func describe(_ query: DataSourceQuery) -> String {
        switch query {
        case let .qdrantSearch(collection, vector, filter, topK, threshold):
            return QdrantQueryScript.json(for: .search(
                collection: collection, vector: vector, filter: filter, topK: topK, scoreThreshold: threshold
            ))
        case let .qdrantScroll(collection, filter, _):
            return QdrantQueryScript.json(for: .scroll(collection: collection, filter: filter))
        case let .esScroll(index, query, _):
            return ElasticsearchQueryScript.json(for: .scroll(index: index, query: query))
        default:
            return "qdrant query"
        }
    }

    // MARK: - Text → query params

    /// Like `parseFilter` (Mongo, removed with the rest of the Mongo-only
    /// query path), but blank/invalid text is `nil` ("no filter")
    /// rather than `.object([])` — the shape `.qdrantSearch`/`.qdrantScroll`'s
    /// optional `filter` param needs.
    static func parseOptionalFilter(_ text: String) -> BerryDocument? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return BerryDocument(jsonObject: json)
    }

    static func parseVector(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [NSNumber]
        else { return nil }
        return array.map(\.floatValue)
    }

    static func parseScoreThreshold(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    // MARK: - Edit-in-place support (docs/architecture/12 §7)

    /// The write-model id for a returned document — Mongo carries it in
    /// `_id`; Qdrant's driver folds it into a top-level `id` field
    /// (`QdrantWire.document(fromPointJSON:)`); Elasticsearch's also nests
    /// under `_id`, same as Mongo (`ElasticsearchWire.document(fromHitJSON:)`).
    static func id(of document: BerryDocument, kind: DataSourceKind) -> BerryDocument {
        switch kind {
        case .document, .search: return document["_id"] ?? .null
        case .vector: return document["id"] ?? .null
        }
    }

    /// Builds an `.update` patch from a fully-edited document, stripping
    /// fields the write model doesn't accept as part of a patch: Mongo's
    /// immutable `_id`, and Qdrant's server-computed `score` (present on
    /// search results, never settable — `QdrantConnection.update` only reads
    /// `vector`/`payload`).
    static func patch(from edited: BerryDocument, kind: DataSourceKind) -> BerryDocument {
        guard case .object(let fields) = edited else { return edited }
        switch kind {
        case .document:
            return .object(fields.filter { $0.0 != "_id" })
        case .vector:
            return .object(fields.filter { $0.0 != "id" && $0.0 != "score" })
        case .search:
            // The read shape nests real fields under "_source"
            // (`ElasticsearchWire.document(fromHitJSON:)`) alongside
            // top-level "_id"/"_score" metadata — unwrap it so the patch
            // sent to `ElasticsearchConnection.update` is the flat field
            // set ES's `_update` API expects, not a document containing a
            // literal "_source" field.
            if case .object(let sourceFields)? = edited["_source"] {
                return .object(sourceFields)
            }
            return .object(fields.filter { $0.0 != "_id" && $0.0 != "_score" && $0.0 != "_source" })
        }
    }
}
