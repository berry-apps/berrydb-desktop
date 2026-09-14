import BerryDataSourceKit
import Foundation

/// The Elasticsearch query DSL script format — a
/// JSON document that is the canonical, runnable form of an Elasticsearch
/// query/command, the search-engine sibling of `QdrantQuery`. It is what the
/// JSON query tab edits, what history stores verbatim, and what a saved
/// query persists. Reads map to `DataSourceQuery`, writes to
/// `DataSourceChangeSet` (the driver already supports both).
///
/// ```jsonc
/// { "index": "logs", "query": { "match": { "level": "error" } }, "from": 0, "size": 50 }  // search
/// { "op": "scroll", "index": "logs", "query": { "match_all": {} } }                          // scroll (paginated browse)
/// { "op": "index", "index": "logs", "document": { "level": "info" } }                        // insert
/// { "op": "update", "index": "logs", "id": "abc", "doc": { "level": "warn" } }                // update
/// { "op": "delete", "index": "logs", "id": "abc" }                                            // delete by id
/// { "op": "delete_by_query", "index": "logs", "query": { "term": { "level": "debug" } } }     // deleteByFilter
/// ```
public enum ElasticsearchQuery: Sendable, Equatable {
    case search(index: String, query: BerryDocument, from: Int, size: Int)
    case scroll(index: String, query: BerryDocument)
    case index(index: String, document: BerryDocument)
    case update(index: String, id: String, doc: BerryDocument)
    case delete(index: String, id: String)
    case deleteByQuery(index: String, query: BerryDocument)

    public var index: String {
        switch self {
        case .search(let i, _, _, _), .scroll(let i, _), .index(let i, _),
             .update(let i, _, _), .delete(let i, _), .deleteByQuery(let i, _):
            return i
        }
    }

    public var isWrite: Bool {
        switch self {
        case .search, .scroll: return false
        case .index, .update, .delete, .deleteByQuery: return true
        }
    }

    /// The read query to stream into the result grid, or nil for a write op.
    public var readQuery: DataSourceQuery? {
        switch self {
        case let .search(index, query, from, size):
            return .esSearch(index: index, query: query, from: from, size: size)
        case let .scroll(index, query):
            return .esScroll(index: index, query: query, pageToken: nil)
        case .index, .update, .delete, .deleteByQuery:
            return nil
        }
    }

    /// The write to apply through the danger gate, or nil for a read op.
    public var changeSets: [DataSourceChangeSet]? {
        switch self {
        case let .index(index, document):
            return [.insert(collection: index, document: document)]
        case let .update(index, id, doc):
            return [.update(collection: index, id: .string(id), patch: doc)]
        case let .delete(index, id):
            return [.delete(collection: index, id: .string(id))]
        case let .deleteByQuery(index, query):
            return [.deleteByFilter(collection: index, filter: query, multi: true)]
        case .search, .scroll:
            return nil
        }
    }
}

public enum ElasticsearchQueryError: Error, Equatable, LocalizedError {
    case empty
    case notJSON
    case notObject
    case missingIndex
    case invalidOp(String)
    case indexNeedsDocument
    case updateNeedsIDAndDoc
    case deleteNeedsID

    public var errorDescription: String? {
        switch self {
        case .empty: return "Query is empty."
        case .notJSON: return "Query is not valid JSON."
        case .notObject: return "Query must be a JSON object."
        case .missingIndex: return "Query needs an \"index\"."
        case .invalidOp(let op): return "Unknown op \"\(op)\" (expected search, scroll, index, update, delete, or delete_by_query)."
        case .indexNeedsDocument: return "index needs a \"document\" object."
        case .updateNeedsIDAndDoc: return "update needs an \"id\" and a \"doc\" object."
        case .deleteNeedsID: return "delete needs an \"id\"."
        }
    }
}

/// Parser/serializer for the Elasticsearch query script format — the
/// search-engine sibling of `QdrantQueryScript`.
public enum ElasticsearchQueryScript {
    public static func parse(_ text: String) throws -> ElasticsearchQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ElasticsearchQueryError.empty }
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { throw ElasticsearchQueryError.notJSON }
        guard let dict = parsed as? [String: Any] else { throw ElasticsearchQueryError.notObject }
        guard let index = dict["index"] as? String, !index.isEmpty else { throw ElasticsearchQueryError.missingIndex }

        let query = queryDocument(dict["query"])
        let op = (dict["op"] as? String)?.lowercased()

        switch op {
        case "index", "insert":
            guard let raw = dict["document"] as? [String: Any] else { throw ElasticsearchQueryError.indexNeedsDocument }
            return .index(index: index, document: BerryDocument(jsonObject: raw))

        case "update":
            guard let id = dict["id"] as? String, !id.isEmpty,
                  let raw = dict["doc"] as? [String: Any]
            else { throw ElasticsearchQueryError.updateNeedsIDAndDoc }
            return .update(index: index, id: id, doc: BerryDocument(jsonObject: raw))

        case "delete":
            guard let id = dict["id"] as? String, !id.isEmpty else { throw ElasticsearchQueryError.deleteNeedsID }
            return .delete(index: index, id: id)

        case "delete_by_query":
            return .deleteByQuery(index: index, query: query ?? .null)

        case "scroll":
            return .scroll(index: index, query: query ?? .null)

        case "search", nil:
            let from = intValue(dict["from"]) ?? 0
            let size = intValue(dict["size"]) ?? 50
            return .search(index: index, query: query ?? .null, from: from, size: size)

        default:
            throw ElasticsearchQueryError.invalidOp(op ?? "")
        }
    }

    /// Canonical JSON text for a query — used to persist history/saved queries.
    public static func json(for query: ElasticsearchQuery) -> String {
        var dict: [String: Any] = [:]
        switch query {
        case let .search(index, query, from, size):
            dict["index"] = index
            if query != .null { dict["query"] = query.jsonObject }
            dict["from"] = from
            dict["size"] = size
        case let .scroll(index, query):
            dict["op"] = "scroll"
            dict["index"] = index
            if query != .null { dict["query"] = query.jsonObject }
        case let .index(index, document):
            dict["op"] = "index"
            dict["index"] = index
            dict["document"] = document.jsonObject
        case let .update(index, id, doc):
            dict["op"] = "update"
            dict["index"] = index
            dict["id"] = id
            dict["doc"] = doc.jsonObject
        case let .delete(index, id):
            dict["op"] = "delete"
            dict["index"] = index
            dict["id"] = id
        case let .deleteByQuery(index, query):
            dict["op"] = "delete_by_query"
            dict["index"] = index
            if query != .null { dict["query"] = query.jsonObject }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func queryDocument(_ value: Any?) -> BerryDocument? {
        guard let object = value as? [String: Any], !object.isEmpty else { return nil }
        return BerryDocument(jsonObject: object)
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
