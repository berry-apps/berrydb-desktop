import BerryStore
import Foundation

/// Client-executed `search_schema`: search this
/// connection's tables/collections by meaning, not literal name — e.g.
/// "customer" can surface `users`, "payment" can surface `invoice`/`billing`.
/// Name vectors and cosine-KNN live locally in `BerryStore`; vector creation
/// uses the stateless `/v1/ai/embed` endpoint. Registered unconditionally
/// (base "ai" capability), same as `search_conversation`.
@MainActor
public final class SchemaSearchToolExecutor: AIToolExecutor {
    private let store: BerryStore
    private let transport: AITransport
    private let indexer: SchemaEmbeddingIndexer
    /// Resolved lazily each call — the active connection can change between
    /// when this executor is registered and when the model actually calls
    /// the tool.
    private let profileID: () -> UUID?
    /// Every currently known table/collection name for the active connection.
    /// Also used to filter stale vectors for objects dropped/renamed since
    /// they were last embedded (BerryStore never cleans those up on its own).
    private let candidateNames: () -> [String]

    public init(
        store: BerryStore, transport: AITransport,
        profileID: @escaping () -> UUID?,
        candidateNames: @escaping () -> [String]
    ) {
        self.store = store
        self.transport = transport
        self.indexer = SchemaEmbeddingIndexer(store: store, transport: transport)
        self.profileID = profileID
        self.candidateNames = candidateNames
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "search_schema",
            description: "Semantically search this connection's tables/collections by meaning rather than literal name, e.g. \"payment\" can surface `invoice`/`billing`. Use when the user describes what data they want conceptually instead of naming an exact object.",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"What kind of data to look for, in plain language."}},"required":["query"]}"#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await executeSearch(call, lease: nil)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        return await executeSearch(call, lease: lease)
    }

    private func executeSearch(_ call: AIToolCall, lease: AIExecutionLease?) async -> ToolOutcome {
        guard call.name == "search_schema" else { return .failed("Unknown tool '\(call.name)'") }
        guard let query = call.args["query"], !query.isEmpty else { return .failed("Missing 'query'") }
        guard let profileID = profileID() else { return .ok(#"{"matches":[]}"#) }
        let names = candidateNames()
        guard !names.isEmpty else { return .ok(#"{"matches":[]}"#) }

        await indexer.backfill(profileID: profileID, candidateNames: names)
        if let lease, !lease.isValid { return .denied }

        let vector = await transport.embed(text: query)
        if let lease, !lease.isValid { return .denied }
        guard vector.count == BerryStore.schemaObjectEmbeddingDimension,
              let nearest = try? store.nearestSchemaObjects(profileID: profileID, to: vector, limit: 8) else {
            return .ok(#"{"matches":[]}"#)
        }
        let live = Set(names)
        let matches = nearest.map(\.name).filter { live.contains($0) }
        if let lease, !lease.isValid { return .denied }

        let json = (try? JSONSerialization.data(withJSONObject: ["matches": matches]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"matches":[]}"#
        return .ok(json)
    }
}
