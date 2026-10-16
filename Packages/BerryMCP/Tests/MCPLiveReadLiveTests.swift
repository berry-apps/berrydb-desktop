import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import BerryMCP
import BerryStore
import Foundation
import Testing

/// The live read service end to end against a real server, from
/// `BERRYDB_TEST_POSTGRES` or `BERRYDB_TEST_MYSQL` (MySQL or MariaDB), and
/// skipped when the variable is unset. Sessions come from the default
/// connection factories with the real driver, so each is made read-only by
/// the driver before a statement runs, and every statement first passes the
/// read policy. Each test makes its own table, routines, views and
/// SELECT-only account, named after a fresh UUID, and drops them on every
/// path.
@Suite("MCP live reads on PostgreSQL", .serialized, .enabled(if: TestServer.postgres != nil))
struct MCPLiveReadPostgresLiveTests {
    @Test func aPlaceholderBindsItsParameter() async throws {
        try await LiveRead.placeholderBindsItsParameter(.postgres)
    }

    @Test func theRowLimitFollowsTheProductionLabel() async throws {
        try await LiveRead.rowLimitFollowsTheProductionLabel(.postgres)
    }

    @Test func writeAttemptsAreRefusedAndWriteNothing() async throws {
        try await LiveRead.writeAttemptsAreRefusedAndWriteNothing(.postgres)
    }

    @Test func aLockTakenThroughAViewEndsWithTheSession() async throws {
        try await LiveRead.lockTakenThroughAViewEndsWithTheSession(.postgres)
    }

    @Test func aStatementPastTheProductionLimitIsEndedOnTheServer() async throws {
        try await LiveRead.statementPastTheProductionLimitIsEnded(.postgres)
    }
}

@Suite("MCP live reads on MySQL and MariaDB", .serialized, .enabled(if: TestServer.mysql != nil))
struct MCPLiveReadMySQLLiveTests {
    @Test func aPlaceholderBindsItsParameter() async throws {
        try await LiveRead.placeholderBindsItsParameter(.mysql)
    }

    @Test func theRowLimitFollowsTheProductionLabel() async throws {
        try await LiveRead.rowLimitFollowsTheProductionLabel(.mysql)
    }

    @Test func writeAttemptsAreRefusedAndWriteNothing() async throws {
        try await LiveRead.writeAttemptsAreRefusedAndWriteNothing(.mysql)
    }

    @Test func aLockTakenThroughAViewEndsWithTheSession() async throws {
        try await LiveRead.lockTakenThroughAViewEndsWithTheSession(.mysql)
    }

    @Test func aStatementPastTheProductionLimitIsEndedOnTheServer() async throws {
        try await LiveRead.statementPastTheProductionLimitIsEnded(.mysql)
    }
}

private enum Engine: Sendable {
    case postgres, mysql

    var server: TestServer { (self == .postgres ? TestServer.postgres : TestServer.mysql)! }
    var driverID: DriverID { self == .postgres ? .postgres : .mysql }
    var dialect: MCPSQLDialect { self == .postgres ? .postgresql : .mysql }
    var driver: any DatabaseDriver.Type { self == .postgres ? PostgresDriver.self : MySQLDriver.self }
    var placeholder: String { self == .postgres ? "$1" : "?" }

    func config(user: String, password: String) -> ConnectionConfig {
        ConnectionConfig(
            driver: driverID, name: "live-read", host: server.host, port: server.port,
            username: user, password: password, database: server.database
        )
    }
}

/// The objects one test made on the server, the admin connection that made
/// them and inspects them, and a live read service over three profiles of
/// the same server.
private struct Fixture: Sendable {
    /// Rows the table starts with: more than the default row limit of 100.
    static let seededRows = 120

    let engine: Engine
    let admin: any DriverConnection
    let table: String
    let isMariaDB: Bool
    /// Taken only by the view that takes a lock; never by the test itself.
    let lockKey: Int
    let readerConfig: ConnectionConfig
    /// A SELECT-only account made for the test.
    let reader: UUID
    /// The server's own account, which can write.
    let writer: UUID
    /// The server's own account with the production label.
    let productionWriter: UUID
    let service: MCPLiveReadService

    var lockName: String { "\(table)_lock" }

