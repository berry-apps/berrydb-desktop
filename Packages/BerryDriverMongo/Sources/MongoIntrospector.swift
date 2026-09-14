import BerryDataSourceKit
import Foundation

/// Best-effort introspection for MongoDB: no DDL to
/// read, only a union of field names/types inferred from up to `sampleSize`
/// recent documents — same inferred schema stance (not strict DDL) as
/// `QdrantIntrospector`'s payload-field inference.
struct MongoIntrospector: DataSourceIntrospector {
    let client: MongoWireClient
    let database: String

    func collections() async throws -> [CollectionRef] {
        let all = try await client.listCollections(database: database)
        return all.filter { !$0.name.hasPrefix("system.") }
    }

    /// "Recent" = sorted by `_id` descending — a MongoDB ObjectId embeds a
    /// creation timestamp in its first 4 bytes, so this approximates
    /// recency without requiring a dedicated `createdAt` field every
    /// collection may not have. Best-effort: a collection with non-ObjectId
    /// `_id` values still returns a sample, just not necessarily the most
    /// recent one by wall-clock time.
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] {
        let limit = max(1, min(sampleSize, 1000))
        let page = try await client.find(
            database: database, collection: collection.name, filter: .object([]), projection: nil,
            sort: .object([("_id", .int(-1))]), limit: limit, batchSize: limit
        )
        var fieldTypes: [String: Set<String>] = [:]
        for document in page.documents {
            guard case .object(let fields) = document else { continue }
            for (name, value) in fields {
                fieldTypes[name, default: []].insert(Self.typeLabel(value))
            }
        }
        var schema: [String: String] = [:]
        for (name, types) in fieldTypes {
            schema[name] = types.sorted().joined(separator: "|")
        }
        return schema
    }

    static func typeLabel(_ doc: BerryDocument) -> String {
        switch doc {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .binary: return "binary"
        case .objectID: return "objectID"
        case .date: return "date"
        case .vector: return "vector"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
