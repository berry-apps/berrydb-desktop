import Foundation

/// Structural analysis over the DSG: circular
/// dependencies, tables without a primary key, columns that look like foreign
/// keys but aren't constrained, and all-nullable tables. Pure — reads only the
/// harvested graph, no DBMS access.
public enum SchemaAnalyzer {
    public static func analyze(_ graph: SchemaGraph) -> [Insight] {
        circularDependencies(graph)
            + missingPrimaryKeys(graph)
            + hiddenForeignKeys(graph)
            + allNullableTables(graph)
    }

    // MARK: - Rules

    private static func circularDependencies(_ graph: SchemaGraph) -> [Insight] {
        graph.circularDependencies().map { cycle in
            let names = cycle.compactMap { graph.nodes[$0]?.name }.sorted()
            return Insight(
                id: "schema.cycle.\(names.joined(separator: "-"))",
                severity: .warning, category: .schema,
                title: "Circular foreign-key dependency",
                detail: "Tables form a reference cycle: \(names.joined(separator: " → ")). "
                    + "Cycles complicate inserts, deletes, and migration ordering.",
                targetNode: cycle.first, targetName: cycle.first.flatMap { graph.nodes[$0]?.name }
            )
        }
    }

    private static func missingPrimaryKeys(_ graph: SchemaGraph) -> [Insight] {
        tables(graph).compactMap { table in
            let cols = columns(of: table, in: graph)
            guard !cols.isEmpty, !cols.contains(where: { $0.attrs["primaryKey"] == "true" }) else { return nil }
            return Insight(
                id: "schema.missing_pk.\(table.name)",
                severity: .warning, category: .schema,
                title: "Table \(table.name) has no primary key",
                detail: "\(table.name) has no primary-key column. A primary key is needed for reliable "
                    + "row identity, replication, and safe edits.",
                targetNode: table.id, targetName: table.name
            )
        }
    }

    /// A `*_id` column with no FK constraint, where a table matching the prefix
    /// exists — a likely relationship the schema doesn't enforce.
    private static func hiddenForeignKeys(_ graph: SchemaGraph) -> [Insight] {
        var insights: [Insight] = []
        let byName = Dictionary(tables(graph).map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        // Index once (O(edges)) instead of a full graph.edges scan per
        // id-column (was O(tables × id-columns × edges) — every sibling
        // rule in this file goes through SchemaGraph's O(1) adjacency maps;
        // this was the one that bypassed them).
        var constrainedColumns: [String: Set<String>] = [:]
        for edge in graph.edges where edge.kind == .references {
            if let column = edge.attrs["column"] {
                constrainedColumns[edge.src, default: []].insert(column)
            }
        }
        for table in tables(graph) {
            for column in columns(of: table, in: graph) where column.name.lowercased().hasSuffix("_id") {
                let alreadyConstrained = constrainedColumns[table.id]?.contains(column.name) == true
                if alreadyConstrained { continue }
                let prefix = String(column.name.dropLast(3)).lowercased()
                guard !prefix.isEmpty else { continue }
                let candidate = [prefix, prefix + "s", prefix + "es"]
                    .lazy.compactMap { byName[$0] }.first { $0.name != table.name }
                guard let parent = candidate else { continue }
                insights.append(Insight(
                    id: "schema.hidden_fk.\(table.name).\(column.name)",
                    severity: .info, category: .schema,
                    title: "Possible missing foreign key: \(table.name).\(column.name)",
                    detail: "\(column.name) looks like it references \(parent.name), but no foreign key "
                        + "enforces it. An unconstrained relationship allows orphaned rows.",
                    targetNode: table.id, targetName: table.name
                ))
            }
        }
        return insights
    }

    private static func allNullableTables(_ graph: SchemaGraph) -> [Insight] {
        tables(graph).compactMap { table in
            let cols = columns(of: table, in: graph)
            guard cols.count >= 2, cols.allSatisfy({ $0.attrs["nullable"] == "true" }) else { return nil }
            return Insight(
                id: "schema.all_nullable.\(table.name)",
                severity: .info, category: .schema,
                title: "Table \(table.name) has no NOT NULL columns",
                detail: "Every column in \(table.name) is nullable; required fields left nullable let "
                    + "incomplete rows through.",
                targetNode: table.id, targetName: table.name
            )
        }
    }

    // MARK: - Helpers

    private static func tables(_ graph: SchemaGraph) -> [GraphNode] {
        graph.nodes.values.filter { $0.kind == .table }.sorted { $0.name < $1.name }
    }

    private static func columns(of table: GraphNode, in graph: SchemaGraph) -> [GraphNode] {
        graph.neighbors(of: table.id, direction: .outgoing, kinds: [.hasColumn]).compactMap { graph.nodes[$0] }
    }
}
