import Foundation

/// A store file of its own under the temporary directory, for a test that
/// builds a `WorkspaceViewModel`. The parameterless initializer opens the
/// application's default store and runs the build's migrations on it.
struct TemporaryStoreFile {
    let path = NSTemporaryDirectory() + "berry-store-\(UUID().uuidString).sqlite"

    /// Deletes the store and the WAL sidecars SQLite created next to it.
    func remove() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }
}
