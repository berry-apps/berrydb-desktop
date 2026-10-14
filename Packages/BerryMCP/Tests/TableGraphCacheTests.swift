import BerryGraph
import BerryStore
import Foundation
import Testing

@testable import BerryMCP

/// Supplies a cache's revisions and graphs, and counts the builds.
private final class GraphSource: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [UUID: Int] = [:]
    private var built: [UUID: Int] = [:]
    /// Tables each built graph holds.
    var tables = 1

    func revision(_ profileID: UUID) -> Int {
        lock.withLock { revisions[profileID, default: 0] }
    }

    /// The stored schema of `profileID` changed.
    func change(_ profileID: UUID) {
        lock.withLock { revisions[profileID, default: 0] += 1 }
    }

    func builds(_ profileID: UUID) -> Int {
        lock.withLock { built[profileID, default: 0] }
    }

    func build(_ profileID: UUID) -> SchemaGraph {
        let count = lock.withLock {
            built[profileID, default: 0] += 1
            return tables
        }
        var graph = SchemaGraph()
        for index in 0..<count {
            graph.addNode(GraphNode(id: "table:.t\(index)", kind: .table, name: "t\(index)"))
        }
        return graph
    }

    /// The lookups of these tests pass times of their own, so the timer's
    /// clock stands still and only a lookup drops an idle graph.
    func cache(maxEntries: Int = 4, maxBytes: Int = 32 * 1024 * 1024, idle: TimeInterval = 60) -> TableGraphCache {
        TableGraphCache(
            maxEntries: maxEntries, maxBytes: maxBytes, idle: idle,
            revision: { [self] in revision($0) }, build: { [self] in build($0) }, clock: { .distantPast }
        )
    }
}

@Suite("Table graph cache")
struct TableGraphCacheTests {
    let start = Date(timeIntervalSince1970: 1_000)

    /// Polls `condition` until it holds, for at most ten seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("the awaited condition never held")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// An idle helper keeps no graph until its next lookup: a timer drops a
    /// graph once it has gone unused for the idle interval, and stops when
    /// nothing is left to drop.
    @Test func aGraphUnusedForTheIdleIntervalIsDroppedWithoutALookup() async throws {
        let source = GraphSource()
        let cache = TableGraphCache(
            maxEntries: 4, maxBytes: 32 * 1024 * 1024, idle: 0.05,
            revision: { source.revision($0) }, build: { source.build($0) }
        )
        let profile = UUID()
        source.change(profile)

        _ = try cache.graph(profileID: profile)
        #expect(cache.entryCount == 1 && cache.isSweeping)
        try await waitUntil { cache.entryCount == 0 }
        try await waitUntil { !cache.isSweeping }
    }

    @Test func droppingEveryGraphStopsTheTimer() throws {
        let source = GraphSource()
        let cache = source.cache()
        let profile = UUID()
        source.change(profile)
        _ = try cache.graph(profileID: profile, now: start)
        #expect(cache.isSweeping)
        cache.dropAll()
        #expect(!cache.isSweeping && cache.entryCount == 0)
    }

    @Test func theSameChangeTimeReusesTheBuiltGraph() throws {
        let source = GraphSource()
        let cache = source.cache()
        let profile = UUID()
        source.change(profile)

        let first = try cache.graph(profileID: profile, now: start)
        let second = try cache.graph(profileID: profile, now: start.addingTimeInterval(1))
        #expect(source.builds(profile) == 1)
        #expect(cache.entryCount == 1)
        #expect(first.nodeCount == second.nodeCount)
    }

    @Test func aNewChangeTimeRebuildsInPlace() throws {
        let source = GraphSource()
        let cache = source.cache()
        let profile = UUID()
        source.change(profile)
        _ = try cache.graph(profileID: profile, now: start)

        source.tables = 3
        source.change(profile)
        let rebuilt = try cache.graph(profileID: profile, now: start.addingTimeInterval(6))
        #expect(source.builds(profile) == 2)
        #expect(rebuilt.nodeCount == 3)
        #expect(cache.entryCount == 1)
    }

    @Test func atMostFourGraphsAreKeptAndTheLeastRecentlyUsedGoesFirst() throws {
        let source = GraphSource()
        let cache = source.cache()
        let profiles = (0..<5).map { _ in UUID() }
        for (index, profile) in profiles.enumerated() {
            _ = try cache.graph(profileID: profile, now: start.addingTimeInterval(Double(index)))
        }
        #expect(cache.entryCount == 4)

        _ = try cache.graph(profileID: profiles[4], now: start.addingTimeInterval(10))
        #expect(source.builds(profiles[4]) == 1)
        _ = try cache.graph(profileID: profiles[0], now: start.addingTimeInterval(11))
        #expect(source.builds(profiles[0]) == 2)
        #expect(cache.entryCount == 4)
    }

