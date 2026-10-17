import BerryDriverKit
@testable import BerryMCP
import BerryStore
import Foundation
import Synchronization
import Testing

@Suite("MCP live read service")
struct MCPLiveReadServiceTests {
    @Test func aReadReturnsColumnsAndRowsAsArrays() async throws {
        let connection = ScriptedReadConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER"), ColumnMeta(name: "createdAt", declaredType: "TEXT")]),
            .rows([[.int(1), .text("2026-10-16T09:30:00Z")], [.int(2), .null]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let result = try await Harness(connection: connection).read("SELECT id, createdAt FROM events")
        #expect(result.columns == ["id", "createdAt"])
        #expect(result.rows == [["1", "2026-10-16T09:30:00Z"], ["2", nil]])
        #expect(result.rowCount == 2)
        #expect(result.truncated == false)
        #expect(result.hasMoreRows == false)
        #expect(result.byteLimitReached == false)
        #expect(result.truncatedCells == 0)
        #expect(result.redactedColumns == [])
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == [
            "byteLimitReached", "columns", "elapsedMs", "hasMoreRows", "redactedColumns",
            "rowCount", "rows", "truncated", "truncatedCells",
        ])
    }

    @Test func theStatementRunsTrimmedWithItsParametersAndTheProfileLimit() async throws {
        let connection = ScriptedReadConnection(events: [
            .columns([ColumnMeta(name: "1", declaredType: "")]),
            .rows([[.int(1)]]),
        ])
        _ = try await Harness(connection: connection).read(" SELECT 1; ", parameters: [.int(1)])
        #expect(connection.log.snapshot().statements == [
            ScriptedStatement(sql: "SELECT 1", parameters: [.int(1)], timeout: .seconds(30)),
        ])
    }

    @Test func aWriteIsRefusedBeforeAnyConnectionOpens() async throws {
        var reason = ""
        do {
            _ = try MCPReadPolicy().validate("DELETE FROM t", dialect: .sqlite)
        } catch {
            reason = String(describing: error)
        }
        #expect(!reason.isEmpty)
        let connection = ScriptedReadConnection(events: [])
        let harness = Harness(connection: connection)
        let error = await harness.failure("DELETE FROM t")
        #expect(error == .policy(reason))
        #expect(error?.description == "The query was refused before it ran: \(reason)")
        #expect(await harness.tracker.factoryCalls == 0)
        #expect(connection.log.snapshot().statements.isEmpty)
    }

    @Test func readingStopsAfterTheRowLimit() async throws {
        let batches = (0..<10).map { batch in
            ResultEvent.rows((0..<1_000).map { [BerryValue.int(Int64(batch * 1_000 + $0))] })
        }
        let connection = ScriptedReadConnection(
            events: [.columns([ColumnMeta(name: "n", declaredType: "INTEGER")])] + batches
                + [.complete(QueryStats(rowsAffected: nil, duration: .zero))]
        )
        let result = try await Harness(connection: connection).read("SELECT n FROM numbers")
        #expect(result.rows.count == 100)
        #expect(result.rows.first == ["0"])
        #expect(result.rows.last == ["99"])
        #expect(result.hasMoreRows)
        #expect(result.truncated)
        let log = connection.log.snapshot()
        #expect(log.rowsHandedOut <= 2_000)
        #expect(log.cancellations == 1)
    }

    @Test func rowLimitIsCappedByTheProfileLimit() async throws {
        let events: [ResultEvent] = [
            .columns([ColumnMeta(name: "n", declaredType: "INTEGER")]),
            .rows((0..<200).map { [BerryValue.int(Int64($0))] }),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ]
        for (isProduction, rowLimit, expected) in [(false, 500, 100), (true, 500, 50), (false, 10, 10)] {
            let harness = Harness(connection: ScriptedReadConnection(events: events), isProduction: isProduction)
            let result = try await harness.read("SELECT n FROM numbers", rowLimit: rowLimit)
            #expect(result.rows.count == expected)
            #expect(result.rowCount == expected)
            #expect(result.hasMoreRows)
        }
    }

    @Test func duplicateColumnsKeepTheirValuesAndAreAllRedacted() async throws {
        let events: [ResultEvent] = [
            .columns(["email", "email", "id"].map { ColumnMeta(name: $0, declaredType: "TEXT") }),
            .rows([[.text("a@example.com"), .text("b@example.com"), .int(1)], [.null, .null, .int(2)]]),
        ]
        let sql = "SELECT email, email, id FROM users"
        let plain = try await Harness(connection: ScriptedReadConnection(events: events)).read(sql)
        #expect(plain.columns == ["email", "email", "id"])
        #expect(plain.rows == [["a@example.com", "b@example.com", "1"], [nil, nil, "2"]])
        #expect(plain.redactedColumns == [])

        let redacting = Harness(connection: ScriptedReadConnection(events: events), redactedColumns: ["email"])
        let redacted = try await redacting.read(sql)
        #expect(redacted.columns == ["email", "email", "id"])
        #expect(redacted.rows == [["[REDACTED]", "[REDACTED]", "1"], ["[REDACTED]", "[REDACTED]", "2"]])
        #expect(redacted.redactedColumns == ["email"])
    }

    @Test func aProductionProfileGetsTheProductionLimits() async throws {
        let wide = String(repeating: "x", count: 10_000)
        let connection = ScriptedReadConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER"), ColumnMeta(name: "body", declaredType: "TEXT")]),
            .rows((0..<60).map { [BerryValue.int(Int64($0)), .text(wide)] }),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let result = try await Harness(connection: connection, isProduction: true).read("SELECT id, body FROM notes")
        #expect(connection.log.snapshot().statements.map(\.timeout) == [.seconds(5)])
        #expect(result.rows.count > 0)
        #expect(result.rows.count <= 50)
        #expect(result.byteLimitReached)
        #expect(result.truncated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(try encoder.encode(result).count <= 262_144)
    }

    @Test func aConnectionThatNeverOpensTimesOut() async throws {
        let gate = AsyncGate()
        let harness = Harness(openBudget: .milliseconds(200), open: { await gate.wait() })
        let clock = ContinuousClock()
        let started = clock.now
        let error = await harness.failure("SELECT 1")
        let waited = clock.now - started
        // The statement never ran, so the text names the connection, not the
        // query: an agent must not shorten its SQL to fix a network problem.
        #expect(error == .openTimedOut(seconds: 1))
        #expect(error?.description == "BerryDB could not open a connection to this database within 1 seconds.")
        // Without the open budget the 30 s request limit would apply. A fully
        // loaded parallel run of the whole suite has delayed this 200 ms
        // deadline by 8 s, so the bound only separates the two; the reported
        // seconds above show which limit fired.
        #expect(waited < .seconds(25))
        // The abandoned request still closes what it opens once the open returns.
        await gate.open()
        let tracker = harness.tracker
        try await withDeadline(.seconds(60)) { await tracker.waitForCloses(1) }
    }

    @Test func aDriverErrorIsOneSanitizedLine() async throws {
        let failing = ScriptedReadConnection(
            events: [.columns([ColumnMeta(name: "a", declaredType: "")])],
            ending: .fail(.queryFailed(message: "relation \"x\"\n  does not exist", code: nil))
        )
        let error = await Harness(connection: failing).failure("SELECT a FROM x")
        #expect(error == .queryFailed("relation \"x\" does not exist"))
        #expect(error?.description == "The database refused the query: relation \"x\" does not exist")

        let verbose = ScriptedReadConnection(
            events: [],
            ending: .fail(.queryFailed(message: String(repeating: "a \n", count: 400), code: nil))
        )
        let long = await Harness(connection: verbose).failure("SELECT a FROM x")
        guard case .queryFailed(let line) = long else {
            Issue.record("expected queryFailed, got \(String(describing: long))")
            return
        }
        #expect(line.count == 500)
        #expect(line.hasPrefix("a a a"))
        #expect(line.hasSuffix("…"))
        #expect(!line.contains("\n"))
    }

    @Test func aConnectionErrorNamesNoHost() async throws {
        let refused = Harness(open: { throw DriverError.connectionFailed("db.internal.example:5432 refused") })
        let error = await refused.failure("SELECT 1")
        #expect(error == .connectionFailed)
        #expect(error?.description == "BerryDB could not connect to this database.")
        #expect(error?.description.contains("internal") == false)

        // A server refusal while connecting can name the host and the user.
        let rejected = Harness(open: {
            throw DriverError.queryFailed(message: "password authentication failed for user \"alice\" on db.internal.example", code: nil)
        })
        #expect(await rejected.failure("SELECT 1") == .connectionFailed)
    }

    @Test func cancellingTheCallerCancelsTheRequest() async throws {
        let connection = ScriptedReadConnection(events: [.columns([ColumnMeta(name: "n", declaredType: "")])], ending: .never)
        let harness = Harness(connection: connection)
        let service = harness.service
        let request = harness.request("SELECT n FROM numbers")
        let task = Task { try await service.run(request) }
        let log = connection.log
        try await withDeadline(.seconds(60)) { await log.waitForStatement() }
        task.cancel()
        #expect(try await withDeadline(.seconds(60)) { await outcome(of: task) } == "cancelled")
        // The caller returns at once; the request unwinds after it.
        let tracker = harness.tracker
        try await withDeadline(.seconds(60)) { await tracker.waitForCloses(1) }
        try await withDeadline(.seconds(60)) { await log.waitForCancellations(1) }
    }

    @Test func cancellingTheCallerDuringAHungOpenReturnsAtOnce() async throws {
        let gate = AsyncGate()
        let harness = Harness(openBudget: .seconds(15), open: { await gate.wait() })
        let service = harness.service
        let request = harness.request("SELECT 1")
        let tracker = harness.tracker
        let task = Task { try await service.run(request) }
        try await withDeadline(.seconds(60)) { await tracker.waitForFactoryCalls(1) }
        let clock = ContinuousClock()
        let cancelled = clock.now
        task.cancel()
        #expect(try await withDeadline(.seconds(60)) { await outcome(of: task) } == "cancelled")
        #expect(clock.now - cancelled < .seconds(5))
        // The connection that opens after the caller left is still closed.
        await gate.open()
        try await withDeadline(.seconds(60)) { await tracker.waitForCloses(1) }
    }

    @Test func aQueryErrorNamesNoAccount() async throws {
        let denied = ScriptedReadConnection(
            events: [],
            ending: .fail(.queryFailed(message: "SELECT command denied to user 'app'@'10.0.0.5' for table 't'", code: 1142))
        )
        let error = await Harness(connection: denied).failure("SELECT a FROM t")
        #expect(error == .queryFailed("SELECT command denied to user '…'@'…' for table 't'"))
        #expect(error?.description.contains("'…'@'…'") == true)
        #expect(error?.description.contains("app") == false)
        #expect(error?.description.contains("10.0.0.5") == false)

        // An account at the 500-character cut is masked before the cut.
        let late = ScriptedReadConnection(
            events: [],
            ending: .fail(.queryFailed(message: String(repeating: "x", count: 488) + " user 'app'@'10.0.0.5' end", code: nil))
        )
        guard case .queryFailed(let line) = await Harness(connection: late).failure("SELECT a FROM t") else {
            Issue.record("expected queryFailed")
            return
        }
        #expect(line.count == 500)
        #expect(!line.contains("app"))
        #expect(!line.contains("10.0"))
    }

    @Test func redactionIgnoresTheColumnNamesCase() async throws {
        let connection = ScriptedReadConnection(events: [
            .columns([ColumnMeta(name: "EMAIL", declaredType: "TEXT"), ColumnMeta(name: "id", declaredType: "INTEGER")]),
            .rows([[.text("a@example.com"), .int(1)]]),
        ])
        let result = try await Harness(connection: connection, redactedColumns: ["email"]).read("SELECT EMAIL, id FROM users")
        #expect(result.rows == [["[REDACTED]", "1"]])
        #expect(result.redactedColumns == ["EMAIL"])
    }

    @Test func aReadOnlyRefusalUsesItsText() async throws {
        let connection = ScriptedReadConnection(events: [], ending: .fail(.readOnlyUnavailable("transaction_read_only reads off")))
        let error = await Harness(connection: connection).failure("SELECT 1")
        #expect(error == .readOnlyUnavailable)
        #expect(error?.description == "BerryDB could not open a read-only session on this database, so the query did not run.")
    }

    @Test func anUnsupportedStatementIsAQueryFailure() async throws {
        let connection = ScriptedReadConnection(events: [], ending: .fail(.unsupported("This connection does not bind parameters.")))
        let error = await Harness(connection: connection).failure("SELECT 1")
        #expect(error == .queryFailed("This connection does not bind parameters."))
    }

    @Test func aColumnListTooLargeForTheCeilingIsRefused() async throws {
        // About 145 KB of column names, all redacted: the limiter's own
        // metadata then lists them again and cannot fit the 256 KiB ceiling.
        let names = (0..<1_400).map { "secret_column_\($0)_" + String(repeating: "x", count: 85) }
        let connection = ScriptedReadConnection(events: [
            .columns(names.map { ColumnMeta(name: $0, declaredType: "TEXT") }),
            .rows([names.map { _ in BerryValue.text("v") }]),
        ])
        let harness = Harness(connection: connection, isProduction: true, redactedColumns: names)
        let error = await harness.failure("SELECT * FROM wide")
        #expect(error == .resultTooLarge)
        #expect(error?.description == "Result too large; narrow the request")
    }

    @Test func theStatementDeadlineReportsTheProfileLimit() async throws {
        let connection = ScriptedReadConnection(events: [.columns([ColumnMeta(name: "n", declaredType: "")])], ending: .never)
        let error = await Harness(connection: connection, isProduction: true).failure("SELECT n FROM numbers")
        #expect(error == .timedOut(seconds: 5))
        let log = connection.log
        try await withDeadline(.seconds(60)) { await log.waitForCancellations(1) }
    }

    @Test func aSlowReadThatKeptEveryRowIsNotTruncated() {
        let complete = MCPTruncationMetadata(
            truncated: false, omittedRows: 0, omittedObjects: 0, omittedGraphNodes: 0, omittedGraphEdges: 0,
            truncatedCells: 0, byteLimitReached: false, elapsedLimitReached: false, redactedColumns: []
        )
        var slow = complete
        slow.elapsedLimitReached = true
        slow.truncated = true
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: false, slow) == false)
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: false, complete) == false)
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: true, complete))
        var omitted = complete
        omitted.omittedRows = 1
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: false, omitted))
        var cut = complete
        cut.truncatedCells = 1
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: false, cut))
        var full = complete
        full.byteLimitReached = true
        #expect(MCPLiveReadService.leftSomethingOut(hasMoreRows: false, full))
    }
}

