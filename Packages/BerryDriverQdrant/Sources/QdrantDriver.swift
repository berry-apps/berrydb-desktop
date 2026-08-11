import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// `DataSourceDriver` for Qdrant (NS-06/07, docs/architecture/12 §5) — zero
/// vendored dependency: plain REST/JSON over `URLSession`. Simplest of the
/// three NoSQL/vector drivers (no SigV4, no SCRAM).
public struct QdrantDriver: DataSourceDriver {
    public static let id: DriverID = .qdrant
    public static let displayName = "Qdrant"
    public static let kind: DataSourceKind = .vector

    public static let capabilities = DataSourceCapabilities(
        write: true,
        vectorSearch: true,
        inferredSchemaOnly: true,
        // No in-DB user system — access is controlled by API key (TI-03
        // Phase D). Shows a static info note in the Users tab instead of
        // hiding it entirely.
        userManagementInfo: true
    )

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection {
        let connection = try QdrantConnection(config: config)
        // Fail fast on a bad host/port instead of only surfacing the problem
        // on the first query — same expectation "Test connection" (KN-06)
        // sets for the other drivers.
        guard await connection.ping() else {
            let host = config.host ?? "?"
            let port = config.port.map(String.init) ?? "?"
            throw DataSourceError.connectionFailed("Could not reach Qdrant at \(host):\(port)")
        }
        return connection
    }
}