    func run(
        _ sql: String, on profile: UUID, parameters: [SQLParameter] = []
    ) async throws -> MCPLiveReadResult {
        let request = MCPLiveReadRequest(profileID: profile, dialect: engine.dialect, sql: sql, parameters: parameters)
        let service = self.service
        return try await withDeadline(.seconds(60)) { try await service.run(request) }
    }

    /// The service's refusal of `sql`; records an issue when it returned
    /// rows, did not finish within a minute or threw anything else.
    func refusal(_ sql: String, on profile: UUID) async -> MCPLiveReadError? {
        do {
            let result = try await run(sql, on: profile)
            Issue.record("\(sql) returned \(result.rows)")
        } catch let error as MCPLiveReadError {
            return error
        } catch is DeadlineExceeded {
            Issue.record("\(sql) did not finish within a minute")
        } catch {
            Issue.record("\(sql) threw \(error)")
        }
        return nil
    }

    @discardableResult
    func admin(_ sql: String) async throws -> [[BerryValue]] {
        try await LiveRead.drain(admin.execute(sql))
    }

    func adminValue(_ sql: String) async throws -> String? {
        try await admin(sql).first?.first?.displayString
    }

    /// Polls `sql` on the admin connection until it reads `expected`, for at
    /// most `seconds`; returns the last value read. A session's locks and
    /// statements end on the server shortly after the client closes it.
    func adminValue(_ sql: String, becomes expected: String, within seconds: Int = 5) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        var value = try await adminValue(sql)
        while value != expected, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            value = try await adminValue(sql)
        }
        return value
    }
}

private enum LiveRead {
    static func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    private static func randomSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    // MARK: Setup

    static func withFixture(_ engine: Engine, _ body: (Fixture) async throws -> Void) async throws {
        let server = engine.server
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let table = "mcp_live_\(suffix)"
        let readerName = "mcp_reader_\(suffix)"
        let readerConfig = engine.config(user: readerName, password: randomSecret())
        let admin = try await engine.driver.init().connect(engine.config(user: server.username, password: server.password))
        var isMariaDB = false
        if engine == .mysql {
            do {
                isMariaDB = try await drain(admin.execute("SELECT VERSION()")).first?.first?.displayString?.contains("MariaDB") == true
            } catch {
                await admin.close()
                throw error
            }
        }
        let fixture = makeFixture(
            engine: engine, admin: admin, table: table, isMariaDB: isMariaDB, readerConfig: readerConfig
        )
        do {
            switch engine {
            case .postgres: try await setUpPostgres(fixture, reader: readerName, password: readerConfig.password!)
            case .mysql: try await setUpMySQL(fixture, reader: readerName, password: readerConfig.password!)
            }
            try await body(fixture)
        } catch {
            await tearDown(fixture, reader: readerName)
            throw error
        }
        await tearDown(fixture, reader: readerName)
    }

    private static func makeFixture(
        engine: Engine, admin: any DriverConnection, table: String, isMariaDB: Bool, readerConfig: ConnectionConfig
    ) -> Fixture {
        let server = engine.server
        let writerConfig = engine.config(user: server.username, password: server.password)
        let reader = UUID(), writer = UUID(), productionWriter = UUID()
        let profiles: [UUID: MCPConnectionProfile] = [
            reader: MCPConnectionProfile(id: reader, driverID: engine.driverID, config: readerConfig),
            writer: MCPConnectionProfile(id: writer, driverID: engine.driverID, config: writerConfig),
            productionWriter: MCPConnectionProfile(
                id: productionWriter, driverID: engine.driverID, config: writerConfig, isProduction: true
            ),
        ]
        let project = MCPProject(
            name: "live", isEnabled: true,
            profiles: profiles.keys.map { MCPProfileAccess(profileID: $0, liveRead: true) }
        )
        let resolver = MCPProjectResolver(
            loadProject: { MCPVerifiedProject(project: project, liveReadProfileIDs: Set(profiles.keys)) },
            profile: { profiles[$0] }
        )
        // The helper registers every driver with `DriverRegistry` at launch;
        // naming the two here keeps the process-wide registry untouched.
        let registries = MCPDriverRegistries(sql: { $0 == engine.driverID ? engine.driver : nil })
        let coordinator = MCPConnectionCoordinator(resolver: resolver, factories: MCPConnectionFactories(registries: registries))
        return Fixture(
            engine: engine, admin: admin, table: table, isMariaDB: isMariaDB,
            lockKey: Int.random(in: 1_000_000...2_000_000_000), readerConfig: readerConfig,
            reader: reader, writer: writer, productionWriter: productionWriter,
            service: MCPLiveReadService(coordinator: coordinator)
        )
    }