@Suite("MCP request deadline")
struct MCPRequestDeadlineTests {
    @Test func anExpiryAfterTheOpenReportsTheStatementLimit() async throws {
        let gate = AsyncGate()
        let outcome = try await withDeadline(.seconds(60)) { () -> MCPLiveReadError? in
            do {
                _ = try await MCPRequestDeadline.run(.milliseconds(300), opening: .milliseconds(100)) { opening in
                    opening.opened(statementLimit: .seconds(7))
                    await gate.wait()
                    return 0
                }
                return nil
            } catch {
                return error as? MCPLiveReadError
            }
        }
        #expect(outcome == .timedOut(seconds: 7))
        await gate.open()
    }

    @Test func anExpiryBeforeTheOpenReportsTheOpenLimit() async throws {
        let gate = AsyncGate()
        let outcome = try await withDeadline(.seconds(60)) { () -> MCPLiveReadError? in
            do {
                _ = try await MCPRequestDeadline.run(.seconds(30), opening: .milliseconds(100)) { _ in
                    await gate.wait()
                    return 0
                }
                return nil
            } catch {
                return error as? MCPLiveReadError
            }
        }
        #expect(outcome == .openTimedOut(seconds: 1))
        await gate.open()
    }

    @Test func aProfileWithoutLiveReadsIsRefusedWithoutConnecting() async throws {
        let harness = Harness(liveRead: false)
        let error = await harness.failure("SELECT 1")
        #expect(error == .liveReadNotEnabled)
        #expect(error?.description == "Live reads are not turned on for this connection. The user can turn them on in BerryDB Settings → AI Agents.")
        #expect(await harness.tracker.factoryCalls == 0)
    }

