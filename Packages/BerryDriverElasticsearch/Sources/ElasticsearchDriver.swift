import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// `DataSourceDriver` for Elasticsearch — zero
/// vendored dependency: plain REST/JSON over `URLSession`, same shape as
/// `QdrantDriver`.
public struct ElasticsearchDriver: DataSourceDriver {
    public static let id: DriverID = .elasticsearch
    public static let displayName = "Elasticsearch"
    public static let kind: DataSourceKind = .search

    public static let capabilities = DataSourceCapabilities(
        write: true,
        vectorSearch: false,
        // `GET /{index}/_mapping` is a real, authoritative field/type catalog
 // not sample-based inference like Mongo.
        inferredSchemaOnly: false,
        // No in-DB user system reachable through this driver's Basic/API-key
 // auth — same static-note treatment as Qdrant (Phase D).
        userManagementInfo: true
    )

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection {
        let connection = try ElasticsearchConnection(config: config)
        // Fail fast on a bad host/port instead of only surfacing the problem
 // on the first query — same "Test connection" expectation as
        // the other drivers.
        guard await connection.ping() else {
            let host = config.host ?? "?"
            let port = config.port.map(String.init) ?? "?"
            throw DataSourceError.connectionFailed("Could not reach Elasticsearch at \(host):\(port)")
        }
        return connection
    }
}