    private static func seedValues() -> String {
        (1...Fixture.seededRows).map { "(\($0), 'row \($0)')" }.joined(separator: ", ")
    }

    /// The writer function is SECURITY DEFINER and owned by the server's own
    /// account, so through a view even the SELECT-only account reaches an
    /// INSERT with write rights; only the read-only transaction stands in
    /// its way.
    private static func setUpPostgres(_ fixture: Fixture, reader: String, password: String) async throws {
        let table = fixture.table
        for statement in [
            "CREATE TABLE \(table) (id int PRIMARY KEY, label text)",
            "INSERT INTO \(table) VALUES \(seedValues())",
            "CREATE SEQUENCE \(table)_seq",
            "CREATE FUNCTION \(table)_writer() RETURNS int LANGUAGE sql SECURITY DEFINER "
                + "AS $$ INSERT INTO \(table) VALUES (999, 'written') RETURNING id $$",
            "CREATE VIEW \(table)_via_writer AS SELECT \(table)_writer() AS id",
            "CREATE VIEW \(table)_via_nextval AS SELECT nextval('\(table)_seq') AS n",
            "CREATE VIEW \(table)_via_flip AS SELECT set_config('transaction_read_only', 'off', true) AS mode, "
                + "\(table)_writer() AS id",
            "CREATE VIEW \(table)_via_lock AS SELECT pg_try_advisory_lock(\(fixture.lockKey)) AS locked",
            "CREATE ROLE \(reader) LOGIN PASSWORD '\(password)'",
            "GRANT SELECT ON \(table), \(table)_via_writer, \(table)_via_nextval, \(table)_via_flip, "
                + "\(table)_via_lock TO \(reader)",
        ] {
            try await fixture.admin(statement)
        }
    }

    /// A view runs with its definer's rights by default
    /// (https://dev.mysql.com/doc/refman/8.4/en/stored-objects-security.html),
    /// so through it the SELECT-only account reaches the writer function
    /// with the server account's rights. DETERMINISTIC lets the function be
    /// created while binary logging is on; it is not true and does not need
    /// to be.
    private static func setUpMySQL(_ fixture: Fixture, reader: String, password: String) async throws {
        let table = fixture.table
        let database = fixture.engine.server.database!
        var statements = [
            "CREATE TABLE \(table) (id INT PRIMARY KEY, label VARCHAR(32))",
            "INSERT INTO \(table) VALUES \(seedValues())",
            "CREATE FUNCTION \(table)_writer() RETURNS INT DETERMINISTIC MODIFIES SQL DATA "
                + "BEGIN INSERT INTO \(table) VALUES (999, 'written'); RETURN 1; END",
            "CREATE VIEW \(table)_via_writer AS SELECT \(table)_writer() AS id",
            "CREATE VIEW \(table)_via_lock AS SELECT GET_LOCK('\(fixture.lockName)', 0) AS locked",
            "CREATE USER '\(reader)'@'%' IDENTIFIED BY '\(password)'",
            "GRANT SELECT ON `\(database)`.`\(table)` TO '\(reader)'@'%'",
            "GRANT SELECT ON `\(database)`.`\(table)_via_writer` TO '\(reader)'@'%'",
            "GRANT SELECT ON `\(database)`.`\(table)_via_lock` TO '\(reader)'@'%'",
        ]
        if fixture.isMariaDB {
            statements += [
                "CREATE SEQUENCE \(table)_seq",
                "GRANT SELECT ON `\(database)`.`\(table)_seq` TO '\(reader)'@'%'",
            ]
        }
        for statement in statements {
            try await fixture.admin(statement)
        }
    }