    @Test func aSessionWithoutItsProfileRunsNothing() async throws {
        let connection = ScriptedReadConnection(events: [.columns([ColumnMeta(name: "n", declaredType: "")])])
        let harness = Harness(connection: connection, sessionCarriesProfile: false)
        let error = await harness.failure("SELECT 1")
        #expect(error == .queryFailed("unexpected error"))
        #expect(connection.log.snapshot().statements.isEmpty)
        #expect(await harness.tracker.closes == 1)
    }

    @Test func aStatementTheServerCancelsReportsTheTimeLimit() async throws {
        for (isProduction, seconds) in [(false, 30), (true, 5)] {
            let connection = ScriptedReadConnection(
                events: [.columns([ColumnMeta(name: "n", declaredType: "")])],
                ending: .fail(.cancelled)
            )
            let error = await Harness(connection: connection, isProduction: isProduction).failure("SELECT n FROM numbers")
            #expect(error == .timedOut(seconds: seconds))
        }
    }

    @Test func aDialectThatDoesNotMatchTheDriverIsRefused() async throws {
        let connection = ScriptedReadConnection(events: [])
        let harness = Harness(connection: connection, driverID: .postgres)
        let error = await harness.failure("SELECT 1", dialect: .sqlite)
        #expect(error == .unsupportedDatabase)
        #expect(error?.description == "Live reads are available for PostgreSQL, MySQL, MariaDB and SQLite connections only.")
        #expect(connection.log.snapshot().statements.isEmpty)
    }

