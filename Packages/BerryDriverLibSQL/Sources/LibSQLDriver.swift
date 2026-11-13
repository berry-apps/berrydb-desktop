import BerryDriverKit
import Foundation

public struct LibSQLDriver: DatabaseDriver {
    public static let id: DriverID = .libsql
    public static let displayName = "libSQL"

    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: true,
        multipleDatabases: false,
        schemas: false,
        explain: true,
        processList: false,
        serverSideCursor: false,
        keyValueBrowser: false
    )

    public static let dialect: any SQLDialect = LibSQLDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await Self.connect(config, sessionConfiguration: nil)
    }

    public static func connect(
        _ config: ConnectionConfig,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) async throws -> LibSQLConnection {
        guard let endpoint = ConnectionConfig.parseLibSQLEndpoint(
            host: config.host,
            port: config.port,
            tlsMode: config.tlsMode
        ) else {
            throw DriverError.connectionFailed("Missing or invalid libSQL URL / hostname")
        }

        let token = config.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = LibSQLConnection(
            baseURL: endpoint.baseURL,
            authToken: (token?.isEmpty == false) ? token : nil,
            tlsMode: endpoint.useTLS ? config.tlsMode : .disable,
            timeoutSeconds: 30,
            sessionConfiguration: sessionConfiguration
        )
        do {
            try await connection.verifyConnection()
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }
}

public struct LibSQLDialect: SQLDialect {
    public init() {}

    public func quoteIdentifier(_ identifier: String) -> String {
        let escaped = identifier.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    public var systemSchemas: Set<String> { [] }
    public var explainPrefix: String? { "EXPLAIN QUERY PLAN " }
    public var supportsDropColumn: Bool { true }
    public var supportsTransactions: Bool { true }
    public var requiresQualifiedIdentifiers: Bool { false }

    public func limitClause(_ limit: Int) -> String {
        "LIMIT \(limit)"
    }
}
