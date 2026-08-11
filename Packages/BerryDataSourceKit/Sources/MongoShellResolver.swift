/// What one parsed `MongoShellStatement` should execute as, in terms of the
/// existing `DataSourceQuery`/`DataSourceChangeSet` surface — no new driver
/// methods, this only maps shell syntax onto what already exists (plus the
/// `updateByFilter`/`deleteByFilter` cases added alongside this resolver).
public enum MongoShellAction: Sendable {
    case query(DataSourceQuery)
    case write(DataSourceChangeSet)
    /// `insertMany([...])` — applied as N sequential `.insert` writes by the
    /// caller (mirrors the existing "delete N selected rows" loop in
    /// `CollectionTabView.grid.onDeleteRows`, which already applies one
    /// `DataSourceChangeSet` at a time in sequence).
    case writeMany([DataSourceChangeSet])
}

public enum MongoShellResolveError: Error, Equatable, Sendable {
    case unsupportedMethod(String)
    case invalidArguments(String)
}

public enum MongoShellResolver {
    public static func resolve(_ statement: MongoShellStatement) throws -> MongoShellAction {
        guard let base = statement.calls.first else {
            throw MongoShellResolveError.unsupportedMethod("")
        }
        // Reject chained calls on all methods except find (which handles its own chain
        // validation in resolveFind to allow .sort() and .limit() specifically).
        if base.method != "find", statement.calls.count > 1 {
            throw MongoShellResolveError.unsupportedMethod(statement.calls[1].method)
        }
        switch base.method {
        case "find":
            return try resolveFind(collection: statement.collection, base: base, chained: statement.calls.dropFirst())
        case "findOne":
            let filter = base.arguments.first ?? .object([])
            let projection = base.arguments.count > 1 ? base.arguments[1] : nil
            return .query(.mongoFind(collection: statement.collection, filter: filter, projection: projection, limit: 1))
        case "aggregate":
            guard case .array(let stages)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("aggregate(...) expects an array of pipeline stages")
            }
            return .query(.mongoAggregate(collection: statement.collection, pipeline: stages))
        case "countDocuments":
            let filter = base.arguments.first ?? .object([])
            return .query(.mongoAggregate(collection: statement.collection, pipeline: [
                .object([("$match", filter)]),
                .object([("$count", .string("count"))]),
            ]))
        case "estimatedDocumentCount":
            return .query(.mongoAggregate(collection: statement.collection, pipeline: [
                .object([("$count", .string("count"))]),
            ]))
        case "distinct":
            guard case .string(let field)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("distinct(...) expects a field name string as its first argument")
            }
            let filter = base.arguments.count > 1 ? base.arguments[1] : .object([])
            return .query(.mongoAggregate(collection: statement.collection, pipeline: [
                .object([("$match", filter)]),
                .object([("$group", .object([("_id", .string("$" + field))]))]),
            ]))
        case "stats":
            let storageStatsObj = BerryDocument.object([])
            let collStatsObj = BerryDocument.object([("storageStats", storageStatsObj)])
            let collStatsStage = BerryDocument.object([("$collStats", collStatsObj)])
            return .query(.mongoAggregate(collection: statement.collection, pipeline: [collStatsStage]))
        case "insertOne":
            guard let document = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("insertOne(...) expects a document")
            }
            return .write(.insert(collection: statement.collection, document: document))
        case "insertMany":
            guard case .array(let documents)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("insertMany(...) expects an array of documents")
            }
            return .writeMany(documents.map { .insert(collection: statement.collection, document: $0) })
        case "bulkWrite":
            guard case .array(let operations)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("bulkWrite(...) expects an array of operations")
            }
            return .writeMany(try operations.map { try resolveBulkOperation($0, collection: statement.collection) })
        case "updateOne", "updateMany":
            return try resolveUpdate(collection: statement.collection, base: base, multi: base.method == "updateMany")
        case "replaceOne", "findOneAndReplace":
            return try resolveReplace(collection: statement.collection, base: base)
        case "deleteOne", "deleteMany":
            let filter = base.arguments.first ?? .object([])
            return .write(.deleteByFilter(collection: statement.collection, filter: filter, multi: base.method == "deleteMany"))
        case "findOneAndDelete":
            let filter = base.arguments.first ?? .object([])
            return .write(.deleteByFilter(collection: statement.collection, filter: filter, multi: false))
        case "findOneAndUpdate":
            return try resolveUpdate(collection: statement.collection, base: base, multi: false)
        case "getIndexes":
            return .query(.mongoListIndexes(collection: statement.collection))
        case "drop":
            return .write(.dropCollection(collection: statement.collection))
        case "createIndex":
            guard let keys = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("createIndex(...) expects a keys document")
            }
            let options = base.arguments.count > 1 ? base.arguments[1] : nil
            return .write(.createIndex(collection: statement.collection, keys: keys, options: options))
        case "dropIndex":
            guard case .string(let indexName)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("dropIndex(...) expects an index name string")
            }
            return .write(.dropIndex(collection: statement.collection, indexName: indexName))
        case "renameCollection":
            guard case .string(let newName)? = base.arguments.first else {
                throw MongoShellResolveError.invalidArguments("renameCollection(...) expects a new name string")
            }
            return .write(.renameCollection(collection: statement.collection, newName: newName))
        default:
            throw MongoShellResolveError.unsupportedMethod(base.method)
        }
    }

    private static func resolveFind(
        collection: String, base: MongoShellCall, chained: ArraySlice<MongoShellCall>
    ) throws -> MongoShellAction {
        let filter = base.arguments.first ?? .object([])
        let projection = base.arguments.count > 1 ? base.arguments[1] : nil
        var limit: Int?
        var sortStage: BerryDocument?
        for call in chained {
            switch call.method {
            case "limit":
                guard case .int(let n)? = call.arguments.first else {
                    throw MongoShellResolveError.invalidArguments("limit(...) expects an integer")
                }
                limit = Int(n)
            case "sort":
                guard let stage = call.arguments.first else {
                    throw MongoShellResolveError.invalidArguments("sort(...) expects an object")
                }
                sortStage = stage
            default:
                // .skip() and anything else: no `DataSourceQuery.mongoFind`
                // field exists for them today — fail loudly instead of
                // silently dropping the clause and returning wrong results.
                throw MongoShellResolveError.unsupportedMethod(call.method)
            }
        }
        if let sortStage {
            // .mongoFind has no sort parameter — lower into the aggregate
            // pipeline path, which already supports arbitrary stages.
            var pipeline: [BerryDocument] = [.object([("$match", filter)])]
            if let projection { pipeline.append(.object([("$project", projection)])) }
            pipeline.append(.object([("$sort", sortStage)]))
            if let limit { pipeline.append(.object([("$limit", .int(Int64(limit)))])) }
            return .query(.mongoAggregate(collection: collection, pipeline: pipeline))
        }
        return .query(.mongoFind(collection: collection, filter: filter, projection: projection, limit: limit))
    }

    private static func resolveUpdate(collection: String, base: MongoShellCall, multi: Bool) throws -> MongoShellAction {
        guard base.arguments.count >= 2 else {
            throw MongoShellResolveError.invalidArguments("\(base.method)(...) expects (filter, update)")
        }
        let filter = base.arguments[0]
        let update = base.arguments[1]
        guard case .object(let fields) = update, fields.contains(where: { $0.0.hasPrefix("$") }) else {
            throw MongoShellResolveError.invalidArguments(
                "\(base.method)(...)'s update document must use an operator like $set/$push"
            )
        }
        return .write(.updateByFilter(collection: collection, filter: filter, update: update, multi: multi))
    }

    /// `replaceOne`/`findOneAndReplace` share `resolveUpdate`'s shape but with
    /// the OPPOSITE validation: the second argument must be a plain
    /// replacement document with NO `$`-operator keys (a bare document at the
    /// wire-protocol level already means "replace the whole document" —
    /// `MongoConnection`'s `updateByFilter` passes it through unmodified).
    private static func resolveReplace(collection: String, base: MongoShellCall) throws -> MongoShellAction {
        guard base.arguments.count >= 2 else {
            throw MongoShellResolveError.invalidArguments("\(base.method)(...) expects (filter, replacement)")
        }
        let filter = base.arguments[0]
        let replacement = base.arguments[1]
        if case .object(let fields) = replacement, fields.contains(where: { $0.0.hasPrefix("$") }) {
            throw MongoShellResolveError.invalidArguments(
                "\(base.method)(...)'s replacement document must not contain operators like $set — pass the whole new document"
            )
        }
        return .write(.updateByFilter(collection: collection, filter: filter, update: replacement, multi: false))
    }

    /// Each `bulkWrite(...)` entry is a single-key object naming the
    /// operation, with its arguments as NAMED fields (`{filter, update}`)
    /// rather than the positional arguments a standalone call uses
    /// (`updateOne(filter, update)`) — real mongosh `bulkWrite` syntax.
    private static func resolveBulkOperation(_ doc: BerryDocument, collection: String) throws -> DataSourceChangeSet {
        guard case .object(let fields) = doc, fields.count == 1 else {
            throw MongoShellResolveError.invalidArguments(
                "each bulkWrite(...) entry must be a single-key object like { insertOne: { document: {...} } }"
            )
        }
        let (opName, opArgs) = fields[0]
        switch opName {
        case "insertOne":
            guard let document = opArgs["document"] else {
                throw MongoShellResolveError.invalidArguments("bulkWrite insertOne requires a \"document\" field")
            }
            return .insert(collection: collection, document: document)
        case "updateOne", "updateMany":
            guard let filter = opArgs["filter"], let update = opArgs["update"] else {
                throw MongoShellResolveError.invalidArguments("bulkWrite \(opName) requires \"filter\" and \"update\" fields")
            }
            guard case .object(let updateFields) = update, updateFields.contains(where: { $0.0.hasPrefix("$") }) else {
                throw MongoShellResolveError.invalidArguments(
                    "bulkWrite \(opName)'s update document must use an operator like $set/$push"
                )
            }
            return .updateByFilter(collection: collection, filter: filter, update: update, multi: opName == "updateMany")
        case "replaceOne":
            guard let filter = opArgs["filter"], let replacement = opArgs["replacement"] else {
                throw MongoShellResolveError.invalidArguments("bulkWrite replaceOne requires \"filter\" and \"replacement\" fields")
            }
            if case .object(let replacementFields) = replacement, replacementFields.contains(where: { $0.0.hasPrefix("$") }) {
                throw MongoShellResolveError.invalidArguments(
                    "bulkWrite replaceOne's replacement document must not contain operators like $set"
                )
            }
            return .updateByFilter(collection: collection, filter: filter, update: replacement, multi: false)
        case "deleteOne", "deleteMany":
            let filter = opArgs["filter"] ?? .object([])
            return .deleteByFilter(collection: collection, filter: filter, multi: opName == "deleteMany")
        default:
            throw MongoShellResolveError.unsupportedMethod("bulkWrite: \(opName)")
        }
    }
}
