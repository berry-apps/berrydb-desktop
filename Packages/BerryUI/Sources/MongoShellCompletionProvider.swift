import BerryCore
import Foundation

/// Suggestions for the Mongo shell editor (ED-13 sibling): collection names
/// right after `db.`, methods right after `db.<collection>.`, and `$`
/// operators/stages inside object literals. Simpler than SQL's
/// `CompletionProvider` (no qualified-name resolution) — token-position
/// heuristics on the text immediately before the cursor are enough for this
/// grammar's three suggestion contexts.
enum MongoShellCompletionProvider {
    static func suggestions(
        script: String,
        utf16Cursor: Int,
        collections: [String],
        inferredFields: [String: [String]] = [:]
    ) -> [CompletionItem] {
        let ns = script as NSString
        let cursor = min(max(utf16Cursor, 0), ns.length)
        let prefix = ns.substring(to: cursor)

        // 1. `db.` -> Suggest collection names
        if prefix.range(of: "db\\.$", options: .regularExpression) != nil {
            return collections.sorted().map {
                CompletionItem(display: $0, insert: $0, icon: "tray.full", detail: L("collection"))
            }
        }

        // 2. `db.<collection>.` -> Suggest methods
        if prefix.range(of: "(?:db\\.)?[A-Za-z0-9_\\.]+\\.$", options: .regularExpression) != nil {
            return MongoShellBuiltins.methods.map {
                CompletionItem(display: $0.name, insert: $0.name, icon: "function", detail: $0.signature)
            }
        }

        // 3. Typing `$` anywhere
        if prefix.hasSuffix("$") {
            return MongoShellBuiltins.allOperators.map {
                CompletionItem(display: "$" + $0, insert: $0, icon: "dollarsign.circle", detail: L("operator"))
            }
        }

        // 4. Inside method invocation e.g. db.users.findOne(...)
        if let (methodName, collectionName, argIndex) = parseMethodCallContext(from: prefix) {
            var items: [CompletionItem] = []

            // Common collection fields + inferred fields
            var fields = Set<String>(["_id", "name", "email", "status", "type", "createdAt", "updatedAt", "active", "role", "title", "user_id", "value", "id", "description"])
            if let col = collectionName, let customFields = inferredFields[col] {
                fields.formUnion(customFields)
            }

            switch methodName {
            case "find", "findOne":
                if argIndex == 0 { // Filter / Query
                    for f in fields.sorted() {
                        items.append(CompletionItem(display: f, insert: f, icon: "tag", detail: L("field")))
                    }
                    for op in MongoShellBuiltins.queryOperators {
                        items.append(CompletionItem(display: "$" + op, insert: "$" + op, icon: "dollarsign.circle", detail: L("query operator")))
                    }
                } else if argIndex == 1 { // Projection
                    for f in fields.sorted() {
                        items.append(CompletionItem(display: f + ": 1", insert: f + ": 1", icon: "tag", detail: L("include field")))
                        items.append(CompletionItem(display: f + ": 0", insert: f + ": 0", icon: "tag", detail: L("exclude field")))
                    }
                } else if argIndex >= 2 { // Options
                    let options = ["sort", "projection", "hint", "maxTimeMS", "readPreference", "collation", "limit", "skip"]
                    for opt in options {
                        items.append(CompletionItem(display: opt, insert: opt + ": ", icon: "slider.horizontal.3", detail: L("option")))
                    }
                }
            case "updateOne", "updateMany", "findOneAndUpdate":
                if argIndex == 0 { // Filter
                    for f in fields.sorted() {
                        items.append(CompletionItem(display: f, insert: f, icon: "tag", detail: L("field")))
                    }
                    for op in MongoShellBuiltins.queryOperators {
                        items.append(CompletionItem(display: "$" + op, insert: "$" + op, icon: "dollarsign.circle", detail: L("query operator")))
                    }
                } else if argIndex == 1 { // Update
                    for op in MongoShellBuiltins.updateOperators {
                        items.append(CompletionItem(display: "$" + op, insert: "$" + op + ": { ", icon: "dollarsign.circle", detail: L("update operator")))
                    }
                    for f in fields.sorted() {
                        items.append(CompletionItem(display: f, insert: f, icon: "tag", detail: L("field")))
                    }
                } else if argIndex >= 2 { // Options
                    let options = ["upsert", "arrayFilters", "collation", "hint", "bypassDocumentValidation"]
                    for opt in options {
                        items.append(CompletionItem(display: opt, insert: opt + ": ", icon: "slider.horizontal.3", detail: L("option")))
                    }
                }
            case "aggregate":
                for stage in MongoShellBuiltins.aggregationStages {
                    items.append(CompletionItem(display: "{ $" + stage + ": {} }", insert: "{ $" + stage + ": {} }", icon: "arrow.triangle.pull", detail: L("pipeline stage")))
                }
            case "createIndex":
                if argIndex == 0 { // Index keys
                    for f in fields.sorted() {
                        items.append(CompletionItem(display: f + ": 1", insert: f + ": 1", icon: "tag", detail: L("ascending index")))
                        items.append(CompletionItem(display: f + ": -1", insert: f + ": -1", icon: "tag", detail: L("descending index")))
                    }
                } else if argIndex >= 1 { // Index options
                    let options = ["unique", "sparse", "background", "name", "expireAfterSeconds"]
                    for opt in options {
                        items.append(CompletionItem(display: opt, insert: opt + ": ", icon: "slider.horizontal.3", detail: L("index option")))
                    }
                }
            default:
                // General fallback inside method calls
                for f in fields.sorted() {
                    items.append(CompletionItem(display: f, insert: f, icon: "tag", detail: L("field")))
                }
                for op in MongoShellBuiltins.allOperators {
                    items.append(CompletionItem(display: "$" + op, insert: "$" + op, icon: "dollarsign.circle", detail: L("operator")))
                }
            }

            if !items.isEmpty {
                return items
            }
        }

        // 5. Fallback for any { ... } block
        let openBraces = prefix.filter { $0 == "{" }.count
        let closeBraces = prefix.filter { $0 == "}" }.count
        if openBraces > closeBraces {
            var items: [CompletionItem] = []
            let defaultFields = ["_id", "name", "email", "status", "type", "createdAt", "updatedAt", "active", "role", "title", "user_id", "value", "id"]
            for f in defaultFields {
                items.append(CompletionItem(display: f, insert: f, icon: "tag", detail: L("field")))
            }
            for op in MongoShellBuiltins.allOperators {
                items.append(CompletionItem(display: "$" + op, insert: "$" + op, icon: "dollarsign.circle", detail: L("operator")))
            }
            return items
        }

        return []
    }

