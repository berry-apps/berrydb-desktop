import BerryDriverKit
import Foundation

/// Convention Memory analyzer — mines the
/// current DSG for an established index-naming convention, so
/// SchemaAnalyzer/MigrationPreviewAnalyzer can flag newly-added
/// indexes that break it. Pure — reads only the harvested graph.
public enum ConventionMemory {
    /// True when at least 2 indexes follow the canonical
    /// "idx_<table>_<firstColumn>" naming template (case-insensitive) AND
    /// they make up at least half of the judgeable indexes — i.e. there's an
    /// established convention in this schema worth enforcing. False when
    /// there isn't enough signal (fewer than 2 conforming indexes).
    public static func hasIndexNamingConvention(_ graph: SchemaGraph) -> Bool {
        let judged = judgedIndexes(in: graph)
        guard judged.count >= 2 else { return false }
        let conformingCount = judged.filter(\.followsConvention).count
        return conformingCount >= 2 && conformingCount * 2 >= judged.count
    }

 /// "Database Memory": whether the convention held
    /// across the schema's own recent history, not just its current shape —
    /// a convention seen in only today's snapshot could be coincidental
    /// (e.g. right after one large migration that happened to match); one
    /// that holds across a majority of recent snapshots too is a real,
    /// longer-standing team habit worth enforcing with more confidence.
    /// `history` is the caller's bounded window of prior snapshots (oldest
    /// signal excluded on purpose — see `WorkspaceViewModel`'s history
    /// limit) — empty history falls back to exactly `hasIndexNamingConvention`.
    public static func hasEstablishedIndexNamingConvention(
        current: SchemaGraph, history: [SchemaGraph]
    ) -> Bool {
        let allGraphs = [current] + history
        let agreeingCount = allGraphs.filter(hasIndexNamingConvention).count
        return agreeingCount * 2 > allGraphs.count
    }

    /// The name the canonical template produces for a new index on
    /// `table`/`column`: "idx_<table>_<column>", lowercased.
    public static func suggestedIndexName(table: String, column: String) -> String {
        "idx_\(table)_\(column)".lowercased()
    }

    /// Flags existing indexes that don't follow the canonical template — ONLY
    /// when a convention is established (otherwise there's no established
    /// convention to compare against, so return []). severity .info, category
    /// .schema, id "schema.naming_convention.<indexName>". `history` is an
 /// optional bounded window of prior snapshots
    /// "Database Memory") — when supplied, requires the convention to hold
    /// across most of that history too, not just the current snapshot alone.
    public static func namingMismatches(_ graph: SchemaGraph, history: [SchemaGraph] = []) -> [Insight] {
        let established = history.isEmpty
            ? hasIndexNamingConvention(graph)
            : hasEstablishedIndexNamingConvention(current: graph, history: history)
        guard established else { return [] }
        return judgedIndexes(in: graph)
            .filter { !$0.followsConvention }
            .map { judged in
                let expected = suggestedIndexName(table: judged.table, column: judged.firstColumn)
                return Insight(
                    id: "schema.naming_convention.\(judged.node.name)",
                    severity: .info,
                    category: .schema,
                    title: "Index \(judged.node.name) does not follow naming convention",
                    detail: "Index \(judged.node.name) on table \(judged.table) should be named \(expected) to match the established convention.",
                    targetNode: judged.node.id,
                    targetName: judged.table
                )
            }
    }

    // MARK: - Internal Helpers

    private struct JudgedIndex {
        let node: GraphNode
        let table: String
        let firstColumn: String
        let followsConvention: Bool
    }

    private static func judgedIndexes(in graph: SchemaGraph) -> [JudgedIndex] {
        graph.nodes.values
            .filter { $0.kind == .index }
            .sorted { $0.name < $1.name }
            .compactMap { index in
                guard let table = graph.neighbors(of: index.id, direction: .incoming, kinds: [.hasIndex])
                    .compactMap({ graph.nodes[$0]?.name }).first else {
                    return nil
                }
                guard let columnsAttr = index.attrs["columns"] else {
                    return nil
                }
                let firstColumn = columnsAttr
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                guard let firstColumn else {
                    return nil
                }
                let expected = suggestedIndexName(table: table, column: firstColumn)
                let follows = index.name.lowercased() == expected
                return JudgedIndex(
                    node: index,
                    table: table,
                    firstColumn: firstColumn,
                    followsConvention: follows
                )
            }
    }
}