    @Test func resolutionRefusalsUseTheirAgentTexts() async throws {
        let profile: @Sendable (UUID) -> MCPConnectionProfile = {
            MCPConnectionProfile(id: $0, driverID: .sqlite, config: .sqlite(path: ":memory:"))
        }
        let project: @Sendable (UUID, Bool) -> MCPVerifiedProject = { id, enabled in
            MCPVerifiedProject(
                project: MCPProject(name: "P", isEnabled: enabled, profiles: [MCPProfileAccess(profileID: id, liveRead: true)]),
                liveReadProfileIDs: [id]
            )
        }
        let cases: [(String, @Sendable (UUID) -> MCPProjectResolver, MCPLiveReadError)] = [
            ("no project", { _ in MCPProjectResolver(loadProject: { nil }, profile: { profile($0) }) }, .noProject),
            ("disabled", { id in MCPProjectResolver(loadProject: { project(id, false) }, profile: { profile($0) }) }, .noProject),
            ("unassigned", { id in
                MCPProjectResolver(
                    loadProject: { project(UUID(), true) }, profile: { _ in profile(id) }
                )
            }, .unknownConnection),
            ("deleted", { id in MCPProjectResolver(loadProject: { project(id, true) }, profile: { _ in nil }) }, .unknownConnection),
            ("unsupported", { id in
                MCPProjectResolver(
                    loadProject: { project(id, true) },
                    profile: { _ in throw MCPProjectResolutionError.unsupportedDriver("cassandra") }
                )
            }, .unsupportedDatabase),
        ]
        for (name, resolver, expected) in cases {
            let harness = Harness(resolver: resolver)
            let error = await harness.failure("SELECT 1")
            #expect(error == expected, "\(name)")
            #expect(await harness.tracker.factoryCalls == 0, "\(name)")
        }
        #expect(MCPLiveReadError.unknownConnection.description == "Unknown connection for this project")
        #expect(MCPLiveReadError.noProject.description == "No BerryDB project is selected for this workspace. Call berrydb_status for details.")
    }
}

