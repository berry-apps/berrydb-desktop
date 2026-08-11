import BerryDataSourceKit
import Foundation

/// Backup/restore for document (Mongo), vector (Qdrant), and search
/// (Elasticsearch) connections (docs/feature/04) — the datasource analogue
/// of `BackupService` (SQL). A backup is a *bundle* directory: a
/// `manifest.json` plus one NDJSON file per collection (one document/point
/// per line). Restore recreates each collection and re-inserts its rows.
/// Streamed so RAM stays flat (principle N3).
///
/// Qdrant note: a point's `distance` metric can't be recovered from its points,
/// so the manifest records the vector size (inferred from the first point) and
/// defaults `distance` to "Cosine" on restore.
enum DataSourceBackupService {
    struct Manifest: Codable {
        var kind: String            // "document" | "vector" | "search"
        var driver: String
        var createdAt: String
        var collections: [Entry]
    }

    struct Entry: Codable {
        var name: String
        var vectorSize: Int?        // vector connections only
        var distance: String?
    }

    struct RestoreResult: Sendable {
        var collections: Int
        var documents: Int
    }

    // MARK: - Backup

    @discardableResult
    static func backup(
        session: DataSourceSession,
        collections: [String]? = nil,
        to bundleURL: URL,
        createdAt: String,
        progress: (@Sendable (_ done: Int, _ total: Int, _ label: String) -> Void)? = nil
    ) async throws -> Int {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var refs = try await session.connection.listCollections()
        if let collections { let keep = Set(collections); refs = refs.filter { keep.contains($0.name) } }
        let total = refs.count

        var entries: [Entry] = []
        for ref in refs {
            progress?(entries.count, total, ref.name)
            let fileURL = bundleURL.appendingPathComponent("\(safeFileComponent(ref.name)).ndjson")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }

            var vectorSize: Int?
            try await forEachDocument(session: session, collection: ref.name) { doc in
                if session.kind == .vector, vectorSize == nil { vectorSize = vectorLength(doc) }
                try handle.write(contentsOf: jsonLine(doc))
            }
            entries.append(Entry(
                name: ref.name,
                vectorSize: session.kind == .vector ? vectorSize : nil,
                distance: session.kind == .vector ? "Cosine" : nil
            ))
        }

        let manifest = Manifest(
            kind: session.kind.rawValue,
            driver: session.driverDisplayName,
            createdAt: createdAt,
            collections: entries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent("manifest.json"))
        return entries.count
    }

    // MARK: - Restore

    @discardableResult
    static func restore(
        session: DataSourceSession,
        from bundleURL: URL,
        progress: (@Sendable (_ done: Int, _ total: Int, _ label: String) -> Void)? = nil
    ) async throws -> RestoreResult {
        let manifestData = try Data(contentsOf: bundleURL.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let total = manifest.collections.count

        var restoredDocs = 0
        for (index, entry) in manifest.collections.enumerated() {
            progress?(index, total, entry.name)
            let ref = CollectionRef(name: entry.name)
            // Recreate the collection. Mongo/Elasticsearch auto-create on
            // insert, but running `create` is harmless; Qdrant MUST be
            // created with its vector size.
            if session.kind == .vector, let size = entry.vectorSize {
                let options = BerryDocument.object([
                    ("vectorSize", .int(Int64(size))),
                    ("distance", .string(entry.distance ?? "Cosine")),
                ])
                try? await session.connection.createCollection(ref, options: options)
            } else {
                try? await session.connection.createCollection(ref, options: .object([]))
            }

            // Stream the NDJSON line by line so a large collection never loads
            // wholesale into RAM (the backup side already writes incrementally).
            let fileURL = bundleURL.appendingPathComponent("\(safeFileComponent(entry.name)).ndjson")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            for try await line in fileURL.lines {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) else { continue }
                _ = try? await session.connection.write(.insert(collection: entry.name, document: BerryDocument(jsonObject: json)))
                restoredDocs += 1
            }
        }
        return RestoreResult(collections: manifest.collections.count, documents: restoredDocs)
    }

    // MARK: - Helpers

    /// A collection/table name is data from the connected server, not
    /// trusted input — `appendingPathComponent` does not normalize `..`, so
    /// a malicious/compromised server returning a name like
    /// `"../../../Library/LaunchAgents/evil"` could otherwise make backup/
    /// restore write or read outside the chosen bundle directory. Stripping
    /// path separators collapses any such name to a single, harmless path
    /// component — the manifest and DB operations still use the real,
    /// unmodified name; only the on-disk filename is sanitized.
    static func safeFileComponent(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
    }

    /// Stream every document/point in a collection to `body`. Mongo streams a
    /// single `find({})`; Qdrant pages through `scroll`; Elasticsearch pages
    /// through PIT + `search_after` (`.esScroll`) — until exhausted.
    private static func forEachDocument(
        session: DataSourceSession, collection: String, _ body: (BerryDocument) throws -> Void
    ) async throws {
        switch session.kind {
        case .document:
            for try await event in session.connection.query(
                .mongoFind(collection: collection, filter: .object([]), projection: nil, limit: nil)
            ) {
                if case .items(let docs) = event { for doc in docs { try body(doc) } }
            }
        case .vector:
            var token: String?
            repeat {
                var next: String?
                for try await event in session.connection.query(
                    .qdrantScroll(collection: collection, filter: nil, pageToken: token)
                ) {
                    switch event {
                    case .items(let docs): for doc in docs { try body(doc) }
                    case .complete(let stats): next = stats.nextPageToken
                    }
                }
                token = next
            } while token != nil
        case .search:
            var token: String?
            repeat {
                var next: String?
                for try await event in session.connection.query(
                    .esScroll(index: collection, query: .null, pageToken: token)
                ) {
                    switch event {
                    case .items(let docs): for doc in docs { try body(doc) }
                    case .complete(let stats): next = stats.nextPageToken
                    }
                }
                token = next
            } while token != nil
        }
    }

    private static func jsonLine(_ doc: BerryDocument) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: doc.jsonObject, options: [.withoutEscapingSlashes])
        data.append(0x0A) // newline
        return data
    }

    private static func vectorLength(_ doc: BerryDocument) -> Int? {
        switch doc["vector"] {
        case .vector(let floats): return floats.count
        case .array(let items): return items.count
        default: return nil
        }
    }
}
