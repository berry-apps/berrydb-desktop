import BerryDriverKit
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import MySQLNIO

/// State needed to cancel from outside the actor: MySQL cancels a query via
/// `KILL QUERY <connection_id>` on a SECONDARY CONNECTION.
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

public actor MySQLDriverConnection: StatementBoundingConnection {
    public nonisolated let id = UUID()

    private var connection: MySQLConnection
    private let config: ConnectionConfig
    private nonisolated let cancelBox: MySQLCancelBox
    private var isClosed = false
    /// How the server sets a variable for one statement, learned from its
    /// version the first time it matters.
    private var perStatementForm: PerStatementForm?
    /// Set by `boundEachStatement(by:)`.
    private var statementTimeout: Duration?
    /// Held by a read-only statement from its first control statement to its
    /// COMMIT, so two read-only statements never share one transaction: the
    /// COMMIT of one would leave the other running in none. Only
    /// `prepareReadOnly()` and `executeReadOnly(_:timeout:)` take it.
    private let turn = ConnectionTurn()

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

 /// Client TLS config for the verifying modes. A custom CA replaces
    /// the trust store; verifyCA drops hostname checking for IP-reached servers.
    static func verifyingTLS(mode: TLSMode, caCertPath: String?) -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = mode == .verifyFull ? .fullVerification : .noHostnameVerification
        if let caCertPath {
            tls.trustRoots = .file(caCertPath)
        }
        return tls
    }

 /// Mutual TLS: attach the client certificate chain + key when both
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
 // TLS. MySQLNIO negotiates TLS whenever a config is
        // passed, so `prefer` and `require` behave the same here (noted in
 // MySQL 8's caching_sha2_password needs TLS.
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
 // verifyCA additionally skips the hostname check.
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

 // MARK: - Execute

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

    private func run(sql statement: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let stats = try await stream(bounded(statement), clock: clock, started: started, into: continuation)
            continuation.yield(.complete(stats))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Streams the rows of `sql` into `continuation` and returns the
    /// statement's statistics, leaving the stream open for the caller.
    private func stream(
        _ sql: String,
        clock: ContinuousClock,
        started: ContinuousClock.Instant,
        into continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async throws -> QueryStats {
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
        } catch {
            // MySQL rejects CREATE FUNCTION/TRIGGER/PROCEDURE (and a few SHOW
            // forms) over the prepared-statement protocol (ER_UNSUPPORTED_PS,
            // 1295). Nothing has streamed yet, so retry once via the text
            // protocol, keeping every statement on the single SQL path.
            let untouched = !state.sentColumns && state.batch.isEmpty && state.affectedRows == nil
            if untouched, Self.isUnsupportedPreparedStatement(error) {
                return try await streamViaTextProtocol(sql, state: state, clock: clock, started: started, into: continuation)
            }
            if !state.batch.isEmpty { continuation.yield(.rows(state.batch)) }
            throw error
        }
        if !state.batch.isEmpty { continuation.yield(.rows(state.batch)) }
        return QueryStats(
            rowsAffected: state.sentColumns ? nil : state.affectedRows,
            duration: clock.now - started
        )
    }

    /// Buffered text-protocol execution — the fallback when a statement can't be
    /// prepared. Small administrative statements only, so buffering is fine.
    private func streamViaTextProtocol(
        _ sql: String,
        state: StreamState,
        clock: ContinuousClock,
        started: ContinuousClock.Instant,
        into continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async throws -> QueryStats {
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
        return QueryStats(rowsAffected: state.sentColumns ? nil : 0, duration: clock.now - started)
    }

    private static func isUnsupportedPreparedStatement(_ error: Error) -> Bool {
        guard error is MySQLError else { return false }
        let text = String(reflecting: error).lowercased()
        return text.contains("1295") || text.contains("prepared statement protocol")
    }

 // MARK: - Value mapping

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

 /// Cancel via a secondary connection: `KILL QUERY <id>` (06).
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
        try await textQuery(bounded(sql))
    }

    /// `sql` with `GROUP_CONCAT` results allowed up to `groupConcatMaxLength`
    /// characters. Set for the statement alone where the server can, so the
    /// session keeps its own limit and a pooled server session never carries
    /// it to another client; otherwise set for the session first.
    func queryAll(_ sql: String, groupConcatMaxLength: Int) async throws -> [[BerryValue]] {
        let form = await serverForm()
        guard form != .none else {
            _ = try await queryAll("SET SESSION group_concat_max_len = \(groupConcatMaxLength)")
            return try await queryAll(sql)
        }
        return try await textQuery(
            Self.statement(sql, form: form, timeout: statementTimeout, groupConcatMaxLength: groupConcatMaxLength)
        )
    }

    private func textQuery(_ sql: String) async throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        do {
            let rows = try await connection.simpleQuery(sql).get()
            return rows.map(Self.berryValues(from:))
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Settings for one statement

    /// How a server sets a variable for one statement.
    enum PerStatementForm: Equatable {
        /// MySQL 8.0.3 and later: `MAX_EXECUTION_TIME` and `SET_VAR` optimizer
        /// hints after `SELECT`
        /// (https://dev.mysql.com/doc/refman/8.4/en/optimizer-hints.html#optimizer-hints-execution-time,
        /// https://dev.mysql.com/doc/refman/8.4/en/optimizer-hints.html#optimizer-hints-set-var).
        /// Hints apply to `SELECT` only, so a `SHOW` statement runs as it is.
        case optimizerHints
        /// MariaDB 10.1.2 and later: `SET STATEMENT ... FOR`
        /// (https://mariadb.com/kb/en/set-statement/). MariaDB reads MySQL's
        /// hints as plain comments.
        case setStatement
        /// An older server, or a version that could not be read: a setting
        /// can only be made for the session.
        case none
    }

    /// Bounds every later statement by `timeout` on its own, leaving nothing
    /// on the server session, where the server offers a per-statement form.
    /// Verified against MySQL 8.4.11 (mysql:8.4), where the hint interrupts a
    /// `SELECT` with error 3024, and MariaDB 11.8.9 (mariadb:11), where
    /// `SET STATEMENT max_statement_time` interrupts it with error 1969; on
    /// both the session's own setting reads 0 afterwards.
    public func boundEachStatement(by timeout: Duration) async -> Bool {
        guard await serverForm() != .none else { return false }
        statementTimeout = timeout
        return true
    }

    private func bounded(_ sql: String) -> String {
        guard let statementTimeout, let perStatementForm else { return sql }
        return Self.statement(sql, form: perStatementForm, timeout: statementTimeout, groupConcatMaxLength: nil)
    }

    private func serverForm() async -> PerStatementForm {
        if let perStatementForm { return perStatementForm }
        let version: String? = if case .text(let text)? = try? await textQuery("SELECT VERSION()").first?.first {
            text
        } else {
            nil
        }
        let form = Self.perStatementForm(version: version)
        perStatementForm = form
        return form
    }

    /// `VERSION()` reads `8.4.11` on MySQL and `11.8.9-MariaDB-ubu2404` on
    /// MariaDB (verified against mysql:8.4 and mariadb:11).
    static func perStatementForm(version: String?) -> PerStatementForm {
        guard let version else { return .none }
        let numbers = version.prefix { $0.isNumber || $0 == "." }.split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 3 else { return .none }
        let release = (numbers[0], numbers[1], numbers[2])
        if version.contains("MariaDB") { return release >= (10, 1, 2) ? .setStatement : .none }
        return release >= (8, 0, 3) ? .optimizerHints : .none
    }

    /// `sql` with the given settings for itself alone, or as it is when it is
    /// not a statement the form applies to.
    static func statement(
        _ sql: String, form: PerStatementForm, timeout: Duration?, groupConcatMaxLength: Int?
    ) -> String {
        let trimmed = sql.drop { $0.isWhitespace }
        let keyword = trimmed.prefix { $0.isLetter }.uppercased()
        let seconds = timeout.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        switch form {
        case .optimizerHints:
            guard keyword == "SELECT" else { return sql }
            var hints: [String] = []
            if let seconds { hints.append("MAX_EXECUTION_TIME(\(Int((seconds * 1_000).rounded())))") }
            if let groupConcatMaxLength { hints.append("SET_VAR(group_concat_max_len = \(groupConcatMaxLength))") }
            guard !hints.isEmpty else { return sql }
            // MySQL 8.4.11 ignored the hints of a second comment without a
            // warning, so every hint goes in one.
            return "SELECT /*+ \(hints.joined(separator: " ")) */" + trimmed.dropFirst("SELECT".count)
        case .setStatement:
            guard keyword == "SELECT" || keyword == "SHOW" else { return sql }
            var settings: [String] = []
            if let seconds { settings.append("max_statement_time=\(String(format: "%g", seconds))") }
            if let groupConcatMaxLength { settings.append("group_concat_max_len=\(groupConcatMaxLength)") }
            guard !settings.isEmpty else { return sql }
            return "SET STATEMENT \(settings.joined(separator: ", ")) FOR " + trimmed
        case .none:
            return sql
        }
    }
}

// MARK: - Read-only statements

/// Each statement runs in a transaction of its own started with START
/// TRANSACTION READ ONLY, where the server refuses a change to a table with
/// error 1792 (https://dev.mysql.com/doc/refman/8.4/en/commit.html,
/// https://mariadb.com/kb/en/start-transaction/). A transaction per statement
/// rather than a read-only session alone, because a statement may switch the
/// session's default back to READ WRITE; the switch then reaches no later
/// statement, which sets the default again and starts its own read-only
/// transaction.
///
/// Some statements leave the read-only transaction before they write, so a
/// text runs only when it starts like a read (`ReadOnlyAllowlist.mysql`) and
/// holds no executable comment. Verified against MariaDB 11.8.9, each from
/// inside START TRANSACTION READ ONLY in a read-only session:
/// `SET STATEMENT transaction_read_only=0 FOR DROP TABLE t` drops the table
/// (https://mariadb.com/kb/en/set-statement/), and a compound statement
/// (https://mariadb.com/kb/en/begin-end/) such as `BEGIN NOT ATOMIC COMMIT;
/// SET SESSION TRANSACTION READ WRITE; INSERT …; END` writes; on MySQL 8.4.11
/// and MariaDB a CALL of a procedure that does the same writes too.
///
/// `SELECT … INTO OUTFILE` writes a file on the server from inside a
/// read-only transaction
/// (https://dev.mysql.com/doc/refman/8.4/en/select-into.html). The approval
/// classifier sends any statement with INTO to the card; what stops the file
/// is a database account without the FILE privilege.
///
/// `execute(_:)`, `ping()`, `queryAll(_:)` and the introspector do not take
/// the connection's turn, so a connection prepared with `prepareReadOnly()`
/// runs its statements through `executeReadOnly(_:timeout:)` only: a
/// statement sent another way while a read-only transaction is open runs
/// inside it, and its own COMMIT would end that transaction.
extension MySQLDriverConnection: ReadOnlyExecuting {
    /// Seconds a statement waits for a metadata lock, such as one held by an
    /// uncommitted ALTER of the user's, before it fails
    /// (https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_lock_wait_timeout).
    static let readOnlyLockWaitSeconds = 5

    /// What runs before each read-only statement, through the text protocol.
    /// A statement that causes an implicit commit, such as CREATE or DROP
    /// TABLE, ends the read-only transaction before it runs
    /// (https://dev.mysql.com/doc/refman/8.4/en/implicit-commit.html) and
    /// then runs under the session's default access mode, so the session is
    /// made read-only again before every statement, in case the statement
    /// before it switched it back; a stored function a SELECT calls can.
    /// Verified against MySQL 8.4.11 and MariaDB 11.8.9: in a read-write
    /// session DROP TABLE runs from inside START TRANSACTION READ ONLY, and
    /// in a read-only session it fails with error 1792. The allowlist keeps
    /// such statements off this connection; the session's mode is the second
    /// line.
    static let readOnlyPreamble = [
        "SET SESSION TRANSACTION READ ONLY",
        "START TRANSACTION READ ONLY",
    ]

    /// Sets the lock wait and reads it back, checks that the read-only
    /// preamble is accepted, and checks that the connection refuses two
    /// statements sent as one. MySQLNIO 1.9.1 does not ask for
    /// CLIENT_MULTI_STATEMENTS (`CapabilityFlags.clientDefault`); if a server
    /// ran a second statement anyway, that statement would not be bound by
    /// the transaction this path opens around the first. The access mode of
    /// a transaction has no variable to read back: `transaction_read_only`
    /// holds the session's default
    /// (https://dev.mysql.com/doc/refman/8.4/en/set-transaction.html).
    public func prepareReadOnly() async throws {
        guard !isClosed else { throw DriverError.notConnected }
        await turn.take()
        defer { turn.give() }
        let lockWait: [[BerryValue]]
        do {
            _ = try await textQuery("SET SESSION lock_wait_timeout = \(Self.readOnlyLockWaitSeconds)")
            lockWait = try await textQuery("SELECT @@SESSION.lock_wait_timeout")
            for control in Self.readOnlyPreamble {
                _ = try await textQuery(control)
            }
            _ = try await textQuery("ROLLBACK")
        } catch {
            _ = try? await textQuery("ROLLBACK")
            throw DriverError.readOnlyUnavailable(Self.mapError(error).detail)
        }
        guard lockWait.first?.first?.displayString == String(Self.readOnlyLockWaitSeconds) else {
            throw DriverError.readOnlyUnavailable("lock_wait_timeout did not read back as \(Self.readOnlyLockWaitSeconds)")
        }
        if (try? await textQuery("DO 1; DO 1")) != nil {
            throw DriverError.readOnlyUnavailable("the server ran two statements sent as one")
        }
    }

    public nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let readOnlyTurn = ReadOnlyTurn()
            let task = Task {
                await self.runReadOnly(sql, timeout: timeout, readOnlyTurn: readOnlyTurn, continuation: continuation)
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                if readOnlyTurn.cancel() { self.cancelCurrentQuery() }
            }
        }
    }

    /// A text the allowlist refuses ends the call before the turn. The
    /// preamble, the statement and COMMIT run in one turn. A refused
    /// preamble ends the call before the statement runs. The statement
    /// carries the server's own execution-time bound where the server has
    /// one (`statement(_:form:timeout:groupConcatMaxLength:)`).
    private func runReadOnly(
        _ statement: String, timeout: Duration, readOnlyTurn: ReadOnlyTurn,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        if let refusal = ReadOnlyAllowlist.mysql.refusal(of: statement) {
            continuation.finish(throwing: refusal)
            return
        }
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        await turn.take()
        defer { turn.give() }
        guard readOnlyTurn.begin() else {
            continuation.finish(throwing: DriverError.cancelled)
            return
        }
        defer { readOnlyTurn.end() }
        let form = await serverForm()
        do {
            for control in Self.readOnlyPreamble {
                _ = try await connection.simpleQuery(control).get()
            }
        } catch {
            _ = try? await connection.simpleQuery("ROLLBACK").get()
            let mapped = Self.mapError(error)
            if case .cancelled = mapped {
                continuation.finish(throwing: mapped)
            } else {
                continuation.finish(throwing: DriverError.readOnlyUnavailable(mapped.detail))
            }
            return
        }
        do {
            let sql = Self.statement(statement, form: form, timeout: timeout, groupConcatMaxLength: nil)
            let stats = try await stream(sql, clock: clock, started: started, into: continuation)
            _ = try? await connection.simpleQuery("COMMIT").get()
            continuation.yield(.complete(stats))
            continuation.finish()
        } catch {
            _ = try? await connection.simpleQuery("ROLLBACK").get()
            continuation.finish(throwing: Self.mapError(error))
        }
    }
}
