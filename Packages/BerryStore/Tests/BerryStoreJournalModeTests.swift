import Foundation
import GRDB
import Synchronization
import Testing

@testable import BerryStore

@Suite("Journal mode and read-only pool")
struct BerryStoreJournalModeTests {
    func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
    }

    /// Removes the store file and the WAL sidecars it may have left.
    func removeStore(at path: String) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    /// Runs `work` on a thread of its own. A test here blocks threads on
    /// semaphores while connections hold locks, so neither the blocked thread
    /// nor the work it waits for may come from a shared pool: on a 3-core CI
    /// runner the global queues' threads are capped near the core count and
    /// the test runner's cooperative pool has three threads, and blocking
    /// them stalled other suites until their ten-second waits gave up, and
    /// once stalled the whole run.
    func onItsOwnThread(_ work: @escaping @Sendable () -> Void) {
        Thread.detachNewThread(work)
    }

    /// `body`'s result, computed on a thread of its own while the test's task
    /// waits without holding a thread. Expectations stay in the test's task,
    /// where Swift Testing attributes them to the test.
    func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            onItsOwnThread { continuation.resume(with: Result { try body() }) }
        }
    }

    @Test func appOpenSwitchesTheStoreToWAL() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        _ = try BerryStore(path: path)
        let mode = try DatabaseQueue(path: path).read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    /// A harvest pass writes in long transactions on the app's writer. A read
    /// the app makes meanwhile, such as the statistics refresh reading the
    /// graph state on the main actor, must not wait for that transaction:
    /// it reads the last committed state, and the next read after the commit
    /// sees the write.
    @Test func anAppReadCompletesWhileTheAppHoldsAWriteTransaction() async throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let store = try BerryStore(path: path)
        let profile = UUID()
        try store.updateSchemaGraphState(profileID: profile) { $0.objectCount = 1 }
        let (completed, seen) = try await offThePool { () -> (Bool, Int?) in
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        onItsOwnThread {
            try? store.write { db in
                try db.execute(
                    sql: "UPDATE schema_graph_state SET objectCount = 2 WHERE profileID = ?", arguments: [profile]
                )
                entered.signal()
                release.wait()
            }
            writerDone.signal()
        }
        entered.wait()
        let readDone = DispatchSemaphore(value: 0)
        let seen = Mutex<Int?>(nil)
        onItsOwnThread {
            let count = try? store.schemaGraphState(profileID: profile)?.objectCount
            seen.withLock { $0 = count }
            readDone.signal()
        }
        let completed = readDone.wait(timeout: .now() + 2) == .success
        release.signal()
        writerDone.wait()
        if !completed { readDone.wait() }
        return (completed, seen.withLock { $0 })
        }

        #expect(completed, "the read waited for the write transaction to end")
        #expect(seen == 1)
        #expect(try store.schemaGraphState(profileID: profile)?.objectCount == 2)
    }

    /// The app keeps at most two reader connections per store; the helper
    /// keeps GRDB's default for its concurrent tool calls.
    @Test func theAppKeepsAtMostTwoReaderConnections() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let app = try BerryStore(path: path)
        let helper = try BerryStore.openReadOnly(path: path)

        #expect((app.reader as? DatabasePool)?.configuration.maximumReaderCount == 2)
        #expect((helper.reader as? DatabasePool)?.configuration.maximumReaderCount == Configuration().maximumReaderCount)
    }

    @Test func theAppReadsAStoreFileThroughAReaderPool() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        #expect(try BerryStore(path: path).usesReaderPool)
        #expect(try !BerryStore(path: ":memory:").usesReaderPool)
    }

    /// sqlite-vec is installed per connection, so every reader of the pool
    /// must have it: a vector query fails with "no such module: vec0" on one
    /// that does not. Concurrent reads open more than one reader.
    @Test func everyReaderConnectionCanQueryTheVectorTable() async throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let store = try BerryStore(path: path)
        let profile = UUID()
        var vector = Array(repeating: Float(0), count: BerryStore.schemaObjectEmbeddingDimension)
        vector[0] = 1
        try store.storeSchemaNameEmbedding(profileID: profile, name: "orders", vector: vector)
        let failures = try await offThePool { () -> Int in
            let failures = Mutex(0)
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                let names = try? store.nearestSchemaObjects(profileID: profile, to: vector, limit: 4).map(\.name)
                if names != ["orders"] { failures.withLock { $0 += 1 } }
            }
            return failures.withLock { $0 }
        }
        #expect(failures == 0)
    }

    /// The writer commits with NORMAL synchronous, as the store did before its
    /// reads moved to a pool: the SQLite bundled with macOS (3.51.0) is built
    /// with `DEFAULT_WAL_SYNCHRONOUS=1` (`PRAGMA compile_options`), and a GRDB
    /// pool sets NORMAL itself. With NORMAL in WAL mode a commit can be
    /// rolled back by a power loss but the file is not corrupted
    /// (https://www.sqlite.org/pragma.html#pragma_synchronous).
    @Test func theWriterKeepsItsSynchronousLevel() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let store = try BerryStore(path: path)
        #expect(try store.write { try Int.fetchOne($0, sql: "PRAGMA synchronous") } == 1)
    }

    /// A store file still in rollback mode cannot switch to WAL while another
    /// connection holds a read on it, as the helper can while the app
    /// starts: the pool's switch waits out the busy timeout and throws. The
    /// store then opens through one queue in rollback mode. The failure is
    /// injected rather than produced with a held lock, because whether a
    /// held read outlasts the switch's busy wait depends on how fast the
    /// machine reaches the switch, and a slow CI runner did not.
    @Test func aStoreThatCannotSwitchToWALOpensAsAQueue() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        struct SwitchRefused: Error {}
        let writer = try BerryStore.openWriter(path: path, configuration: Configuration()) { _, _ in
            throw SwitchRefused()
        }

        #expect(writer is DatabaseQueue)
        #expect(try writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "delete")
    }

    @Test func readOnlyOpenOnWALUsesAPoolAndReadsWhileTheAppWrites() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let app = try BerryStore(path: path)
        let helper = try BerryStore.openReadOnly(path: path)
        #expect(helper.usesReaderPool)
        let profile = UUID()
        try #require(app.dbWriter).writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                try db.execute(sql: "INSERT INTO schema_graph_state (profileID, objectCount, detailedCount) VALUES (?, 1, 0)", arguments: [profile])
                // The helper reads the committed state, so it still sees no row
                // while this transaction is open.
                #expect(try helper.schemaGraphState(profileID: profile) == nil)
                return .commit
            }
        }
        #expect(try helper.schemaGraphState(profileID: profile)?.objectCount == 1)
    }

    @Test func aHeldReadNeverBlocksAnAppCommit() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let app = try BerryStore(path: path)
        let helper = try BerryStore.openReadOnly(path: path)
        let profile = UUID()
        func storedCount(_ db: Database) throws -> Int? {
            try Int.fetchOne(db, sql: "SELECT objectCount FROM schema_graph_state WHERE profileID = ?", arguments: [profile])
        }
        try helper.read { db in
            let before = try storedCount(db)
            // In rollback mode a commit needs the file's exclusive lock, which
            // it cannot get while this read is open, so it fails with a lock
            // error (https://www.sqlite.org/lockingv3.html); observed as
            // "database is locked" after the busy timeout, and at once as a
            // disk I/O error when the reader is a read-only connection in the
            // same process. In WAL mode this read keeps its snapshot and the
            // commit goes through.
            #expect(throws: Never.self) {
                try app.write { appDB in
                    try appDB.execute(sql: "INSERT INTO schema_graph_state (profileID, objectCount, detailedCount) VALUES (?, 1, 0)", arguments: [profile])
                }
            }
            let after = try storedCount(db)
            #expect(before == nil)
            #expect(after == nil)
        }
        #expect(try helper.schemaGraphState(profileID: profile)?.objectCount == 1)
    }

    @Test func readOnlyOpenOnARollbackStoreStillWorks() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        _ = try BerryStore(path: path)
        try DatabaseQueue(path: path).inDatabase { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        let helper = try BerryStore.openReadOnly(path: path)
        #expect(!helper.usesReaderPool)
        _ = try helper.mcpProjects()
    }

    @Test func readOnlyStoreRefusesWrites() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        _ = try BerryStore(path: path)
        let helper = try BerryStore.openReadOnly(path: path)
        #expect(throws: BerryStore.ReadOnlyWriteAttempt.self) {
            try helper.updateSchemaGraphState(profileID: UUID()) { $0.objectCount = 1 }
        }
    }

    @Test func checkpointMovesCommittedPagesIntoTheStoreFile() throws {
        let path = tempPath()
        defer { removeStore(at: path) }
        let store = try BerryStore(path: path)
        try store.updateSchemaGraphState(profileID: UUID()) { $0.objectCount = 1 }
        // The main file without its -wal sidecar holds only what a checkpoint
        // has moved into it; a short run of commits stays far below the
        // automatic checkpoint threshold.
        func rowsInMainFileAlone() -> Int? {
            let copy = tempPath()
            defer { removeStore(at: copy) }
            try? FileManager.default.copyItem(atPath: path, toPath: copy)
            return try? DatabaseQueue(path: copy).read {
                try Int.fetchOne($0, sql: "SELECT count(*) FROM schema_graph_state")
            }
        }
        #expect(rowsInMainFileAlone() == nil)
        store.checkpoint()
        #expect(rowsInMainFileAlone() == 1)
        try BerryStore.openReadOnly(path: path).checkpoint()
    }

    @Test func memoryManagerReleasesAfterIdleAndOnDemand() async throws {
        let store = try BerryStore(path: ":memory:")
        // The default utility-QoS queue went unserved for more than five
        // seconds while the whole suite ran on a loaded machine, so the timer
        // never fired within the wait. The queue is the manager's to choose;
        // what is under test is the idle release, so it gets one the
        // scheduler serves first.
        let queue = DispatchQueue(label: "memory-manager-test", qos: .userInitiated)
        let manager = StoreMemoryManager(store: store, idle: 0.05, queue: queue)
        manager.touch()
        let deadline = ContinuousClock.now + .seconds(10)
        while store.releaseCount < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterIdle = store.releaseCount
        #expect(afterIdle >= 1)
        manager.releaseNow()
        #expect(store.releaseCount > afterIdle)
        manager.stop()
    }

    /// The kernel raises memory pressure; a test cannot, so it calls the
    /// handler the pressure source runs.
    @Test func memoryPressureReleasesTheStoreAndRunsTheCallback() throws {
        let store = try BerryStore(path: ":memory:")
        let callbacks = Mutex(0)
        let manager = StoreMemoryManager(store: store, onPressure: { callbacks.withLock { $0 += 1 } })
        manager.handleMemoryPressure()
        #expect(store.releaseCount == 1)
        #expect(callbacks.withLock { $0 } == 1)
        manager.stop()
    }
}