    @Test func anEntryUnusedForLongerThanTheIdleTimeIsDroppedOnTheNextLookup() throws {
        let source = GraphSource()
        let cache = source.cache(idle: 60)
        let idle = UUID()
        let busy = UUID()
        _ = try cache.graph(profileID: idle, now: start)
        _ = try cache.graph(profileID: busy, now: start.addingTimeInterval(30))
        #expect(cache.entryCount == 2)

        _ = try cache.graph(profileID: busy, now: start.addingTimeInterval(61))
        #expect(cache.entryCount == 1)
        #expect(source.builds(busy) == 1)

        _ = try cache.graph(profileID: idle, now: start.addingTimeInterval(62))
        #expect(source.builds(idle) == 2)
    }

    /// One table is 200 estimated bytes: two fit 450 bytes, a third does
    /// not, and a graph larger than the whole budget is returned unkept.
    @Test func theEstimatedSizeOfTheKeptGraphsStaysWithinTheBudget() throws {
        let source = GraphSource()
        let cache = source.cache(maxBytes: 450)
        let profiles = (0..<3).map { _ in UUID() }
        _ = try cache.graph(profileID: profiles[0], now: start)
        _ = try cache.graph(profileID: profiles[1], now: start.addingTimeInterval(1))
        #expect(cache.entryCount == 2)
        _ = try cache.graph(profileID: profiles[2], now: start.addingTimeInterval(2))
        #expect(cache.entryCount == 2)
        _ = try cache.graph(profileID: profiles[0], now: start.addingTimeInterval(3))
        #expect(source.builds(profiles[0]) == 2)

        source.tables = 3
        let large = UUID()
        let graph = try cache.graph(profileID: large, now: start.addingTimeInterval(4))
        #expect(graph.nodeCount == 3)
        _ = try cache.graph(profileID: large, now: start.addingTimeInterval(5))
        #expect(source.builds(large) == 2)
        #expect(cache.entryCount == 2)
    }

    @Test func edgesCountTowardsTheEstimate() {
        var graph = SchemaGraph()
        graph.addNode(GraphNode(id: "table:.a", kind: .table, name: "a"))
        graph.addNode(GraphNode(id: "table:.b", kind: .table, name: "b"))
        graph.addEdge(GraphEdge(src: "table:.a", dst: "table:.b", kind: .references))
        #expect(TableGraphCache.estimatedSize(of: graph) == 2 * 200 + 120)
    }

    @Test func dropAllEmptiesTheCache() throws {
        let source = GraphSource()
        let cache = source.cache()
        let profile = UUID()
        _ = try cache.graph(profileID: profile, now: start)
        cache.dropAll()
        #expect(cache.entryCount == 0)
        _ = try cache.graph(profileID: profile, now: start)
        #expect(source.builds(profile) == 2)
    }

    @Test func aFailedBuildKeepsNothing() throws {
        struct BuildFailed: Error {}
        let cache = TableGraphCache(
            maxEntries: 4, maxBytes: 1_024, idle: 60, revision: { _ in 0 }, build: { _ in throw BuildFailed() }
        )
        #expect(throws: BuildFailed.self) { try cache.graph(profileID: UUID(), now: start) }
        #expect(cache.entryCount == 0)
    }

    /// A pass that stops after its listing was committed leaves the change
    /// time where it was although the stored schema moved, so a graph keyed on
    /// that time would stay stale until a later pass completed. The cache is
    /// keyed on a revision every committed change of the stored schema moves.
    @Test func aListingCommittedByAPassThatThenFailedReplacesTheGraph() throws {
        let store = try BerryStore(path: ":memory:")
        let profile = UUID()
        func listed(_ names: [String]) -> [SchemaListedObject] {
            names.map { SchemaListedObject(database: "shop", name: $0, kind: "table", fingerprint: "f") }
        }
        _ = try store.applySchemaListing(profileID: profile, objects: listed(["orders"]), relations: [], now: start)
        try store.updateSchemaGraphState(profileID: profile) {
            $0.lastCheckedAt = start
            $0.lastChangedAt = start
        }
        let cache = TableGraphCache(reader: GraphReader(store: store))
        #expect(try cache.graph(profileID: profile).nodeCount == 1)

        _ = try store.applySchemaListing(
            profileID: profile, objects: listed(["orders", "customers"]), relations: [], now: start.addingTimeInterval(60)
        )

        #expect(try store.schemaGraphState(profileID: profile)?.lastChangedAt == start)
        #expect(try cache.graph(profileID: profile).nodeCount == 2)
    }
}
