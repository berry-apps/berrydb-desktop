import BerryStore
import Foundation

/// Best-effort table/collection-name indexing for `search_schema`
/// Names are embedded lazily, right before a search needs them, so
/// opening a connection never pays an embedding round trip it might not use.
public struct SchemaEmbeddingIndexer: Sendable {
    private let store: BerryStore
    private let transport: AITransport
    private let maxConcurrentRequests: Int

    public init(
        store: BerryStore, transport: AITransport,
        maxConcurrentRequests: Int = 4
    ) {
        self.store = store
        self.transport = transport
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    public func backfill(profileID: UUID, candidateNames: [String]) async {
        guard let missing = try? store.schemaObjectNamesMissingEmbeddings(
            profileID: profileID, candidateNames: candidateNames
        ), !missing.isEmpty else { return }
        var start = missing.startIndex
        while start < missing.endIndex {
            let end = missing.index(
                start, offsetBy: maxConcurrentRequests,
                limitedBy: missing.endIndex
            ) ?? missing.endIndex
            let batch = Array(missing[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for name in batch {
                    group.addTask { await index(profileID: profileID, name: name) }
                }
            }
            start = end
        }
    }

    private func index(profileID: UUID, name: String) async {
        let vector = await transport.embed(text: name)
        guard vector.count == BerryStore.schemaObjectEmbeddingDimension else { return }
        try? store.saveSchemaObjectEmbedding(profileID: profileID, name: name, vector: vector)
    }
}