    private static func tearDown(_ fixture: Fixture, reader: String) async {
        let table = fixture.table
        let statements: [String]
        switch fixture.engine {
        case .postgres:
            statements = [
                "DROP VIEW IF EXISTS \(table)_via_writer, \(table)_via_nextval, \(table)_via_flip, \(table)_via_lock",
                "DROP FUNCTION IF EXISTS \(table)_writer()",
                "DROP SEQUENCE IF EXISTS \(table)_seq",
                "DROP TABLE IF EXISTS \(table), \(table)_copy",
                "DROP ROLE IF EXISTS \(reader)",
            ]
        case .mysql:
            statements = [
                "DROP USER IF EXISTS '\(reader)'@'%'",
                "DROP VIEW IF EXISTS \(table)_via_writer, \(table)_via_lock",
                "DROP FUNCTION IF EXISTS \(table)_writer",
                "DROP TABLE IF EXISTS \(table)",
            ] + (fixture.isMariaDB ? ["DROP SEQUENCE IF EXISTS \(table)_seq"] : [])
        }
        for statement in statements {
            _ = try? await fixture.admin(statement)
        }
        await fixture.admin.close()
    }

    // MARK: Reads

    static func placeholderBindsItsParameter(_ engine: Engine) async throws {
        try await withFixture(engine) { fixture in
            let sql = "SELECT id, label FROM \(fixture.table) WHERE id = \(engine.placeholder)"
            for profile in [fixture.reader, fixture.writer] {
                let result = try await fixture.run(sql, on: profile, parameters: [.int(7)])
                #expect(result.columns == ["id", "label"])
                #expect(result.rows == [["7", "row 7"]])
                #expect(result.truncated == false)
            }
        }
    }

    static func rowLimitFollowsTheProductionLabel(_ engine: Engine) async throws {
        try await withFixture(engine) { fixture in
            let sql = "SELECT id FROM \(fixture.table) ORDER BY id"
            for (profile, limit) in [(fixture.writer, 100), (fixture.productionWriter, 50), (fixture.reader, 100)] {
                let result = try await fixture.run(sql, on: profile)
                #expect(result.rowCount == limit)
                #expect(result.rows.first == ["1"])
                #expect(result.rows.last == ["\(limit)"])
                #expect(result.hasMoreRows)
                #expect(result.truncated)
            }
        }
    }

    // MARK: Write attempts

    /// A statement that tries to write, lock, wait or leave the read-only
    /// transaction, and how it is refused.
    private struct Attempt {
        enum Refusal {
            /// The read policy refuses it with this reason, whichever account
            /// the profile uses.
            case policy(String)
            /// The database refuses it; the message holds one of these, per
            /// account.
            case database(reader: [String], writer: [String])
        }

        let sql: String
        let refusal: Refusal
    }

