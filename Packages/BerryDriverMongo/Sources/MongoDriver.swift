import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// `DataSourceDriver` for MongoDB.
/// Hand-rolled pure-Swift OP_MSG wire protocol + BSON + SCRAM-SHA-256 auth.
public struct MongoDriver: DataSourceDriver {
    public static let id: DriverID = .mongodb
    public static let displayName = "MongoDB"
    public static let kind: DataSourceKind = .document

    public static let capabilities = DataSourceCapabilities(
        write: true,
        vectorSearch: false,
        inferredSchemaOnly: true,
 // Real createUser/dropUser/usersInfo admin commands (Phase C).
        userManagement: true
    )

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DataSourceConnection {
        let connection = try MongoConnection(config: config)
        // `open()` performs the TCP connect + `hello` handshake + SCRAM
 // auth — failure here is the "Test connection" fail-fast
        // point, same expectation the other drivers set.
        try await connection.open()
        return connection
    }
}