/// One coordinator over one live-read profile whose sessions run on a
/// scripted connection; the request's profile ID is the profile's.
private struct Harness {
    let profileID: UUID
    let tracker: Tracker
    let service: MCPLiveReadService

    init(
        connection: ScriptedReadConnection = ScriptedReadConnection(events: []),
        driverID: DriverID = .sqlite,
        isProduction: Bool = false,
        redactedColumns: [String] = [],
        liveRead: Bool = true,
        sessionCarriesProfile: Bool = true,
        resolver: (@Sendable (UUID) -> MCPProjectResolver)? = nil,
        openBudget: Duration = .seconds(15),
        open: @escaping @Sendable () async throws -> Void = {}
    ) {
        let id = UUID()
        let tracker = Tracker()
        let project = MCPProject(
            name: "P", isEnabled: true,
            profiles: [MCPProfileAccess(profileID: id, liveRead: liveRead, redactedColumns: redactedColumns)]
        )
        let resolver = resolver?(id) ?? MCPProjectResolver(
            loadProject: { MCPVerifiedProject(project: project, liveReadProfileIDs: liveRead ? [id] : []) },
            profile: { requested in
                guard requested == id else { return nil }
                return MCPConnectionProfile(id: id, driverID: driverID, config: .sqlite(path: ":memory:"), isProduction: isProduction)
            }
        )
        let coordinator = MCPConnectionCoordinator(resolver: resolver, sqlFactory: { profile in
            await tracker.factoryCalled()
            try await open()
            let lifecycle = MCPConnectionLifecycle(
                cancel: { await tracker.cancelled() },
                closeConnection: { await tracker.closed() }
            )
            return MCPSQLSession(connection: connection, lifecycle: lifecycle, profile: sessionCarriesProfile ? profile : nil)
        })
        profileID = id
        self.tracker = tracker
        service = MCPLiveReadService(coordinator: coordinator, openBudget: openBudget)
    }

    func request(
        _ sql: String, parameters: [SQLParameter] = [], rowLimit: Int? = nil, dialect: MCPSQLDialect = .sqlite
    ) -> MCPLiveReadRequest {
        MCPLiveReadRequest(profileID: profileID, dialect: dialect, sql: sql, parameters: parameters, rowLimit: rowLimit)
    }