    private static func attempts(_ fixture: Fixture) -> [Attempt] {
        let table = fixture.table
        let writerFunction = "\(table)_writer".uppercased()
        switch fixture.engine {
        case .postgres:
            let readOnly = "in a read-only transaction"
            // PostgreSQL 16.15 also refuses the writes among these inside
            // BEGIN READ ONLY, and the driver refuses SET and COMMIT before
            // the server; it runs pg_advisory_lock and pg_sleep there, so for
            // those two the policy is the only refusal.
            return [
                Attempt(
                    sql: "WITH made AS (INSERT INTO \(table) VALUES (999, 'written') RETURNING id) SELECT id FROM made",
                    refusal: .policy("Prohibited operation: INSERT")
                ),
                Attempt(sql: "SELECT nextval('\(table)_seq')", refusal: .policy("Prohibited operation: NEXTVAL")),
                Attempt(sql: "SELECT \(table)_writer()", refusal: .policy("Prohibited operation: unapproved function \(writerFunction)")),
                Attempt(
                    sql: "SELECT set_config('transaction_read_only', 'off', true)",
                    refusal: .policy("Prohibited operation: unapproved function SET_CONFIG")
                ),
                Attempt(sql: "SET TRANSACTION READ WRITE", refusal: .policy("Prohibited operation: SET")),
                Attempt(sql: "COMMIT", refusal: .policy("Prohibited operation: COMMIT")),
                Attempt(sql: "SELECT pg_advisory_lock(1)", refusal: .policy("Prohibited operation: unapproved function PG_ADVISORY_LOCK")),
                Attempt(sql: "SELECT pg_sleep(10)", refusal: .policy("Prohibited operation: unapproved function PG_SLEEP")),
                Attempt(sql: "SELECT id INTO \(table)_copy FROM \(table)", refusal: .policy("Prohibited operation: INTO")),
                // A function behind a view is out of the policy's sight; the
                // read-only transaction refuses its write.
                Attempt(
                    sql: "SELECT id FROM \(table)_via_writer",
                    refusal: .database(reader: [readOnly], writer: [readOnly])
                ),
                Attempt(
                    sql: "SELECT n FROM \(table)_via_nextval",
                    refusal: .database(reader: ["permission denied", readOnly], writer: [readOnly])
                ),
                Attempt(
                    sql: "SELECT mode, id FROM \(table)_via_flip",
                    refusal: .database(
                        reader: ["read-write mode must be set before any query"],
                        writer: ["read-write mode must be set before any query"]
                    )
                ),
            ]
        case .mysql:
            let readOnly = "READ ONLY transaction"
            // MySQL 8.4.11 and MariaDB 11.8.9 run GET_LOCK and SLEEP inside
            // START TRANSACTION READ ONLY, and there write the file of INTO
            // OUTFILE for an account with the FILE privilege. For those three
            // the policy is the only refusal; for the file, the privilege is
            // the database's. A WITH clause cannot hold an INSERT in either
            // server; MySQL accepts one before DELETE
            // (https://dev.mysql.com/doc/refman/8.4/en/with.html).
            var attempts = [
                Attempt(
                    sql: "WITH made AS (INSERT INTO \(table) VALUES (999, 'written')) SELECT 1",
                    refusal: .policy("Prohibited operation: INSERT")
                ),
                Attempt(
                    sql: "WITH gone AS (SELECT 1 AS id) DELETE FROM \(table) WHERE id IN (SELECT id FROM gone)",
                    refusal: .policy("Prohibited operation: DELETE")
                ),
                Attempt(sql: "SELECT \(table)_writer()", refusal: .policy("Prohibited operation: unapproved function \(writerFunction)")),
                Attempt(sql: "SET TRANSACTION READ WRITE", refusal: .policy("Prohibited operation: SET")),
                Attempt(sql: "COMMIT", refusal: .policy("Prohibited operation: COMMIT")),
                Attempt(sql: "SELECT GET_LOCK('x', 0)", refusal: .policy("Prohibited operation: unapproved function GET_LOCK")),
                Attempt(sql: "SELECT SLEEP(10)", refusal: .policy("Prohibited operation: SLEEP")),
                Attempt(
                    sql: "SELECT id FROM \(table) INTO OUTFILE '/tmp/\(table).txt'",
                    refusal: .policy("Prohibited operation: INTO")
                ),
                // A function behind a view is out of the policy's sight; the
                // read-only transaction refuses its write.
                Attempt(
                    sql: "SELECT id FROM \(table)_via_writer",
                    refusal: .database(reader: [readOnly], writer: [readOnly])
                ),
            ]
            if fixture.isMariaDB {
                attempts += [
                    Attempt(sql: "SELECT NEXTVAL(\(table)_seq)", refusal: .policy("Prohibited operation: NEXTVAL")),
                    Attempt(
                        sql: "SELECT NEXT VALUE FOR \(table)_seq",
                        refusal: .policy("Prohibited operation: NEXT VALUE FOR")
                    ),
                ]
            }
            return attempts
        }
    }

