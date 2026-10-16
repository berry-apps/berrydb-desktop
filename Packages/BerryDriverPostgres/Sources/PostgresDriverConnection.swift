import BerryDriverKit
import Foundation
import Logging
import NIOSSL
import PostgresNIO

/// What a cancel needs from outside the actor: Postgres cancels a statement
/// with `pg_cancel_backend(pid)` sent on a second connection, so the box
/// keeps the backend to send it to and the statements that may be stopped
/// there.
final class PostgresCancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _backendPID: Int32?
    private var _transactionPID: Int32?
    private var running: [UUID: String] = [:]
    let config: ConnectionConfig

    init(config: ConnectionConfig) { self.config = config }

    /// The backend read once after connect.
    var backendPID: Int32? {
        get { lock.withLock { _backendPID } }
        set { lock.withLock { _backendPID = newValue } }
    }

    /// The backend read inside the read-only transaction open now; nil
    /// outside one. A pooler in transaction mode keeps a transaction on one
    /// backend until it ends (https://www.pgbouncer.org/features.html), so
    /// while it is set it is the backend the running statement is on.
    var transactionPID: Int32? {
        get { lock.withLock { _transactionPID } }
        set { lock.withLock { _transactionPID = newValue } }
    }

    /// Records `sql` as running until `ended(_:)` is called with the result.
    func started(_ sql: String) -> UUID {
        lock.withLock {
            let id = UUID()
            running[id] = sql
            return id
        }
    }

    func ended(_ id: UUID) {
        lock.withLock { running[id] = nil }
    }

    /// The backend a cancel sent now goes to and the statements it may stop
    /// there; nil when nothing runs or no backend is known.
    var cancelTarget: (pid: Int32, statements: [String])? {
        lock.withLock {
            guard !running.isEmpty, let pid = _transactionPID ?? _backendPID else { return nil }
            return (pid, Array(running.values))
        }
    }
}

/// A parameter sent as text with no type (OID 0), which the server reads as
/// the type its place in the statement gives it
/// (`PostgresDriverConnection.bindings(for:)`).
struct UntypedText: PostgresDynamicTypeEncodable {
    let value: String

    var psqlType: PostgresDataType { .null }
    var psqlFormat: PostgresFormat { .text }

    func encode<JSONEncoder: PostgresJSONEncoder>(
        into byteBuffer: inout ByteBuffer, context: PostgresEncodingContext<JSONEncoder>
    ) {
        byteBuffer.writeString(value)
    }
}

