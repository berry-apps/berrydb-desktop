import BerryDriverKit
import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// State needed to cancel from outside the actor (docs/architecture/05 §4):
/// Postgres cancels a query via `pg_cancel_backend(pid)` on a SECONDARY CONNECTION.
final class PostgresCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _backendPID: Int32?
    let config: ConnectionConfig

    init(config: ConnectionConfig) { self.config = config }

    var backendPID: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return _backendPID }
        set { lock.lock(); defer { lock.unlock() }; _backendPID = newValue }
    }
}

public actor PostgresDriverConnection: DriverConnection {
    public nonisolated let id = UUID()

    private var connection: PostgresConnection
    private var config: ConnectionConfig
    private nonisolated let cancelBox: PostgresCancelBox
    private var isClosed = false

    static let batchSize = 500
    private static let logger: Logger = {
        var logger = Logger(label: "berrydb.driver.postgres")
        logger.logLevel = .error
        return logger
    }()

    public init(config: ConnectionConfig) async throws {
        self.config = config
        self.cancelBox = PostgresCancelBox(config: config)
        self.connection = try await Self.makeRawConnection(config)
        await refreshBackendPID()
    }

    /// Client TLS config for the verifying modes (KN-04). A custom CA replaces
    /// the trust store; verifyCA drops hostname checking for IP-reached servers.
    static func verifyingTLS(mode: TLSMode, caCertPath: String?) -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = mode == .verifyFull ? .fullVerification : .noHostnameVerification
        if let caCertPath {
            tls.trustRoots = .file(caCertPath)
        }
        return tls
    }

    /// Mutual TLS (KN-04): attach the client certificate chain + key when both
    /// paths are set. Applies to every TLS mode except `disable`.
    static func applyClientIdentity(_ tls: inout TLSConfiguration, config: ConnectionConfig) throws {
        guard let certPath = config.clientCertPath, !certPath.isEmpty,
              let keyPath = config.clientKeyPath, !keyPath.isEmpty else { return }
        tls.certificateChain = try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) }
        tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyPath, format: .pem))
    }

    private static func makeRawConnection(_ config: ConnectionConfig) async throws -> PostgresConnection {
        guard let host = config.host else {
            throw DriverError.connectionFailed("Missing host")
        }
        // TLS per KN-04 (docs/architecture/07 §4); default is `prefer`.
        let tlsMode: PostgresConnection.Configuration.TLS
        switch config.tlsMode {
        case .disable:
            tlsMode = .disable
        case .prefer:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            try Self.applyClientIdentity(&tls, config: config)
            tlsMode = .prefer(try NIOSSLContext(configuration: tls))
        case .require:
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.certificateVerification = .none
            try Self.applyClientIdentity(&tls, config: config)
            tlsMode = .require(try NIOSSLContext(configuration: tls))
        case .verifyCA, .verifyFull:
            // Verify the chain against the system trust store or a custom CA;
            // verifyCA additionally skips the hostname check (KN-04).
            var tls = Self.verifyingTLS(mode: config.tlsMode, caCertPath: config.caCertPath)
            try Self.applyClientIdentity(&tls, config: config)
            tlsMode = .require(try NIOSSLContext(configuration: tls))
        }

        let pgConfig = PostgresConnection.Configuration(
            host: host,
            port: config.port ?? 5432,
            username: config.username ?? "postgres",
            password: config.password,
            database: config.database,
            tls: tlsMode
        )
        do {
            return try await PostgresConnection.connect(
                configuration: pgConfig,
                id: 1,
                logger: logger
            )
        } catch {
            throw DriverError.connectionFailed(Self.describe(error))
        }
    }

    private func refreshBackendPID() async {
        do {
            let rows = try await connection.query("SELECT pg_backend_pid()", logger: Self.logger)
            for try await pid in rows.decode(Int32.self) {
                cancelBox.backendPID = pid
            }
        } catch {
            cancelBox.backendPID = nil
        }
    }

    /// Test hook: exposes whether the cancel precondition holds (05 §4).
    public nonisolated var debugBackendPID: Int32? { cancelBox.backendPID }

    // MARK: - Execute (docs/architecture/06 · L2)

    public nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(sql: sql, continuation: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    self.cancelCurrentQuery()
                }
            }
        }
    }

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let rows = try await connection.query(
                PostgresQuery(unsafeSQL: sql),
                logger: Self.logger
            )
            var sentColumns = false
            var batch: [[BerryValue]] = []
            batch.reserveCapacity(Self.batchSize)

            for try await row in rows {
                let cells = Array(row)
                if !sentColumns {
                    sentColumns = true
                    continuation.yield(.columns(cells.map {
                        ColumnMeta(name: $0.columnName, declaredType: String(describing: $0.dataType))
                    }))
                }
                batch.append(cells.map(Self.berryValue(from:)))
                if batch.count >= Self.batchSize {
                    continuation.yield(.rows(batch))
                    batch.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
            }
            if !batch.isEmpty { continuation.yield(.rows(batch)) }
            continuation.yield(.complete(QueryStats(
                rowsAffected: nil,   // PostgresNIO does not expose the command tag yet — note in 05 §6
                duration: clock.now - started
            )))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    // MARK: - Value mapping (docs/architecture/05 §3 — no information loss)

    static func berryValue(from cell: PostgresCell) -> BerryValue {
        guard cell.bytes != nil else { return .null }
        do {
            switch cell.dataType {
            case .bool:
                return .bool(try cell.decode(Bool.self))
            case .int2:
                return .int(Int64(try cell.decode(Int16.self)))
            case .int4:
                return .int(Int64(try cell.decode(Int32.self)))
            case .int8:
                return .int(try cell.decode(Int64.self))
            case .float4:
                return .double(Double(try cell.decode(Float.self)))
            case .float8:
                return .double(try cell.decode(Double.self))
            case .numeric:
                return .decimal(String(describing: try cell.decode(Decimal.self)))
            case .text, .varchar, .bpchar, .name:
                return .text(try cell.decode(String.self))
            case .bytea:
                return .bytes(Data(try cell.decode(ByteBuffer.self).readableBytesView))
            case .uuid:
                return .uuid(try cell.decode(UUID.self))
            case .date, .timestamp:
                return .timestamp(try cell.decode(Date.self), hasTimezone: false)
            case .timestamptz:
                return .timestamp(try cell.decode(Date.self), hasTimezone: true)
            case .json, .jsonb:
                return .json(try cell.decode(String.self))
            default:
                return unknownValue(from: cell)
            }
        } catch {
            // Decode failure → keep the raw bytes instead of crashing/losing data.
            return unknownValue(from: cell)
        }
    }

    private static func unknownValue(from cell: PostgresCell) -> BerryValue {
        // Text format can be shown as a string — friendlier than hex.
        if cell.format == .text, let bytes = cell.bytes,
           let string = bytes.getString(at: bytes.readerIndex, length: bytes.readableBytes) {
            return .text(string)
        }
        let data = cell.bytes.map { Data($0.readableBytesView) } ?? Data()
        return .unknown(raw: data, typeName: String(describing: cell.dataType))
    }

    static func mapError(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError { return driverError }
        if let psql = error as? PSQLError {
            let state = psql.serverInfo?[.sqlState]
            if state == "57014" { return .cancelled }   // query_canceled
            let message = psql.serverInfo?[.message] ?? describe(psql)
            return .queryFailed(message: message, code: nil)
        }
        return .queryFailed(message: describe(error), code: nil)
    }

    private static func describe(_ error: Error) -> String {
        (error as? PSQLError).map { String(reflecting: $0) } ?? error.localizedDescription
    }

    // MARK: - Control

    /// Cancel via a secondary connection: `SELECT pg_cancel_backend(pid)` (05 §4, 06 · L6).
    public nonisolated func cancelCurrentQuery() {
        guard let pid = cancelBox.backendPID else { return }
        let config = cancelBox.config
        Task {
            guard let companion = try? await Self.makeRawConnection(config) else { return }
            _ = try? await companion.query(
                "SELECT pg_cancel_backend(\(pid))",
                logger: Self.logger
            )
            try? await companion.close()
        }
    }

    /// Postgres cannot switch databases on the same connection → reconnect (05 §4).
    public func setDatabase(_ name: String) async throws {
        let newConfig = ConnectionConfig(
            driver: config.driver, name: config.name, filePath: nil,
            host: config.host, port: config.port,
            username: config.username, password: config.password,
            database: name
        )
        let newConnection = try await Self.makeRawConnection(newConfig)
        try? await connection.close()
        connection = newConnection
        config = newConfig
        await refreshBackendPID()
    }

    public nonisolated var introspector: any Introspector {
        PostgresIntrospector(connection: self)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        do {
            _ = try await connection.query("SELECT 1", logger: Self.logger)
            return true
        } catch {
            return false
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await connection.close()
    }

    // MARK: - Internal query for introspection

    func queryAll(_ sql: String) async throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        do {
            let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger)
            var result: [[BerryValue]] = []
            for try await row in rows {
                result.append(Array(row).map(Self.berryValue(from:)))
            }
            return result
        } catch {
            throw Self.mapError(error)
        }
    }
}
