import BerryDriverKit
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO

/// State needed to cancel from outside the actor: MySQL cancels a query via
/// `KILL QUERY <connection_id>` on a SECONDARY CONNECTION (docs/architecture/05 §4).
final class MySQLCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _connectionID: UInt64?
    let config: ConnectionConfig

    init(config: ConnectionConfig) { self.config = config }

    var connectionID: UInt64? {
        get { lock.lock(); defer { lock.unlock() }; return _connectionID }
        set { lock.lock(); defer { lock.unlock() }; _connectionID = newValue }
    }
}

public actor MySQLDriverConnection: DriverConnection {
    public nonisolated let id = UUID()

    private var connection: MySQLConnection
    private let config: ConnectionConfig
    private nonisolated let cancelBox: MySQLCancelBox
    private var isClosed = false

    static let batchSize = 500
    private static let logger: Logger = {
        var logger = Logger(label: "berrydb.driver.mysql")
        logger.logLevel = .error
        return logger
    }()

    public init(config: ConnectionConfig) async throws {
        self.config = config
        self.cancelBox = MySQLCancelBox(config: config)
        self.connection = try await Self.makeRawConnection(config)
        await refreshConnectionID()
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

    private static func makeRawConnection(_ config: ConnectionConfig) async throws -> MySQLConnection {
        guard let host = config.host else {
            throw DriverError.connectionFailed("Missing host")
        }
        let port = config.port ?? 3306
        // TLS per KN-04 (07 §4). MySQLNIO negotiates TLS whenever a config is
        // passed, so `prefer` and `require` behave the same here (noted in
        // docs/architecture/05 §6). MySQL 8's caching_sha2_password needs TLS.
        let tls: TLSConfiguration?
        switch config.tlsMode {
        case .disable:
            tls = nil
        case .prefer, .require:
            var configTLS = TLSConfiguration.makeClientConfiguration()
            configTLS.certificateVerification = .none
            try? Self.applyClientIdentity(&configTLS, config: config)
            tls = configTLS
        case .verifyCA, .verifyFull:
            // Verify the chain against the system trust store or a custom CA;
            // verifyCA additionally skips the hostname check (KN-04).
            var verifying = Self.verifyingTLS(mode: config.tlsMode, caCertPath: config.caCertPath)
            try? Self.applyClientIdentity(&verifying, config: config)
            tls = verifying
        }

        // NIOSSL rejects IP literals as SNI hostname (cannotUseIPAddressInSNI) —
        // only pass a server name when the host is an actual DNS name.
        let sniHostname: String? = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil

        do {
            let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
            return try await MySQLConnection.connect(
                to: address,
                username: config.username ?? "root",
                database: config.database ?? "",
                password: config.password,
                tlsConfiguration: tls,
                serverHostname: sniHostname,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.next()
            ).get()
        } catch let error as DriverError {
            throw error
        } catch {
            throw DriverError.connectionFailed(Self.describe(error))
        }
    }

    private func refreshConnectionID() async {
        do {
            let rows = try await connection.simpleQuery("SELECT CONNECTION_ID() AS id").get()
            if let value = rows.first?.column("id")?.int {
                cancelBox.connectionID = UInt64(value)
            }
        } catch {
            cancelBox.connectionID = nil
        }
    }

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

    /// Streaming accumulator for one statement. The onRow callback runs
    /// sequentially on the connection's event loop, so no lock is needed.
    private final class StreamState: @unchecked Sendable {
        var sentColumns = false
        var batch: [[BerryValue]] = []
        var affectedRows: Int64?
    }

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now

        // The onRow callback runs sequentially on the connection's event loop →
        // the box needs no lock; continuation.yield is thread-safe by design.
        let state = StreamState()

        do {
            try await connection.query(
                sql,
                onRow: { row in
                    if !state.sentColumns {
                        state.sentColumns = true
                        continuation.yield(.columns(row.columnDefinitions.map {
                            ColumnMeta(
                                name: $0.name,
                                declaredType: String(describing: $0.columnType)
                            )
                        }))
                    }
                    state.batch.append(Self.berryValues(from: row))
                    if state.batch.count >= Self.batchSize {
                        continuation.yield(.rows(state.batch))
                        state.batch.removeAll(keepingCapacity: true)
                    }
                },
                onMetadata: { metadata in
                    state.affectedRows = Int64(bitPattern: metadata.affectedRows)
                }
            ).get()

            if !state.batch.isEmpty { continuation.yield(.rows(state.batch)) }
            continuation.yield(.complete(QueryStats(
                rowsAffected: state.sentColumns ? nil : state.affectedRows,
                duration: clock.now - started
            )))
            continuation.finish()
        } catch {
            // MySQL rejects CREATE FUNCTION/TRIGGER/PROCEDURE (and a few SHOW
            // forms) over the prepared-statement protocol (ER_UNSUPPORTED_PS,
            // 1295). Nothing has streamed yet, so retry once via the text
            // protocol — keeping every statement on the single SQL path (N1).
            let untouched = !state.sentColumns && state.batch.isEmpty && state.affectedRows == nil
            if untouched, Self.isUnsupportedPreparedStatement(error) {
                await runViaTextProtocol(sql, state: state, clock: clock, started: started,
                                         continuation: continuation)
                return
            }
            if !state.batch.isEmpty { continuation.yield(.rows(state.batch)) }
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Buffered text-protocol execution — the fallback when a statement can't be
    /// prepared. Small administrative statements only, so buffering is fine.
    private func runViaTextProtocol(
        _ sql: String,
        state: StreamState,
        clock: ContinuousClock,
        started: ContinuousClock.Instant,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        do {
            let rows = try await connection.simpleQuery(sql).get()
            if let first = rows.first {
                state.sentColumns = true
                continuation.yield(.columns(first.columnDefinitions.map {
                    ColumnMeta(name: $0.name, declaredType: String(describing: $0.columnType))
                }))
                for row in rows {
                    state.batch.append(Self.berryValues(from: row))
                    if state.batch.count >= Self.batchSize {
                        continuation.yield(.rows(state.batch))
                        state.batch.removeAll(keepingCapacity: true)
                    }
                }
                if !state.batch.isEmpty { continuation.yield(.rows(state.batch)) }
            }
            continuation.yield(.complete(QueryStats(
                rowsAffected: state.sentColumns ? nil : 0,
                duration: clock.now - started
            )))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    private static func isUnsupportedPreparedStatement(_ error: Error) -> Bool {
        guard error is MySQLError else { return false }
        let text = String(reflecting: error).lowercased()
        return text.contains("1295") || text.contains("prepared statement protocol")
    }

    // MARK: - Value mapping (docs/architecture/05 §3)

    static func berryValues(from row: MySQLRow) -> [BerryValue] {
        row.columnDefinitions.map { definition in
            guard let data = row.column(definition.name, table: definition.table) else {
                return .null
            }
            return berryValue(from: data, definition: definition)
        }
    }

    static func berryValue(from data: MySQLData, definition: MySQLProtocol.ColumnDefinition41) -> BerryValue {
        if data.buffer == nil { return .null }
        switch data.type {
        case .tiny, .short, .long, .int24, .longlong, .year, .bit:
            if let value = data.int { return .int(Int64(value)) }
        case .float, .double:
            if let value = data.double { return .double(value) }
        case .decimal, .newdecimal:
            if let value = data.string { return .decimal(value) }
            // Binary protocol ships DECIMAL as a length-encoded ASCII string,
            // but MySQLData.string does not cover NEWDECIMAL — read it raw.
            if var buffer = data.buffer,
               let value = buffer.readString(length: buffer.readableBytes) {
                return .decimal(value)
            }
        case .date:
            if let time = data.time {
                var components = DateComponents()
                components.year = time.year.map(Int.init)
                components.month = time.month.map(Int.init)
                components.day = time.day.map(Int.init)
                return .date(components)
            }
        case .datetime, .timestamp, .timestamp2, .datetime2:
            if let date = data.date {
                return .timestamp(date, hasTimezone: data.type == .timestamp || data.type == .timestamp2)
            }
        case .json:
            if let value = data.string { return .json(value) }
            // Same as DECIMAL: MySQLData.string does not cover MYSQL_TYPE_JSON.
            if var buffer = data.buffer,
               let value = buffer.readString(length: buffer.readableBytes) {
                return .json(value)
            }
        case .varchar, .varString, .string, .enum, .set,
             .tinyBlob, .mediumBlob, .longBlob, .blob, .geometry:
            // charset 63 (binary) → a real BLOB; everything else is a string.
            let isBinary = definition.characterSet == .binary
            if !isBinary, let value = data.string { return .text(value) }
            if var buffer = data.buffer,
               let bytes = buffer.readBytes(length: buffer.readableBytes) {
                return .bytes(Data(bytes))
            }
        case .null:
            return .null
        default:
            break
        }
        // Unrecognized / decode failure → keep the bytes (no data loss).
        if var buffer = data.buffer,
           let bytes = buffer.readBytes(length: buffer.readableBytes) {
            return .unknown(raw: Data(bytes), typeName: String(describing: data.type))
        }
        return .null
    }

    static func mapError(_ error: Error) -> DriverError {
        if let driverError = error as? DriverError { return driverError }
        if let mysqlError = error as? MySQLError {
            // ER_QUERY_INTERRUPTED (1317) — hit by KILL QUERY.
            let text = String(reflecting: mysqlError)
            if text.contains("1317") || text.lowercased().contains("interrupted") {
                return .cancelled
            }
            return .queryFailed(message: describe(mysqlError), code: nil)
        }
        return .queryFailed(message: describe(error), code: nil)
    }

    private static func describe(_ error: Error) -> String {
        if let mysqlError = error as? MySQLError {
            return String(reflecting: mysqlError)
        }
        return error.localizedDescription
    }

    // MARK: - Control

    /// Cancel via a secondary connection: `KILL QUERY <id>` (05 §4, 06 · L6).
    public nonisolated func cancelCurrentQuery() {
        guard let connectionID = cancelBox.connectionID else { return }
        let config = cancelBox.config
        Task {
            guard let companion = try? await Self.makeRawConnection(config) else { return }
            _ = try? await companion.simpleQuery("KILL QUERY \(connectionID)").get()
            try? await companion.close().get()
        }
    }

    /// MySQL switches databases with USE — text protocol (statement cannot be prepared).
    public func setDatabase(_ name: String) async throws {
        let quoted = MySQLDialect().quoteIdentifier(name)
        do {
            _ = try await connection.simpleQuery("USE \(quoted)").get()
        } catch {
            throw Self.mapError(error)
        }
    }

    public nonisolated var introspector: any Introspector {
        MySQLIntrospector(connection: self)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        do {
            _ = try await connection.simpleQuery("SELECT 1").get()
            return true
        } catch {
            return false
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        try? await connection.close().get()
    }

    // MARK: - Internal query for introspection (text protocol, small results)

    func queryAll(_ sql: String) async throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        do {
            let rows = try await connection.simpleQuery(sql).get()
            return rows.map(Self.berryValues(from:))
        } catch {
            throw Self.mapError(error)
        }
    }
}
