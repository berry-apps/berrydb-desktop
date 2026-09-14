import BerryStore
import Foundation
import Testing

@testable import BerryGraph

@Suite("Graph persistence + Digital Twin")
struct GraphPersistenceTests {
    private func makeStore() throws -> GraphStore {
        GraphStore(store: try BerryStore(path: ":memory:"))
    }

    private func edgeKeys(_ graph: SchemaGraph) -> Set<String> {
        Set(graph.edges.map { "\($0.src)->\($0.dst):\($0.kind.rawValue)" })
    }

    private func chain() -> SchemaGraph {
        var g = SchemaGraph()
        for name in ["a", "b", "c"] { g.addNode(GraphNode(id: name, kind: .table, name: name)) }
        g.addNode(GraphNode(id: "col", kind: .column, name: "id", attrs: ["type": "int"]))
        g.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        g.addEdge(GraphEdge(src: "b", dst: "c", kind: .references))
        g.addEdge(GraphEdge(src: "a", dst: "col", kind: .hasColumn))
        return g
    }

    @Test func roundTripsGraph() throws {
        let store = try makeStore()
        let profile = UUID()
        let original = chain()
        try store.persist(original, profileID: profile, now: Date(timeIntervalSince1970: 1000))

        let loaded = try store.loadGraph(profileID: profile)
        #expect(Set(loaded.nodes.keys) == Set(original.nodes.keys))
        #expect(edgeKeys(loaded) == edgeKeys(original))
        // Attributes survive the JSON round-trip.
        #expect(loaded.nodes["col"]?.attrs["type"] == "int")
    }

    @Test func emptyWhenNoSnapshot() throws {
        let store = try makeStore()
        #expect(try store.loadGraph(profileID: UUID()).nodeCount == 0)
    }

    @Test func timeTravelReconstructsEarlierGraph() throws {
        let store = try makeStore()
        let profile = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)

        try store.persist(chain(), profileID: profile, now: t1)

        // t2: drop c (and its edge), add d.
        var later = SchemaGraph()
        for name in ["a", "b", "d"] { later.addNode(GraphNode(id: name, kind: .table, name: name)) }
        later.addEdge(GraphEdge(src: "a", dst: "b", kind: .references))
        try store.persist(later, profileID: profile, now: t2)

        let atT1 = try store.loadGraph(profileID: profile, asOf: t1)
        #expect(Set(atT1.nodes.keys) == ["a", "b", "c", "col"])
        #expect(edgeKeys(atT1).contains("b->c:references"))

        let latest = try store.loadGraph(profileID: profile) // newest snapshot
        #expect(Set(latest.nodes.keys) == ["a", "b", "d"])
        #expect(!edgeKeys(latest).contains("b->c:references"))
        #expect(edgeKeys(latest) == ["a->b:references"])
    }

    @Test func dedupesSnapshotWhenStructureUnchanged() throws {
        let store = try makeStore()
        let profile = UUID()
        try store.persist(chain(), profileID: profile, now: Date(timeIntervalSince1970: 1000))
        // Identical structure → no new snapshot (harvest-on-refresh must not
        // bloat the timeline).
        try store.persist(chain(), profileID: profile, now: Date(timeIntervalSince1970: 2000))
        #expect(try store.snapshots(profileID: profile).count == 1)

        // A structural change does record a new snapshot.
        var changed = chain()
        changed.addNode(GraphNode(id: "d", kind: .table, name: "d"))
        try store.persist(changed, profileID: profile, now: Date(timeIntervalSince1970: 3000))
        let snapshots = try store.snapshots(profileID: profile)
        #expect(snapshots.count == 2)
        #expect(snapshots.first?.takenAt == Date(timeIntervalSince1970: 3000)) // newest first
        #expect(snapshots.first?.nodeCount == 5)
    }

    @Test func digestStableAndSensitive() {
        let a = chain()
        var b = chain()
        #expect(GraphStore.digest(a) == GraphStore.digest(b))
        b.addNode(GraphNode(id: "z", kind: .table, name: "z"))
        #expect(GraphStore.digest(a) != GraphStore.digest(b))
    }
}

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
