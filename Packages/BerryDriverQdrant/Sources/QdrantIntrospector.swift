import BerryDataSourceKit
import Foundation

/// Best-effort introspection for Qdrant (docs/architecture/12 §3/§5): there is
/// no DDL, only the collection's vector config plus a sample-based union of
/// payload field names/types — always inferred, never authoritative.
struct QdrantIntrospector: DataSourceIntrospector {
    let client: QdrantHTTPClient

    func collections() async throws -> [CollectionRef] {
        try await client.listCollections()
    }

    /// Keys `"_vector.size"`/`"_vector.distance"` report the collection's
    /// vector config; every other key is a payload field name, with its value
    /// the `|`-joined union of `BerryDocument` type labels seen across the
    /// sample (docs/architecture/12 §3 "suy luận, không phải schema thật").
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] {
        var schema: [String: String] = [:]

        let info = try await client.collectionInfo(name: collection.name)
        if let size = info.vectorSize { schema["_vector.size"] = String(size) }
        if let distance = info.distance { schema["_vector.distance"] = distance }

        let limit = max(1, min(sampleSize, 1000))
        let (points, _) = try await client.scroll(
            collection: collection.name, filter: nil, pageToken: nil, limit: limit, withVector: false
        )

        var fieldTypes: [String: Set<String>] = [:]
        for point in points {
            guard let payload = point["payload"] as? [String: Any],
                  case .object(let fields) = BerryDocument(jsonObject: payload) else { continue }
            for (name, value) in fields {
                fieldTypes[name, default: []].insert(QdrantWire.typeLabel(value))
            }
        }
        for (name, types) in fieldTypes {
            schema[name] = types.sorted().joined(separator: "|")
        }
        return schema
    }
}
