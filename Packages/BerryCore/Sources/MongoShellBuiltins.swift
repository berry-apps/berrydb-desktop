/// MongoDB shell method/operator names for the shell-script editor's
/// highlighter and completion popup (mirrors `SQLBuiltins`/`SQLStatements`,
/// ED-13's per-dialect autocomplete pattern). Each method carries its real
/// parameter signature (not just a bare name) so the completion popup can
/// show Navicat-style detail text like `insertOne(document)`
/// (docs/feedback/02.md).
public struct MongoShellMethod: Sendable {
    public let name: String
    public let signature: String

    public init(name: String, signature: String) {
        self.name = name
        self.signature = signature
    }
}

public enum MongoShellBuiltins {
    public static let methods: [MongoShellMethod] = [
        .init(name: "find", signature: "find(query, projection)"),
        .init(name: "findOne", signature: "findOne(query, projection, options)"),
        .init(name: "findOneAndDelete", signature: "findOneAndDelete(filter, options)"),
        .init(name: "findOneAndReplace", signature: "findOneAndReplace(filter, replacement, options)"),
        .init(name: "findOneAndUpdate", signature: "findOneAndUpdate(filter, update, options)"),
        .init(name: "insertOne", signature: "insertOne(document)"),
        .init(name: "insertMany", signature: "insertMany(documents)"),
        .init(name: "bulkWrite", signature: "bulkWrite(operations)"),
        .init(name: "updateOne", signature: "updateOne(filter, update)"),
        .init(name: "updateMany", signature: "updateMany(filter, update)"),
        .init(name: "replaceOne", signature: "replaceOne(filter, replacement)"),
        .init(name: "deleteOne", signature: "deleteOne(filter)"),
        .init(name: "deleteMany", signature: "deleteMany(filter)"),
        .init(name: "aggregate", signature: "aggregate(pipeline)"),
        .init(name: "countDocuments", signature: "countDocuments(filter)"),
        .init(name: "estimatedDocumentCount", signature: "estimatedDocumentCount()"),
        .init(name: "distinct", signature: "distinct(field, filter)"),
        .init(name: "stats", signature: "stats()"),
        .init(name: "getIndexes", signature: "getIndexes()"),
        .init(name: "drop", signature: "drop()"),
        .init(name: "createIndex", signature: "createIndex(keys, options)"),
        .init(name: "dropIndex", signature: "dropIndex(indexName)"),
        .init(name: "renameCollection", signature: "renameCollection(newName)"),
    ]

    public static let queryOperators = [
        "eq", "ne", "gt", "gte", "lt", "lte", "in", "nin", "exists", "regex", "and", "or", "not", "nor",
    ]

    public static let updateOperators = ["set", "unset", "inc", "push", "pull", "pop", "addToSet", "rename"]

    public static let aggregationStages = ["match", "group", "sort", "project", "limit", "unwind", "lookup", "count"]

    public static let aggregationOperators = ["sum", "avg", "min", "max", "first", "last"]

    /// Bare names (no leading `$`) — callers prefix as needed for display vs.
    /// insertion (the completion popup inserts after an already-typed `$`).
    public static var allOperators: [String] {
        queryOperators + updateOperators + aggregationStages + aggregationOperators
    }
}
