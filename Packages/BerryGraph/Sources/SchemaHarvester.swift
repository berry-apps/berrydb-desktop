import BerryCore
import BerryDriverKit
import Foundation

/// Builds the DSG from a live connection's schema
/// **Metadata only** — reads objects + table detail through the
/// introspector (`SchemaCatalog`), never SELECTs user data (Q6). Harvesting is
/// off by default on production profiles; pass `allowProduction` to
/// override after an explicit user opt-in. The stats/workload/plan harvesters
/// (which run SELECTs on catalog views via QueryService) come in a later chunk.
public enum SchemaHarvester {
    public enum HarvestError: Error, Equatable {
        case productionDisabled
    }

    /// Builds the structural DSG from the session's current schema. Does not
    /// persist — use `harvest` to also record a snapshot.
    public static func buildGraph(
        session: Session,
        catalog: SchemaCatalog,
        allowProduction: Bool = false
    ) async throws -> SchemaGraph {
        guard !session.isProduction || allowProduction else {
            throw HarvestError.productionDisabled
        }
        let objects = try await catalog.objects()
        var details: [TableRef: TableDetail] = [:]
        for object in objects where object.kind == .table {
            let ref = TableRef(database: object.database, name: object.name)
            // A table can be dropped between listing and detail — a live harvest
 // runs against a mutating DB (background pass). Skip the
            // vanished table rather than abort the whole graph; its node still
            // exists (from `objects`), just without columns/edges.
            if let detail = try? await catalog.tableDetail(ref) {
                details[ref] = detail
            }
        }
        return SchemaGraphBuilder.build(objects: objects, details: details)
    }

    /// Builds the DSG and persists it as a Digital-Twin snapshot for a saved
 /// profile.
    @discardableResult
    public static func harvest(
        session: Session,
        catalog: SchemaCatalog,
        into graphStore: GraphStore,
        profileID: UUID,
        now: Date,
        allowProduction: Bool = false
    ) async throws -> SchemaGraph {
        let structural = try await buildGraph(session: session, catalog: catalog, allowProduction: allowProduction)
 // Enrich with catalog/stats views (foundation) — best-effort,
        // metadata only (Q6), through QueryService (N1).
        let graph = await StatsHarvester.enrich(structural, session: session)
        try graphStore.persist(graph, profileID: profileID, now: now)
        return graph
    }
}