    static func writeAttemptsAreRefusedAndWriteNothing(_ engine: Engine) async throws {
        try await withFixture(engine) { fixture in
            // The server's account is one the privilege check reports as
            // able to write; the account made for the test is not.
            let writerConnection = try await engine.driver.init().connect(
                engine.config(user: engine.server.username, password: engine.server.password)
            )
            let writerFindings = try await MCPPrivilegeCheck.findings(on: writerConnection, driver: engine.driverID)
            await writerConnection.close()
            let readerConnection = try await engine.driver.init().connect(fixture.readerConfig)
            let readerFindings = try await MCPPrivilegeCheck.findings(on: readerConnection, driver: engine.driverID)
            await readerConnection.close()
            #expect(!writerFindings.isEmpty)
            #expect(readerFindings == [])

            for attempt in attempts(fixture) {
                for (account, profile) in [("reader", fixture.reader), ("writer", fixture.writer)] {
                    let error = await fixture.refusal(attempt.sql, on: profile)
                    switch attempt.refusal {
                    case .policy(let reason):
                        #expect(error == .policy(reason), "\(account): \(attempt.sql)")
                    case .database(let reader, let writer):
                        let fragments = account == "reader" ? reader : writer
                        guard case .queryFailed(let message)? = error else {
                            Issue.record("\(account): \(attempt.sql) was not refused by the database: \(String(describing: error))")
                            continue
                        }
                        #expect(fragments.contains { message.contains($0) }, "\(account): \(attempt.sql): \(message)")
                    }
                    try await expectNothingWritten(fixture, after: "\(account): \(attempt.sql)")
                }
            }
        }
    }

    private static func expectNothingWritten(_ fixture: Fixture, after attempt: String) async throws {
        let table = fixture.table
        #expect(try await fixture.adminValue("SELECT count(*) FROM \(table)") == "\(Fixture.seededRows)", "\(attempt)")
        #expect(try await fixture.adminValue("SELECT count(*) FROM \(table) WHERE id = 999") == "0", "\(attempt)")
        switch fixture.engine {
        case .postgres:
            #expect(try await fixture.adminValue("SELECT count(*) FROM \(table)_seq WHERE is_called") == "0", "\(attempt)")
            #expect(
                try await fixture.adminValue("SELECT count(*) FROM pg_class WHERE relname = '\(table)_copy'") == "0",
                "\(attempt)"
            )
        case .mysql:
            if fixture.isMariaDB {
                #expect(try await fixture.adminValue("SELECT next_not_cached_value FROM \(table)_seq") == "1", "\(attempt)")
            }
        }
    }

    // MARK: Locks and time

    /// A function behind a view can take a lock, which writes nothing and
    /// which the read-only transaction allows; the session-level lock ends
    /// with the session the request closes.
    static func lockTakenThroughAViewEndsWithTheSession(_ engine: Engine) async throws {
        try await withFixture(engine) { fixture in
            let held: String
            switch engine {
            case .postgres:
                held = "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND objid = \(fixture.lockKey)"
            case .mysql:
                held = "SELECT IS_USED_LOCK('\(fixture.lockName)') IS NOT NULL"
            }
            for profile in [fixture.reader, fixture.writer] {
                let result = try await fixture.run("SELECT locked FROM \(fixture.table)_via_lock", on: profile)
                #expect(result.rows == [[engine == .postgres ? "true" : "1"]])
                #expect(try await fixture.adminValue(held, becomes: "0") == "0")
                try await expectNothingWritten(fixture, after: "lock view")
            }
        }
    }

    /// The policy refuses the sleep functions, so the statement that runs
    /// past the limit is the largest sum over the seeded table joined with
    /// itself six times, 120^6 rows read one by one. A count(*) of the same
    /// join does not do: MySQL 8.4.11 returned it in milliseconds without
    /// reading the rows.
    static func statementPastTheProductionLimitIsEnded(_ engine: Engine) async throws {
        try await withFixture(engine) { fixture in
            let table = fixture.table
            let aliases = ["a", "b", "c", "d", "e", "f"]
            let sum = aliases.map { "\($0).id" }.joined(separator: " + ")
            let joined = aliases.map { "\(table) \($0)" }.joined(separator: ", ")
            let clock = ContinuousClock()
            let started = clock.now
            let error = await fixture.refusal("SELECT max(\(sum)) FROM \(joined)", on: fixture.productionWriter)
            let elapsed = clock.now - started
            #expect(error == .timedOut(seconds: 5))
            #expect(elapsed < .seconds(10))

            let running: String
            switch engine {
            case .postgres:
                running = "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND state = 'active' "
                    + "AND query LIKE '%\(table) a,%'"
            case .mysql:
                running = "SELECT COUNT(*) FROM information_schema.processlist WHERE id <> CONNECTION_ID() "
                    + "AND info LIKE '%\(table) a,%'"
            }
            let stillRunning = try await fixture.adminValue(running, becomes: "0")
            #expect(stillRunning == "0")
        }
    }
}
