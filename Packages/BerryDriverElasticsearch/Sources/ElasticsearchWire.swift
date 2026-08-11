import BerryDataSourceKit
import Foundation

/// Pure JSON <-> `BerryDocument` conversions for the Elasticsearch REST wire
/// format (docs/architecture/17 §2) — no networking, so these are
/// unit-testable without a stubbed `URLSession`, same split as `QdrantWire`.
enum ElasticsearchWire {
    /// One search hit (`_id`/`_score`/`_index`/`_source`) folded into the flat
    /// `BerryDocument.object` shape the driver streams to callers — `_source`
    /// fields nest under a `"_source"` key rather than being merged at the top
    /// level, same reasoning as Qdrant's payload nesting under `"payload"`
    /// (avoids a silent field-name collision between `_id`/`_score` and a
    /// document field that happens to be named the same).
    static func document(fromHitJSON json: [String: Any]) -> BerryDocument {
        var fields: [(String, BerryDocument)] = []
        if let id = json["_id"] as? String {
            fields.append(("_id", .string(id)))
        }
        if let score = json["_score"] as? NSNumber {
            fields.append(("_score", .double(score.doubleValue)))
        }
        if let source = json["_source"] as? [String: Any] {
            fields.append(("_source", BerryDocument(jsonObject: source)))
        }
        return .object(fields)
    }

    /// The `sort` array on a hit — the tiebreaker values `search_after` needs
    /// to resume from this hit on the next page (docs/architecture/17 §2).
    static func sortValues(fromHitJSON json: [String: Any]) -> [Any]? {
        json["sort"] as? [Any]
    }

    /// `query.jsonObject` as an ES Query DSL body — `.null`/empty means "match
    /// everything", same empty-means-match-all convention as `.mongoFind`'s
    /// filter (unlike Qdrant's `filter: BerryDocument?`, this case's `query`
    /// is non-optional).
    static func queryDSLBody(_ query: BerryDocument) -> [String: Any] {
        if case .object(let fields) = query, fields.isEmpty { return ["match_all": [String: Any]()] }
        if case .null = query { return ["match_all": [String: Any]()] }
        return (query.jsonObject as? [String: Any]) ?? ["match_all": [String: Any]()]
    }

    /// Short label for the field-type schema shown alongside the real ES
    /// `_mapping` (docs/architecture/17 §4) — mirrors `QdrantWire.typeLabel`'s
    /// intent but reports the ES-declared type name, not an inferred shape.
    static func flattenMapping(_ properties: [String: Any], prefix: String = "") -> [String: String] {
        var result: [String: String] = [:]
        for (name, raw) in properties {
            guard let field = raw as? [String: Any] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix).\(name)"
            if let nested = field["properties"] as? [String: Any] {
                result.merge(flattenMapping(nested, prefix: path)) { _, new in new }
            } else if let type = field["type"] as? String {
                result[path] = type
            } else {
                // `properties`-less object field with no explicit `type` —
                // ES's implicit "object" default.
                result[path] = "object"
            }
        }
        return result
    }
}
