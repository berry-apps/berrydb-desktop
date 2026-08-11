import BerryDriverKit
import Testing

@testable import BerryGraph

/// Database Persona dispatch (DI-27, docs/architecture/13 §5.7).
@Suite("Database Persona (DI-27)")
struct DatabasePersonaTests {
    /// A table with no primary key and no columns nullable-appropriate — would
    /// trip `schema.missing_pk`/`schema.all_nullable` under the relational rules.
    private func flawedGraph() -> SchemaGraph {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "tbl:t", kind: .table, name: "t"))
        for name in ["a", "b"] {
            let col = GraphNode(id: "col:t.\(name)", kind: .column, name: name,
                                attrs: ["primaryKey": "false", "nullable": "true", "type": "text"])
            g.addNode(col)
            g.addEdge(GraphEdge(src: "tbl:t", dst: col.id, kind: .hasColumn))
        }
        return g
    }

    @Test func mapsDriversToExpectedPersona() {
        #expect(DatabasePersona.persona(for: .postgres) == .relational)
        #expect(DatabasePersona.persona(for: .mysql) == .relational)
        #expect(DatabasePersona.persona(for: .sqlite) == .relational)
        #expect(DatabasePersona.persona(for: .sqlserver) == .relational)
        #expect(DatabasePersona.persona(for: .mongodb) == .document)
        #expect(DatabasePersona.persona(for: .dynamodb) == .document)
        #expect(DatabasePersona.persona(for: .redis) == .keyValue)
        #expect(DatabasePersona.persona(for: .qdrant) == .vector)
    }

    @Test func relationalDialectsStillRunTheExistingRules() {
        let graph = flawedGraph()
        #expect(!InsightEngine.analyze(graph, dialect: .postgres).isEmpty)
        #expect(!InsightEngine.analyze(graph, dialect: .mysql).isEmpty)
    }

    @Test func nonRelationalDialectsGetNoFalsePositives() {
        let graph = flawedGraph()
        #expect(InsightEngine.analyze(graph, dialect: .mongodb).isEmpty)
        #expect(InsightEngine.analyze(graph, dialect: .redis).isEmpty)
        #expect(InsightEngine.analyze(graph, dialect: .qdrant).isEmpty)
        #expect(InsightEngine.analyze(graph, dialect: .dynamodb).isEmpty)
    }
}
