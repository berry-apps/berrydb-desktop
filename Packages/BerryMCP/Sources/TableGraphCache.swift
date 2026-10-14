import BerryGraph
import Foundation

/// The table-level graphs the graph tools traverse, kept between calls so a
/// run of graph queries on one connection reads and builds its graph once.
///
/// A profile's graph is reused while the stored schema's revision is the one
/// it was built for; every committed change of the stored objects or
/// relations moves it, also one written by a pass that failed afterwards.
/// At most `maxEntries` graphs are kept, and their estimated sizes (200 bytes
/// per node, 120 per edge) add up to at most `maxBytes`, the least recently
/// used going first. A graph not used for longer than `idle` is dropped at
/// the next lookup, and by a timer that runs while any graph is kept, so a
/// helper left idle gives the memory back without waiting for another call.
/// A graph estimated larger than `maxBytes` on its own is returned without
/// being kept.
///
/// A lock rather than an actor guards it, because the helper answers
/// concurrent requests on its read pool and they ask for graphs
/// synchronously. Graphs are built outside the lock, so building one
/// profile's graph never holds up a lookup for another; two concurrent misses
/// for one profile may both build, and the later replaces the earlier.
public final class TableGraphCache: @unchecked Sendable {
    static let bytesPerNode = 200
    static let bytesPerEdge = 120

    private final class Entry {
        let revision: Int
        let graph: SchemaGraph
        let size: Int
        var lastUsed: Date

        init(revision: Int, graph: SchemaGraph, size: Int, lastUsed: Date) {
            self.revision = revision
            self.graph = graph
            self.size = size
            self.lastUsed = lastUsed
        }
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private let idle: TimeInterval
    private let revision: @Sendable (UUID) throws -> Int
    private let build: @Sendable (UUID) throws -> SchemaGraph
    /// What the timer measures idleness against: the same time a lookup
    /// defaults to.
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    /// Drops idle graphs while any is kept; nil once the cache is empty.
    private var sweeper: Task<Void, Never>?

    /// Reads each profile's revision from `reader.state` and builds its graph
    /// with `reader.tableGraph`.
    public convenience init(
        reader: GraphReader, maxEntries: Int = 4, maxBytes: Int = 32 * 1024 * 1024, idle: TimeInterval = 60
    ) {
        self.init(
            maxEntries: maxEntries, maxBytes: maxBytes, idle: idle,
            revision: { try reader.state(profileID: $0).revision },
            build: { try reader.tableGraph(profileID: $0) }
        )
    }

    init(
        maxEntries: Int, maxBytes: Int, idle: TimeInterval,
        revision: @escaping @Sendable (UUID) throws -> Int,
        build: @escaping @Sendable (UUID) throws -> SchemaGraph,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
        self.idle = idle
        self.revision = revision
        self.build = build
        self.clock = clock
    }

    deinit {
        sweeper?.cancel()
    }

    /// The table-level graph of `profileID`, from the cache while the stored
    /// schema has not changed since it was built.
    public func graph(profileID: UUID, now: Date = Date()) throws -> SchemaGraph {
        let current = try revision(profileID)
        let cached: SchemaGraph? = lock.withLock {
            dropIdle(now: now)
            updateSweeper()
            guard let entry = entries[profileID], entry.revision == current else { return nil }
            entry.lastUsed = now
            return entry.graph
        }
        if let cached { return cached }

        let graph = try build(profileID)
        let size = Self.estimatedSize(of: graph)
        lock.withLock {
            entries[profileID] = nil
            defer { updateSweeper() }
            guard size <= maxBytes else { return }
            entries[profileID] = Entry(revision: current, graph: graph, size: size, lastUsed: now)
            while entries.count > maxEntries || entries.values.reduce(0, { $0 + $1.size }) > maxBytes,
                  let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                entries[oldest] = nil
            }
        }
        return graph
    }

    /// Drops every kept graph, for when the system asks for memory back.
    public func dropAll() {
        lock.withLock {
            entries.removeAll()
            updateSweeper()
        }
    }

    var entryCount: Int {
        lock.withLock { entries.count }
    }

    var isSweeping: Bool {
        lock.withLock { sweeper != nil }
    }

    static func estimatedSize(of graph: SchemaGraph) -> Int {
        graph.nodeCount * bytesPerNode + graph.edgeCount * bytesPerEdge
    }

    /// Must be called with the lock held.
    private func dropIdle(now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastUsed) <= idle }
    }

    /// Starts the timer when a graph is kept and none runs, and cancels it
    /// once the cache is empty. Must be called with the lock held.
    private func updateSweeper() {
        if entries.isEmpty {
            sweeper?.cancel()
            sweeper = nil
            return
        }
        guard sweeper == nil else { return }
        let idle = idle
        sweeper = Task.detached(priority: .utility) { [weak self] in
            var wait = idle
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                guard let self, let next = self.sweep() else { return }
                wait = next
            }
        }
    }

    /// Drops the graphs unused for longer than `idle` and returns how long
    /// until the next one may be, at most `idle`, or nil, ending the timer,
    /// once none is kept.
    private func sweep() -> TimeInterval? {
        lock.withLock {
            let now = clock()
            dropIdle(now: now)
            guard let oldest = entries.values.map(\.lastUsed).min() else {
                sweeper = nil
                return nil
            }
            return min(idle, max(0.001, oldest.addingTimeInterval(idle).timeIntervalSince(now)))
        }
    }
}
