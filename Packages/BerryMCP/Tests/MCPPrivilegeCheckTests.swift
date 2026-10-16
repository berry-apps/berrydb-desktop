import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP privilege check parsing")
struct MCPPrivilegeCheckParsingTests {
    @Test func readOnlyGrantsHaveNoFindings() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: [
            "GRANT SELECT, SHOW VIEW ON `app`.* TO `u`@`%`",
            "GRANT USAGE ON *.* TO `u`@`%`",
        ]) == [])
    }

    @Test func writePrivilegesAreReportedByName() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: ["GRANT SELECT, INSERT ON `app`.* TO `u`@`%`"]) == ["INSERT"])
    }

    @Test func columnListsAreDroppedBeforeComparing() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: [
            "GRANT SELECT (a, b), UPDATE (b) ON `app`.`t` TO `u`@`%`",
        ]) == ["UPDATE"])
    }

    @Test func allPrivilegesIsReported() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: ["GRANT ALL PRIVILEGES ON *.* TO `u`@`%`"]) == ["ALL PRIVILEGES"])
    }

    @Test func grantOptionIsReportedEvenOnAReadOnlyLine() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: [
            "GRANT SELECT ON `app`.* TO `u`@`%` WITH GRANT OPTION",
        ]) == ["GRANT OPTION"])
    }

    @Test func grantOptionFollowedByResourceLimitsIsStillReported() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: [
            "GRANT SELECT ON `app`.* TO `u`@`%` WITH GRANT OPTION MAX_QUERIES_PER_HOUR 10",
        ]) == ["GRANT OPTION"])
    }

    @Test func roleMembershipLinesAreSkipped() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: ["GRANT `reader`@`%` TO `u`@`%`"]) == [])
    }

    @Test func findingsAreUppercasedDeduplicatedAndSorted() {
        #expect(MCPPrivilegeCheck.mysqlFindings(grantLines: [
            "GRANT update, Delete, SELECT ON `a`.* TO `u`@`%`",
            "GRANT DELETE, INSERT ON `b`.* TO `u`@`%`",
        ]) == ["DELETE", "INSERT", "UPDATE"])
    }

    @Test func postgresRowSplitsTheCommaList() {
        #expect(MCPPrivilegeCheck.postgresFindings(row: .text("column_write,table_write")) == ["column_write", "table_write"])
    }

    @Test func postgresNullRowHasNoFindings() {
        #expect(MCPPrivilegeCheck.postgresFindings(row: .null) == [])
        #expect(MCPPrivilegeCheck.postgresFindings(row: nil) == [])
    }

    @Test func postgresQueryIsTheDocumentedOne() {
        #expect(MCPPrivilegeCheck.postgresQuery.hasPrefix("SELECT string_agg(reason, ',' ORDER BY reason) FROM ("))
        #expect(MCPPrivilegeCheck.postgresQuery.contains("'setrole_writer'"))
    }
}

/// Records every statement it is asked to run; the check must not run any on
/// a driver it does not cover.
private actor RecordingConnection: DriverConnection {
    nonisolated let id = UUID()
    private let log = StatementLog()
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        log.add(sql)
        return .init { $0.finish() }
    }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
    nonisolated var statements: [String] { log.all }
}

private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func add(_ sql: String) { lock.lock(); statements.append(sql); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return statements }
}

@Suite("MCP privilege check driver coverage")
struct MCPPrivilegeCheckCoverageTests {
    @Test(arguments: [DriverID.sqlserver, .dynamodb, .redis, .mongodb])
    func aDriverTheCheckDoesNotCoverThrowsInsteadOfPassing(driver: DriverID) async {
        let connection = RecordingConnection()
        await #expect(throws: DriverError.self) {
            _ = try await MCPPrivilegeCheck.findings(on: connection, driver: driver)
        }
        #expect(connection.statements.isEmpty)
    }

    @Test func sqliteHasNoRolesAndNothingToFind() async throws {
        let connection = RecordingConnection()
        #expect(try await MCPPrivilegeCheck.findings(on: connection, driver: .sqlite) == [])
        #expect(connection.statements.isEmpty)
    }
}

private func randomSecret() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
}

private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws {
    for try await _ in stream {}
}

@Suite("MCP privilege check on PostgreSQL", .serialized, .enabled(if: TestServer.postgres != nil))
struct MCPPrivilegeCheckPostgresLiveTests {
    private func config(user: String, password: String) -> ConnectionConfig {
        let server = TestServer.postgres!
        return ConnectionConfig(
            driver: .postgres, name: "privilege-check", host: server.host, port: server.port,
            username: user, password: password, database: server.database
        )
    }

    private func withRole(
        _ body: (_ admin: PostgresDriverConnection, _ role: String, _ table: String, _ open: () async throws -> PostgresDriverConnection) async throws -> Void
    ) async throws {
        let server = TestServer.postgres!
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let role = "mcp_ro_\(suffix)"
        let table = "mcp_priv_\(suffix)"
        let password = randomSecret()
        let admin = try await PostgresDriverConnection(config: config(user: server.username, password: server.password))
        do {
            try await drain(admin.execute("CREATE TABLE \(table) (id int)"))
            try await drain(admin.execute("CREATE ROLE \(role) LOGIN PASSWORD '\(password)'"))
            try await drain(admin.execute("GRANT SELECT ON \(table) TO \(role)"))
            let cfg = config(user: role, password: password)
            try await body(admin, role, table) { try await PostgresDriverConnection(config: cfg) }
        } catch {
            await cleanUp(admin, role: role, table: table)
            throw error
        }
        await cleanUp(admin, role: role, table: table)
    }

