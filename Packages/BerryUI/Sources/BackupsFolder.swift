import Foundation
import Observation

/// Observable progress for a backup/restore run. `@MainActor`
/// makes it Sendable, so a `@Sendable` progress callback running off the main
/// actor can hand values back via `Task { @MainActor in … }` without a data race.
@MainActor
@Observable
final class BackupProgress {
    var fraction: Double?
    var label: String?

    func reset() { fraction = 0; label = nil }
    func clear() { fraction = nil; label = nil }
    func update(done: Int, total: Int, label: String) {
        fraction = total > 0 ? Double(done) / Double(total) : nil
        self.label = label.isEmpty ? nil : label
    }
}

/// One backup on disk — a `.sql` dump (SQL connections) or a bundle directory
/// with a `manifest.json` (Mongo/Qdrant). Listed by the Backup manager tab.
public struct BackupFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let modified: Date
    /// A bundle directory (Mongo/Qdrant) rather than a single `.sql` file.
    public let isBundle: Bool
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
}

/// The per-connection backups directory: a stable location
/// under Application Support so the Backup manager can list past backups
/// instead of the user hunting for loose files.
enum BackupsFolder {
    static func directory(forKey key: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("BerryDB/backups/\(sanitize(key))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Backups in `directory`, newest first. A directory counts only when it
    /// holds a `manifest.json` (our bundle marker); files only when `.sql`.
    static func list(in directory: URL) -> [BackupFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { url -> BackupFile? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            if isDir {
                guard fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
            } else {
                guard url.pathExtension.lowercased() == "sql" else { return nil }
            }
            return BackupFile(url: url, modified: values?.contentModificationDate ?? .distantPast, isBundle: isDir)
        }
        .sorted { $0.modified > $1.modified }
    }

    private static func sanitize(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let string = String(cleaned)
        return string.isEmpty ? "default" : string
    }
}