public actor PostgresDriverConnection: StatementBoundingConnection, CatalogReadScoping {
    public nonisolated let id = UUID()

    private var connection: PostgresConnection
    private var config: ConnectionConfig
    private nonisolated let cancelBox: PostgresCancelBox
    private var isClosed = false
    /// Set by `boundEachStatement(by:)`.
    private var statementTimeout: Duration?
    /// The catalog read scope whose transaction is open.
    private var openScope: CatalogReadScope?
    /// On a bounded connection a scope, or a statement made outside every
    /// scope, holds the connection's turn until it ends: a statement sent
    /// while another scope's transaction is open would run inside it, and a
    /// scope opened inside another would be ended by its COMMIT.
    private let turn = ConnectionTurn()
    /// Awaited between a read-only statement's preamble and the statement.
    /// That window is a few round trips wide and nothing on the server can
    /// hold it open, so this is how a test lands a cancel in it.
    private var afterReadOnlyPreamble: (@Sendable () async -> Void)?

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

    private static func makeRawConnection(_ config: ConnectionConfig) async throws -> PostgresConnection {
        guard let host = config.host else {
            throw DriverError.connectionFailed("Missing host")
        }
 // TLS; default is `prefer`.
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
 // verifyCA additionally skips the hostname check.
            var tls = Self.verifyingTLS(mode: config.tlsMode, caCertPath: config.caCertPath)
            try Self.applyClientIdentity(&tls, config: config)
            tlsMode = .require(try NIOSSLContext(configuration: tls))
        }

        var pgConfig = PostgresConnection.Configuration(
            host: host,
            port: config.port ?? 5432,
            username: config.username ?? "postgres",
            password: config.password,
            database: config.database,
            tls: tlsMode
        )
        pgConfig.options.additionalStartupParameters = Self.startupParameters(for: config)
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

 /// Test hook: exposes whether the cancel precondition holds.
    public nonisolated var debugBackendPID: Int32? { cancelBox.backendPID }

    /// Test hook: makes the backend read at connect another session's, as a
    /// pooler in transaction mode does once it hands that backend on.
    nonisolated func pointCancelForTesting(at pid: Int32) {
        cancelBox.backendPID = pid
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

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await inTurn { try await streamRows(sql, into: continuation) }
            continuation.yield(.complete(QueryStats(
 rowsAffected: nil, // PostgresNIO does not expose the command tag yet — note
                duration: clock.now - started
            )))
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    /// Streams the rows of `sql` into `continuation` in batches, leaving the
    /// stream open for the caller to complete.
    private func streamRows(
        _ sql: String, parameters: [SQLParameter] = [],
        into continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async throws {
        let running = cancelBox.started(sql)
        defer { cancelBox.ended(running) }
        let rows = try await connection.query(
            PostgresQuery(unsafeSQL: sql, binds: Self.bindings(for: parameters)), logger: Self.logger
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
    }

    /// Every value is sent as text with no type (OID 0), and the server
    /// gives each parameter the type its place in the statement asks for, as
    /// for a client that sends no parameter types
    /// (https://www.postgresql.org/docs/current/protocol-message-formats.html#PROTOCOL-MESSAGE-FORMATS-PARSE).
    /// A NULL already goes without a type (`appendNull()`, PostgresNIO
    /// 1.33.0). Verified against PostgreSQL 16.15, where the server accepts
    /// `inf` and `nan`, as Swift writes a Double, for float8 and numeric:
    /// - A parameter the statement never uses is left without a type, which
    ///   fails the statement with "could not determine data type of
    ///   parameter". Sent with its type, it was accepted and ignored, so a
    ///   statement given too many parameters ran.
    /// - A number compares with a varchar column, which has no operator for
    ///   bigint, and a double with a numeric column exactly, where float8
    ///   compared each numeric rounded to a double.
    /// - A double that is a whole number goes as an integer where that is
    ///   the same number (`text(of:)`): an integer column refuses `3.0`, as
    ///   Swift writes the double, with "invalid input syntax for type
    ///   integer", and float8 and numeric read `3` as well.
    /// - The cost: a parameter with nothing around it to give it a type is
    ///   read as text (`SELECT $1` returns the text `1`), and where text
    ///   does not fit, as in `$1 + $2`, the statement fails until a cast
    ///   gives the parameter a type (`$1::int8 + $2`).
    /// The text a double is sent as. A whole number that is the same number
    /// as Swift's shortest form of the double goes as an integer, which an
    /// integer column reads and which float8 and numeric read as the same
    /// value. Any other double keeps Swift's shortest form: a whole number
    /// past 2^53 whose exact value differs from that form (2^60 + 1 as a
    /// double prints as `1.152921504606847e+18`, exactly
    /// 1152921504606846976) then reaches numeric as the decimal it reads
    /// today, and negative zero keeps its sign, which float8 keeps (verified
    /// against PostgreSQL 16.15: `'-0.0'::float8` is `-0`, `'0'::float8` is
    /// `0`).
    static func text(of value: Double) -> String {
        let shortest = String(value)
        guard !(value == 0 && value.sign == .minus), let integer = Int64(exactly: value),
              Decimal(string: shortest) == Decimal(integer)
        else { return shortest }
        return String(integer)
    }

    static func bindings(for parameters: [SQLParameter]) -> PostgresBindings {
        var bindings = PostgresBindings(capacity: parameters.count)
        for parameter in parameters {
            switch parameter {
            case .null: bindings.appendNull()
            case .bool(let value): bindings.append(UntypedText(value: value ? "true" : "false"))
            case .int(let value): bindings.append(UntypedText(value: String(value)))
            case .double(let value): bindings.append(UntypedText(value: text(of: value)))
            case .text(let value): bindings.append(UntypedText(value: value))
            }
        }
        return bindings
    }

 // MARK: - Value mapping (no information loss)

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

    /// Cancels through a second connection, and only a backend that is
    /// running one of this connection's statements
    /// (`cancelStatement(pid:statements:)`).
    public nonisolated func cancelCurrentQuery() {
        guard let target = cancelBox.cancelTarget else { return }
        let config = cancelBox.config
        Task {
            guard let companion = try? await Self.makeRawConnection(config) else { return }
            _ = try? await companion.query(
                Self.cancelStatement(pid: target.pid, statements: target.statements),
                logger: Self.logger
            )
            try? await companion.close()
        }
    }

    /// `pg_cancel_backend(pid)` for a backend whose running statement is one
    /// of `statements`. Behind a pooler in transaction mode, a statement
    /// outside a transaction can run on any server backend, and the one this
    /// connection read at connect may be running another client's statement
    /// by the time a cancel is sent (https://www.pgbouncer.org/features.html);
    /// an unguarded cancel stops that client's statement (observed against
    /// PostgreSQL 16.15 with the cancel pointed at another session's
    /// backend). `pg_stat_activity.query` holds the text of the backend's
    /// running statement, cut at `track_activity_query_size` bytes
    /// (https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW),
    /// so a statement matches when its text starts with that column. A
    /// backend with `track_activities` off reports its state as `disabled`
    /// and no statement, so it is cancelled by its process ID alone, as
    /// before; otherwise Stop would never stop a statement there.
    static func cancelStatement(pid: Int32, statements: [String]) -> PostgresQuery {
        var binds = PostgresBindings(capacity: 2)
        binds.append(pid)
        binds.append(statements)
        return PostgresQuery(
            unsafeSQL: """
                SELECT pg_cancel_backend(pid) FROM pg_stat_activity
                WHERE pid = $1 AND (state = 'disabled' OR (
                  state = 'active' AND length(query) > 0
                  AND EXISTS (SELECT 1 FROM unnest($2::text[]) AS running(statement)
                              WHERE left(running.statement, length(query)) = query)))
                """,
            binds: binds
        )
    }

 /// Postgres cannot switch databases on the same connection → reconnect.
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
            return try await inTurn {
                let running = cancelBox.started(sql)
                defer { cancelBox.ended(running) }
                let rows = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger)
                var result: [[BerryValue]] = []
                for try await row in rows {
                    result.append(Array(row).map(Self.berryValue(from:)))
                }
                return result
            }
        } catch {
            throw Self.mapError(error)
        }
    }

    // MARK: - Catalog read scopes

    /// Bounds the statements of every later catalog read scope: a scope runs
    /// as one read-only transaction that sets `statement_timeout` with SET
    /// LOCAL, which bounds each statement in it
    /// (https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-STATEMENT-TIMEOUT)
    /// and ends with the transaction
    /// (https://www.postgresql.org/docs/current/sql-set.html), so nothing
    /// stays on a server session that a pooler in transaction mode hands to
    /// another client. Verified against PostgreSQL 16.15
    /// (postgres:16-alpine): a statement is cancelled at the timeout and the
    /// session's `statement_timeout` reads 0 after the scope. A scope costs
    /// three round trips besides its statements, BEGIN, SET LOCAL and COMMIT:
    /// PostgresNIO sends every statement with the extended query protocol,
    /// which carries one statement per message
    /// (https://www.postgresql.org/docs/current/protocol-flow.html#PROTOCOL-FLOW-EXT-QUERY).
    /// A pass and a statistics refresh, the metadata connection's only
    /// readers, each read in one scope; a statement outside every scope runs
    /// unbounded, in its turn.
    ///
    /// A pass keeps its transaction open while it writes the store between
    /// two reads. A server whose `idle_in_transaction_session_timeout` is
    /// shorter than such a gap ends the session
    /// (https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-IDLE-IN-TRANSACTION-SESSION-TIMEOUT),
    /// as a pooler's limit on idle transactions can; the pass then fails as a
    /// connection failure, its connection is dropped, and the next pass
    /// resumes from the rows already written.
    public func boundEachStatement(by timeout: Duration) async -> Bool {
        statementTimeout = timeout
        return true
    }

    /// Opens a scope on a bounded connection once the connection's turn is
    /// free, and nil on any other. A server that refuses BEGIN or SET LOCAL
    /// also gets nil, after a rollback, and the reads run unscoped and
    /// unbounded: PgBouncer in statement pooling mode refuses a transaction of
    /// more than one statement (https://www.pgbouncer.org/features.html), and
    /// the bound is a safeguard, not a requirement.
    public func beginCatalogReads() async throws -> CatalogReadScope? {
        guard let timeout = statementTimeout, !isClosed else { return nil }
        await turn.take()
        let milliseconds = timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000
        do {
            try await command("BEGIN READ ONLY")
            try await command("SET LOCAL statement_timeout = '\(milliseconds)ms'")
        } catch {
            await finishTransaction(commit: false)
            turn.give()
            return nil
        }
        let scope = CatalogReadScope()
        openScope = scope
        return scope
    }

    /// Ends the scope's transaction and gives the turn back. A read-only
    /// transaction has nothing to lose, so a failed COMMIT is not reported;
    /// a failed statement left the transaction aborted, and its ROLLBACK
    /// ends it.
    public func endCatalogReads(_ scope: CatalogReadScope, commit: Bool) async {
        guard openScope == scope else { return }
        openScope = nil
        await finishTransaction(commit: commit)
        turn.give()
    }

    /// Also sent when the scope's task was cancelled: PostgresNIO 1.33.0
    /// still sends a statement from a cancelled task, and the session was
    /// observed idle, outside any transaction, after a cancelled scope ended.
    private func finishTransaction(commit: Bool) async {
        try? await command(commit ? "COMMIT" : "ROLLBACK")
    }

    /// `body` at once on an unbounded connection or for a read of the open
    /// scope, and otherwise once the connection's turn is free.
    private func inTurn<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard statementTimeout != nil else { return try await body() }
        if let openScope, CatalogReadScope.current == openScope { return try await body() }
        await turn.take()
        defer { turn.give() }
        return try await body()
    }

    private func command(_ sql: String) async throws {
        for try await _ in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger) {}
    }
}

