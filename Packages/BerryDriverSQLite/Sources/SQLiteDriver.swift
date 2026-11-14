import BerryDriverKit
import Foundation

public struct SQLiteDriver: DatabaseDriver {
    public static let id: DriverID = .sqlite
    public static let displayName = "SQLite"

 // Capability matrix:
    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: true,          // sqlite3_interrupt
        multipleDatabases: false,   // attach considered later
        schemas: false,
        explain: true,
        processList: false,
        serverSideCursor: false,    // in-process, not needed
        keyValueBrowser: false
    )

    public static let dialect: any SQLDialect = SQLiteDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let path = config.filePath else {
            throw DriverError.connectionFailed("Missing SQLite file path")
        }
        return try SQLiteConnection(path: path)
    }
}
