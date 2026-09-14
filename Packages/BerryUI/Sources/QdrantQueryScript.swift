import BerryDataSourceKit
import Foundation

/// The Qdrant query DSL — a JSON document that is the canonical,
/// runnable form of a Qdrant query, the vector-store analogue of a Mongo shell
/// script. It is what the hybrid Form/JSON query tab edits, what history stores
/// verbatim, and what a saved query persists. Reads map to `DataSourceQuery`,
/// writes to `DataSourceChangeSet` (the driver already supports both).
///
/// ```jsonc
/// { "collection": "docs", "vector": [0.1, 0.2], "top": 10,
///   "filter": { "lang": "vi" }, "score_threshold": 0.7 }   // search
/// { "collection": "docs", "filter": { "lang": "vi" } }       // scroll (no vector)
/// { "op": "upsert", "collection": "docs",
///   "points": [ { "id": 1, "vector": [0.1, 0.2], "payload": { "lang": "vi" } } ] }
/// { "op": "delete", "collection": "docs", "ids": [1, 2, 3] }
/// ```
public enum QdrantQuery: Sendable, Equatable {
    case search(collection: String, vector: [Float], filter: BerryDocument?, topK: Int, scoreThreshold: Double?)
    case scroll(collection: String, filter: BerryDocument?)
    case upsert(collection: String, points: [BerryDocument])
    case delete(collection: String, ids: [BerryDocument])

    public var collection: String {
        switch self {
        case .search(let c, _, _, _, _), .scroll(let c, _), .upsert(let c, _), .delete(let c, _): return c
        }
    }

    public var isWrite: Bool {
        switch self {
        case .search, .scroll: return false
        case .upsert, .delete: return true
        }
    }

    /// The read query to stream into the result grid, or nil for a write op.
    public var readQuery: DataSourceQuery? {
        switch self {
        case let .search(c, vector, filter, topK, threshold):
            return .qdrantSearch(collection: c, vector: vector, filter: filter, topK: topK, scoreThreshold: threshold)
        case let .scroll(c, filter):
            return .qdrantScroll(collection: c, filter: filter, pageToken: nil)
        case .upsert, .delete:
            return nil
        }
    }

    /// The write(s) to apply through the danger gate, or nil for a read op.
    /// Each point/id is one change so the confirm flow can preview them individually.
    public var changeSets: [DataSourceChangeSet]? {
        switch self {
        case let .upsert(c, points):
            return points.map { .insert(collection: c, document: $0) }
        case let .delete(c, ids):
            return ids.map { .delete(collection: c, id: $0) }
        case .search, .scroll:
            return nil
        }
    }
}

public enum QdrantQueryError: Error, Equatable, LocalizedError {
    case empty
    case notJSON
    case notObject
    case missingCollection
    case invalidOp(String)
    case searchNeedsVector
    case upsertNeedsPoints
    case pointNeedsVector
    case deleteNeedsIDs

    public var errorDescription: String? {
        switch self {
        case .empty: return "Query is empty."
        case .notJSON: return "Query is not valid JSON."
        case .notObject: return "Query must be a JSON object."
        case .missingCollection: return "Query needs a \"collection\"."
        case .invalidOp(let op): return "Unknown op \"\(op)\" (expected search, scroll, upsert, or delete)."
        case .searchNeedsVector: return "A search needs a numeric \"vector\" array."
        case .upsertNeedsPoints: return "upsert needs a non-empty \"points\" array."
        case .pointNeedsVector: return "Every upserted point needs a \"vector\"."
        case .deleteNeedsIDs: return "delete needs a non-empty \"ids\" array."
        }
    }
}