// MARK: - Read-only statements

extension PostgresDriverConnection: ReadOnlyExecuting {
    /// Opens one read-only transaction and reads the mode back, so a proxy
    /// that accepts BEGIN READ ONLY without honouring it fails here instead
    /// of on a write. PgBouncer in statement pooling mode refuses the BEGIN
    /// (https://www.pgbouncer.org/features.html).
    public func prepareReadOnly() async throws {
        guard !isClosed else { throw DriverError.notConnected }
        await turn.take()
        defer { turn.give() }
        let mode: String?
        do {
            try await command("BEGIN READ ONLY")
            mode = try await firstText("SHOW transaction_read_only")
        } catch {
            await finishTransaction(commit: false)
            throw DriverError.readOnlyUnavailable(Self.mapError(error).detail)
        }
        await finishTransaction(commit: false)
        guard mode == "on" else {
            throw DriverError.readOnlyUnavailable("transaction_read_only reads \(mode ?? "nothing") inside BEGIN READ ONLY")
        }
    }

    public nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    public nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let readOnlyTurn = ReadOnlyTurn()
            let task = Task {
                await self.runReadOnly(sql, parameters: parameters, timeout: timeout, readOnlyTurn: readOnlyTurn, continuation: continuation)
            }
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                task.cancel()
                if readOnlyTurn.cancel() { self.cancelCurrentQuery() }
            }
        }
    }

    /// What runs before each read-only statement: BEGIN READ ONLY, then one
    /// SELECT that sets the bounds for the transaction alone and reads the
    /// backend it runs on. `set_config` with `is_local` true is SET LOCAL
    /// (https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SET),
    /// which ends with the transaction, so nothing stays on a server session
    /// a pooler hands on (https://www.postgresql.org/docs/current/sql-set.html).
    /// `statement_timeout` bounds the statement on the server as well as on
    /// the client, and a value of 0 would turn the bound off
    /// (https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-STATEMENT-TIMEOUT),
    /// so it never drops below 1 ms. `lock_timeout` keeps a read from
    /// queueing behind the user's uncommitted DDL, and other sessions behind
    /// the read (https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-LOCK-TIMEOUT).
    /// The backend is read inside the transaction because a pooler in
    /// transaction mode keeps it for this connection until the transaction
    /// ends, so a cancel sent while the statement runs reaches the statement.
    static func readOnlyPreamble(timeout: Duration) -> [String] {
        let milliseconds = max(1, timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return [
            "BEGIN READ ONLY",
            "SELECT set_config('statement_timeout', '\(milliseconds)ms', true), set_config('lock_timeout', '5s', true), pg_backend_pid()",
        ]
    }

    /// `application_name` lists the connection in `pg_stat_activity`;
    /// PgBouncer tracks it for each client itself
    /// (https://www.pgbouncer.org/config.html#track_extra_parameters), so a
    /// pooler neither refuses nor drops it.
    static func startupParameters(for config: ConnectionConfig) -> [(String, String)] {
        guard let name = config.applicationName else { return [] }
        return [("application_name", name)]
    }

    /// A text the allowlist refuses (`ReadOnlyAllowlist.postgres`), such as
    /// a DO block or a CALL, ends the call before the turn. BEGIN, the
    /// bounds, the statement and COMMIT run in one turn, so no other
    /// statement on this connection lands inside the transaction. A refused
    /// BEGIN or SET LOCAL, or a cancel during them, ends the call before the
    /// statement runs.
    private func runReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration, readOnlyTurn: ReadOnlyTurn,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        if let refusal = ReadOnlyAllowlist.postgres.refusal(of: sql) {
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
        defer { cancelBox.transactionPID = nil }
        do {
            let preamble = Self.readOnlyPreamble(timeout: timeout)
            try await command(preamble[0])
            cancelBox.transactionPID = try await lastInt32(preamble[1])
        } catch {
            await finishTransaction(commit: false)
            let mapped = Self.mapError(error)
            if case .cancelled = mapped {
                continuation.finish(throwing: mapped)
            } else {
                continuation.finish(throwing: DriverError.readOnlyUnavailable(Self.mapError(error).detail))
            }
            return
        }
        await afterReadOnlyPreamble?()
        // A cancel sent while the preamble ran can land between two of its
        // commands, on a backend with nothing running, and is lost there;
        // the statement then ran to its end (verified against PostgreSQL
        // 16.15). The stream's cancellation is all that is left of it.
        guard !Task.isCancelled else {
            await finishTransaction(commit: false)
            continuation.finish(throwing: DriverError.cancelled)
            return
        }
        do {
            try await streamRows(sql, parameters: parameters, into: continuation)
            await finishTransaction(commit: true)
            continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: clock.now - started)))
            continuation.finish()
        } catch {
            await finishTransaction(commit: false)
            continuation.finish(throwing: Self.mapError(error))
        }
    }

    func holdAfterReadOnlyPreamble(_ hold: @escaping @Sendable () async -> Void) {
        afterReadOnlyPreamble = hold
    }

    /// The last column of the first row of `sql`, read as a 32-bit integer.
    private func lastInt32(_ sql: String) async throws -> Int32? {
        var value: Int32?
        for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger) {
            if value == nil, let cell = Array(row).last {
                value = try cell.decode(Int32.self)
            }
        }
        return value
    }

    private func firstText(_ sql: String) async throws -> String? {
        var first: String?
        for try await row in try await connection.query(PostgresQuery(unsafeSQL: sql), logger: Self.logger) {
            if first == nil, case .text(let text)? = Array(row).first.map(Self.berryValue(from:)) {
                first = text
            }
        }
        return first
    }
}