    func read(
        _ sql: String, parameters: [SQLParameter] = [], rowLimit: Int? = nil, dialect: MCPSQLDialect = .sqlite
    ) async throws -> MCPLiveReadResult {
        let service = self.service
        let request = self.request(sql, parameters: parameters, rowLimit: rowLimit, dialect: dialect)
        return try await withDeadline(.seconds(60)) { try await service.run(request) }
    }

    /// The service's refusal; records an issue when it returned or threw anything else.
    func failure(_ sql: String, dialect: MCPSQLDialect = .sqlite) async -> MCPLiveReadError? {
        do {
            let result = try await read(sql, dialect: dialect)
            Issue.record("expected a refusal, got \(result)")
        } catch let error as MCPLiveReadError {
            return error
        } catch {
            Issue.record("expected MCPLiveReadError, got \(error)")
        }
        return nil
    }
}

private actor Tracker {
    private(set) var factoryCalls = 0
    private(set) var closes = 0
    private(set) var cancels = 0
    func factoryCalled() { factoryCalls += 1 }
    func closed() { closes += 1 }
    func cancelled() { cancels += 1 }
    func waitForCloses(_ count: Int) async {
        while closes < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func waitForFactoryCalls(_ count: Int) async {
        while factoryCalls < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// How a request task ended, as text, so a test can compare it.
private func outcome(of task: Task<MCPLiveReadResult, Error>) async -> String {
    do {
        _ = try await task.value
        return "returned"
    } catch is CancellationError {
        return "cancelled"
    } catch {
        return "\(error)"
    }
}

private actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Ignores cancellation, as an SSH channel that never comes up does.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct ScriptedStatement: Equatable, Sendable {
    let sql: String
    let parameters: [SQLParameter]
    let timeout: Duration
}

/// What a scripted connection was asked to run and what its reader took.
/// Locked rather than actor-held, so a stream's termination handler records
/// synchronously, before the reader returns.
private final class ScriptLog: Sendable {
    struct Snapshot: Sendable {
        var statements: [ScriptedStatement] = []
        var rowsHandedOut = 0
        var cancellations = 0
    }

    private let state = Mutex(Snapshot())

    func snapshot() -> Snapshot { state.withLock { $0 } }
    func received(_ statement: ScriptedStatement) { state.withLock { $0.statements.append(statement) } }
    func handedOut(_ rows: Int) { state.withLock { $0.rowsHandedOut += rows } }
    func cancelled() { state.withLock { $0.cancellations += 1 } }
    func waitForStatement() async {
        while snapshot().statements.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func waitForCancellations(_ count: Int) async {
        while snapshot().cancellations < count { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Replays `events` for every read-only statement. The stream buffers one
/// event and the next is produced only once the reader took the previous
/// one, so a reader that stops early leaves the rest unproduced, as a
/// server-side cursor does.
private actor ScriptedReadConnection: ReadOnlyExecuting {
    enum Ending: Sendable {
        case finish
        case never
        case fail(DriverError)
    }

    nonisolated let id = UUID()
    nonisolated let log = ScriptLog()
    private nonisolated let events: [ResultEvent]
    private nonisolated let ending: Ending

    init(events: [ResultEvent], ending: Ending = .finish) {
        self.events = events
        self.ending = ending
    }

    func prepareReadOnly() async throws {}

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        executeReadOnly(sql, parameters: [], timeout: timeout)
    }

    nonisolated func executeReadOnly(
        _ sql: String, parameters: [SQLParameter], timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        log.received(ScriptedStatement(sql: sql, parameters: parameters, timeout: timeout))
        let (stream, continuation) = AsyncThrowingStream<ResultEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let log = self.log
        continuation.onTermination = { termination in
            if case .cancelled = termination { log.cancelled() }
        }
        let events = self.events
        let ending = self.ending
        Task {
            for event in events {
                var delivered = false
                while !delivered {
                    switch continuation.yield(event) {
                    case .enqueued:
                        delivered = true
                    case .dropped:
                        try? await Task.sleep(for: .milliseconds(1))
                    case .terminated:
                        return
                    @unknown default:
                        return
                    }
                }
                if case .rows(let batch) = event { log.handedOut(batch.count) }
            }
            switch ending {
            case .finish: continuation.finish()
            case .never: break
            case .fail(let error): continuation.finish(throwing: error)
            }
        }
        return stream
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}
