import BerryStore
import Foundation

/// What one `SchemaEmbeddingIndexer.drain` pass did.
public struct DrainResult: Sendable, Equatable {
    /// Objects whose name now has a vector.
    public let embedded: Int
    /// Requests that failed: no usable vector came back, or the store could not
    /// save it. Whether they counted an attempt is decided by `unavailable`.
    public let failed: Int
    /// Every request of the batch failed, which the transport reports the same
    /// way whatever the cause, so it is taken to be an outage and no object was
    /// charged an attempt; or the store could not save a vector or record a
    /// failed attempt, which says nothing about the names either. The caller
    /// should wait before draining again.
    public let unavailable: Bool
}

/// Embeds table and collection names for `search_schema`: in the background
/// from the store's queue of objects whose name has no vector yet, and inside
/// a search for a bounded number of the names it lists, which covers a
/// connection whose names the background queue never reaches.
public struct SchemaEmbeddingIndexer: Sendable {
    private let store: BerryStore
    private let transport: AITransport
    private let maxConcurrentRequests: Int

    public init(
        store: BerryStore, transport: AITransport,
        maxConcurrentRequests: Int = 4
    ) {
        self.store = store
        self.transport = transport
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    /// Of `candidateNames`, the first `limit` that have no vector yet; none
    /// when the store cannot say. Asynchronous so a caller on the main actor
    /// does not run the lookup there.
    public func namesWithoutVector(profileID: UUID, among candidateNames: [String], limit: Int) async -> [String] {
        (try? store.schemaNamesWithoutEmbedding(profileID: profileID, among: candidateNames, limit: limit)) ?? []
    }

    /// Embeds `names` by name, at most `maxConcurrentRequests` at once, and
    /// stores each vector that comes back. A failure counts no attempt
    /// anywhere: a name may have no stored object to count it on, and the
    /// next search asks for it again. Returns false once the store refused a
    /// vector; no further request starts then, and the ones in flight are
    /// cancelled, since the store would refuse their vectors too.
    public func embed(profileID: UUID, names: [String]) async -> Bool {
        var pending = names.makeIterator()
        var stored = true
        await withTaskGroup(of: (name: String, vector: [Float]).self) { group in
            func startNext() {
                guard stored, !Task.isCancelled, let next = pending.next() else { return }
                group.addTask { (next, await transport.embed(text: next)) }
            }
            for _ in 0..<maxConcurrentRequests { startNext() }
            while let result = await group.next() {
                if stored, !Task.isCancelled, result.vector.count == BerryStore.schemaObjectEmbeddingDimension {
                    do {
                        try store.storeSchemaNameEmbedding(profileID: profileID, name: result.name, vector: result.vector)
                    } catch {
                        stored = false
                        group.cancelAll()
                    }
                }
                startNext()
            }
        }
        return stored
    }

    private struct QueuedName: Sendable {
        let id: Int64
        let name: String
    }

    /// Embeds up to `batch` queued objects of the profile, oldest first.
    ///
    /// One request per name, because the embedding endpoint takes a single
    /// text, with at most `maxConcurrentRequests` running at once. The next
    /// name starts as soon as any request finishes, so one slow response does
    /// not hold back a whole group.
    ///
    /// A failure counts an attempt on the object, and the store stops offering
    /// it after five, until its definition changes and it is queued again. The
    /// transport answers every failure with an empty vector, so a network or
    /// provider outage looks the same as a name the provider rejects; the only
    /// sign of an outage is a batch in which every request failed, and then no
    /// attempt is counted. The cost is that a name which always fails and is
    /// alone in its batches is retried for as long as no batch also contains a
    /// success. A request that ends because the work was cancelled counts
    /// nothing either: it says nothing about the name, and counting it would use
    /// up the name's attempts each time the app quits mid-drain.
    ///
    /// A store that cannot save says nothing about the names either. The first
    /// vector it refuses to save ends the batch: no further request starts,
    /// the ones in flight are cancelled, no attempt is counted, and the result
    /// is `unavailable`. A failure to record an attempt drops the attempts not
    /// yet recorded and makes the result `unavailable` too. Without that, a
    /// store that refused to record the attempts would hand the drain the same
    /// names on every batch.
    public func drain(profileID: UUID, batch: Int = 100) async -> DrainResult {
        guard batch > 0,
              let objects = try? store.schemaObjectsNeedingEmbedding(profileID: profileID, limit: batch),
              !objects.isEmpty
        else { return DrainResult(embedded: 0, failed: 0, unavailable: false) }
        var pending = objects.map { QueuedName(id: $0.id, name: $0.name) }.makeIterator()
        var embedded = 0
        var answered = 0
        var failedIDs: [Int64] = []
        var storeFailures = 0

        await withTaskGroup(of: (queued: QueuedName, vector: [Float]?).self) { group in
            func startNext() {
                guard !Task.isCancelled, let next = pending.next() else { return }
                group.addTask {
                    let vector = await transport.embed(text: next.name)
                    return (next, Task.isCancelled ? nil : vector)
                }
            }
            for _ in 0..<maxConcurrentRequests { startNext() }
            while let result = await group.next() {
                guard storeFailures == 0 else { continue }
                guard let vector = result.vector else {
                    startNext()
                    continue
                }
                if vector.count == BerryStore.schemaObjectEmbeddingDimension {
                    answered += 1
                    do {
                        // False when the object was removed while its request
                        // was outstanding: nothing was written, and there is
                        // nothing left to count.
                        if try store.storeSchemaEmbedding(
                            id: result.queued.id, profileID: profileID, name: result.queued.name, vector: vector
                        ) {
                            embedded += 1
                        }
                    } catch {
                        storeFailures += 1
                        group.cancelAll()
                        continue
                    }
                } else {
                    failedIDs.append(result.queued.id)
                }
                startNext()
            }
        }
        if storeFailures == 0, answered > 0 {
            for id in failedIDs {
                do {
                    try store.recordSchemaEmbeddingFailure(id: id)
                } catch {
                    storeFailures += 1
                    break
                }
            }
        }
        let failed = failedIDs.count + storeFailures
        return DrainResult(
            embedded: embedded, failed: failed, unavailable: storeFailures > 0 || (answered == 0 && !failedIDs.isEmpty)
        )
    }
}
