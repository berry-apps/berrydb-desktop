import BerryDriverKit
import Foundation

/// Builds the structural DSG from harvested schema metadata
/// tables/views become nodes, columns and indexes hang off them,
/// and foreign keys become `references` edges. Workload/plan/migration edges are
/// added by the harvesters in a later pass. Pure — the caller fetches
/// `TableDetail`s (via `SchemaCatalog`, N1) and passes them in.
public enum SchemaGraphBuilder {
    public static func build(
        objects: [SchemaObject],
        details: [TableRef: TableDetail]
    ) -> SchemaGraph {
        var graph = SchemaGraph()

        // Table + view nodes.
        for object in objects where object.kind == .table || object.kind == .view {
            let kind: NodeKind = object.kind == .view ? .view : .table
            graph.addNode(GraphNode(
                id: GraphID.node(kind, database: object.database, name: object.name),
                kind: kind, name: object.name, database: object.database
            ))
        }

        for (ref, detail) in details {
            let tableID = GraphID.node(.table, database: ref.database, name: ref.name)
            // Ensure the table node exists even if it wasn't in `objects`.
            if graph.nodes[tableID] == nil {
                graph.addNode(GraphNode(id: tableID, kind: .table, name: ref.name, database: ref.database))
            }

            for column in detail.columns {
                let columnID = GraphID.node(.column, database: ref.database, name: column.name, in: ref.name)
                graph.addNode(GraphNode(
                    id: columnID, kind: .column, name: column.name, database: ref.database,
                    attrs: [
                        "type": column.declaredType,
                        "nullable": String(column.isNullable),
                        "primaryKey": String(column.isPrimaryKey),
                    ]
                ))
                graph.addEdge(GraphEdge(src: tableID, dst: columnID, kind: .hasColumn))
            }

            for index in detail.indexes {
                let indexID = GraphID.node(.index, database: ref.database, name: index.name, in: ref.name)
                graph.addNode(GraphNode(
                    id: indexID, kind: .index, name: index.name, database: ref.database,
                    attrs: ["unique": String(index.isUnique), "columns": index.columns.joined(separator: ",")]
                ))
                graph.addEdge(GraphEdge(src: tableID, dst: indexID, kind: .hasIndex))
            }

            for fk in detail.foreignKeys {
                let parentID = GraphID.node(.table, database: ref.database, name: fk.referencedTable)
                // A referenced table not in `objects` still gets a stub node so
                // the reference edge is meaningful for blast-radius queries.
                if graph.nodes[parentID] == nil {
                    graph.addNode(GraphNode(id: parentID, kind: .table, name: fk.referencedTable, database: ref.database))
                }
                graph.addEdge(GraphEdge(
                    src: tableID, dst: parentID, kind: .references,
                    attrs: ["column": fk.column, "referencedColumn": fk.referencedColumn]
                ))
            }
        }

        return graph
    }
}
