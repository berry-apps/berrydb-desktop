import Foundation
import GRDB
import Testing

@testable import BerryStore

@Suite("BerryStore read-only open")
struct BerryStoreReadOnlyTests {
    func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
    }

    @Test func opensAFullyMigratedStoreWithoutWriting() throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let store = try BerryStore.openReadOnly(path: path)
        _ = try store.mcpProjects()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    @Test func rejectsAStoreMissingMigrations() throws {
        let path = tempPath()
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)") }
        #expect(throws: BerryStore.ReadOnlyOpenError.self) { try BerryStore.openReadOnly(path: path) }
    }

    @Test func rejectsAStoreFromANewerApp() throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let queue = try DatabaseQueue(path: path)
        try queue.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('v99-from-the-future')") }
        #expect(throws: BerryStore.ReadOnlyOpenError.self) { try BerryStore.openReadOnly(path: path) }
    }

    /// A lock taken on a store file from a second connection, standing in for
    /// the other process (app or helper).
    ///
    /// The lock runs on a dedicated `Thread`, and the test awaits it through
    /// continuations. Waiting with a semaphore on work queued to a shared
    /// pool would block a Swift concurrency thread until that pool serves the
    /// work, which on a machine with few cores can starve every test thread.
    private final class HeldLock: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var isReleased = false
        private(set) var error: (any Error)?

        /// Takes the lock with `sql`, holds it for `duration`, then commits.
        /// Returns once the lock is held.
        static func take(_ sql: String, on path: String, for duration: TimeInterval) async throws -> HeldLock {
            let other = try DatabaseQueue(path: path)
            let held = HeldLock()
            await withCheckedContinuation { (acquired: CheckedContinuation<Void, Never>) in
                held.setAcquiredWaiter(acquired)
                Thread {
                    do {
                        try other.inDatabase { db in
                            try db.execute(sql: sql)
                            _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
                            held.signalAcquired()
                            Thread.sleep(forTimeInterval: duration)
                            try db.execute(sql: "COMMIT")
                        }
                    } catch {
                        held.record(error)
                    }
                    held.signalAcquired()
                    held.markReleased()
                }.start()
            }
            return held
        }

        private var acquiredWaiter: CheckedContinuation<Void, Never>?

        private func setAcquiredWaiter(_ waiter: CheckedContinuation<Void, Never>) {
            lock.lock()
            acquiredWaiter = waiter
            lock.unlock()
        }

        /// Resumes the acquiring test once, whichever of lock or failure comes first.
        private func signalAcquired() {
            lock.lock()
            let waiter = acquiredWaiter
            acquiredWaiter = nil
            lock.unlock()
            waiter?.resume()
        }

        /// Suspends until the lock has been released, without blocking a thread.
        func released() async {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isReleased {
                    lock.unlock()
                    waiter.resume()
                } else {
                    releaseWaiter = waiter
                    lock.unlock()
                }
            }
        }

        private func record(_ error: any Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        private func markReleased() {
            lock.lock()
            isReleased = true
            let waiter = releaseWaiter
            releaseWaiter = nil
            lock.unlock()
            waiter?.resume()
        }
    }

    @Test func appWriteWaitsForAHelperReadInsteadOfFailing() async throws {
        let path = tempPath()
        let store = try BerryStore(path: path)
        let held = try await HeldLock.take("BEGIN DEFERRED", on: path, for: 0.5)

        try store.save(ConnectionProfile(driverID: "sqlite", name: "Saved during a read"))

        await held.released()
        #expect(held.error == nil)
        #expect(try store.allProfiles().map(\.name) == ["Saved during a read"])
    }

    @Test func helperReadWaitsForAnAppWriteInsteadOfFailing() async throws {
        let path = tempPath()
        _ = try BerryStore(path: path)
        let held = try await HeldLock.take("BEGIN EXCLUSIVE", on: path, for: 0.5)

        let helper = try BerryStore.openReadOnly(path: path)
        #expect(try helper.mcpProjects().isEmpty)

        await held.released()
        #expect(held.error == nil)
    }

    @Test func missingFileIsAnErrorNotACreation() {
        let path = tempPath()
        #expect(throws: (any Error).self) { try BerryStore.openReadOnly(path: path) }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
