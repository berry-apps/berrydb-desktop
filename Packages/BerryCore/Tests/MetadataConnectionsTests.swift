import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverSQLite
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryCore

@Suite("Metadata connections")
struct MetadataConnectionsTests {
    private static let maxExecutionTime = "SET SESSION max_execution_time = 15000"
    private static let maxStatementTime = "SET SESSION max_statement_time = 15"

    /// PostgreSQL bounds each statement on its own, so it has no session
    /// alternative; MySQL keeps them for servers without a per-statement form.
    @Test func timeoutStatementAlternativesPerDriver() {
        #expect(MetadataConnections.timeoutStatementAlternatives(for: .postgres).isEmpty)
        #expect(MetadataConnections.timeoutStatementAlternatives(for: .mysql) == [Self.maxExecutionTime, Self.maxStatementTime])
        #expect(MetadataConnections.timeoutStatementAlternatives(for: .sqlite).isEmpty)
    }

    @Test func opensASecondConnectionForASQLiteSessionAndCachesIt() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-metadata-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectionManager()
        let session = try await manager.open(.sqlite(path: path))
        defer { Task { await manager.close(session.id) } }
        let pool = MetadataConnections()
        defer { Task { await pool.closeAll() } }
        let first = try await pool.connection(for: session)
        let second = try await pool.connection(for: session)
        #expect(first.id == second.id)
        #expect(first.id != session.connection.id)
        #expect(await pool.timeoutApplied(sessionID: session.id) == false)
        _ = try await first.introspector.objects(in: nil)
        await pool.close(sessionID: session.id)
        await #expect(throws: CancellationError.self) { _ = try await pool.connection(for: session) }
        #expect(await pool.cachedSessionCount == 0)
    }

    /// A pass or a statistics refresh can ask for a session's connection after
    /// the session closed; reopening it would hold a connection nothing closes
    /// until the app quits.
    @Test func aClosedSessionIsNeverConnectedAgain() async throws {
        let script = Script()
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        _ = try await pool.connection(for: session)
        await pool.close(sessionID: session.id)
        await #expect(throws: CancellationError.self) { _ = try await pool.connection(for: session) }

        let neverOpened = await Self.session(driver: .mysql, script: script)
        await pool.close(sessionID: neverOpened.id)
        await #expect(throws: CancellationError.self) { _ = try await pool.connection(for: neverOpened) }

        #expect(await script.connects == 1)
        #expect(await pool.cachedSessionCount == 0)
    }

    /// The metadata connection's reads of a pass or a refresh run in one
    /// transaction opened for them, which carries the bound, rather than
    /// under a session setting. VACUUM refuses to run inside a transaction
    /// block (https://www.postgresql.org/docs/current/sql-vacuum.html), so it
    /// shows whether a statement ran in one.
    @Test(.enabled(if: TestServer.postgres != nil))
    func postgresMetadataStatementsAreBoundedInATransactionOfTheirOwn() async throws {
        DriverRegistry.register(PostgresDriver.self)
        let server = TestServer.postgres!
        let manager = ConnectionManager()
        let session = try await manager.open(
            ConnectionConfig(
                driver: .postgres, name: "t", host: server.host, port: server.port,
                username: server.username, password: server.password, database: server.database
            ))
        defer { Task { await manager.close(session.id) } }
        let pool = MetadataConnections()
        defer { Task { await pool.closeAll() } }
        let connection = try await pool.connection(for: session)
        let scoping = try #require(connection as? any CatalogReadScoping)
        for try await _ in connection.execute("CREATE TEMP TABLE metadata_probe (id int)") {}
        var row: [BerryValue] = []
        try await scoping.withCatalogReads {
            for try await event in connection.execute("SELECT current_setting('statement_timeout')") {
                if case let .rows(rows) = event, let first = rows.first { row = first }
            }
            await #expect(throws: DriverError.self) { for try await _ in connection.execute("VACUUM metadata_probe") {} }
        }
        #expect(row == [.text("15s")])
        #expect(await pool.timeoutApplied(sessionID: session.id))
    }

    /// The bound is each statement's own on MySQL 8.0.3 or later and on
    /// MariaDB 10.1.2 or later, so the server session's setting stays unset.
    /// MariaDB's SET STATEMENT sets the variable while its statement runs, so
    /// the probe starts with WITH, which the bound leaves as it is.
    @Test(.enabled(if: TestServer.mysql != nil))
    func mysqlMetadataStatementsLeaveTheSessionUnbounded() async throws {
        DriverRegistry.register(MySQLDriver.self)
        let server = TestServer.mysql!
        let manager = ConnectionManager()
        let session = try await manager.open(
            ConnectionConfig(
                driver: .mysql, name: "t", host: server.host, port: server.port,
                username: server.username, password: server.password, database: server.database
            ))
        defer { Task { await manager.close(session.id) } }
        let pool = MetadataConnections()
        defer { Task { await pool.closeAll() } }
        let connection = try await pool.connection(for: session)
        func first(_ sql: String) async throws -> BerryValue? {
            var value: BerryValue?
            for try await event in connection.execute(sql) {
                if case let .rows(rows) = event { value = rows.first?.first }
            }
            return value
        }
        guard case let .text(version)? = try await first("SELECT VERSION()") else {
            Issue.record("no version")
            return
        }
        let variable = version.contains("MariaDB") ? "max_statement_time" : "max_execution_time"

        let bound = try await first("WITH probe AS (SELECT 1) SELECT @@SESSION.\(variable) FROM probe")

        #expect(bound?.displayString.flatMap(Double.init) == 0)
        #expect(await pool.timeoutApplied(sessionID: session.id))
    }

    // MARK: - Scripted driver

    @Test func closingWhileConnectingClosesTheConnectionOnceItExists() async throws {
        let gate = Gate()
        let script = Script(gate: gate)
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let opening = Task { try await pool.connection(for: session) }
        await gate.waitUntilReached()
        let closing = Task { await pool.close(sessionID: session.id) }
        await Self.waitUntil { await pool.cachedSessionCount == 0 }
        await gate.open()
        await closing.value

        #expect(await script.closes == 1)
        #expect(await pool.cachedSessionCount == 0)
        await #expect(throws: CancellationError.self) { _ = try await opening.value }
    }

    @Test func concurrentFirstCallsShareOneConnect() async throws {
        let gate = Gate()
        let script = Script(gate: gate)
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let first = Task { try await pool.connection(for: session) }
        await gate.waitUntilReached()
        let second = Task { try await pool.connection(for: session) }
        // A second connect, if the pool started one, would be blocked at the
        // gate as well; there is nothing to observe but the passage of time.
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()

        #expect(try await first.value.id == second.value.id)
        #expect(await script.connects == 1)
    }

    @Test func aFailedConnectIsNotCachedSoTheNextCallRetries() async throws {
        let script = Script(failingConnects: 1)
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        await #expect(throws: ScriptedError.self) { _ = try await pool.connection(for: session) }
        #expect(await pool.cachedSessionCount == 0)
        _ = try await pool.connection(for: session)
        #expect(await script.connects == 2)
        #expect(await pool.cachedSessionCount == 1)
    }

    /// A server, a pooler or a tunnel closes an idle connection on its own
    /// schedule; the harvest then discards the cached one, which must be
    /// closed and replaced by a fresh connect on the next call, while the
    /// session stays open.
    @Test func aDiscardedConnectionIsClosedAndTheNextCallOpensAnother() async throws {
        let script = Script()
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let dead = try await pool.connection(for: session)
        await pool.discard(sessionID: session.id)
        #expect(await script.closes == 1)
        #expect(await pool.cachedSessionCount == 0)

        let fresh = try await pool.connection(for: session)
        #expect(fresh.id != dead.id)
        #expect(await script.connects == 2)

        // A discard after the session closed opens nothing again.
        await pool.close(sessionID: session.id)
        await pool.discard(sessionID: session.id)
        await #expect(throws: CancellationError.self) { _ = try await pool.connection(for: session) }
        #expect(await script.connects == 2)
    }

    @Test func mysqlFallsBackToMariaDBsTimeoutWhenTheFirstStatementIsRejected() async throws {
        let script = Script(rejecting: [Self.maxExecutionTime])
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let connection = try await pool.connection(for: session)

        #expect(await script.executed == [Self.maxExecutionTime, Self.maxStatementTime])
        #expect(await pool.timeoutApplied(sessionID: session.id))
        for try await _ in connection.execute("SELECT 1") {}
        #expect(await script.executed.last == "SELECT 1")
        #expect(await script.closes == 0)
    }

    @Test func mysqlKeepsTheConnectionWithoutATimeoutWhenEveryStatementIsRejected() async throws {
        let script = Script(rejecting: [Self.maxExecutionTime, Self.maxStatementTime])
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let connection = try await pool.connection(for: session)

        #expect(await script.executed == [Self.maxExecutionTime, Self.maxStatementTime])
        #expect(await pool.timeoutApplied(sessionID: session.id) == false)
        for try await _ in connection.execute("SELECT 1") {}
        #expect(await script.executed.last == "SELECT 1")
        #expect(await script.closes == 0)
    }

    @Test func mysqlStopsAtTheFirstAcceptedStatement() async throws {
        let script = Script()
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        _ = try await pool.connection(for: session)

        #expect(await script.executed == [Self.maxExecutionTime])
        #expect(await pool.timeoutApplied(sessionID: session.id))
    }

    /// A connection that bounds each statement on its own gets no session
    /// statement.
    @Test func aConnectionThatBoundsEachStatementGetsNoSessionStatement() async throws {
        let script = Script(bounds: true)
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        _ = try await pool.connection(for: session)

        #expect(await script.bounds == [MetadataConnections.statementTimeout])
        #expect(await script.executed.isEmpty)
        #expect(await pool.timeoutApplied(sessionID: session.id))
    }

    /// One whose server offers no per-statement form falls back to the
    /// session statements.
    @Test func aConnectionThatCannotBoundEachStatementGetsTheSessionStatement() async throws {
        let script = Script(bounds: false)
        let session = await Self.session(driver: .mysql, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        _ = try await pool.connection(for: session)

        #expect(await script.bounds == [MetadataConnections.statementTimeout])
        #expect(await script.executed == [Self.maxExecutionTime])
        #expect(await pool.timeoutApplied(sessionID: session.id))
    }

    /// PostgreSQL has no session fallback: a connection that cannot bound its
    /// statements runs without a bound.
    @Test func postgresWithoutPerStatementBoundsRunsUnbounded() async throws {
        let script = Script(bounds: false)
        let session = await Self.session(driver: .postgres, script: script)
        let pool = Self.pool()
        defer { Task { await pool.closeAll() } }

        let connection = try await pool.connection(for: session)

        #expect(await script.executed.isEmpty)
        #expect(await pool.timeoutApplied(sessionID: session.id) == false)
        for try await _ in connection.execute("SELECT 1") {}
        #expect(await script.closes == 0)
    }

    // MARK: - Fixtures

    /// A pool whose driver lookup is the scripted driver, so these tests never
    /// write to the process-wide `DriverRegistry` that other suites read.
    private static func pool() -> MetadataConnections {
        MetadataConnections(driverType: { _ in ScriptedDriver.self })
    }

    private static func session(driver: DriverID, script: Script) async -> Session {
        let name = UUID().uuidString
        await ScriptRegistry.shared.register(script, for: name)
        return Session(
            id: UUID(), profileID: nil, isProduction: false,
            config: ConnectionConfig(driver: driver, name: name),
            connection: ScriptedConnection(script: Script()),
            capabilities: Capabilities(), dialect: SQLiteDialect(),
            driverDisplayName: "Scripted", tunnel: nil, recordHistory: false
        )
    }

    private static func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within 5 seconds")
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum ScriptedError: Error {
    case rejected
    case connectFailed
}

/// Lets a test hold `connect` open and observe that it is in flight.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reachedWaiter: CheckedContinuation<Void, Never>?
    private var isReached = false
    private var isOpen = false

    func pass() async {
        isReached = true
        reachedWaiter?.resume()
        reachedWaiter = nil
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilReached() async {
        if isReached { return }
        await withCheckedContinuation { reachedWaiter = $0 }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// What one test tells the scripted driver to do, and what the driver did.
private actor Script {
    private let rejected: Set<String>
    private var failingConnects: Int
    private let gate: Gate?
    /// What the connection answers when asked to bound each statement.
    let boundsAnswer: Bool
    private(set) var executed: [String] = []
    private(set) var bounds: [Duration] = []
    private(set) var connects = 0
    private(set) var closes = 0

    init(rejecting rejected: Set<String> = [], failingConnects: Int = 0, gate: Gate? = nil, bounds: Bool = false) {
        self.rejected = rejected
        self.failingConnects = failingConnects
        self.gate = gate
        self.boundsAnswer = bounds
    }

    func bound(by timeout: Duration) -> Bool {
        bounds.append(timeout)
        return boundsAnswer
    }

    func connect() async throws {
        connects += 1
        if let gate { await gate.pass() }
        if failingConnects > 0 {
            failingConnects -= 1
            throw ScriptedError.connectFailed
        }
    }

    func run(_ sql: String) throws {
        executed.append(sql)
        if rejected.contains(sql) { throw ScriptedError.rejected }
    }

    func closed() { closes += 1 }
}

/// The driver is built with no arguments, so it finds its script by the
/// configuration's name.
private actor ScriptRegistry {
    static let shared = ScriptRegistry()
    private var scripts: [String: Script] = [:]

    func register(_ script: Script, for name: String) { scripts[name] = script }
    func script(for name: String) -> Script? { scripts[name] }
}

private struct ScriptedDriver: DatabaseDriver {
    static let id = DriverID.mysql
    static let displayName = "Scripted"
    static let capabilities = Capabilities()
    static let dialect: any SQLDialect = SQLiteDialect()
    init() {}

    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let script = await ScriptRegistry.shared.script(for: config.name) else {
            throw DriverError.connectionFailed("No script registered for this configuration")
        }
        try await script.connect()
        return ScriptedConnection(script: script)
    }
}

private actor ScriptedConnection: StatementBoundingConnection {
    nonisolated let id = UUID()
    private let script: Script

    init(script: Script) { self.script = script }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        let script = script
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await script.run(sql)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async { await script.closed() }
    func boundEachStatement(by timeout: Duration) async -> Bool { await script.bound(by: timeout) }
}
