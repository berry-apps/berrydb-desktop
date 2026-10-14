import BerryStore
import Foundation

/// Builds a `SchemaGraph` from stored rows with the node ids, kinds and
/// attributes `SchemaGraphBuilder` gives the same objects.
struct GraphAssembly {
    var graph = SchemaGraph()

    mutating func addObject(database: String?, name: String, kind: String) {
        let nodeKind: NodeKind = kind == "view" ? .view : .table
        graph.addNode(GraphNode(
            id: GraphID.node(nodeKind, database: database, name: name), kind: nodeKind, name: name, database: database
        ))
    }

    /// Columns and indexes hang off the object's own node. For a view that
    /// is the view node, where `SchemaGraphBuilder` would hang them off a
    /// table node of the same name: the catalog harvest it served never read
    /// a view's columns, so it never had to tell the two apart.
    mutating func addDefinition(_ definition: SchemaDefinition, of object: SchemaObjectRecord) {
        let kind: NodeKind = object.kind == "view" ? .view : .table
        let ownerID = GraphID.node(kind, database: object.database, name: object.name)
        for column in definition.columns {
            let id = GraphID.node(.column, database: object.database, name: column.name, in: object.name)
            graph.addNode(GraphNode(
                id: id, kind: .column, name: column.name, database: object.database,
                attrs: ["type": column.type, "nullable": String(column.nullable), "primaryKey": String(column.primaryKey)]
            ))
            graph.addEdge(GraphEdge(src: ownerID, dst: id, kind: .hasColumn))
        }
        for index in definition.indexes {
            let id = GraphID.node(.index, database: object.database, name: index.name, in: object.name)
            graph.addNode(GraphNode(
                id: id, kind: .index, name: index.name, database: object.database,
                attrs: ["unique": String(index.unique), "columns": index.columns.joined(separator: ",")]
            ))
            graph.addEdge(GraphEdge(src: ownerID, dst: id, kind: .hasIndex))
        }
    }

    /// A foreign key is an edge between tables. An end the graph does not
    /// hold, such as a table outside the harvested schemas, gets a node of
    /// its own so the edge still counts in blast-radius and path queries.
    mutating func addRelation(_ relation: SchemaRelationEnds) {
        let source = tableNode(database: relation.srcDatabase, name: relation.srcName)
        let target = tableNode(database: relation.dstDatabase, name: relation.dstName)
        graph.addEdge(GraphEdge(
            src: source, dst: target, kind: .references,
            attrs: ["column": relation.srcColumn, "referencedColumn": relation.dstColumn]
        ))
    }

    /// Statistics name an object by namespace and name only; they are
    /// attached to the table or view of that name, and dropped when the graph
    /// holds neither.
    mutating func addStatistics(_ rows: [SchemaStatsRecord]) {
        for row in rows {
            let candidates = [NodeKind.table, .view].map { GraphID.node($0, database: row.database, name: row.name) }
            guard let id = candidates.first(where: { graph.nodes[$0] != nil }), var node = graph.nodes[id] else { continue }
            node.attrs.merge(GraphReader.counterAttributes(of: row)) { _, new in new }
            graph.addNode(node)
            for (name, scans) in GraphReader.indexCounters(of: row) {
                let indexID = GraphID.node(.index, database: row.database, name: name, in: row.name)
                guard var index = graph.nodes[indexID] else { continue }
                index.attrs.merge(GraphReader.indexAttributes(scans: scans)) { _, new in new }
                graph.addNode(index)
            }
        }
    }

    private mutating func tableNode(database: String?, name: String) -> String {
        let id = GraphID.node(.table, database: database, name: name)
        if graph.nodes[id] == nil {
            graph.addNode(GraphNode(id: id, kind: .table, name: name, database: database))
        }
        return id
    }
}
