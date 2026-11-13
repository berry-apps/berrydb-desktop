import BerryDriverKit
import Foundation

public struct LibSQLDriver: DatabaseDriver {
    public static let id: DriverID = .libsql
    public static let displayName = "libSQL"
    public static let defaultMaxResponseBytes = 64 * 1024 * 1024
    public static let defaultTimeoutSeconds: TimeInterval = 300

    public static let capabilities = Capabilities(
        transactions: true,
        cancelQuery: false,
        multipleDatabases: false,
        schemas: false,
        explain: true,
        processList: false,
        serverSideCursor: false,
        keyValueBrowser: false
    )

    public static let dialect: any SQLDialect = SQLiteDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await Self.connect(config, sessionConfiguration: nil)
    }

    public static func connect(
        _ config: ConnectionConfig,
        sessionConfiguration: URLSessionConfiguration? = nil,
        maxResponseBytes: Int = LibSQLDriver.defaultMaxResponseBytes,
        timeoutSeconds: TimeInterval = LibSQLDriver.defaultTimeoutSeconds
    ) async throws -> LibSQLConnection {
        guard let endpoint = ConnectionConfig.parseLibSQLEndpoint(
            host: config.host,
            port: config.port,
            tlsMode: config.tlsMode
        ) else {
            throw DriverError.connectionFailed("Missing or invalid libSQL URL / hostname")
        }

        let configuredToken = config.password?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = (configuredToken?.isEmpty == false) ? configuredToken : endpoint.authToken
        let resolvedTLSMode: TLSMode = endpoint.useTLS
            ? (config.tlsMode == .disable ? .require : config.tlsMode)
            : .disable
        let connection = LibSQLConnection(
            baseURL: endpoint.baseURL,
            authToken: (resolvedToken?.isEmpty == false) ? resolvedToken : nil,
            tlsMode: resolvedTLSMode,
            timeoutSeconds: max(1, timeoutSeconds),
            maxResponseBytes: maxResponseBytes,
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