    private func cleanUp(_ admin: PostgresDriverConnection, role: String, table: String) async {
        _ = try? await drain(admin.execute("DROP TABLE IF EXISTS \(table)"))
        _ = try? await drain(admin.execute("DROP ROLE IF EXISTS \(role)"))
        await admin.close()
    }

    @Test func aSelectOnlyRoleHasNoFindings() async throws {
        try await withRole { _, _, _, open in
            let connection = try await open()
            let found = try await MCPPrivilegeCheck.findings(on: connection, driver: .postgres)
            await connection.close()
            #expect(found == [])
        }
    }

    @Test func aRoleWithInsertIsReportedAsTableWrite() async throws {
        try await withRole { admin, role, table, open in
            try await drain(admin.execute("GRANT INSERT ON \(table) TO \(role)"))
            let connection = try await open()
            let found = try await MCPPrivilegeCheck.findings(on: connection, driver: .postgres)
            await connection.close()
            #expect(found.contains("table_write"))
        }
    }

    @Test func aSuperuserIsReported() async throws {
        let server = TestServer.postgres!
        let admin = try await PostgresDriverConnection(config: config(user: server.username, password: server.password))
        let found = try await MCPPrivilegeCheck.findings(on: admin, driver: .postgres)
        await admin.close()
        #expect(found.contains("superuser"))
    }
}

@Suite("MCP privilege check on MySQL and MariaDB", .serialized, .enabled(if: TestServer.mysql != nil))
struct MCPPrivilegeCheckMySQLLiveTests {
    private func config(user: String, password: String) -> ConnectionConfig {
        let server = TestServer.mysql!
        return ConnectionConfig(
            driver: .mysql, name: "privilege-check", host: server.host, port: server.port,
            username: user, password: password, database: server.database
        )
    }

    private func withUser(
        _ body: (_ admin: MySQLDriverConnection, _ user: String, _ table: String, _ open: () async throws -> MySQLDriverConnection) async throws -> Void
    ) async throws {
        let server = TestServer.mysql!
        let database = server.database!
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let user = "mcp_ro_\(suffix)"
        let table = "mcp_priv_\(suffix)"
        let password = randomSecret()
        let admin = try await MySQLDriverConnection(config: config(user: server.username, password: server.password))
        do {
            try await drain(admin.execute("CREATE TABLE `\(database)`.`\(table)` (id int)"))
            try await drain(admin.execute("CREATE USER '\(user)'@'%' IDENTIFIED BY '\(password)'"))
            try await drain(admin.execute("GRANT SELECT ON `\(database)`.`\(table)` TO '\(user)'@'%'"))
            let cfg = config(user: user, password: password)
            try await body(admin, user, table) { try await MySQLDriverConnection(config: cfg) }
        } catch {
            await cleanUp(admin, database: database, user: user, table: table)
            throw error
        }
        await cleanUp(admin, database: database, user: user, table: table)
    }

    private func cleanUp(_ admin: MySQLDriverConnection, database: String, user: String, table: String) async {
        _ = try? await drain(admin.execute("DROP USER IF EXISTS '\(user)'@'%'"))
        _ = try? await drain(admin.execute("DROP ROLE IF EXISTS '\(user)_role'"))
        _ = try? await drain(admin.execute("DROP TABLE IF EXISTS `\(database)`.`\(table)`"))
        await admin.close()
    }

    @Test func aSelectOnlyUserHasNoFindings() async throws {
        try await withUser { _, _, _, open in
            let connection = try await open()
            let found = try await MCPPrivilegeCheck.findings(on: connection, driver: .mysql)
            await connection.close()
            #expect(found == [])
        }
    }

    @Test func aUserWithInsertIsReported() async throws {
        try await withUser { admin, user, table, open in
            try await drain(admin.execute("GRANT INSERT ON `\(TestServer.mysql!.database!)`.`\(table)` TO '\(user)'@'%'"))
            let connection = try await open()
            let found = try await MCPPrivilegeCheck.findings(on: connection, driver: .mysql)
            await connection.close()
            #expect(found == ["INSERT"])
        }
    }

    /// MySQL folds a granted role in with SET ROLE ALL; MariaDB has no such
    /// statement, so the check reports that roles were not looked at.
    @Test func aWriteGrantedThroughARoleIsNeverMissed() async throws {
        try await withUser { admin, user, table, open in
            let role = "\(user)_role"
            try await drain(admin.execute("CREATE ROLE '\(role)'"))
            try await drain(admin.execute("GRANT INSERT ON `\(TestServer.mysql!.database!)`.`\(table)` TO '\(role)'"))
            try await drain(admin.execute("GRANT '\(role)' TO '\(user)'@'%'"))
            let connection = try await open()
            let found = try await MCPPrivilegeCheck.findings(on: connection, driver: .mysql)
            await connection.close()
            #expect(found.contains("INSERT") || found.contains("roles_not_checked"))
        }
    }
}