/// Parser/serializer for the Qdrant query DSL — the vector-store sibling of
/// `MongoShellParser`/`MongoShellResolver`.
public enum QdrantQueryScript {
    public static func parse(_ text: String) throws -> QdrantQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QdrantQueryError.empty }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { throw QdrantQueryError.notJSON }
        guard let dict = parsed as? [String: Any] else { throw QdrantQueryError.notObject }
        guard let collection = dict["collection"] as? String, !collection.isEmpty else { throw QdrantQueryError.missingCollection }

        let filter = filterDocument(dict["filter"])
        let op = (dict["op"] as? String)?.lowercased()

        switch op {
        case "upsert":
            guard let rawPoints = dict["points"] as? [Any], !rawPoints.isEmpty else { throw QdrantQueryError.upsertNeedsPoints }
            var points: [BerryDocument] = []
            for raw in rawPoints {
                guard let object = raw as? [String: Any] else { throw QdrantQueryError.upsertNeedsPoints }
                guard object["vector"] != nil else { throw QdrantQueryError.pointNeedsVector }
                points.append(BerryDocument(jsonObject: object))
            }
            return .upsert(collection: collection, points: points)

        case "delete":
            guard let rawIDs = dict["ids"] as? [Any], !rawIDs.isEmpty else { throw QdrantQueryError.deleteNeedsIDs }
            return .delete(collection: collection, ids: rawIDs.map { BerryDocument(jsonObject: $0) })

        case "search", "scroll", nil:
            let vector = vectorArray(dict["vector"])
            // Explicit "search", or no op with a vector present → vector search.
            if op == "search" || (op == nil && !(vector ?? []).isEmpty) {
                guard let vector, !vector.isEmpty else { throw QdrantQueryError.searchNeedsVector }
                let topK = intValue(dict["top"]) ?? 10
                return .search(
                    collection: collection, vector: vector, filter: filter,
                    topK: topK, scoreThreshold: doubleValue(dict["score_threshold"])
                )
            }
            return .scroll(collection: collection, filter: filter)

        default:
            throw QdrantQueryError.invalidOp(op ?? "")
        }
    }

    /// Canonical JSON text for a query — used to seed the JSON editor from the
    /// form, and to persist history/saved queries.
    public static func json(for query: QdrantQuery) -> String {
        var dict: [String: Any] = [:]
        switch query {
        case let .search(collection, vector, filter, topK, threshold):
            dict["collection"] = collection
            dict["vector"] = vector.map { Double($0) }
            dict["top"] = topK
            if let filter { dict["filter"] = filter.jsonObject }
            if let threshold { dict["score_threshold"] = threshold }
        case let .scroll(collection, filter):
            dict["collection"] = collection
            if let filter { dict["filter"] = filter.jsonObject }
        case let .upsert(collection, points):
            dict["op"] = "upsert"
            dict["collection"] = collection
            dict["points"] = points.map(\.jsonObject)
        case let .delete(collection, ids):
            dict["op"] = "delete"
            dict["collection"] = collection
            dict["ids"] = ids.map(\.jsonObject)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: - Form-field helpers (Form ⇄ JSON sync)

    /// Parse a form vector field (`[0.1, 0.2]`) → floats, or nil if blank/invalid.
    public static func parseVector(_ text: String) -> [Float]? {
        vectorArray(jsonValue(text))
    }

    /// Parse a form filter field (`{ "lang": "vi" }`) → document, or nil if blank/invalid.
    public static func parseFilter(_ text: String) -> BerryDocument? {
        filterDocument(jsonValue(text))
    }

    /// A vector as a compact JSON array, for seeding the form's vector field.
    public static func json(forVector vector: [Float]) -> String {
        vector.isEmpty ? "" : compactJSON(vector.map { Double($0) })
    }

    /// A document as compact JSON text, for seeding the form's filter field.
    public static func jsonText(for document: BerryDocument) -> String {
        compactJSON(document.jsonObject)
    }

    private static func jsonValue(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is [Any],
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - JSON value helpers

    private static func filterDocument(_ value: Any?) -> BerryDocument? {
        guard let object = value as? [String: Any], !object.isEmpty else { return nil }
        return BerryDocument(jsonObject: object)
    }

    private static func vectorArray(_ value: Any?) -> [Float]? {
        guard let array = value as? [Any] else { return nil }
        return array.compactMap { ($0 as? NSNumber)?.floatValue }
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
