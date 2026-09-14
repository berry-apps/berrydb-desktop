import BerryDataSourceKit
import Foundation

/// One grouping level in the NoSQL/vector sidebar tree
/// Mongo's `listCollections()` reports every entry under the SAME
/// working database (`MongoConnection.database` — one connection scopes to
/// one working database, no cross-database listing), so grouping naturally
/// collapses to a single named group; Qdrant collections carry no `database`
/// at all, so grouping collapses to one flat, unnamed group. The type
/// stays generic — grouped strictly by whatever `CollectionRef.database`
/// actually reports — instead of hardcoding "two-level for Mongo, flat for
/// Qdrant".
public struct DataSourceTreeGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let database: String?
    public let collections: [CollectionRef]
}

public enum DataSourceTree {
    /// Groups collections by `database`, sorted by database name then
    /// collection name. A nil database produces one ungrouped bucket.
    public static func group(_ collections: [CollectionRef]) -> [DataSourceTreeGroup] {
        let grouped = Dictionary(grouping: collections, by: \.database)
        return grouped
            .map { database, refs in
                DataSourceTreeGroup(
                    id: database ?? "",
                    database: database,
                    collections: refs.sorted { $0.name < $1.name }
                )
            }
            .sorted { ($0.database ?? "") < ($1.database ?? "") }
    }
}
