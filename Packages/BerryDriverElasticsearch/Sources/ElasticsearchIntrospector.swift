import BerryDataSourceKit
import Foundation

/// Introspection for Elasticsearch (docs/architecture/17 §4) — unlike Qdrant's
/// sample-based inference, `_mapping` is a real, declared schema, so this
/// reads it directly instead of sampling documents.
struct ElasticsearchIntrospector: DataSourceIntrospector {
    let client: ElasticsearchHTTPClient

    func collections() async throws -> [CollectionRef] {
        try await client.listIndices()
    }

    /// `sampleSize` is accepted for protocol conformance but unused —
    /// `_mapping` already describes every field, not just a sample.
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] {
        try await client.mapping(index: collection.name)
    }
}