    private static func parseMethodCallContext(from prefix: String) -> (methodName: String, collectionName: String?, argIndex: Int)? {
        let pattern = #"(?:db\.)?([A-Za-z0-9_\.]+)\.([A-Za-z0-9_]+)\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = prefix as NSString
        let matches = regex.matches(in: prefix, options: [], range: NSRange(location: 0, length: ns.length))
        guard let lastMatch = matches.last else { return nil }

        let collectionName = ns.substring(with: lastMatch.range(at: 1))
        let methodName = ns.substring(with: lastMatch.range(at: 2))

        let callStart = lastMatch.range.location + lastMatch.range.length
        if callStart <= ns.length {
            let argsText = ns.substring(from: callStart)
            var depthParen = 0
            var depthBrace = 0
            var depthBracket = 0
            var argIndex = 0
            for char in argsText {
                switch char {
                case "(": depthParen += 1
                case ")": depthParen -= 1
                case "{": depthBrace += 1
                case "}": depthBrace -= 1
                case "[": depthBracket += 1
                case "]": depthBracket -= 1
                case ",":
                    if depthParen == 0 && depthBrace == 0 && depthBracket == 0 {
                        argIndex += 1
                    }
                default: break
                }
            }
            return (methodName, collectionName, argIndex)
        }
        return nil
    }
}
