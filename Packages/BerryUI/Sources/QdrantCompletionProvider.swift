import BerryCore
import Foundation

/// Suggestions for the Qdrant JSON query editor (docs/feature/03) — the vector
/// sibling of `MongoShellCompletionProvider`. Token-position heuristics on the
/// text before the cursor: top-level keys of the DSL, `op` values, and
/// collection names right after `"collection":`.
enum QdrantCompletionProvider {
    private static let keys: [(String, String)] = [
        ("collection", "the target collection"),
        ("vector", "query vector [Float] — omit to scroll/browse"),
        ("top", "max results (search)"),
        ("filter", "payload filter object"),
        ("score_threshold", "min similarity score (search)"),
        ("op", "search | scroll | upsert | delete"),
        ("points", "points to upsert"),
        ("ids", "point ids to delete"),
    ]

    static func suggestions(text: String, utf16Cursor: Int, collections: [String]) -> [CompletionItem] {
        let ns = text as NSString
        let cursor = min(max(utf16Cursor, 0), ns.length)
        let prefix = ns.substring(to: cursor)

        // Value of "op": suggest the four ops.
        if prefix.range(of: "\"op\"\\s*:\\s*\"?$", options: .regularExpression) != nil {
            return ["search", "scroll", "upsert", "delete"].map {
                CompletionItem(display: $0, insert: $0, icon: "bolt", detail: L("operation"))
            }
        }

        // Value of "collection": suggest collection names.
        if prefix.range(of: "\"collection\"\\s*:\\s*\"?$", options: .regularExpression) != nil {
            return collections.sorted().map {
                CompletionItem(display: $0, insert: $0, icon: "point.3.filled.connected.trianglepath.dotted", detail: L("collection"))
            }
        }

        // Key position: right after `{` or `,` (with optional whitespace and an
        // optional opening quote) → suggest DSL keys.
        if prefix.range(of: "[{,]\\s*\"?$", options: .regularExpression) != nil {
            return keys.map {
                CompletionItem(display: $0.0, insert: $0.0, icon: "key", detail: $0.1)
            }
        }

        return []
    }
}
