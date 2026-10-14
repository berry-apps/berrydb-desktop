import Foundation
import Testing

@testable import BerryGraph

@Suite("GraphDiff")
struct GraphDiffTests {
    @Test func reportsAddedAndRemoved() {
        var before = SchemaGraph()
        for n in ["a", "b", "c"] { before.addNode(GraphNode(id: n, kind: .table, name: n)) }
        before.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        before.addEdge(GraphEdge(src: "b", dst: "c", kind: .references))

        var after = SchemaGraph()
        for n in ["a", "b", "d"] { after.addNode(GraphNode(id: n, kind: .table, name: n)) }
        after.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        after.addEdge(GraphEdge(src: "a", dst: "d", kind: .references))

        let diff = before.diff(to: after)
        #expect(diff.addedNodes == ["d"])
        #expect(diff.removedNodes == ["c"])
        #expect(diff.addedEdges.map { "\($0.src)->\($0.dst)" } == ["a->d"])
        #expect(diff.removedEdges.map { "\($0.src)->\($0.dst)" } == ["b->c"])
        #expect(!diff.isEmpty)
    }

    @Test func identicalGraphsDiffEmpty() {
        var g = SchemaGraph()
        g.addNode(GraphNode(id: "a", kind: .table, name: "a"))
        g.addEdge(GraphEdge(src: "a", dst: "a", kind: .references))
        #expect(g.diff(to: g).isEmpty)
    }
}
